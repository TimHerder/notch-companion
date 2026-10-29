import Foundation

enum CodexClientError: LocalizedError {
    case unavailable(String)
    case rpc(Int, String)
    case disconnected
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .rpc(_, let message): return message
        case .disconnected: return "Codex disconnected. Reconnect to continue your saved threads."
        case .timedOut(let method): return "Codex did not respond to \(method). Reconnect to check the saved thread before retrying."
        }
    }
}

/// A supported app-server client with its own stdio process and the user's
/// existing Codex home. Native Codex owns configuration, auth, tools and storage.
/// Closing this client never stops another frontend's process.
@MainActor
final class CodexClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let profileID: String

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var ready = false
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var state = CodexProtocolState()
    private var images: [String: [String]] = [:]
    private var titles: [String: String] = [:]
    private var selectedModels: [String: RuntimeModelChoice] = [:]
    private var permissionModes: [String: PermissionMode] = [:]
    /// Each thread's own approval/sandbox policies and model as opened.
    private var inheritedPolicies: [String: (approval: Any, sandbox: Any)] = [:]
    private var threadModels: [String: String] = [:]
    /// turn/start overrides persist for later turns; these threads carry one.
    private var policyOverridden = Set<String>()
    private var planOverridden = Set<String>()
    /// Delegation instructions per thread, added to its first turn in this process.
    private var delegationInstructions: [String: String] = [:]
    private var instructedThreads = Set<String>()
    private let writeQueue = DispatchQueue(label: "NotchCompanion.Codex.write")
    private let executableOverride: URL?

    init(profileID: String? = nil, executable: URL? = nil) {
        self.executableOverride = executable
        self.profileID = URL(fileURLWithPath: profileID ?? RuntimeRoute.defaultProfile(.codex)).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func childEnvironment(_ environment: [String: String], profileID: String) -> [String: String] {
        var result = environment
        for key in ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_APP_TOOLS_PIPE_PATH"] { result.removeValue(forKey: key) }
        result["CODEX_HOME"] = profileID
        let home = FileManager.default.homeDirectoryForCurrentUser
        result["PATH"] = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        return result
    }

    /// Only the companion's own server is overridden, so the user's MCP servers stay.
    static func delegationConfig(_ delegation: [String: Any]) -> [String: Any] {
        ["mcp_servers.\(DelegationServer.name)": ["url": delegation["url"] as? String ?? "", "tool_timeout_sec": 65 * 60,
                                                   "http_headers": ["Authorization": "Bearer " + (delegation["token"] as? String ?? "")]]]
    }

    func connect() async throws {
        if ready { return }
        guard process == nil else { throw CodexClientError.unavailable("Codex is already connecting.") }
        let environment = Self.childEnvironment(ProcessInfo.processInfo.environment, profileID: profileID)
        let executable = try RuntimeInstallation.codex(environment: ProcessInfo.processInfo.environment,
                                                       userHome: FileManager.default.homeDirectoryForCurrentUser,
                                                       configuredExecutable: executableOverride?.path ?? RuntimeLocation.codexExecutable.saved())
        let child = Process()
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.environment = environment
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        let runID = UUID()
        generation = runID
        process = child
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        errorOutput = stderrPipe.fileHandleForReading
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { Task { @MainActor [weak self] in self?.receive(data, generation: runID) } }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            // Tool/provider diagnostics can contain credentials or conversation
            // text. Drain without persisting or exposing raw stderr.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                self.fail(CodexClientError.unavailable("Codex stopped (exit \(terminated.terminationStatus)). Reconnect to resume saved threads."))
            }
        }
        do {
            try child.run()
            _ = try await rpc("initialize", ["clientInfo": ["name": "notch_companion", "title": "Notch Companion", "version": "0.2.0"], "capabilities": ["experimentalApi": true]])
            try write(["method": "initialized", "params": [:]])
            ready = true
            onConnectionChange?(true, nil)
        } catch {
            fail(error)
            throw error
        }
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard ready else { throw CodexClientError.disconnected }
        if method == "runtime.models" {
            var arguments: [String: Any] = ["includeLayers": false]
            if let cwd = params["cwd"] as? String, !cwd.isEmpty { arguments["cwd"] = cwd }
            let config = try await rpc("config/read", arguments)["config"] as? [String: Any] ?? [:]
            var rows: [[String: Any]] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var page: [String: Any] = ["limit": 100, "includeHidden": false]
                if let cursor { page["cursor"] = cursor }
                let result = try await rpc("model/list", page)
                rows += result["data"] as? [[String: Any]] ?? []
                cursor = result["nextCursor"] as? String
                if let cursor, !seen.insert(cursor).inserted { throw CodexClientError.unavailable("Codex repeated a model catalog page. Try refreshing.") }
            } while cursor != nil
            return ["catalog": RuntimeModelCatalog.codex(config: config, rows: rows)]
        }
        if method == "runtime.rateLimits" {
            return ["limits": RuntimeRateLimit.codex(try await rpc("account/rateLimits/read", ["excludeResetCreditDetails": true]))]
        }
        if method == "session.create" {
            var arguments: [String: Any] = ["ephemeral": false, "threadSource": "notch_companion", "serviceName": "notch_companion", "historyMode": "legacy"]
            if let cwd = params["cwd"] as? String { arguments["cwd"] = cwd }
            // Deliberately omit model, instructions, approval and permissions
            // overrides: app-server loads the established effective profile.
            let delegation = params["delegation"] as? [String: Any]
            if let delegation { arguments["config"] = Self.delegationConfig(delegation) }
            let response = try await rpc("thread/start", arguments)
            let thread = response["thread"] as? [String: Any] ?? [:]
            let id = try state.register(thread)
            delegationInstructions[id] = delegation?["instructions"] as? String
            state.tokenTotals[id] = 0
            remember(id, response)
            if let title = params["title"] as? String, !title.isEmpty {
                titles[id] = title
                // Naming must not orphan a successfully created native thread.
                do { _ = try await rpc("thread/name/set", ["threadId": id, "name": title]) }
                catch { onEvent?("runtime.notice", ["session_id": id, "message": "Codex saved the thread, but its title could not be updated."]) }
            }
            return sessionResult(thread, response: response)
        }
        if method == "session.resume" {
            guard let id = params["session_id"] as? String, !id.isEmpty else { throw CodexClientError.unavailable("Missing saved Codex thread ID.") }
            var arguments: [String: Any] = ["threadId": id]
            let delegation = params["delegation"] as? [String: Any]
            if let delegation { arguments["config"] = Self.delegationConfig(delegation) }
            let response = try await rpc("thread/resume", arguments)
            let thread = response["thread"] as? [String: Any] ?? [:]
            guard thread["id"] as? String == id else { throw CodexClientError.unavailable("Codex resumed a different thread; the saved conversation was not changed.") }
            if let instructions = delegation?["instructions"] as? String { delegationInstructions[id] = instructions }
            _ = try state.register(thread)
            remember(id, response)
            return sessionResult(thread, response: response)
        }
        let sid = params["session_id"] as? String ?? ""
        guard state.ownedThreads.contains(sid) else { throw CodexClientError.unavailable("This Codex thread is not registered with the companion.") }
        switch method {
        case "session.model.set":
            guard state.activeTurns[sid] == nil, !state.startingThreads.contains(sid),
                  !state.parents.contains(where: { $0.value == sid && state.activeTurns[$0.key] != nil }) else {
                throw CodexClientError.unavailable("Wait for this session and its delegated work before changing models.")
            }
            guard let model = params["model"] as? String, !model.isEmpty else { throw CodexClientError.unavailable("Choose a model first.") }
            // turn/start is the native model override API. Stage without sending
            // or changing the user's global configuration.
            selectedModels[sid] = RuntimeModelChoice(model: model, reasoningEffort: params["reasoning_effort"] as? String)
            return [:]
        case "session.permission.set":
            guard state.activeTurns[sid] == nil, !state.startingThreads.contains(sid),
                  !state.parents.contains(where: { $0.value == sid && state.activeTurns[$0.key] != nil }) else {
                throw CodexClientError.unavailable("Wait for this session and its delegated work before changing permissions.")
            }
            // Staged like the model: turn/start carries it, nothing is sent now.
            if let raw = params["mode"] as? String {
                guard let mode = PermissionMode(rawValue: raw) else { throw CodexClientError.unavailable("Codex does not offer this permission mode.") }
                permissionModes[sid] = mode
            } else { permissionModes.removeValue(forKey: sid) }
            return [:]
        case "file.attach", "image.attach":
            guard let path = params["path"] as? String else { throw CodexClientError.unavailable("Missing attachment path.") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard properties?.isRegularFile == true, properties?.isReadable == true else {
                throw CodexClientError.unavailable("The attachment \(url.lastPathComponent) is no longer readable.")
            }
            if method == "image.attach" {
                if !(images[sid] ?? []).contains(url.path) { images[sid, default: []].append(url.path) }
                return ["path": url.path]
            }
            // Non-image files are native local path references. Codex reads
            // them using its configured tools and existing access policy.
            let escapedPath = String(data: try JSONSerialization.data(withJSONObject: [url.path]), encoding: .utf8) ?? url.path
            return ["ref_text": "Attached local file (read using your normal file tools): " + escapedPath]
        case "image.detach":
            if let path = params["path"] as? String { images[sid]?.removeAll { $0 == path } }
            return ["detached": true]
        case "prompt.submit":
            guard state.activeTurns[sid] == nil, !state.startingThreads.contains(sid),
                  !state.parents.contains(where: { $0.value == sid && state.activeTurns[$0.key] != nil }) else {
                throw CodexClientError.unavailable("This Codex session or one of its delegated agents is still working. Wait or stop it before sending another message.")
            }
            state.startingThreads.insert(sid)
            let staged = images[sid] ?? []
            var inputs: [[String: Any]] = [["type": "text", "text": params["text"] as? String ?? ""]]
            inputs += staged.map { ["type": "localImage", "path": $0] }
            do {
                var arguments: [String: Any] = ["threadId": sid, "input": inputs, "clientUserMessageId": params["turn_id"] as? String ?? UUID().uuidString]
                let selectedModel = selectedModels[sid]
                let permissionMode = permissionModes[sid]
                if let selectedModel {
                    arguments["model"] = selectedModel.model
                    if let effort = selectedModel.reasoningEffort { arguments["effort"] = effort }
                }
                arguments.merge(permissionArguments(sid, model: selectedModel)) { _, new in new }
                // Additive context, as T3 Code sends it: the profile's instructions stay.
                let instruct = delegationInstructions[sid].flatMap { instructedThreads.contains(sid) ? nil : $0 }
                if let instruct { arguments["additionalContext"] = ["notch_delegation": ["kind": "application", "value": instruct]] }
                let result = try await rpc("turn/start", arguments)
                // A rejected turn did not apply its reset. Keep the previous
                // override pending until the native turn accepts these arguments.
                if arguments["sandboxPolicy"] != nil, permissionMode == nil || permissionMode == .plan {
                    policyOverridden.remove(sid)
                }
                if let collaboration = arguments["collaborationMode"] as? [String: Any], collaboration["mode"] as? String == "default" {
                    planOverridden.remove(sid)
                }
                if instruct != nil { instructedThreads.insert(sid) }
                let turn = result["turn"] as? [String: Any] ?? [:]
                if turn["status"] as? String == "inProgress", let id = turn["id"] as? String,
                   !state.completedTurns.contains(sid + ":" + id) { state.activeTurns[sid] = id }
                state.startingThreads.remove(sid)
                images[sid]?.removeAll { staged.contains($0) }
                return ["accepted": true, "turn_id": turn["id"] as? String ?? ""]
            } catch {
                // A rejected RPC did not start a turn. A lost response is
                // ambiguous; block a duplicate until reconnect/resume checks it.
                if case CodexClientError.rpc = error { state.startingThreads.remove(sid) }
                throw error
            }
        case "prompt.steer":
            // Input into the running turn; a turn that already ended rejects it.
            guard let turn = state.activeTurns[sid] else { throw BusyInputRejection(message: "This Codex thread has no running turn to steer.") }
            var input: [[String: Any]] = [["type": "text", "text": params["text"] as? String ?? ""]]
            for path in params["images"] as? [String] ?? [] {
                do { _ = try ClaudeClient.attachment(["path": path]) }
                catch { throw BusyInputRejection(message: error.localizedDescription) }
                input.append(["type": "localImage", "path": path])
            }
            let result = try await rpc("turn/steer", ["threadId": sid, "expectedTurnId": turn, "input": input,
                                                      "clientUserMessageId": params["turn_id"] as? String ?? UUID().uuidString])
            return ["steered": true, "turn_id": result["turnId"] as? String ?? turn]
        case "session.interrupt":
            let threads = [sid] + state.parents.filter { $0.value == sid }.map(\.key)
            for thread in threads {
                if let turn = state.activeTurns[thread] { _ = try await rpc("turn/interrupt", ["threadId": thread, "turnId": turn]) }
            }
            return ["interrupted": true]
        case "approval.respond", "clarify.respond":
            let requestID = params["request_id"] as? String ?? ""
            let requestThread = state.requests[requestID]?.threadID
            if let reply = try state.answer(params, approval: method == "approval.respond") {
                try write(reply)
                if let requestThread, requestThread != sid {
                    onEvent?("subagent.thinking", ["session_id": sid, "subagent_id": requestThread, "status": "working"])
                }
            }
            return ["resolved": true]
        case "session.rename":
            let title = params["title"] as? String ?? ""
            _ = try await rpc("thread/name/set", ["threadId": sid, "name": title])
            titles[sid] = title
            return ["renamed": true]
        default: throw CodexClientError.unavailable("Codex does not support \(method) through this companion.")
        }
    }

    private func remember(_ id: String, _ response: [String: Any]) {
        if let approval = response["approvalPolicy"], let sandbox = response["sandbox"] { inheritedPolicies[id] = (approval, sandbox) }
        if let model = response["model"] as? String, !model.isEmpty { threadModels[id] = model }
    }

    /// The staged mode as turn/start overrides. Inherit sends the thread's own
    /// policies once after an override, then nothing.
    private func permissionArguments(_ sid: String, model selected: RuntimeModelChoice?) -> [String: Any] {
        let mode = permissionModes[sid]
        var arguments: [String: Any] = [:]
        let inherited = inheritedPolicies[sid]
        switch mode {
        case .ask?, .autoEdit?, .fullAccess?:
            // Auto-edit keeps the profile's own workspace-write roots and network setting.
            let workspace = (inherited?.sandbox as? [String: Any])?["type"] as? String == "workspaceWrite" ? inherited!.sandbox : ["type": "workspaceWrite"]
            arguments = mode == .ask ? ["approvalPolicy": "on-request", "sandboxPolicy": ["type": "readOnly"]]
                : mode == .autoEdit ? ["approvalPolicy": "on-request", "sandboxPolicy": workspace]
                : ["approvalPolicy": "never", "sandboxPolicy": ["type": "dangerFullAccess"]]
            // Native events can confirm acceptance even if the RPC reply is lost.
            policyOverridden.insert(sid)
        default:
            if policyOverridden.contains(sid), let inherited { arguments = ["approvalPolicy": inherited.approval, "sandboxPolicy": inherited.sandbox] }
        }
        // Plan is Codex's experimental collaboration mode; it names the model to keep.
        if mode == .plan || planOverridden.contains(sid), let model = selected?.model ?? threadModels[sid] {
            arguments["collaborationMode"] = ["mode": mode == .plan ? "plan" : "default",
                "settings": ["model": model, "reasoning_effort": selected?.reasoningEffort as Any? ?? NSNull(), "developer_instructions": NSNull()]]
            if mode == .plan { planOverridden.insert(sid) }
        }
        return arguments
    }

    private func sessionResult(_ thread: [String: Any], response: [String: Any]) -> [String: Any] {
        let id = thread["id"] as? String ?? ""
        var result: [String: Any] = ["session_id": id, "stored_session_id": id, "profile_id": profileID,
                "messages": CodexProtocolState.history(thread), "cwd": thread["cwd"] as? String ?? "",
                "running": state.activeTurns[id] != nil || (thread["status"] as? [String: Any])?["type"] as? String == "active"]
        result["info"] = ["model": response["model"] ?? "", "provider": response["modelProvider"] ?? ""]
        if let status = (thread["turns"] as? [[String: Any]])?.last?["status"] as? String,
           ["completed", "failed", "interrupted"].contains(status) {
            result["terminal_status"] = CodexProtocolState.status(status)
        }
        return result
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true, input != nil else { throw CodexClientError.disconnected }
        sequence += 1
        let id = sequence
        let runID = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                guard let self, self.generation == runID else { return }
                self.timeouts.removeValue(forKey: id)
                self.pending.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut(method))
            }
            do { try write(["id": id, "method": method, "params": params]) }
            catch { timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    private func write(_ frame: [String: Any]) throws {
        guard let handle = input else { throw CodexClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: frame)
        data.append(0x0A)
        let runID = generation
        writeQueue.async { [weak self] in
            do { try handle.write(contentsOf: data) }
            catch {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == runID else { return }
                    self.fail(CodexClientError.disconnected)
                }
            }
        }
    }

    private func receive(_ data: Data, generation runID: UUID) {
        guard generation == runID else { return }
        buffer.append(data)
        guard buffer.count <= 32 * 1024 * 1024 else { fail(CodexClientError.unavailable("Codex sent an oversized response.")); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = frame["method"] as? String {
                let params = frame["params"] as? [String: Any] ?? [:]
                let events: [CodexProtocolState.Event]
                if let id = frame["id"] {
                    let result = state.serverRequest(id: id, method: method, params: params)
                    events = result.events
                    if let reply = result.reply { try? write(reply) }
                } else { events = state.notifications(method, params) }
                for event in events {
                    // Announce the accepted choice before usage can arrive; a
                    // late RPC response must not clear fresh stats or reroutes.
                    if event.name == "message.start", let sid = event.payload["session_id"] as? String,
                       let model = selectedModels[sid] {
                        onEvent?("session.info", ["session_id": sid, "model": model.model])
                    }
                    onEvent?(event.name, event.payload)
                }
            } else if let id = frame["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if let error = frame["error"] as? [String: Any] {
                    continuation.resume(throwing: CodexClientError.rpc(error["code"] as? Int ?? -1, error["message"] as? String ?? "Codex request failed."))
                } else { continuation.resume(returning: frame["result"] as? [String: Any] ?? [:]) }
            }
        }
    }

    func disconnect() { cleanup(CodexClientError.disconnected); onConnectionChange?(false, nil) }
    private func fail(_ error: Error) { cleanup(error); onConnectionChange?(false, error.localizedDescription) }
    private func cleanup(_ error: Error) {
        generation = UUID()
        ready = false
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close()
        input = nil; output = nil; errorOutput = nil
        buffer.removeAll()
        state = CodexProtocolState()
        images.removeAll()
        titles.removeAll()
        selectedModels.removeAll()
        permissionModes.removeAll(); inheritedPolicies.removeAll(); threadModels.removeAll()
        policyOverridden.removeAll(); planOverridden.removeAll()
        delegationInstructions.removeAll(); instructedThreads.removeAll()
        if let child = process {
            child.terminationHandler = nil
            // stdin EOF is the normal app-server detach. Escalate only for this
            // owned child if it does not exit; callers already enforce idle.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if child.isRunning { child.terminate() }
            }
        }
        process = nil
    }
}
