import Foundation

/// Official agy streaming input is text-only and explicitly rejects control
/// messages. Keep its inherited permission policy; do not make it interactive
/// by enabling permission bypass or substituting the separate ACP environment.
struct AntigravityProtocolState {
    var sessionID: String?
    var expectedID: String?
    var active = false
    var text = ""
    var tools = Set<Int>()
    var delegatedSteps = Set<Int>()
    var turnID = ""
    var model: String?
    var contextUsed: Int?

    mutating func begin(_ id: String) throws {
        guard !active else { throw AppError("Antigravity CLI is still working. Wait or stop before sending again.") }
        active = true; text = ""; tools.removeAll(); delegatedSteps.removeAll(); turnID = id
    }

    mutating func receive(_ frame: [String: Any]) throws -> [ClaudeProtocolState.Event] {
        let type = frame["event"] as? String ?? ""
        let body = frame[type] as? [String: Any] ?? [:]
        let id = frame["conversation_id"] as? String ?? body["conversation_id"] as? String
        if let id, !id.isEmpty {
            guard UUID(uuidString: id) != nil, expectedID == nil || expectedID == id,
                  sessionID == nil || sessionID == id else { throw AppError("Antigravity CLI returned a different native conversation. The saved session was not retargeted.") }
            sessionID = id
        }
        guard let sessionID else { throw AppError("Antigravity CLI did not provide a durable conversation ID. Check CLI compatibility.") }
        func event(_ name: String, _ values: [String: Any] = [:]) -> ClaudeProtocolState.Event {
            var values = values; values["session_id"] = sessionID
            return .init(name: name, payload: values)
        }
        if type == "init" {
            model = body["model"] as? String ?? model
            var info: [String: Any] = [:]; info["model"] = model
            return [event("session.info", info), event("runtime.notice", ["message": AntigravityClient.protocolNote])]
        }
        guard active else { return [] }
        if type == "step_update" {
            var events: [ClaudeProtocolState.Event] = []
            if body["step_type"] as? String == "unknown", body["state"] as? String == "DONE" {
                events.append(event("runtime.notice", ["message": "Antigravity completed a native interaction without exposing its details. Its JSON interface cannot display ask_question prompts or accept their replies. Ask it to write the question in its message, then answer in the composer."]))
            }
            if body["step_type"] as? String == "agent_response", body["state"] as? String == "DONE",
               let usage = body["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int, input >= 0,
               let cached = usage["cache_read_tokens"] as? Int, cached >= 0,
               !input.addingReportingOverflow(cached).overflow {
                contextUsed = input + cached
                events.append(event("session.info", ["usage": ["context_used": input + cached, "context_estimated": true]]))
            }
            if body["step_type"] as? String == "agent_response", let delta = body["text_delta"] as? String {
                text += delta; events.append(event("message.delta", ["text": delta]))
            }
            if let index = body["step_index"] as? Int, body["step_type"] as? String == "tool" {
                let tool = body["tool_info"] as? [String: Any] ?? [:]
                let name = body["tool_name"] as? String ?? tool["name"] as? String ?? "Tool"
                let key = turnID + ":" + String(index)
                if tools.insert(index).inserted { events.append(event("tool.start", ["tool_id": key, "name": name, "context": CodexProtocolState.describe(tool["parameters"])])) }
                if body["state"] as? String == "DONE" {
                    events.append(event("tool.complete", ["tool_id": key, "result": CodexProtocolState.describe(tool["output"]), "is_error": tool["error"] != nil]))
                    if tool["error"] != nil { events.append(event("runtime.notice", ["message": "An Antigravity tool failed or was denied by its native headless permission policy."])) }
                }
            }
            if let index = body["step_index"] as? Int, let delegated = body["subagent_info"] as? [String: Any],
               !(delegated["subagents"] as? [[String: Any]] ?? []).isEmpty {
                if body["state"] as? String == "DONE" { delegatedSteps.remove(index) }
                else { delegatedSteps.insert(index) }
            }
            return events
        }
        if type == "result" {
            let status = body["status"] as? String ?? ""
            guard ["SUCCESS", "ERROR", "CANCELED", "INTERRUPTED", "INVALID", "WAITING", "RUNNING"].contains(status) else { throw AppError("Antigravity CLI returned an unsupported result status. Check its native saved conversation before retrying.") }
            guard status != "WAITING", status != "RUNNING", delegatedSteps.isEmpty else {
                throw AppError("Antigravity CLI still reports work or input that its headless interface cannot settle. The owned frontend was stopped; continue this saved conversation in the native CLI.")
            }
            active = false
            let failed = status == "ERROR" || status == "INVALID"
            var events: [ClaudeProtocolState.Event] = []
            if failed { events.append(event("session.error", ["message": "Antigravity CLI could not complete this turn. Check native sign-in, permissions, and provider availability."])) }
            events.append(event("message.complete", ["text": body["response"] as? String ?? text,
                "status": failed ? "error" : status == "SUCCESS" ? "complete" : "interrupted", "completion_id": turnID]))
            // result.usage is cumulative across the conversation, not context
            // occupancy. It must never become the context meter.
            return events
        }
        if type == "control_request" || type == "control_response" { throw AppError("This Antigravity CLI requests an unsupported interaction. No permission was granted.") }
        return []
    }
}

@MainActor
final class AntigravityClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let profileID: String
    private var executable: URL?
    private let executableOverride: URL?
    private var sessions: [UUID: Session] = [:]
    private var generation = UUID()
    nonisolated static let protocolNote = "Native agy models, tools and latest-request token estimate. The CLI does not report a context-window limit or expose its question tool's prompts and replies here. Ask for questions in ordinary messages. Headless permissions follow native policy; interactive approval replies are unavailable."
    nonisolated static let capabilities: [String: Bool] = ["resume": true, "attachments": true, "images": false,
        "approvals": false, "questions": false, "modelSelection": true, "contextUsage": true, "delegation": false]
    private var catalogs: [String: RuntimeModelCatalog] = [:]

