import Foundation
import UniformTypeIdentifiers

/// Pi's supported RPC frontend. Each owned conversation has one native process;
/// resources, credentials and the native session directory remain Pi's choices.
@MainActor
final class PiClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let profileID: String
    private var executable: URL?
    private let executableOverride: URL?
    private var sessions: [String: PiSession] = [:]
    private var catalogRequests: [UUID: PiSession] = [:]

    init(profileID: String, executable: URL? = nil) { self.profileID = profileID; self.executableOverride = executable }

    func connect() async throws {
        executable = try RuntimeInstallation.executable(for: .pi, configuredExecutable: executableOverride?.path)
        guard FileManager.default.fileExists(atPath: profileID) else { throw AppError("Choose your existing Pi agent directory in Settings and set up Pi normally first.") }
        if let executable { try await verifyVersion(executable) }
        onConnectionChange?(true, nil)
    }


    private func verifyVersion(_ executable: URL) async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("notch-pi-version-" + UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let child = Process(); child.executableURL = executable; child.arguments = ["--version"]
        child.environment = RuntimeEnvironment.native(environment: ProcessInfo.processInfo.environment, runtime: .pi, profileID: profileID)
        child.standardOutput = handle; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
        try child.run()
        for _ in 0..<100 {
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !child.isRunning else { child.terminate(); throw AppError("Pi's version check timed out. Verify the selected native pi executable.") }
        guard child.terminationStatus == 0, let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4096,
              let version = try? String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              Self.supportsVersion(version) else { throw AppError("This adapter requires Pi 1.0.2 or newer in the 1.x series for settled-run events and session-only model changes. Upgrade Pi yourself or choose a compatible existing installation.") }
    }
    static func supportsVersion(_ value: String) -> Bool {
        let numeric = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return false }
        let pieces = components.compactMap { Int($0) }
        return pieces.count == 3 && pieces[0] == 1 && (pieces[1] > 0 || pieces[2] >= 2)
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let executable else { throw AppError("Pi is disconnected. Reconnect in Settings.") }
        if method == "runtime.models" {
            let requestedCwd = URL(fileURLWithPath: params["cwd"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path).standardizedFileURL.resolvingSymlinksInPath().path
            if let session = sessions.values.first(where: { $0.cwd == requestedCwd }) {
                return ["catalog": try await session.catalog()]
            }
            let session = try await start(executable: executable, cwd: requestedCwd, path: nil, persistent: false)
            let requestID = UUID()
            catalogRequests[requestID] = session
            defer { session.stop(); catalogRequests.removeValue(forKey: requestID) }
            return ["catalog": try await session.catalog()]
        }
        if method == "session.create" || method == "session.resume" {
            let path = method == "session.resume" ? params["session_id"] as? String : nil
            if method == "session.resume", path?.hasPrefix("/") != true { throw AppError("The saved Pi session path is missing. The original conversation was preserved.") }
            if let path, let existing = sessions[path] { return try await existing.result(profileID: profileID) }
            var cwd = params["cwd"] as? String
            if let path {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
                let prefix = try handle.read(upToCount: 65_536) ?? Data()
                guard let line = prefix.split(separator: 0x0A).first,
                      let header = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      header["type"] as? String == "session", let nativeCwd = header["cwd"] as? String else {
                    throw AppError("This saved Pi file is not a native session. The original conversation was preserved.")
                }
                cwd = nativeCwd
            }
            let session = try await start(executable: executable, cwd: cwd, path: path, delegation: params["delegation"] as? [String: Any])
            do {
                let nativeState = try await session.rpc("get_state")
                guard let nativePath = nativeState["sessionFile"] as? String, nativePath.hasPrefix("/"),
                      path == nil || URL(fileURLWithPath: nativePath).standardizedFileURL.path == URL(fileURLWithPath: path!).standardizedFileURL.path else {
                    throw AppError("Pi did not select the requested persistent session. Check that this Pi version supports persistent RPC sessions.")
                }
                session.id = nativePath
                sessions[nativePath] = session
                if method == "session.create", let title = params["title"] as? String, !title.isEmpty {
                    _ = try? await session.rpc("set_session_name", ["name": title])
                }
                return try await session.result(profileID: profileID)
            } catch { session.stop(); throw error }
        }
        guard let id = params["session_id"] as? String, let session = sessions[id] else { throw AppError("This Pi session is not registered with the companion.") }
        switch method {
        case "session.model.set":
            guard !session.state.busy else { throw AppError("Wait for Pi's run, retries and compaction to settle before changing models.") }
            guard let model = params["model"] as? String, let provider = params["provider"] as? String else { throw AppError("Choose a Pi model and provider from its native catalog.") }
            session.invalidateUsage()
            _ = try await session.rpc("set_model", ["provider": provider, "modelId": model])
            let result = try await session.rpc("get_state")["model"] as? [String: Any] ?? [:]
            guard result["id"] as? String == model, result["provider"] as? String == provider else { throw AppError("Pi did not confirm the selected model and provider.") }
            let info = PiProtocolState.info(model: result, stats: try await session.rpc("get_session_stats"))
            onEvent?("session.info", info.merging(["session_id": id]) { _, new in new })
            return ["info": info]
        case "file.attach", "image.attach":
            let file = try PiProtocolState.readableFile(params["path"] as? String)
            if method == "image.attach" {
                if !session.images.contains(file.path) { session.images.append(file.path) }
                return ["path": file.path]
            }
            return ["ref_text": "Attached local file (read with your configured file tools): " + CodexProtocolState.describe([file.path])]
        case "image.detach":
            session.images.removeAll { $0 == params["path"] as? String }; return ["detached": true]
        case "prompt.steer":
            guard session.state.busy else { throw BusyInputRejection(message: "Pi has no running turn to steer.") }
            let images: [[String: Any]]
            do { images = try (params["images"] as? [String] ?? []).map { try PiProtocolState.image($0) } }
            catch { throw BusyInputRejection(message: error.localizedDescription) }
            _ = try await session.rpc("steer", ["message": params["text"] as? String ?? "", "images": images])
            return ["steered": true]
        case "prompt.submit":
            guard !session.state.busy else { throw AppError("Pi is still working, retrying, compacting, or handling queued input. Wait or stop before sending again.") }
            let images = try session.images.map { try PiProtocolState.image($0) }
            session.state.begin()
            do {
                let response = try await session.rpc("prompt", ["message": params["text"] as? String ?? "", "images": images])
                session.images.removeAll()
                if response["disposition"] as? String == "handled", !session.state.observedWork {
                    let native = try await session.rpc("get_state")
                    if !session.state.observedWork, native["isStreaming"] as? Bool == false, native["isCompacting"] as? Bool == false, native["pendingMessageCount"] as? Int == 0 { session.emitSettled() }
                }
                return ["accepted": true]
            } catch {
                // Explicit native rejection is safe to retry; lost responses
                // remain busy until the native lifecycle or reconnect settles.
                if case PiRequestError.rejected = error { session.state.busy = false }
                throw error
            }
        case "session.interrupt":
            _ = try await session.rpc("clear_queue")
            _ = try await session.rpc("abort")
            return ["interrupted": true] // agent_settled is authoritative.
        case "clarify.respond", "approval.respond":
            try session.answer(params); return ["resolved": true]
        case "session.rename":
            _ = try await session.rpc("set_session_name", ["name": params["title"] as? String ?? ""]); return ["renamed": true]
        default: throw AppError("Pi does not support \(method) through this companion.")
        }
    }

    private func start(executable: URL, cwd: String?, path: String?, persistent: Bool = true, delegation: [String: Any]? = nil) async throws -> PiSession {
        try await NativeJSONProcess.awaitPendingStops()
        let session = PiSession()
        session.onFailure = { [weak self, weak session] error in
            guard let self, let session, self.sessions[session.id] === session else { return }
            self.sessions.removeValue(forKey: session.id)
            self.onEvent?("session.disconnected", ["session_id": session.id, "message": error.localizedDescription])
        }
        session.onEvent = { [weak self, weak session] name, payload in
            guard let self, let session, !session.id.isEmpty, self.sessions[session.id] === session else { return }
            self.onEvent?(name, payload.merging(["session_id": session.id]) { _, new in new })
        }
        let folder = URL(fileURLWithPath: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
        var arguments = ["--mode", "rpc"]
        if !persistent { arguments.append("--no-session") }
        if let questions = CompanionResources.bundle.url(forResource: "pi_questions", withExtension: "mjs") {
            arguments += ["--extension", questions.path]
        }
        var environment = RuntimeEnvironment.native(environment: ProcessInfo.processInfo.environment, runtime: .pi, profileID: profileID)
        arguments += Self.delegationArguments(delegation, environment: &environment)
        if let path { arguments += ["--session", path] }
        try session.start(executable: executable, arguments: arguments, environment: environment, cwd: folder)
        return session
    }

    /// The companion's tools through a process-only extension; the token
    /// reaches it in the environment, which the extension clears.
    static func delegationArguments(_ delegation: [String: Any]?, environment: inout [String: String]) -> [String] {
        guard let delegation, let url = delegation["url"] as? String, let token = delegation["token"] as? String,
              let extensionFile = CompanionResources.bundle.url(forResource: "pi_delegation", withExtension: "mjs") else { return [] }
        environment[DelegationBridge.urlKey] = url
        environment[DelegationBridge.tokenKey] = token
        return ["--extension", extensionFile.path]
    }

    func disconnect() {
        for session in catalogRequests.values { session.stop() }
        catalogRequests.removeAll()
        for session in sessions.values { session.stop() }
        sessions.removeAll(); executable = nil; onConnectionChange?(false, nil)
    }
}

enum PiRequestError: LocalizedError, RuntimeDefinitiveRejection {
    case rejected(String)
    var errorDescription: String? { switch self { case .rejected(let reason): return reason } }
}

@MainActor
private final class PiSession {
    var id = ""
    var cwd = ""
    var images: [String] = []
    var state = PiProtocolState()
    var onEvent: ((String, [String: Any]) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let process = NativeJSONProcess()
    private var pending: [String: (String, CheckedContinuation<[String: Any], Error>)] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var dialogs: [String: [String: Any]] = [:]
    private var dialogTimeouts: [String: Task<Void, Never>] = [:]
    private var usageRefresh: Task<Void, Never>?
    private var usageRevision = 0

    func start(executable: URL, arguments: [String], environment: [String: String], cwd: URL) throws {
        self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath().path
        process.onFrame = { [weak self] in self?.receive($0) }
        process.onFailure = { [weak self] error in
            guard let self else { return }
            self.stop(error)
            self.onFailure?(AppError("Pi's frontend disconnected. Reconnect to check its saved session before sending again."))
        }
        try process.start(executable: executable, arguments: arguments, environment: environment, cwd: cwd)
    }

    func rpc(_ command: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let key = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = (command, continuation)
            timeouts[key] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.timeouts.removeValue(forKey: key)
                self?.pending.removeValue(forKey: key)?.1.resume(throwing: AppError("Pi did not acknowledge \(command). Reconnect to check the native session before retrying."))
            }
            do { try process.send(params.merging(["id": key, "type": command]) { _, new in new }) }
            catch { timeouts.removeValue(forKey: key)?.cancel(); pending.removeValue(forKey: key)?.1.resume(throwing: error) }
        }
    }

    func result(profileID: String) async throws -> [String: Any] {
        let native = try await rpc("get_state")
        state.busy = state.busy || native["isStreaming"] as? Bool == true || native["isCompacting"] as? Bool == true || (native["pendingMessageCount"] as? Int ?? 0) > 0
        let messages = try await rpc("get_messages")["messages"] as? [[String: Any]] ?? []
        return ["session_id": id, "stored_session_id": id, "profile_id": profileID, "running": state.busy,
                "messages": PiProtocolState.history(messages), "history_complete": false,
                "catalog": try await catalog(native),
                "info": PiProtocolState.info(model: native["model"] as? [String: Any] ?? [:], stats: try await rpc("get_session_stats"))]
    }

    func catalog(_ native: [String: Any]? = nil) async throws -> RuntimeModelCatalog {
        let current: [String: Any]
        if let native { current = native } else { current = try await rpc("get_state") }
        let model = current["model"] as? [String: Any] ?? [:]
        let rows = try await rpc("get_available_models")["models"] as? [[String: Any]] ?? []
        return RuntimeModelCatalog(defaultModel: PiProtocolState.choice(model), models: rows.compactMap { row in
            PiProtocolState.choice(row).map { RuntimeModelOption(choice: $0, title: row["name"] as? String ?? $0.model) }
        }, configuredContextWindow: model["contextWindow"] as? Int)
    }

    private func receive(_ frame: [String: Any]) {
        if frame["type"] as? String == "response", let id = frame["id"] as? String, let request = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            guard frame["command"] as? String == request.0 else { request.1.resume(throwing: AppError("Pi returned a mismatched command response.")); return }
            if frame["success"] as? Bool == true { request.1.resume(returning: frame["data"] as? [String: Any] ?? [:]) }
            else if frame["success"] as? Bool == false { request.1.resume(throwing: PiRequestError.rejected(frame["error"] as? String ?? "Pi rejected the request.")) }
            else { request.1.resume(throwing: AppError("Pi returned a malformed command acknowledgement. Check native history before retrying.")) }
            return
        }
        if frame["type"] as? String == "extension_ui_request" {
            guard let id = frame["id"] as? String, let method = frame["method"] as? String else { return }
            if ["select", "confirm", "input", "editor"].contains(method) {
                dialogs[id] = frame
                var payload: [String: Any] = ["request_id": id, "allows_free_text": method == "input" || method == "editor", "question": [frame["title"] as? String, frame["message"] as? String, frame["prefill"] as? String].compactMap { $0 }.joined(separator: "\n\n")]
                if method == "confirm" { payload["choices"] = ["Yes", "No"] }
                else if let options = frame["options"] { payload["choices"] = options }
                onEvent?("clarify.request", payload)
                if let milliseconds = frame["timeout"] as? Int, milliseconds > 0 {
                    dialogTimeouts[id] = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
                        self?.dialogs.removeValue(forKey: id); self?.dialogTimeouts.removeValue(forKey: id)
                        self?.onEvent?("clarify.expire", ["request_id": id])
                    }
                }
            } else if ["notify", "setStatus", "setWidget"].contains(method) {
                let text = frame["message"] as? String ?? frame["statusText"] as? String ?? (frame["widgetLines"] as? [String])?.joined(separator: "\n") ?? ""
                if !text.isEmpty { onEvent?("runtime.notice", ["message": text]) }
            } else if method == "set_editor_text" {
                onEvent?("runtime.notice", ["message": "Pi extension suggested input: " + (frame["text"] as? String ?? "")])
            } else if method != "setTitle" {
                try? process.send(["type": "extension_ui_response", "id": id, "cancelled": true])
                onEvent?("runtime.notice", ["message": "This Pi extension interface requires the native terminal UI and was cancelled."])
            }
            return
        }
        for event in state.consume(frame) { onEvent?(event.0, event.1) }
        if ["message_end", "compaction_start", "compaction_end", "agent_settled"].contains(frame["type"] as? String ?? "") {
            usageRevision += 1
            let revision = usageRevision
            usageRefresh?.cancel()
            usageRefresh = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let native = try await self.rpc("get_state")
                    let stats = try await self.rpc("get_session_stats")
                    guard !Task.isCancelled, self.usageRevision == revision else { return }
                    self.onEvent?("session.info", PiProtocolState.info(model: native["model"] as? [String: Any] ?? [:], stats: stats))
                } catch { /* Usage is optional; a failed sample must not fail an accepted turn. */ }
            }
        }
    }

    func answer(_ params: [String: Any]) throws {
        let id = params["request_id"] as? String ?? ""
        guard let dialog = dialogs[id] else { throw AppError("This Pi question expired or belongs to another session.") }
        let answer = params["answer"] as? String ?? params["choice"] as? String ?? ""
        let frame = try PiProtocolState.dialogReply(dialog, answer: answer)
        try process.send(frame)
        dialogs.removeValue(forKey: id); dialogTimeouts.removeValue(forKey: id)?.cancel()
    }
    func emitSettled() { for event in state.consume(["type": "agent_settled"]) { onEvent?(event.0, event.1) } }
    func invalidateUsage() { usageRefresh?.cancel(); usageRefresh = nil; usageRevision += 1 }
    func stop(_ error: Error = AppError("Pi disconnected.")) {
        invalidateUsage()
        for timeout in timeouts.values { timeout.cancel() }; timeouts.removeAll()
        for timeout in dialogTimeouts.values { timeout.cancel() }; dialogTimeouts.removeAll(); dialogs.removeAll()
        for request in pending.values { request.1.resume(throwing: error) }; pending.removeAll()
        process.stop()
    }
}

