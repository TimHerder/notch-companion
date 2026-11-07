import Foundation

/// Native OpenCode / DeepSeek Harness / Cursor CLI / Antigravity CLI ACP v1 frontends. Only
/// the companion's delegation bridge is injected; no provider overrides or alternate empty
/// agent homes; modes only as advertised and explicitly chosen per session.
@MainActor
final class ACPRuntimeClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let runtime: RuntimeKind
    let profileID: String
    private let process = NativeJSONProcess()
    private var ready = false
    private var generation = UUID()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var submissions: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private lazy var state = ACPProtocolState(antigravity: runtime == .antigravity)
    private var capabilities: [String: Any] = [:]
    private var directories: [String: String] = [:]
    private var images: [String: [String]] = [:]
    /// Advertised modes per session, its mode as opened, and whether an override is applied.
    private var modeIDs: [String: [PermissionMode: String]] = [:]
    private var delegationServers: [String: [[String: Any]]] = [:]
    private var inheritedModes: [String: String] = [:]
    private var modeOverridden = Set<String>()
    private var version = "ACP v1"
    private let executableOverride: URL?
    private var executable: URL?

    init(runtime: RuntimeKind, profileID: String, executableOverride: URL? = nil) {
        self.runtime = runtime
        self.profileID = URL(fileURLWithPath: profileID).standardizedFileURL.resolvingSymlinksInPath().path
        self.executableOverride = executableOverride
    }

    nonisolated static func deepSeekLaunch(profileID: String) throws -> (home: String, arguments: [String]) {
        let url = URL(fileURLWithPath: profileID).standardizedFileURL.resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().lastPathComponent == "profiles",
              name.lowercased() != "desktop", !name.hasPrefix("-"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("package.json").path) else {
            throw ACPClientError.unavailable("Select your existing DeepSeek Harness profile folder under $DSH_HOME/profiles. It must already contain your native configuration and an ACP bridge. The companion will not create a different ACP or SDK profile or modify your composition.")
        }
        return (url.deletingLastPathComponent().deletingLastPathComponent().path, ["--profile", name])
    }

    func connect() async throws {
        if ready { return }
        guard !process.isRunning else { throw ACPClientError.unavailable("The ACP frontend is already connecting.") }
        try await NativeJSONProcess.awaitPendingStops()
        if runtime == .antigravity {
            let native = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(runtime.defaultProfileDirectory).standardizedFileURL.resolvingSymlinksInPath().path
            guard profileID == native else { throw ACPClientError.unavailable("Antigravity CLI supports only its existing ~/.gemini/antigravity-cli profile. A custom home cannot be selected through its native interface.") }
        }
        let executable = try executableOverride ?? RuntimeInstallation.executable(for: runtime)
        self.executable = executable
        var environment = RuntimeEnvironment.native(runtime: runtime, profileID: profileID)
        let arguments: [String]
        if runtime == .deepseek {
            let launch = try Self.deepSeekLaunch(profileID: profileID)
            environment["DSH_HOME"] = launch.home; arguments = launch.arguments
        } else if [.opencode, .cursor, .antigravity].contains(runtime) { arguments = ["acp"] }
        else { throw ACPClientError.unavailable("This runtime has no supported ACP launch contract.") }
        let run = UUID(); generation = run
        process.onFrame = { [weak self] frame in
            guard let self, self.generation == run else { return }; self.receive(frame)
        }
        process.onFailure = { [weak self] error in
            guard let self, self.generation == run else { return }; self.fail(error)
        }
        do {
            try process.start(executable: executable, arguments: arguments, environment: environment, cwd: FileManager.default.homeDirectoryForCurrentUser)
            let response = try await rpc("initialize", ["protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false,
                                       // No form for agy: its questions then arrive as plain-option `interaction_` permission requests.
                                       "elicitation": runtime == .antigravity ? [String: Any]() : ["form": runtime == .opencode]],
                "clientInfo": ["name": "notch-companion", "title": "Notch Companion", "version": "0.3.0"]])
            guard response["protocolVersion"] as? Int == 1 else { throw ACPClientError.unavailable("\(runtime.title) did not negotiate ACP v1. Select a compatible native installation.") }
            capabilities = response["agentCapabilities"] as? [String: Any] ?? [:]
            // Cursor's documented flow; sign-in itself stays with `cursor-agent login`.
            if runtime == .cursor {
                do { _ = try await rpc("authenticate", ["methodId": "cursor_login"]) }
                catch { throw ACPClientError.unavailable("Cursor CLI is not signed in. Run cursor-agent login in Terminal, then reconnect. (\(error.localizedDescription))") }
            }
            let info = response["agentInfo"] as? [String: Any] ?? [:]
            version = "ACP v1" + ((info["version"] as? String).map { " · " + $0 } ?? "")
            ready = true; onConnectionChange?(true, "\(runtime.title) connected (\(version))")
        } catch { fail(error); throw error }
    }

    /// The companion's tools through its stdio bridge; the session's own servers come from native configuration.
    static func mcpServers(_ delegation: [String: Any]?) -> [[String: Any]] {
        guard let delegation, let bridge = delegation["bridge"] as? String, let url = delegation["url"] as? String,
              let token = delegation["token"] as? String else { return [] }
        return [["name": DelegationServer.name, "command": bridge, "args": [DelegationBridge.flag],
                 "env": [["name": DelegationBridge.urlKey, "value": url], ["name": DelegationBridge.tokenKey, "value": token]]]]
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard ready else { throw ACPClientError.unavailable("\(runtime.title) is disconnected. Reconnect to check its saved sessions.") }
        if method == "runtime.models" {
            let cwd = params["cwd"] as? String ?? ""
            let sid = directories.first(where: { $0.value == cwd })?.key
            if sid == nil, runtime == .antigravity, let executable {
                let run = generation
                let catalog = try await AntigravityClient.discoverModels(executable: executable, profileID: profileID, cwd: ClaudeClient.trustedDirectory(params))
                guard run == generation else { throw ACPClientError.unavailable("Antigravity disconnected during model discovery.") }
                return ["catalog": catalog]
            }
            return ["catalog": sid.map { state.catalog($0) }
                ?? RuntimeModelCatalog(note: "ACP reports models when a native session opens. Send the first message with the native default; the companion does not create hidden sessions to fetch a catalog.")]
        }
        if method == "session.create" || method == "session.resume" {
            if params["activity_unverified"] as? Bool == true {
                throw ACPClientError.unavailable("Delegated OpenCode activity could not be verified through ACP. Continue and inspect this saved conversation in native OpenCode; the companion will not clear its protection from transcript replay alone.")
            }
            let cwd = params["cwd"] as? String ?? ""
            guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else { throw ACPClientError.unavailable("Choose this conversation's existing native working folder before opening it.") }
            if runtime == .antigravity { _ = try ClaudeClient.trustedDirectory(params) }
            // A reload of a live session (Check last send) keeps the bridge it was opened with.
            let servers = (params["delegation"] as? [String: Any]).map(Self.mcpServers)
                ?? (params["session_id"] as? String).flatMap { delegationServers[$0] } ?? []
            var args: [String: Any] = ["cwd": cwd, "mcpServers": servers]
            // Antigravity keeps an appended prompt only for this process, so every open with the bridge sends it.
            if !servers.isEmpty, (((capabilities["_meta"] as? [String: Any])?["antigravity"] as? [String: Any])?["systemPrompt"] as? [String: Any])?["append"] as? Bool == true {
                args["_meta"] = ["antigravity": ["systemPrompt": ["append": Delegation.instructions]]]
            }
            var nativeMethod = "session/new"
            let saved = params["session_id"] as? String
            if method == "session.resume" {
                guard let saved, !saved.isEmpty else { throw ACPClientError.unavailable("The saved native session ID is missing.") }
                guard !state.active.contains(saved), state.children[saved]?.isEmpty ?? true else { throw ACPClientError.unavailable("This native session still has active or unverified delegated work.") }
                // agy's load accepts IDs it never saved, so a cold resume of a conversation that was ever prompted must find it in its native list.
                if runtime == .antigravity, !state.owned.contains(saved), params["native_submission_attempted"] as? Bool != false, try await !listed(saved) {
                    throw ACPClientError.unavailable("Antigravity no longer lists this saved conversation, and resuming it would start an empty one under the same ID. Its history here is kept; continue in a new session.")
                }
                // Antigravity resumes without a replay, as T3 Code does.
                if capabilities["loadSession"] as? Bool == true, runtime != .antigravity {
                    nativeMethod = "session/load"; state.loading.insert(saved); state.history[saved] = []
                    state.historyWithoutMessageIDs.remove(saved)
                } else if (capabilities["sessionCapabilities"] as? [String: Any])?["resume"] != nil { nativeMethod = "session/resume" }
                else { throw ACPClientError.unavailable("This installed ACP version does not support native session resume. Its saved conversation is preserved.") }
                args["sessionId"] = saved; state.owned.insert(saved)
            }
            do {
                let result = try await rpc(nativeMethod, args)
                guard let sid = result["sessionId"] as? String ?? saved, !sid.isEmpty,
                      saved == nil || saved == sid else { throw ACPClientError.unavailable("The native runtime returned a different session identity. The saved conversation was not retargeted.") }
                state.owned.insert(sid); state.loading.remove(sid); directories[sid] = cwd
                delegationServers[sid] = servers
                state.config[sid] = result["configOptions"] as? [[String: Any]] ?? []
                if runtime == .antigravity { state.models[sid] = result["models"] as? [String: Any] }
                let modes = result["modes"] as? [String: Any]
                modeIDs[sid] = ACPProtocolState.permissionModes(modes)
                // Cursor's `ask` mode is read-only Q&A, not ask-before-editing. Antigravity's
                // `default` follows its native permission settings, which may never ask.
                if runtime == .cursor || runtime == .antigravity { modeIDs[sid]?[.ask] = nil }
                if let current = modes?["currentModeId"] as? String { inheritedModes[sid] = current }
                let catalog = state.catalog(sid)
                let promptCaps = capabilities["promptCapabilities"] as? [String: Any] ?? [:]
                var info: [String: Any] = ["capabilities": ["resume": capabilities["loadSession"] as? Bool == true || (capabilities["sessionCapabilities"] as? [String: Any])?["resume"] != nil,
                    "attachments": true, "images": promptCaps["image"] as? Bool == true, "approvals": true,
                    "questions": [.opencode, .cursor, .antigravity].contains(runtime), "modelSelection": !catalog.models.isEmpty,
                    "contextUsage": true, "delegation": false,
                    "permissionModes": PermissionMode.allCases.filter { modeIDs[sid]?[$0] != nil }.map(\.rawValue)],
                    "capability_note": [.cursor, .antigravity].contains(runtime) ? runtime.capabilityNote : runtime == .deepseek
                        ? "Selected native ACP composition; native resume preserves context but ACP does not replay history or expose interactive extensions. Lost sends require native verification."
                        : "ACP v1: native child activity is shown, but ACP cannot confirm child completion. If delegation occurs, further sends remain protected pending native verification. Models are reported after the native session opens."]
                if let model = catalog.defaultModel?.model { info["model"] = model }
                var response: [String: Any] = ["session_id": sid, "stored_session_id": sid, "profile_id": profileID, "cwd": cwd, "running": false, "info": info, "catalog": catalog]
                if nativeMethod == "session/load" {
                    response["messages"] = state.history.removeValue(forKey: sid) ?? []
                    response["history_complete"] = !state.historyWithoutMessageIDs.contains(sid)
                } else if nativeMethod == "session/resume" { response["history_complete"] = false }
                return response
            } catch {
                if let saved { state.loading.remove(saved); state.owned.remove(saved); state.history.removeValue(forKey: saved) }
                throw error
            }
        }
        let sid = params["session_id"] as? String ?? ""
        guard state.owned.contains(sid) else { throw ACPClientError.unavailable("This native session is not owned by the companion.") }
        switch method {
        case "session.model.set":
            guard !state.active.contains(sid), state.children[sid]?.isEmpty ?? true else { throw ACPClientError.unavailable("Wait for native work and verify delegated activity before changing models.") }
            let model = params["model"] as? String ?? ""
            if state.models[sid] != nil {
                guard state.catalog(sid).models.contains(where: { $0.choice.model == model }) else { throw ACPClientError.unavailable("Choose a model advertised by this native ACP session.") }
                // Session-scoped; the response is empty, so the agent's acknowledgement is the readback.
                _ = try await rpc("session/set_model", ["sessionId": sid, "modelId": model])
                state.models[sid]?["currentModelId"] = model
                onEvent?("session.info", ["session_id": sid, "model": model]); return [:]
            }
            let options = state.config[sid] ?? []
            guard let option = options.first(where: { $0["category"] as? String == "model" || $0["id"] as? String == "model" }),
                  let configID = option["id"] as? String,
                  ACPProtocolState.catalog(options).models.contains(where: { $0.choice.model == model }) else { throw ACPClientError.unavailable("Choose a model advertised by this native ACP session.") }
            let result = try await rpc("session/set_config_option", ["sessionId": sid, "configId": configID, "value": model])
            state.config[sid] = result["configOptions"] as? [[String: Any]] ?? []
            guard ACPProtocolState.catalog(state.config[sid] ?? []).defaultModel?.model == model else { throw ACPClientError.unavailable("The native session did not confirm the selected model. No prompt was sent.") }
            onEvent?("session.info", ["session_id": sid, "model": model]); return [:]
        case "session.permission.set":
            guard !state.active.contains(sid), state.children[sid]?.isEmpty ?? true else { throw ACPClientError.unavailable("Wait for native work and verify delegated activity before changing permissions.") }
            let target: String
            if let raw = params["mode"] as? String {
                guard let mode = PermissionMode(rawValue: raw), let native = modeIDs[sid]?[mode] else { throw ACPClientError.unavailable("Choose a mode advertised by this native ACP session.") }
                target = native
            } else {
                // Inherit restores the session's opening mode once after an override.
                guard modeOverridden.contains(sid), let inherited = inheritedModes[sid] else { return [:] }
                target = inherited
            }
            _ = try await rpc("session/set_mode", ["sessionId": sid, "modeId": target])
            if params["mode"] == nil { modeOverridden.remove(sid) } else { modeOverridden.insert(sid) }
            return [:]
        case "file.attach", "image.attach":
            guard let path = params["path"] as? String else { throw ACPClientError.unavailable("The attachment path is missing.") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isReadable == true else { throw ACPClientError.unavailable("The attachment is no longer a readable regular file.") }
            if method == "image.attach" {
                guard (capabilities["promptCapabilities"] as? [String: Any])?["image"] as? Bool == true else { throw ACPClientError.unavailable("This native ACP session does not support image prompts. Attach text or use its native interface.") }
                guard Self.imageMIME(url) != nil, (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw ACPClientError.unavailable("ACP images must be PNG, JPEG, GIF or WebP and at most 8 MB.") }
                if !(images[sid] ?? []).contains(url.path) { images[sid, default: []].append(url.path) }
                return ["path": url.path]
            }
            return ["ref_text": "Attached local file (read with your configured native tools): " + ACPProtocolState.describe([url.path])]
        case "image.detach":
            if let path = params["path"] as? String { images[sid]?.removeAll { $0 == path } }; return ["detached": true]
        case "prompt.submit":
            var prompt: [[String: Any]] = [["type": "text", "text": params["text"] as? String ?? ""]]
            for path in images[sid] ?? [] {
                let url = URL(fileURLWithPath: path)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 8 * 1024 * 1024, let mime = Self.imageMIME(url) else { throw ACPClientError.unavailable("An image changed or exceeds the ACP image limit.") }
                prompt.append(["type": "image", "data": data.base64EncodedString(), "mimeType": mime])
            }
            guard try JSONSerialization.data(withJSONObject: prompt).count < 15 * 1024 * 1024 else { throw ACPClientError.unavailable("The combined image attachments exceed the native request limit.") }
            try state.begin(sid)
            let run = generation
            return try await withCheckedThrowingContinuation { continuation in
                submissions[sid] = continuation
                Task { @MainActor [weak self] in
                    guard let self, self.generation == run else { return }
                    do {
                        let result = try await self.rpc("session/prompt", ["sessionId": sid, "prompt": prompt], timeout: 1_800)
                        guard self.generation == run else { return }
                        self.accept(sid)
                        self.emit(self.state.finish(sid, stopReason: result["stopReason"] as? String ?? "unknown"))
                    } catch {
                        guard self.generation == run else { return }
                        if case ACPClientError.rpc = error {
                            let accepted = self.state.started.contains(sid)
                            if accepted { self.emit(self.state.finish(sid, stopReason: "error", error: error.localizedDescription)) }
                            else { self.state.active.remove(sid) }
                        }
                        self.submissions.removeValue(forKey: sid)?.resume(throwing: error)
                    }
                }
            }
        case "session.interrupt":
            try process.send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sid]])
            guard state.children[sid]?.isEmpty ?? true else { throw ACPClientError.unavailable("Cancellation was requested, but ACP cannot confirm delegated children stopped. Check and stop them in native OpenCode; the companion will not mark them idle without evidence.") }
            return ["interrupted": true]
        case "approval.respond", "clarify.respond":
            if let frame = try state.answer(params, approval: method == "approval.respond") { try process.send(frame) }
            return ["resolved": true]
        case "session.rename":
            return ["renamed": true, "local_only": true] // ACP has no native title setter.
        default: throw ACPClientError.unavailable("\(runtime.title) does not support \(method) through ACP.")
        }
    }

    private func accept(_ sid: String) {
        images.removeValue(forKey: sid)
        submissions.removeValue(forKey: sid)?.resume(returning: ["accepted": true])
    }
    private func emit(_ events: [ACPProtocolState.Event]) {
        for event in events {
            if event.name == "message.start", let sid = event.payload["session_id"] as? String { accept(sid) }
            onEvent?(event.name, event.payload)
        }
    }
    private func receive(_ frame: [String: Any]) {
        guard frame["jsonrpc"] as? String == "2.0" else { fail(ACPClientError.unavailable("The runtime sent an incompatible ACP message.")); return }
        if let method = frame["method"] as? String {
            let params = frame["params"] as? [String: Any] ?? [:]
            if let id = frame["id"] {
                let translated = state.serverRequest(id: id, method: method, params: params)
                if !translated.events.isEmpty, let sid = params["sessionId"] as? String,
                   state.active.contains(sid), state.started.insert(sid).inserted {
                    emit([state.event("message.start", sid, ["role": "assistant"])])
                }
                emit(translated.events)
                if let reply = translated.reply { do { try process.send(reply) } catch { fail(error) } }
            } else { emit(state.notification(method, params)) }
        } else if let id = frame["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = frame["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                let message = error["message"] as? String ?? "The native ACP request failed."
                // ACP's auth_required; agy reuses the sign-in cached by an interactive `agy` session.
                let text = code != -32000 ? message : runtime == .antigravity ? "Antigravity CLI is not signed in. Run agy in Terminal and sign in once, then send again."
                    : message + " Complete authentication in the native runtime if requested."
                continuation.resume(throwing: ACPClientError.rpc(code, text))
            } else if let result = frame["result"] as? [String: Any] { continuation.resume(returning: result) }
            else if frame["result"] is NSNull { continuation.resume(returning: [:]) }
            else { continuation.resume(throwing: ACPClientError.unavailable("The native runtime sent an invalid ACP result.")) }
        }
    }

    private func listed(_ sid: String) async throws -> Bool {
        var cursor: String?
        for _ in 0..<100 {
            let page = try await rpc("session/list", cursor.map { ["cursor": $0] } ?? [:])
            if (page["sessions"] as? [[String: Any]] ?? []).contains(where: { $0["sessionId"] as? String == sid }) { return true }
            guard let next = page["nextCursor"] as? String, !next.isEmpty, next != cursor else { return false }
            cursor = next
        }
        return false
    }

    private func rpc(_ method: String, _ params: [String: Any], timeout: Double = 45) async throws -> [String: Any] {
        sequence += 1; let id = sequence, run = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard let self, self.generation == run else { return }
                self.fail(ACPClientError.unavailable("\(self.runtime.title) timed out during \(method). Check that the selected native profile exposes ACP v1. Reconnect and inspect the saved session before retrying a prompt."))
            }
            do { try process.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
            catch { deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    func disconnect() { cleanup(ACPClientError.unavailable("The native ACP frontend disconnected.")); onConnectionChange?(false, nil) }
    private func fail(_ error: Error) { cleanup(error); onConnectionChange?(false, error.localizedDescription) }
    private func cleanup(_ error: Error) {
        generation = UUID(); ready = false
        for deadline in deadlines.values { deadline.cancel() }; deadlines.removeAll()
        for item in pending.values { item.resume(throwing: error) }; pending.removeAll()
        for item in submissions.values { item.resume(throwing: error) }; submissions.removeAll()
        process.stop(); state = ACPProtocolState(antigravity: runtime == .antigravity); directories.removeAll(); images.removeAll(); capabilities.removeAll()
        modeIDs.removeAll(); inheritedModes.removeAll(); modeOverridden.removeAll(); delegationServers.removeAll()
    }
    private static func imageMIME(_ url: URL) -> String? {
        ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()]
    }
}