    @MainActor private final class Session {
        let key = UUID()
        let process = NativeJSONProcess()
        let cwd: URL
        var state: AntigravityProtocolState
        var opening: CheckedContinuation<[String: Any], Error>?
        var submission: CheckedContinuation<[String: Any], Error>?
        var timeout: Task<Void, Never>?
        init(cwd: URL, expectedID: String?) { self.cwd = cwd; state = AntigravityProtocolState(expectedID: expectedID) }
        func close(_ error: Error) {
            process.stop(); timeout?.cancel(); timeout = nil
            let first = opening; opening = nil; first?.resume(throwing: error)
            let sent = submission; submission = nil; sent?.resume(throwing: error)
        }
    }

    init(profileID: String, executableURL: URL? = nil) {
        self.profileID = URL(fileURLWithPath: profileID).standardizedFileURL.resolvingSymlinksInPath().path
        executableOverride = executableURL
    }

    static func arguments(resume id: String?, model: String? = nil) throws -> [String] {
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json"]
        if let id {
            guard UUID(uuidString: id) != nil else { throw AppError("Antigravity CLI needs a valid saved native conversation UUID.") }
            arguments += ["--conversation", id]
        }
        if let model { arguments += ["--model", model] }
        return arguments
    }

    func connect() async throws {
        let native = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli").standardizedFileURL.resolvingSymlinksInPath().path
        guard profileID == native else { throw AppError("Antigravity CLI currently supports only its existing ~/.gemini/antigravity-cli profile. A custom home cannot be selected through the documented native interface.") }
        executable = try executableOverride ?? RuntimeInstallation.executable(for: .antigravity)
        onConnectionChange?(true, "Antigravity CLI found; native sign-in is checked when opening a conversation.")
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard executable != nil else { throw AppError("Antigravity CLI is disconnected. Set up the installed native CLI first.") }
        if method == "runtime.models" { return ["catalog": try await catalog(cwd: ClaudeClient.trustedDirectory(params))] }
        if method == "session.create" || method == "session.resume" {
            let cwd = try ClaudeClient.trustedDirectory(params)
            let id = method == "session.resume" ? params["session_id"] as? String : nil
            if method == "session.resume", id == nil { throw AppError("The saved Antigravity conversation has no native ID.") }
            if let existing = sessions.values.first(where: { $0.state.sessionID == id && id != nil }) {
                guard existing.cwd == cwd else { throw AppError("The saved Antigravity conversation belongs to a different project folder.") }
                return result(existing)
            }
            let session = Session(cwd: cwd, expectedID: id)
            let catalog = try await catalog(cwd: cwd)
            session.state.model = catalog.defaultModel?.model
            sessions[session.key] = session
            session.process.onFrame = { [weak self, weak session] frame in
                guard let self, let session, self.sessions[session.key] === session else { return }; self.receive(frame, session)
            }
            session.process.onFailure = { [weak self, weak session] error in
                guard let self, let session, self.sessions[session.key] === session else { return }; self.failed(session, error)
            }
            return try await open(session, model: nil)
        }
        let id = params["session_id"] as? String ?? ""
        guard let session = sessions.values.first(where: { $0.state.sessionID == id }), session.process.isRunning else { throw AppError("This Antigravity conversation is disconnected. Resume it before sending again.") }
        switch method {
        case "session.model.set":
            guard !session.state.active else { throw AppError("Wait for Antigravity to finish before changing models.") }
            let choice = RuntimeModelChoice(model: params["model"] as? String ?? "")
            guard catalogs[session.cwd.path]?.contains(choice) == true else { throw AppError("Choose an available native Antigravity model.") }
            if session.state.model == choice.model { return result(session) }
            session.process.stop()
            session.state = AntigravityProtocolState(expectedID: id)
            let opened = try await open(session, model: choice.model)
            guard session.state.model == choice.model else { failed(session, AppError("Antigravity did not confirm the selected model. No prompt was sent.")); throw AppError("Antigravity did not confirm the selected model.") }
            return opened
        case "file.attach":
            let url = try ClaudeClient.attachment(params)
            return ["ref_text": "Attached local file (read with native tools and existing permissions): " + CodexProtocolState.describe([url.path])]
        case "image.attach": throw AppError("Antigravity's streaming input only accepts text. Image attachment input is unavailable in this interface.")
        case "image.detach": return [:]
        case "prompt.submit":
            let text = params["text"] as? String ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else { throw AppError("Antigravity CLI handles slash commands outside its JSON stream. Run this command in the native CLI.") }
            try session.state.begin(params["turn_id"] as? String ?? UUID().uuidString)
            onEvent?("message.start", ["session_id": id, "role": "assistant"])
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    session.submission = continuation
                    timeout(session, seconds: 330, message: "Antigravity CLI did not settle the turn. Delivery remains uncertain; check its native conversation before retrying.")
                    do { try session.process.send(["event": "user", "message": ["content": text]]) }
                    catch { failed(session, error) }
                }
            } onCancel: { Task { @MainActor [weak self, weak session] in if let self, let session { self.failed(session, CancellationError()) } } }
        case "session.interrupt":
            try session.process.interrupt()
            return ["interrupted": true]
        case "approval.respond", "clarify.respond": throw AppError(Self.protocolNote)
        case "session.rename": return ["renamed": false, "local_only": true]
        default: throw AppError("This operation is unavailable through Antigravity CLI's headless interface.")
        }
    }

    private func result(_ session: Session) -> [String: Any] {
        var info: [String: Any] = ["capabilities": Self.capabilities, "capability_note": Self.protocolNote]
        info["model"] = session.state.model
        if let used = session.state.contextUsed { info["usage"] = ["context_used": used, "context_estimated": true] }
        var value: [String: Any] = ["session_id": session.state.sessionID ?? "", "stored_session_id": session.state.sessionID ?? "", "profile_id": profileID,
         "cwd": session.cwd.path, "history_complete": false, "running": session.state.active,
         "info": info]
        value["catalog"] = catalogs[session.cwd.path]
        return value
    }

    private func open(_ session: Session, model: String?) async throws -> [String: Any] {
        do {
            try await NativeJSONProcess.awaitPendingStops()
            guard let executable, sessions[session.key] === session else { throw AppError("Antigravity disconnected before opening the conversation.") }
            try session.process.start(executable: executable, arguments: Self.arguments(resume: session.state.expectedID, model: model), environment: RuntimeEnvironment.native(runtime: .antigravity, profileID: profileID), cwd: session.cwd)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    session.opening = continuation
                    timeout(session, seconds: 60, message: "Antigravity CLI did not expose the requested native conversation before input. No prompt was sent.")
                }
            } onCancel: { Task { @MainActor [weak self, weak session] in if let self, let session { self.failed(session, CancellationError()) } } }
        } catch { failed(session, error); throw error }
    }

    private func command(_ arguments: [String], cwd: URL) async throws -> [String: Any] {
        guard let executable else { throw AppError("Antigravity disconnected before its model query.") }
        let process = NativeJSONProcess()
        var pending: CheckedContinuation<[String: Any], Error>?
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            let reply = pending; pending = nil
            reply?.resume(throwing: AppError("Antigravity's native model query timed out."))
        }
        defer { deadline.cancel(); process.stop() }
        process.onFrame = { value in let reply = pending; pending = nil; reply?.resume(returning: value) }
        process.onFailure = { error in let reply = pending; pending = nil; reply?.resume(throwing: error) }
        try process.start(executable: executable, arguments: arguments, environment: RuntimeEnvironment.native(runtime: .antigravity, profileID: profileID), cwd: cwd)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    private func catalog(cwd: URL) async throws -> RuntimeModelCatalog {
        let run = generation
        let models = try await command(["--output-format", "json", "models"], cwd: cwd)
        let current = try await command(["--print", "/model", "--output-format", "json"], cwd: cwd)
        let result = try Self.catalog(models: models, current: current)
        guard run == generation else { throw AppError("Antigravity disconnected during model discovery.") }
        catalogs[cwd.path] = result
        return result
    }

    static func catalog(models: [String: Any], current: [String: Any]) throws -> RuntimeModelCatalog {
        guard models["status"] as? String == "SUCCESS", current["status"] as? String == "SUCCESS",
              let command = models["command"] as? [String: Any], command["name"] as? String == "models",
              let data = command["data"] as? [String: Any], let rows = data["models"] as? [[String: Any]],
              let selected = current["command"] as? [String: Any], selected["name"] as? String == "model",
              let model = (selected["data"] as? [String: Any])?["id"] as? String else {
            throw AppError("Antigravity did not return its native model catalog. Check CLI compatibility.")
        }
        let options = rows.compactMap { row -> RuntimeModelOption? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return RuntimeModelOption(choice: .init(model: id), title: row["label"] as? String ?? id)
        }
        return RuntimeModelCatalog(defaultModel: .init(model: model), models: options)
    }

    private func receive(_ frame: [String: Any], _ session: Session) {
        do {
            let events = try session.state.receive(frame)
            if frame["event"] as? String == "init" {
                session.timeout?.cancel(); session.timeout = nil
                let open = session.opening; session.opening = nil; open?.resume(returning: result(session))
            }
            let body = frame["step_update"] as? [String: Any] ?? [:]
            if (frame["event"] as? String == "step_update" && body["step_type"] as? String == "user_input") || frame["event"] as? String == "result" {
                let sent = session.submission; session.submission = nil
                sent?.resume(returning: ["accepted": true, "turn_id": session.state.turnID])
            }
            if !session.state.active, session.opening == nil { session.timeout?.cancel(); session.timeout = nil }
            for event in events { onEvent?(event.name, event.payload) }
        } catch { failed(session, error) }
    }

    private func timeout(_ session: Session, seconds: UInt64, message: String) {
        session.timeout?.cancel()
        session.timeout = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self, let session else { return }; self.failed(session, AppError(message))
        }
    }
    private func failed(_ session: Session, _ error: Error) {
        guard sessions.removeValue(forKey: session.key) != nil else { return }
        session.close(error)
        if let id = session.state.sessionID { onEvent?("session.disconnected", ["session_id": id, "message": error.localizedDescription]) }
    }
    func disconnect() {
        generation = UUID()
        let owned = sessions.values; sessions.removeAll(); executable = nil
        for session in owned { session.close(AppError("Antigravity CLI disconnected. Resume its native conversation before sending again.")) }
        catalogs.removeAll()
        onConnectionChange?(false, nil)
    }
}
