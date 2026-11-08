import Foundation

/// An owned, supported headless frontend for the existing Hermes profile.
/// Session/history/memory writes remain native; the messaging gateway and OAuth
/// refresh grant stay owned by the user's existing runtime.
@MainActor
final class SharedHermesClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let profileID: String

    private var process: Process?
    private var ownershipPipe: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var webSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var readTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var requestID = 0
    private var ready = false
    private var generation = UUID()
    private var credential = ""
    private var computerUseRelay: ComputerUseLaunchRelay?
    /// Pipe lines leave the main actor, in order; the pipe closes after them.
    private let ownershipWrites = DispatchQueue(label: "NotchCompanion.SharedHermes.ownership")
    /// The frontend registers delegation tools once, when the first session asks
    /// for them: nil once Hermes confirmed them, else why it could not.
    private var delegationTools: Task<String?, Never>?
    private var delegationAck: CheckedContinuation<String?, Never>?
    static let delegationUnavailable = "Hermes did not add Notch Companion's delegation tools, so this session cannot delegate. It works as usual otherwise."

    init(profileID: String? = nil) {
        self.profileID = URL(fileURLWithPath: profileID ?? RuntimeRoute.defaultProfile(.hermes))
            .resolvingSymlinksInPath().path
    }

    /// Kept separate from launching so filesystem boundaries can be tested with
    /// disposable fixtures. Native conversation and memory stores stay writable.
    static func hermesRoot(profile: URL, userHome: URL) -> URL {
        let standard = userHome.appendingPathComponent(".hermes").resolvingSymlinksInPath()
        let selected = profile.resolvingSymlinksInPath()
        if selected.path == standard.path || selected.path.hasPrefix(standard.path + "/") { return standard }
        if selected.deletingLastPathComponent().lastPathComponent == "profiles" {
            return selected.deletingLastPathComponent().deletingLastPathComponent()
        }
        return selected
    }

    static func sharedAuthDirectory(environment: [String: String], userHome: URL) -> URL? {
        guard let value = environment["HERMES_SHARED_AUTH_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value == "~" { return userHome }
        if value.hasPrefix("~/") { return userHome.appendingPathComponent(String(value.dropFirst(2))) }
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: userHome.path, isDirectory: true))
            .absoluteURL.standardizedFileURL
    }

    static func protectionProfile(source: URL, profile: URL, userHome: URL, codexHome: URL? = nil,
                                  sharedAuthDirectory: URL? = nil) -> String {
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var rules = "(version 1)(allow default)"
        let root = hermesRoot(profile: profile, userHome: userHome)
        let profiles = Set([profile, root])
        let immutableTrees = [source, userHome.appendingPathComponent(".codex"), root.appendingPathComponent("shared"),
                              root.appendingPathComponent("tools"), userHome.appendingPathComponent(".hermes/tools"),
                              source.deletingLastPathComponent().appendingPathComponent("tools")]
            + [codexHome, sharedAuthDirectory].compactMap { $0 }
        let immutablePaths = Set(immutableTrees.flatMap { [$0.path, canonicalPath($0.path)] })
        let protectedTrees = immutableTrees
            + profiles.flatMap { [$0.appendingPathComponent("skills"), $0.appendingPathComponent("profiles")] }
        let container = root.appendingPathComponent("profiles")
        let profileContainerPaths = Set([container.path, canonicalPath(container.path)])
        // Foundation's URL canonicalization can shorten /private/var back to
        // /var. Seatbelt compares the kernel path, so use POSIX realpath and
        // resolve the nearest existing ancestor for protected files not yet made.
        for path in Set(protectedTrees.flatMap { [$0.path, canonicalPath($0.path)] }).sorted() {
            // Named profiles keep native stores writable inside root/profiles,
            // while sibling profiles and the selected profile's identity stay protected.
            let selectedPaths = profileContainerPaths.contains(path) && !immutablePaths.contains(path)
                ? Set([profile.path, canonicalPath(profile.path)]).filter { $0.hasPrefix(path + "/") } : []
            let exceptions = selectedPaths.map { "(require-not (subpath \(quote($0))))" }.joined()
            let filter = exceptions.isEmpty ? "(subpath \(quote(path)))" : "(require-all (subpath \(quote(path)))\(exceptions))"
            rules += "(deny file-write* \(filter))"
        }
        // Managed dependency code is immutable; native generation leases live
        // beside each venv and remain writable for process ownership.
        for home in Set([root, userHome.appendingPathComponent(".hermes"), source.deletingLastPathComponent()]) {
            let installs = home.appendingPathComponent("installs")
            for path in Set([installs.path, canonicalPath(installs.path)]) {
                let pattern = "^" + NSRegularExpression.escapedPattern(for: path) + "/[^/]+/environments/[^/]+/venv(/|$)"
                rules += "(deny file-write* (regex \(quote(pattern))))"
            }
        }
        let protectedFiles = profiles.flatMap { profile in
            ["config.yaml", ".env", "auth.json", ".anthropic_oauth.json", "SOUL.md", "gateway.pid", "gateway.lock", "active_profile"]
                .map { profile.appendingPathComponent($0) }
        } + [".claude/.credentials.json", ".claude.json", ".qwen/oauth_creds.json"].map { userHome.appendingPathComponent($0) }
        for path in protectedFiles {
            for resolved in Set([path.path, canonicalPath(path.path)]).sorted() {
                rules += "(deny file-write* (literal \(quote(resolved))))"
            }
        }
        return rules
    }

    private static func canonicalPath(_ path: String) -> String {
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        guard parent != path else { return path }
        let resolvedParent = canonicalPath(parent)
        return (resolvedParent == "/" ? "" : resolvedParent) + "/" + url.lastPathComponent
    }

    static func frontendEnvironment(_ original: [String: String], profile: URL, source: URL,
                                    userHome: URL, credential: String) -> [String: String] {
        let identityKeys: Set<String> = ["HERMES_DESKTOP", "HERMES_GATEWAY", "HERMES_TUI", "HERMES_HOME",
            "HERMES_PROFILE", "HERMES_PROFILE_NAME", "HERMES_CONFIG", "HERMES_CONFIG_PATH", "HERMES_ENV", "HERMES_ENV_PATH",
            "HERMES_SPAWN", "HERMES_SUPERVISED_CHILD", "HERMES_S6_SUPERVISED_CHILD", "HERMES_COMPUTE_HOST_CHILD",
            "HERMES_DELEGATED_CHILD_CONTEXT", "HERMES_CRON_SESSION", "HERMES_SINGLE_QUERY_SESSION", "HERMES_INTERACTIVE",
            "HERMES_EXEC_ASK", "HERMES_PTY_HOST", "HERMES_CWD", "HERMES_PLATFORM", "HERMES_WEB_DIST", "HERMES_SERVE_HEADLESS",
            "HERMES_DASHBOARD_SESSION_TOKEN", "HERMES_DASHBOARD_WS_HOST", "HERMES_KANBAN_TASK", "HERMES_KANBAN_RUN_ID",
            "HERMES_KANBAN_CLAIM_LOCK", "HERMES_KANBAN_GOAL_MODE", "HERMES_KANBAN_GOAL_MAX_TURNS",
            "_HERMES_GATEWAY", "_HERMES_GATEWAY_BREAKAWAY", "HERMES_ACTION_ID", "HERMES_NONINTERACTIVE", "HERMES_TENANT",
            "HERMES_IRON_PROXY_NONCE", "HERMES_IRON_PROXY_MGMT_KEY",
            "PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV", "HERMES_RUNTIME_DIR", "HERMES_INSTALL_ROOT"]
        let identityPrefixes = ["HERMES_DESKTOP_", "HERMES_GATEWAY_", "HERMES_SESSION_", "HERMES_PARENT_",
                                "HERMES_UPDATE_", "HERMES_TUI_", "CODEX_"]
        var result = original.filter { key, _ in
            !identityKeys.contains(key) && !identityPrefixes.contains(where: key.hasPrefix)
        }
        result["HERMES_HOME"] = profile.path
        result["HERMES_DASHBOARD_SESSION_TOKEN"] = credential
        result["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        result["PYTHONDONTWRITEBYTECODE"] = "1"
        result["PYTHONUNBUFFERED"] = "1"
        result["PATH"] = [source.appendingPathComponent("venv/bin").path,
                          source.appendingPathComponent(".venv/bin").path,
                          userHome.appendingPathComponent(".local/bin").path,
                          "/opt/homebrew/bin", "/usr/local/bin",
                          original["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        return result
    }

    static func readyPort(in line: String) -> Int? {
        guard let range = line.range(of: #"HERMES_(?:BACKEND|DASHBOARD)_READY port=([0-9]+)"#,
                                     options: .regularExpression),
              let number = line[range].split(separator: "=").last,
              let port = Int(number), (1...65535).contains(port) else { return nil }
        return port
    }

    func connect() async throws {
        if ready { return }
        guard process == nil else { throw HermesClientError.unavailable("Hermes is already connecting.") }
        let files = FileManager.default
        let userHome = files.homeDirectoryForCurrentUser
        let profile = URL(fileURLWithPath: profileID)
        let installation = try RuntimeInstallation.hermes(environment: ProcessInfo.processInfo.environment,
                                                          userHome: userHome, configuredSource: RuntimeLocation.hermesSource.saved())
        let source = installation.source, python = installation.python
        let config = profile.appendingPathComponent("config.yaml").resolvingSymlinksInPath()
        guard (try? config.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              files.isReadableFile(atPath: config.path) else {
            throw HermesClientError.unavailable("The saved Hermes profile is unavailable at \(profile.path). Restore that profile before resuming its conversations.")
        }
        guard let worker = CompanionResources.bundle.url(forResource: "hermes_frontend", withExtension: "py")
                ?? CompanionResources.bundle.url(forResource: "hermes_frontend", withExtension: "py", subdirectory: "Resources") else {
            throw HermesClientError.unavailable("The supported Hermes frontend launcher is missing. Rebuild the application.")
        }
        guard files.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw HermesClientError.unavailable("The macOS protection helper is unavailable. Hermes was not started.")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", Self.protectionProfile(source: source, profile: profile, userHome: userHome,
                                                       codexHome: URL(fileURLWithPath: RuntimeRoute.defaultProfile(.codex)),
                                                       sharedAuthDirectory: Self.sharedAuthDirectory(environment: ProcessInfo.processInfo.environment, userHome: userHome)),
                           python.path, "-I", "-B", "-u", worker.path, "--source", source.path, "--profile-home", profile.path]
        credential = UUID().uuidString + UUID().uuidString
        let relay = try ComputerUseLaunchRelay()
        computerUseRelay = relay
        var environment = Self.frontendEnvironment(ProcessInfo.processInfo.environment, profile: profile,
                                                   source: source, userHome: userHome, credential: credential)
        environment["NOTCH_CUA_RELAY_DIR"] = relay.directory.path
        child.environment = environment
        // Do not use the installation as a project cwd. Session creation supplies
        // the user's chosen workspace explicitly through the native RPC.
        child.currentDirectoryURL = userHome
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        ownershipPipe = input.fileHandleForWriting
        stdout = output.fileHandleForReading
        stderr = errors.fileHandleForReading
        process = child
        let runID = UUID()
        generation = runID
        for (handle, isError) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
            handle.readabilityHandler = { [weak self] pipe in
                let bytes = pipe.availableData
                if bytes.isEmpty { pipe.readabilityHandler = nil; return }
                Task { @MainActor [weak self] in self?.receiveStartup(bytes, isError: isError, generation: runID) }
            }
        }
        child.terminationHandler = { [weak self] exited in
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                self.fail(HermesClientError.unavailable("The Hermes frontend stopped (exit \(exited.terminationStatus)). Saved conversations remain in Hermes; reconnect to continue."))
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyWaiter = continuation
                startupTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(70)) } catch { return }
                    guard let self, self.generation == runID, !self.ready else { return }
                    self.fail(HermesClientError.timedOut("frontend startup"))
                }
                do { try child.run() }
                catch { fail(HermesClientError.unavailable("The protected Hermes frontend could not be launched.")) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                self.fail(CancellationError())
            }
        }
        // Newer Hermes fails approvals/questions at once for a WebSocket client
        // that never says it answers server→client requests. Older builds reject
        // the unknown method and keep their *.request events, so ignore failure.
        _ = try? await request("client.capabilities", params: ["server_requests": true])
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard ready, let socket else { throw HermesClientError.disconnected }
        if method == "session.create" || method == "session.resume", let delegation = params["delegation"] as? [String: Any] {
            let failure = await registerDelegationTools()
            let result = try await request(method, params: params.filter { $0.key != "delegation" })
            if let sid = result["session_id"] as? String {
                if let failure { onEvent?("runtime.notice", ["session_id": sid, "message": failure]) }
                // The token crosses only the ownership pipe and stays in the frontend's memory.
                else { writeOwnership(Self.bindMessage(session: sid, delegation: delegation)) }
            }
            return result
        }
        if method == "prompt.steer" {
            guard (params["images"] as? [String] ?? []).isEmpty else { throw BusyInputRejection(message: "Queue images for Hermes with Command–Return.") }
            let result = try await request("session.steer", params: ["session_id": params["session_id"] ?? "", "text": params["text"] ?? ""])
            guard result["status"] as? String == "queued" else {
                throw BusyInputRejection(message: "Hermes could not steer this turn. Use Command–Return to queue your message.")
            }
            return ["steered": true]
        }
        if method == "runtime.models" {
            let result = try await request("model.options", params: ["explicit_only": true])
            return ["catalog": RuntimeModelCatalog.hermes(result)]
        }
        if method == "session.model.set" {
            guard let sid = params["session_id"] as? String, !sid.isEmpty,
                  let name = params["model"] as? String else { throw AppError("Choose a session and model first.") }
            let choice = RuntimeModelChoice(model: name, provider: params["provider"] as? String, reasoningEffort: params["reasoning_effort"] as? String)
            return try await Self.setSessionModel(choice, sessionID: sid,
                confirmed: params["confirmed"] as? Bool ?? false, request: request)
        }
        switch Self.serverRequestAnswer(method, params) {
        case .respond(let frame)?:
            try await send(frame, on: socket)
            return ["resolved": true]
        case .call(let name, let values)?:
            return try await request(name, params: values)
        case nil: break
        }
        requestID += 1
        let identifier = requestID
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": identifier, "method": method, "params": Self.nativeParams(method, params)]
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let text = String(data: data, encoding: .utf8) else { throw HermesClientError.unavailable("The Hermes request could not be encoded.") }
        let runID = generation
        let result = try await withCheckedThrowingContinuation { continuation in
            pending[identifier] = continuation
            timeouts[identifier] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                guard let self, self.generation == runID else { return }
                self.timeouts.removeValue(forKey: identifier)
                self.pending.removeValue(forKey: identifier)?.resume(throwing: HermesClientError.timedOut(method))
            }
            Task { @MainActor [weak self] in
                do { try await socket.send(.string(text)) }
                catch {
                    guard let self, self.generation == runID else { return }
                    self.fail(HermesClientError.disconnected)
                }
            }
        }
        // Questions still waiting from before a reconnect are re-delivered with
        // the resume reply (newer Hermes); the router replays them once bound.
        if method == "session.resume" {
            for open in result["open_requests"] as? [[String: Any]] ?? [] {
                guard let id = open["id"] as? String, let name = open["method"] as? String else { continue }
                receiveServerRequest(id: id, method: name, params: open["params"] as? [String: Any] ?? [:])
            }
        }
        return result
    }

    /// Fields other adapters consume. Hermes never read them, and builds with
    /// typed wire contracts reject unknown keys instead of ignoring them.
    static let companionOnlyParams = ["project_trusted", "activity_unverified", "pending_turn_id", "turn_id", "delegation", "native_submission_attempted"]

    static func nativeParams(_ method: String, _ params: [String: Any]) -> [String: Any] {
        var values = params
        for key in companionOnlyParams { values.removeValue(forKey: key) }
        // Resume reopens the native session's own folder; AppModel checks it.
        if method == "session.resume" { values.removeValue(forKey: "cwd") }
        if method == "session.create" {
            values["source"] = "notch_companion"
            values["follow_profile_config"] = true
        }
        return values
    }

    enum ServerRequestAnswer {
        case respond([String: Any])
        case call(String, [String: Any])
    }

    /// Newer Hermes asks through JSON-RPC server→client requests (`srq-…` ids)
    /// instead of `*.request` events and `*.respond` methods. Approvals settle
    /// with a response frame; each clarify answer locks one question, and the
    /// last lock resolves the request. Older request IDs keep their methods.
    static func serverRequestAnswer(_ method: String, _ params: [String: Any]) -> ServerRequestAnswer? {
        guard let id = params["request_id"] as? String, id.hasPrefix("srq-") else { return nil }
        switch method {
        case "approval.respond":
            return .respond(["jsonrpc": "2.0", "id": id, "result": ["choice": params["choice"] as? String ?? "deny"]])
        case "clarify.respond":
            return .call("clarify.lock", ["request_id": id, "question_id": params["question_id"] as? String ?? "",
                                          "answer": params["answers"] ?? params["answer"] ?? ""])
        default: return nil
        }
    }

    enum ServerRequestOutcome {
        case event(String, [String: Any])
        case decline([String: Any], notice: String)
    }

    /// Present supported server requests as the companion's existing events.
    /// Everything else is declined at once with the protocol's unhandled-method
    /// reply, so the agent does not wait out a deadline for an invisible card.
    static func serverRequestOutcome(id: String, method: String, params: [String: Any]) -> ServerRequestOutcome {
        var payload = params
        payload["request_id"] = id
        switch method {
        case "approval":
            return .event("approval.request", payload)
        case "clarify":
            // A reconnect replay carries answers already locked; ask only the rest.
            let locked = params["answers"] as? [String: Any] ?? [:]
            let questions = params["questions"] as? [[String: Any]] ?? []
            payload["questions"] = questions.filter { locked[$0["qid"] as? String ?? ""] == nil }
            payload.removeValue(forKey: "answers")
            return .event("clarify.request", payload)
        default:
            let secure = ["sudo", "secret", "display.install.sudo"].contains(method) || method.hasPrefix("vault.")
            let notice = secure
                ? "Hermes requested secure input that this companion cannot collect. The request was declined; use your existing Hermes to configure the required access."
                : "Hermes requested a desktop feature that this companion does not provide. Continue in your existing Hermes frontend for that feature."
            return .decline(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": notice]], notice: notice)
        }
    }

    private func receiveServerRequest(id: String, method: String, params: [String: Any]) {
        switch Self.serverRequestOutcome(id: id, method: method, params: params) {
        case .event(let name, let payload):
            onEvent?(name, payload)
        case .decline(let frame, let notice):
            onEvent?("runtime.notice", ["session_id": params["session_id"] ?? "", "message": notice])
            guard let socket else { return }
            Task { @MainActor [weak self] in try? await self?.send(frame, on: socket) }
        }
    }

    private func send(_ frame: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let text = String(data: data, encoding: .utf8) else { throw HermesClientError.unavailable("The Hermes reply could not be encoded.") }
        let runID = generation
        do { try await socket.send(.string(text)) }
        catch {
            if generation == runID { fail(HermesClientError.disconnected) }
            throw HermesClientError.disconnected
        }
    }

    static func setSessionModel(_ choice: RuntimeModelChoice, sessionID: String, confirmed: Bool,
                               request: (String, [String: Any]) async throws -> [String: Any]) async throws -> [String: Any] {
        guard let value = choice.hermesSessionValue else { throw AppError("Hermes returned a model identifier that cannot be selected safely.") }
        // Use the configured catalog, not a live session's accidentally rerouted
        // provider, so affected conversations can switch back without losing history.
        let catalog = RuntimeModelCatalog.hermes(try await request("model.options", ["explicit_only": true]))
        guard choice.provider == catalog.defaultModel?.provider,
              catalog.contains(choice) else {
            throw AppError("That model is no longer available from your configured Hermes provider. Refresh the model picker and choose again.")
        }
        // Explicit --provider skips Hermes's native deferred-build wait. Observe
        // the supported live-session payload before switching so that build cannot
        // overwrite the selected model. No prompt or profile write is needed.
        let deadline = Date().addingTimeInterval(30)
        while true {
            try Task.checkCancellation()
            let snapshot = try await request("session.activate", ["session_id": sessionID, "omit_messages": true])
            if snapshot["running"] as? Bool == true { throw NativeSessionBusy() }
            if let info = snapshot["info"] as? [String: Any], info["lazy"] as? Bool != true { break }
            guard Date() < deadline else { throw HermesClientError.timedOut("Hermes session initialization") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = try await request("config.set", ["session_id": sessionID, "key": "model", "value": value,
            "confirm_expensive_model": confirmed])
        if result["confirm_required"] as? Bool == true { return result }
        if result["deferred"] as? Bool == true { throw NativeSessionBusy() }
        let snapshot = try await request("session.activate", ["session_id": sessionID, "omit_messages": true])
        let info = snapshot["info"] as? [String: Any] ?? [:]
        guard info["model"] as? String == choice.model, info["provider"] as? String == choice.provider else {
            throw AppError("Hermes did not apply the selected model and provider. Your message has not been sent; refresh the model picker and try again.")
        }
        if let effort = choice.reasoningEffort {
            let applied = try await request("config.set", ["session_id": sessionID, "key": "reasoning", "value": effort, "scope": "session"])
            guard applied["value"] as? String == effort else {
                throw AppError("Hermes did not confirm the reasoning effort. Your message has not been sent.")
            }
        }
        return result
    }

    func disconnect() {
        cleanup(error: HermesClientError.disconnected)
        onConnectionChange?(false, nil)
    }

    /// Sends the companion's tools once and waits for the frontend to confirm
    /// them before a session is opened, so its first agent already has them.
    private func registerDelegationTools() async -> String? {
        if let delegationTools { return await delegationTools.value }
        let runID = generation
        let task = Task { @MainActor [weak self] () -> String? in
            await withCheckedContinuation { continuation in
                guard let self, self.generation == runID else {
                    return continuation.resume(returning: SharedHermesClient.delegationUnavailable)
                }
                self.delegationAck = continuation
                self.writeOwnership(SharedHermesClient.toolsMessage)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, self.generation == runID else { return }
                    self.settleDelegationTools(SharedHermesClient.delegationUnavailable)
                }
            }
        }
        delegationTools = task
        return await task.value
    }

    /// What `hermes_frontend.py` reads from the ownership pipe, one JSON line each.
    static var toolsMessage: [String: Any] { ["tools": Delegation.tools, "instructions": Delegation.instructions] }
    static func bindMessage(session: String, delegation: [String: Any]) -> [String: Any] {
        ["bind": session, "url": delegation["url"] ?? "", "token": delegation["token"] ?? ""]
    }
    /// The frontend's `NOTCH_DELEGATION` answer: nil once the tools are in place, else the notice.
    static func delegationFailure(_ payload: [String: Any]) -> String? {
        payload["ready"] as? Bool == true ? nil : payload["message"] as? String ?? delegationUnavailable
    }

    private func settleDelegationTools(_ failure: String?) {
        delegationAck?.resume(returning: failure)
        delegationAck = nil
    }

    private func writeOwnership(_ message: [String: Any]) {
        guard let pipe = ownershipPipe, var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        ownershipWrites.async { try? pipe.write(contentsOf: line) }
    }

    private func receiveStartup(_ bytes: Data, isError: Bool, generation runID: UUID) {
        guard generation == runID else { return }
        var buffer = isError ? stderrBuffer : stdoutBuffer
        buffer.append(bytes)
        // Backend diagnostics can contain private data. Parse only readiness and
        // our explicit launcher error; drop everything else without persistence.
        if buffer.count > 1024 * 1024 { buffer.removeAll() }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            if line.hasPrefix("NOTCH_CUA_LAUNCH "),
               let data = line.dropFirst("NOTCH_CUA_LAUNCH ".count).data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let relay = computerUseRelay {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == runID else { return }
                    // Invalid launches never become arbitrary process execution.
                    // Hermes's original readiness timeout reports tool failure.
                    try? await relay.launch(payload)
                }
            } else if line.hasPrefix("NOTCH_DELEGATION "),
                      let data = line.dropFirst("NOTCH_DELEGATION ".count).data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settleDelegationTools(Self.delegationFailure(payload))
            } else if let port = Self.readyPort(in: line), socket == nil {
                openSocket(port: port, generation: runID)
            } else if line.hasPrefix("NOTCH_FRONTEND_ERROR "),
                      let data = line.dropFirst("NOTCH_FRONTEND_ERROR ".count).data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = payload["message"] as? String {
                fail(HermesClientError.unavailable(message))
                return
            }
        }
        if isError { stderrBuffer = buffer } else { stdoutBuffer = buffer }
    }

    private func openSocket(port: Int, generation runID: UUID) {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/api/ws"
        components.queryItems = [URLQueryItem(name: "token", value: credential)]
        guard let url = components.url else { fail(HermesClientError.disconnected); return }
        var request = URLRequest(url: url)
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        webSession = session
        let connection = session.webSocketTask(with: request)
        connection.maximumMessageSize = 32 * 1024 * 1024
        socket = connection
        connection.resume()
        readTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    guard let self, self.generation == runID else { return }
                    switch message {
                    case .string(let text): self.receiveFrame(Data(text.utf8))
                    case .data(let data): self.receiveFrame(data)
                    @unknown default: break
                    }
                }
            } catch {
                guard let self, self.generation == runID else { return }
                self.fail(HermesClientError.unavailable("Hermes's authenticated connection closed. Reconnect to resume your saved conversations."))
            }
        }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.generation == runID else { return }
                // The native RPC heartbeat updates frontend client liveness;
                // transport-level WS pings alone do not update that marker.
                do { _ = try await self.request("gateway.ping", params: [:]) }
                catch {
                    guard self.generation == runID else { return }
                    self.fail(HermesClientError.disconnected)
                    return
                }
            }
        }
    }

    private func receiveFrame(_ data: Data) {
        // The native transport normally sends one JSON object per WS message;
        // accepting newline batches preserves the documented stdio-equivalent wire.
        for line in data.split(separator: 0x0A) {
            guard let frame = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if frame["method"] as? String == "event", let params = frame["params"] as? [String: Any],
               let type = params["type"] as? String {
                var payload = params["payload"] as? [String: Any] ?? [:]
                payload["session_id"] = params["session_id"] as? String ?? ""
                if type == "gateway.ready", !ready {
                    ready = true
                    credential = ""
                    startupTask?.cancel()
                    startupTask = nil
                    readyWaiter?.resume()
                    readyWaiter = nil
                    onConnectionChange?(true, nil)
                }
                if let reply = Self.unavailableReply(type: type, payload: payload) {
                    onEvent?("runtime.notice", ["session_id": payload["session_id"] ?? "", "message": reply.notice])
                    Task { @MainActor [weak self] in _ = try? await self?.request(reply.method, params: reply.params) }
                } else if type == "request.cancel" {
                    // One withdrawal event replaces the older per-kind *.expire events.
                    onEvent?("clarify.expire", ["session_id": payload["session_id"] ?? "", "request_id": payload["id"] ?? ""])
                } else {
                    onEvent?(type, payload)
                }
            } else if let method = frame["method"] as? String, let id = frame["id"] as? String {
                receiveServerRequest(id: id, method: method, params: frame["params"] as? [String: Any] ?? [:])
            } else if let id = frame["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if let error = frame["error"] as? [String: Any] {
                    continuation.resume(throwing: HermesClientError.rpc(error["code"] as? Int ?? -1,
                        error["message"] as? String ?? "Hermes request failed."))
                } else { continuation.resume(returning: frame["result"] as? [String: Any] ?? [:]) }
            }
        }
    }

    /// Match the installed frontend's late-response schema. Desktop-specific
    /// bridges must settle immediately instead of hanging a tool for 30–600s.
    static func unavailableReply(type: String, payload: [String: Any])
        -> (method: String, params: [String: Any], notice: String)? {
        let fields = ["sudo.request": "password", "secret.request": "value",
                      "terminal.read.request": "text", "preview.read.request": "text",
                      "preview.act.request": "text", "window.read.request": "text",
                      "tour.request": "text", "mcp.setup.request": "result"]
        guard let field = fields[type], let requestID = payload["request_id"] as? String else { return nil }
        let secure = type == "sudo.request" || type == "secret.request"
        let notice = secure
            ? "Hermes requested secure input that this companion cannot collect. The request was declined; use your existing Hermes to configure the required access."
            : "Hermes requested a desktop feature that this companion does not provide. Continue in your existing Hermes frontend for that feature."
        var response: [String: Any] = ["request_id": requestID]
        response["session_id"] = payload["session_id"]
        if secure {
            response[field] = ""
        } else {
            let result = ["status": type == "mcp.setup.request" ? "declined" : "unavailable", "error": notice]
            let json = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            response[field] = json.flatMap { String(data: $0, encoding: .utf8) } ?? notice
        }
        return (String(type.dropLast("request".count)) + "respond", response, notice)
    }

    private func fail(_ error: Error) {
        cleanup(error: error)
        onConnectionChange?(false, error.localizedDescription)
    }

    private func cleanup(error: Error) {
        generation = UUID()
        computerUseRelay?.stop()
        computerUseRelay = nil
        ready = false
        credential = ""
        startupTask?.cancel()
        startupTask = nil
        readTask?.cancel()
        readTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for waiter in pending.values { waiter.resume(throwing: error) }
        pending.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        webSession?.invalidateAndCancel()
        webSession = nil
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        stdout = nil
        stderr = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        settleDelegationTools(Self.delegationUnavailable)
        delegationTools = nil
        // This pipe owns only our frontend; neither this path nor SIGTERM ever
        // addresses the user's messaging gateway. The worker handles EOF too.
        let pipe = ownershipPipe
        ownershipWrites.async { try? pipe?.close() }
        ownershipPipe = nil
        if let child = process {
            child.terminationHandler = nil
            if child.isRunning {
                // EOF gives the worker time to stop its private CUA daemons
                // before Hermes's SIGTERM handler bypasses Python atexit.
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
    }
}