struct PiProtocolState {
    var busy = false
    var observedWork = false
    private var text = ""
    private var completedText = ""
    private var status = "complete"
    private var error: String?
    mutating func begin() { busy = true; observedWork = false; text = ""; completedText = ""; status = "complete"; error = nil }
    mutating func consume(_ frame: [String: Any]) -> [(String, [String: Any])] {
        if !busy, ["message_start", "message_update", "message_end", "tool_execution_start", "tool_execution_end"].contains(frame["type"] as? String ?? "") { return [] }
        switch frame["type"] as? String {
        case "agent_start":
            if !busy { begin() }
            observedWork = true
            return [("message.start", [:])]
        case "message_start":
            if (frame["message"] as? [String: Any])?["role"] as? String == "assistant" { text = ""; return [("message.start", [:])] }
        case "message_update":
            let event = frame["assistantMessageEvent"] as? [String: Any] ?? [:]
            if event["type"] as? String == "text_delta", let delta = event["delta"] as? String { text += delta; return [("message.delta", ["text": delta])] }
        case "message_end":
            guard let message = frame["message"] as? [String: Any], message["role"] as? String == "assistant" else { return [] }
            text = Self.text(message)
            if !text.isEmpty { completedText = text }
            switch message["stopReason"] as? String {
            case "error": status = "error"; error = message["errorMessage"] as? String ?? "Pi's provider request failed."
            case "aborted": status = "interrupted"
            default: status = "complete"; error = nil
            }
            return text.isEmpty ? [] : [("message.interim", ["text": text, "already_streamed": true])]
        case "tool_execution_start", "tool_execution_end":
            let finished = frame["type"] as? String == "tool_execution_end"
            let result = frame["result"] as? [String: Any] ?? [:]
            return [(finished ? "tool.complete" : "tool.start", ["tool_id": frame["toolCallId"] ?? "", "name": frame["toolName"] ?? "Tool", "context": CodexProtocolState.describe(frame["args"]), "result": Self.text(result), "is_error": frame["isError"] as? Bool ?? false])]
        case "compaction_start", "auto_retry_start", "summarization_retry_scheduled":
            busy = true; observedWork = true
            return [("runtime.notice", ["message": frame["type"] as? String == "compaction_start" ? "Pi is compacting its context." : "Pi is retrying; this session is still working."])]
        case "queue_update":
            if !(frame["steering"] as? [Any] ?? []).isEmpty || !(frame["followUp"] as? [Any] ?? []).isEmpty { busy = true; observedWork = true }
        case "extension_error": return [("runtime.notice", ["message": "A Pi extension reported an error: " + (frame["error"] as? String ?? "unknown error")])]
        case "agent_settled":
            guard busy else { return [] }
            busy = false
            var payload: [String: Any] = ["text": completedText, "status": status]
            if let error { payload["error"] = error }
            return [("message.complete", payload)]
        default: break // agent_end is deliberately not a terminal event.
        }
        return []
    }
    static func text(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func history(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.enumerated().compactMap { index, message in
            guard let role = message["role"] as? String, ["assistant", "user"].contains(role) else { return nil }
            return ["role": role, "text": text(message), "row_id": message["id"] as? String ?? String(index)]
        }
    }
    static func choice(_ model: [String: Any]) -> RuntimeModelChoice? {
        guard let id = model["id"] as? String, let provider = model["provider"] as? String else { return nil }
        return RuntimeModelChoice(model: id, provider: provider)
    }
    static func info(model: [String: Any], stats: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["model": model["id"] ?? "", "provider": model["provider"] ?? "", "context_reset": true, "capabilities": ["resume": true, "attachments": true, "images": true, "approvals": false, "questions": true, "modelSelection": true, "contextUsage": true, "delegation": false]]
        let context = stats["contextUsage"] as? [String: Any] ?? [:]
        var usage: [String: Any] = ["context_estimated": true]
        if let limit = context["contextWindow"] as? Int ?? model["contextWindow"] as? Int, limit > 0 { usage["context_max"] = limit }
        if let used = context["tokens"] as? Int, used >= 0 { usage["context_used"] = used }
        result["usage"] = usage
        return result
    }
    static func dialogReply(_ dialog: [String: Any], answer: String) throws -> [String: Any] {
        var reply: [String: Any] = ["type": "extension_ui_response", "id": dialog["id"] ?? ""]
        switch dialog["method"] as? String {
        case "confirm":
            guard ["Yes", "No"].contains(answer) else { throw AppError("Choose Yes or No for this Pi confirmation.") }
            reply["confirmed"] = answer == "Yes"
        case "select":
            guard (dialog["options"] as? [String] ?? []).contains(answer) else { throw AppError("Choose one of this Pi extension's options.") }
            reply["value"] = answer
        case "input", "editor": reply["value"] = answer
        default: reply["cancelled"] = true
        }
        return reply
    }
    static func readableFile(_ path: String?) throws -> URL {
        guard let path, path.hasPrefix("/") else { throw AppError("Choose an absolute attachment path.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard info.isRegularFile == true, info.isReadable == true else { throw AppError("This attachment is no longer a readable file.") }
        return url
    }
    static func image(_ path: String) throws -> [String: Any] {
        let url = try readableFile(path)
        guard let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/"),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 6 * 1024 * 1024 else { throw AppError("Choose an image smaller than 6 MB.") }
        return ["type": "image", "mimeType": mime, "data": try Data(contentsOf: url).base64EncodedString()]
    }
}
