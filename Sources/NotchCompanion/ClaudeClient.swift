import Foundation

@MainActor
final class ClaudeClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let profileID: String
    private var executable: URL?
    private let executableOverride: URL?
    private var sessions: [String: Session] = [:]

    @MainActor private final class Session {
        let process = NativeJSONProcess()
        let cwd: URL
        var state: ClaudeProtocolState
        var info: [String: Any] = [:]
        var catalog = RuntimeModelCatalog()
        var effortOverride: String?
        /// The profile's own Ultracode, whatever the model, read when the process opens; nil when the CLI does not report it.
        var nativeUltracode: Bool?
        /// Launched with bypass allowed, and whether native history exists to resume.
        var allowsBypass = false
        var resumable = false
        /// The profile's own mode, read before the first override; nil while none is applied.
        var inheritedMode: String?
        var appliedMode: String?
        /// The companion's delegation server for this session, re-sent if the process reopens.
        var delegation: [String: Any]?
        var controls: [String: CheckedContinuation<[String: Any], Error>] = [:]
        var timeouts: [String: Task<Void, Never>] = [:]
        var send: CheckedContinuation<[String: Any], Error>?
        var sendTimeout: Task<Void, Never>?
        var steers: [String: CheckedContinuation<[String: Any], Error>] = [:]
        var steerTimeouts: [String: Task<Void, Never>] = [:]
        var steeringReceipts = Set<String>()
        var images: [String] = []
        init(id: String, cwd: URL) { state = ClaudeProtocolState(sessionID: id); self.cwd = cwd }
        func close(_ error: Error) {
            process.stop()
            for task in timeouts.values { task.cancel() }; timeouts.removeAll()
            let pending = controls.values; controls.removeAll()
            for value in pending { value.resume(throwing: error) }
            sendTimeout?.cancel(); sendTimeout = nil
            let submitted = send; send = nil; submitted?.resume(throwing: error)
            for task in steerTimeouts.values { task.cancel() }; steerTimeouts.removeAll()
            let steering = steers.values; steers.removeAll()
            for value in steering { value.resume(throwing: error) }
        }
    }

    init(profileID: String, executableURL: URL? = nil) {
        self.profileID = URL(fileURLWithPath: profileID).standardizedFileURL.resolvingSymlinksInPath().path
        executableOverride = executableURL
    }

    static let capabilities: [String: Bool] = ["resume": true, "attachments": true, "images": true,
        "approvals": true, "questions": true, "modelSelection": true, "contextUsage": true, "delegation": true]

    static func arguments(id: String, resume: Bool, allowBypass: Bool = false, delegation: [String: Any]? = nil, computerUse executable: String? = nil) throws -> [String] {
        guard UUID(uuidString: id) != nil else { throw AppError("Claude Code requires a valid saved native session UUID.") }
        let allowed = (delegation.map { [allowedDelegationTools($0)] } ?? []) + (executable == nil ? [] : [computerUseTools])
        // Only a session the user gave Full access may switch into bypass; the
        // flag alone leaves the native mode unchanged.
        return ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
                "--forward-subagent-text", resume ? "--resume=\(id)" : "--session-id=\(id)"]
            + (allowBypass ? ["--allow-dangerously-skip-permissions"] : [])
            + (executable.map { ["--mcp-config", computerUseConfig($0)] } ?? [])
            + (allowed.isEmpty ? [] : ["--allowedTools", allowed.joined(separator: ",")])
    }

    /// Pre-allowed as the CLI's own setup does; the per-app grant is the approval.
    static let computerUseTools = "mcp__computer-use__*"

    /// Claude's built-in computer-use server, which the CLI adds itself only to
    /// interactive sessions. The CLI still runs it in-process and applies its own
    /// gates: the project's /mcp switch, the plan and the per-app grant.
    static func computerUseConfig(_ executable: String) -> String {
        let config = ["mcpServers": ["computer-use": ["type": "stdio", "command": executable, "args": ["--computer-use-mcp"]]]]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Pre-approves the companion's tools, as T3 Code does; a Plan session only the read-only ones.
    static func allowedDelegationTools(_ delegation: [String: Any]) -> String {
        let readOnly = delegation["read_only_tools"] as? [String] ?? []
        let prefix = "mcp__\(DelegationServer.name)__"
        return readOnly.isEmpty ? prefix + "*" : readOnly.map { prefix + $0 }.joined(separator: ",")
    }

    /// Added over stdin so the token stays out of argv; the user's own servers stay.
    static func delegationServers(_ delegation: [String: Any]) -> [String: Any] {
        [DelegationServer.name: ["type": "http", "url": delegation["url"] as? String ?? "",
                                 "headers": ["Authorization": "Bearer " + (delegation["token"] as? String ?? "")],
                                 "timeout": 65 * 60 * 1000]]
    }

    static let nativePermissionModes: [PermissionMode: String] = [.ask: "default", .autoEdit: "acceptEdits", .plan: "plan", .fullAccess: "bypassPermissions"]

    /// The mode a process opened in, as a `PermissionMode` raw value or, for modes the companion does not offer, a title.
    static func profilePermission(_ native: String?) -> String? {
        guard let native else { return nil }
        let mapped = native == "manual" ? "default" : native
        return nativePermissionModes.first { $0.value == mapped }?.key.rawValue ?? ["auto": "Auto", "dontAsk": "Don't ask"][native] ?? native
    }

    static func trustedDirectory(_ params: [String: Any]) throws -> URL {
        guard params["project_trusted"] as? Bool == true else { throw AppError("Trust this project in Notch Companion before launching native project hooks and tools.") }
        guard let path = params["cwd"] as? String, path.hasPrefix("/") else { throw AppError("Choose this conversation's existing project folder before starting the native agent.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw AppError("The saved project folder is unavailable. Restore it before resuming this conversation.") }
        return url
    }

    func connect() async throws {
        executable = try executableOverride ?? RuntimeInstallation.executable(for: .claude)
        guard (try? URL(fileURLWithPath: profileID).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            executable = nil; throw AppError("Choose the existing Claude Code configuration folder and sign in with the native claude CLI first.")
        }
        onConnectionChange?(true, "Claude Code found. Authentication and project resources are checked when opening a session.")
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard executable != nil else { throw AppError("Claude Code is disconnected. Reconnect in Settings.") }
        if method == "runtime.models" {
            // An untrusted project is read from a neutral folder so its settings stay unloaded.
            let cwd = params["project_trusted"] as? Bool == true ? try Self.trustedDirectory(params) : FileManager.default.temporaryDirectory
            if let session = sessions.values.first(where: { $0.cwd == cwd && $0.process.isRunning }) { return ["catalog": session.catalog] }
            return ["catalog": try await probeCatalog(cwd: cwd)]
        }
        // Claude reports limits only in rate_limit_event frames during turns.
        if method == "runtime.rateLimits" { return [:] }
        if method == "session.create" || method == "session.resume" {
            let cwd = try Self.trustedDirectory(params)
            let id = method == "session.create" ? UUID().uuidString.lowercased() : params["session_id"] as? String ?? ""
            if let existing = sessions[id] {
                guard existing.cwd == cwd else { throw AppError("This Claude Code session belongs to a different working folder.") }
                if let delegation = params["delegation"] as? [String: Any] {
                    existing.delegation = delegation
                    _ = try? await control(existing, ["subtype": "mcp_set_servers", "servers": Self.delegationServers(delegation)])
                }
                return sessionResult(existing)
            }
            let session = try await open(id: id, cwd: cwd, resume: method == "session.resume",
                                         allowBypass: params["permission_mode"] as? String == PermissionMode.fullAccess.rawValue,
                                         delegation: params["delegation"] as? [String: Any])
            return sessionResult(session)
        }
        let id = params["session_id"] as? String ?? ""
        guard let session = sessions[id], session.process.isRunning else { throw AppError("This Claude Code session is disconnected. Resume it before sending.") }
        switch method {
        case "session.model.set":
            guard !session.state.active, session.state.children.isEmpty, session.state.requests.isEmpty else { throw AppError("Wait for Claude Code and delegated work before changing models.") }
            let effort = params["reasoning_effort"] as? String
            guard let model = params["model"] as? String,
                  session.catalog.contains(RuntimeModelChoice(model: model, reasoningEffort: effort, ultracode: params["ultracode"] as? Bool)) else {
                throw AppError("Choose a model and effort from Claude Code's current native catalog.")
            }
            _ = try await control(session, ["subtype": "set_model", "model": model])
            // Claude drops Ultracode whenever effort changes, so it is restated each time: the
            // conversation's choice, or else the profile's own (off on a model without it).
            let offersUltracode = session.catalog.option(for: RuntimeModelChoice(model: model))?.offersUltracode == true
            let ultracode = params["ultracode"] as? Bool ?? session.nativeUltracode.map { $0 && offersUltracode }
            if effort != nil || session.effortOverride != nil || ultracode != nil ||
                session.catalog.option(for: RuntimeModelChoice(model: model))?.reasoningEfforts.isEmpty == false {
                // Native flag settings affect only this frontend, not user or
                // project settings. Null restores Claude's inherited effort.
                var flags: [String: Any] = ["effortLevel": effort as Any? ?? NSNull()]
                if let ultracode { flags["ultracode"] = ultracode }
                _ = try await control(session, ["subtype": "apply_flag_settings", "settings": flags])
                session.effortOverride = effort
                let settings = try await control(session, ["subtype": "get_settings"])
                let applied = settings["applied"] as? [String: Any]
                if ultracode == true, applied?["ultracodeAvailable"] as? Bool != true {
                    throw AppError(applied?["ultracodeAvailable"] == nil
                        ? "This Claude Code version does not report Ultracode. Update it through its native installer. Your message was not sent."
                        : "Claude Code's Ultracode needs dynamic workflows, which are off (see /config in Claude Code). Your message was not sent.")
                }
                // A CLI without the field cannot have Ultracode on.
                guard let applied, applied["model"] as? String == model,
                      effort == nil || applied["effort"] as? String == effort,
                      ultracode == nil || (applied["ultracode"] as? Bool ?? false) == ultracode else {
                    throw AppError("Claude Code did not apply the selected model and effort. Your message was not sent.")
                }
            }
            // The control response acknowledges the selection but does not
            // report an effective model. Only native metadata updates that.
            return ["model_override_accepted": true]
        case "session.permission.set":
            guard !session.state.active, session.state.children.isEmpty, session.state.requests.isEmpty else { throw AppError("Wait for Claude Code and delegated work before changing permissions.") }
            let mode = try (params["mode"] as? String).map { raw -> String in
                guard let mode = PermissionMode(rawValue: raw), let native = Self.nativePermissionModes[mode] else { throw AppError("Claude Code does not offer this permission mode.") }
                return native
            }
            guard mode != nil || session.appliedMode != nil else { return [:] } // Inherit, nothing to restore.
            var target = session
            if target.appliedMode == nil {
                let settings = try await control(target, ["subtype": "get_settings"])
                let configured = ((settings["effective"] as? [String: Any])?["permissions"] as? [String: Any])?["defaultMode"] as? String
                target.inheritedMode = configured == nil || configured == "manual" ? "default" : configured
            }
            let native = mode ?? target.inheritedMode ?? "default"
            if native == "bypassPermissions", !target.allowsBypass { target = try await reopen(target, allowBypass: true) }
            let applied = try await control(target, ["subtype": "set_permission_mode", "mode": native])
            guard applied["mode"] == nil || applied["mode"] as? String == native else {
                throw AppError("Claude Code did not apply the selected permission mode. Your message was not sent.")
            }
            target.appliedMode = mode
            if mode == nil {
                // Default restored the configured mode, which can differ from the one the process opened in.
                target.info["profile_permission_mode"] = Self.profilePermission(native)
                emit(target.state.event("session.info", ["profile_permission_mode": target.info["profile_permission_mode"] ?? native]))
            }
            return ["mode": native]
        case "file.attach", "image.attach":
            let url = try Self.attachment(params)
            if method == "image.attach" {
                guard ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max <= 8 * 1024 * 1024 else { throw AppError("Claude Code image input requires a PNG, JPEG, GIF, or WebP of at most 8 MB.") }
                if !session.images.contains(url.path) { session.images.append(url.path) }
                return ["path": url.path]
            }
            return ["ref_text": "Attached local file (read with your native file tools and permissions): " + CodexProtocolState.describe([url.path])]
        case "image.detach":
            if let path = params["path"] as? String { session.images.removeAll { $0 == path } }; return [:]
        case "prompt.steer":
            guard session.state.supportsSteering, session.state.active, session.state.result == nil, session.state.requests.isEmpty else {
                throw BusyInputRejection(message: "This Claude Code session has no running turn that accepts steering. Use Command–Return to queue.")
            }
            let id = params["turn_id"] as? String ?? UUID().uuidString
            var blocks: [[String: Any]] = [["type": "text", "text": params["text"] as? String ?? ""]]
            do {
                for path in params["images"] as? [String] ?? [] {
                    let url = try Self.attachment(["path": path])
                    let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()]
                    guard let mime, (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 8 * 1024 * 1024 else {
                        throw BusyInputRejection(message: "Claude Code requires a PNG, JPEG, GIF or WebP image of at most 8 MB.")
                    }
                    let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
                    guard bytes.count <= 8 * 1024 * 1024 else { throw BusyInputRejection(message: "The attached image is too large.") }
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": bytes.base64EncodedString()]])
                }
            } catch { throw BusyInputRejection(message: error.localizedDescription) }
            session.state.pendingSteering.insert(id)
            return try await withCheckedThrowingContinuation { continuation in
                session.steers[id] = continuation
                session.steerTimeouts[id] = Task { @MainActor [weak session] in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    guard let session else { return }
                    session.steerTimeouts.removeValue(forKey: id)
                    session.steers.removeValue(forKey: id)?.resume(throwing: AppError("Claude Code did not acknowledge this steering message. Check its native history before retrying."))
                }
                // This path is used only for the human composer's steering input.
                do { try session.process.send(["type": "user", "session_id": session.state.sessionID, "uuid": id,
                    "parent_tool_use_id": NSNull(), "priority": "now", "origin": ["kind": "human"],
                    "message": ["role": "user", "content": blocks]]) }
                catch { failed(session, error) }
            }
        case "prompt.submit":
            let turn = params["turn_id"] as? String ?? UUID().uuidString
            var blocks: [[String: Any]] = [["type": "text", "text": params["text"] as? String ?? ""]]
            var started = false
            do {
                for path in session.images {
                    let url = try Self.attachment(["path": path])
                    let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
                    guard bytes.count <= 8 * 1024 * 1024 else { throw AppError("The attached image is too large.") }
                    let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()] ?? "image/png"
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": bytes.base64EncodedString()]])
                }
                try session.state.begin(turn)
                started = true
                session.resumable = true
                emit(session.state.event("message.start", ["role": "assistant"]))
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        session.send = continuation
                        session.sendTimeout = Task { @MainActor [weak self, weak session] in
                            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                            guard let self, let session else { return }
                            self.failed(session, AppError("Claude Code did not acknowledge the send. Its delivery is uncertain; check native history before retrying."))
                        }
                        do { try session.process.send(["type": "user", "session_id": id, "uuid": turn, "parent_tool_use_id": NSNull(), "message": ["role": "user", "content": blocks]]) }
                        catch { failed(session, error) }
                    }
                } onCancel: { Task { @MainActor [weak self, weak session] in if let self, let session { self.failed(session, CancellationError()) } } }
            } catch {
                if started { failed(session, error) }
                throw error
            }
        case "session.interrupt":
            session.state.interrupted = true
            for child in session.state.children {
                _ = try await control(session, ["subtype": "stop_task", "task_id": child])
            }
            var request: [String: Any] = ["subtype": "interrupt"]
            if session.state.supportsSteering { request["cancel_queued"] = true }
            _ = try await control(session, request)
            // The process remains open for native task/idle receipts. A control
            // acknowledgement alone is not proof that delegated work settled.
            return ["interrupted": true]
        case "approval.respond", "clarify.respond":
            if let reply = try session.state.answer(params, approval: method == "approval.respond") { try session.process.send(reply) }
            return ["resolved": true]
        case "session.rename": return ["renamed": false, "local_only": true]
        default: throw AppError("Claude Code does not support this operation through the companion.")
        }
    }

    static func attachment(_ params: [String: Any]) throws -> URL {
        guard let path = params["path"] as? String, path.hasPrefix("/") else { throw AppError("Choose a local attachment.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values?.isRegularFile == true, values?.isReadable == true else { throw AppError("The attachment is no longer readable.") }
        return url
    }

    /// Bypass can only be allowed at launch: reopen this idle conversation with it.
    private func reopen(_ old: Session, allowBypass: Bool) async throws -> Session {
        let id = old.state.sessionID
        sessions.removeValue(forKey: id)
        old.close(AppError("Claude Code reopened this session to allow Full access."))
        let session = try await open(id: id, cwd: old.cwd, resume: old.resumable, allowBypass: allowBypass, delegation: old.delegation)
        session.inheritedMode = old.inheritedMode
        return session
    }

    private func open(id: String, cwd: URL, resume: Bool, allowBypass: Bool = false, delegation: [String: Any]? = nil) async throws -> Session {
        let arguments = try Self.arguments(id: id, resume: resume, allowBypass: allowBypass, delegation: delegation, computerUse: executable?.path)
        let session = Session(id: id, cwd: cwd)
        session.allowsBypass = allowBypass
        session.delegation = delegation
        session.resumable = resume
        sessions[id] = session
        session.process.onFrame = { [weak self, weak session] frame in
            guard let self, let session, self.sessions[id] === session else { return }; self.receive(frame, session)
        }
        session.process.onFailure = { [weak self, weak session] error in
            guard let self, let session, self.sessions[id] === session else { return }; self.failed(session, error)
        }
        var environment = RuntimeEnvironment.native(runtime: .claude, profileID: profileID)
        environment["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1"
        environment["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = "1"
        do {
            try await NativeJSONProcess.awaitPendingStops()
            guard sessions[id] === session, let executable else {
                throw AppError("Claude Code connection changed before the session opened. No message was sent.")
            }
            try session.process.start(executable: executable, arguments: arguments, environment: environment, cwd: cwd)
            var initialize: [String: Any] = ["subtype": "initialize", "forwardSubagentText": true,
                                             "supportedDialogKinds": [ClaudeProtocolState.computerUseDialog]]
            // Appended to Claude's own system prompt; the profile's instructions stay.
            if let instructions = delegation?["instructions"] as? String { initialize["appendSystemPrompt"] = instructions }
            let initialized = try await control(session, initialize)
            guard let models = initialized["models"] as? [[String: Any]] else { throw AppError("This Claude Code version does not provide the required structured initialization. Update it through its native installer.") }
            // Older CLIs return an initial state but do not stream subsequent
            // state changes. Only an observed state event enables that gate.
            if initialized["session_state"] as? String == "running" { session.state.active = true }
            session.catalog = Self.catalog(models)
            // What Default permissions means here: the profile's own mode, e.g. bypassPermissions from its settings.
            // An older CLI reports none: null clears a saved mode rather than leaving it stale.
            session.info["profile_permission_mode"] = Self.profilePermission(initialized["current_permission_mode"] as? String) ?? NSNull()
            let settings = try? await control(session, ["subtype": "get_settings"])
            // A rejected read is tolerated; a process that stopped during it is not.
            guard sessions[id] === session else { throw AppError("Claude Code stopped while opening this session. No message was sent.") }
            // `ultracode` holds only on a model that offers it; older CLIs report nothing else.
            let applied = settings?["applied"] as? [String: Any]
            session.nativeUltracode = applied?["ultracodeRequested"] as? Bool ?? applied?["ultracode"] as? Bool
            session.info["profile_ultracode"] = session.nativeUltracode
            if let delegation {
                // Delegation is additive: a server that does not connect leaves the session usable.
                let added = try? await control(session, ["subtype": "mcp_set_servers", "servers": Self.delegationServers(delegation)])
                if added == nil || (added?["errors"] as? [String: Any])?.isEmpty == false {
                    emit(session.state.event("runtime.notice", ["message": "Claude Code did not add Notch Companion's delegation tools to this session."]))
                }
            }
            return session
        } catch { failed(session, error); throw error }
    }

    static let probeArguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                 "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config"]

    /// Reads the catalog before a session exists, as T3 Code does: initialize only,
    /// so no prompt, saved session, hooks or MCP servers.
    private func probeCatalog(cwd: URL) async throws -> RuntimeModelCatalog {
        guard let executable else { throw AppError("Claude Code is disconnected. Reconnect in Settings.") }
        let process = NativeJSONProcess()
        defer { process.stop() }
        var environment = RuntimeEnvironment.native(runtime: .claude, profileID: profileID)
        environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        let models: [[String: Any]] = try await withCheckedThrowingContinuation { continuation in
            var pending: CheckedContinuation<[[String: Any]], Error>? = continuation
            func finish(_ result: Result<[[String: Any]], Error>) { pending?.resume(with: result); pending = nil }
            process.onFrame = { frame in
                guard frame["type"] as? String == "control_response", let response = frame["response"] as? [String: Any] else { return }
                if let models = (response["response"] as? [String: Any])?["models"] as? [[String: Any]] { finish(.success(models)) }
                else { finish(.failure(AppError("Claude Code did not report its models. Check its sign-in and version."))) }
            }
            process.onFailure = { finish(.failure($0)) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                finish(.failure(AppError("Claude Code did not report its models.")))
            }
            do {
                try process.start(executable: executable, arguments: Self.probeArguments, environment: environment, cwd: cwd)
                try process.send(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "initialize"]])
            } catch { finish(.failure(error)) }
        }
        return Self.catalog(models)
    }

    static func catalog(_ rows: [[String: Any]]) -> RuntimeModelCatalog {
        var models: [RuntimeModelOption] = []
        for row in rows where row["disabled"] as? Bool != true {
            guard let model = row["resolvedModel"] as? String ?? row["value"] as? String, !model.isEmpty else { continue }
            let efforts = row["supportsEffort"] as? Bool == true ? row["supportedEffortLevels"] as? [String] ?? [] : []
            // Claude Code offers Ultracode on the models it offers xhigh on; get_settings confirms it before a send.
            let option = RuntimeModelOption(choice: RuntimeModelChoice(model: model), title: row["displayName"] as? String ?? model,
                reasoningEfforts: efforts, offersUltracode: efforts.contains("xhigh"))
            // Default and a named alias often resolve to the same model. Keep
            // unique row identities and prefer the named model's label.
            if let index = models.firstIndex(where: { $0.id == option.id }) {
                if row["value"] as? String != "default" { models[index] = option }
            } else { models.append(option) }
        }
        let nativeDefault = rows.first { $0["value"] as? String == "default" && $0["disabled"] as? Bool != true }?["resolvedModel"] as? String
        return RuntimeModelCatalog(defaultModel: nativeDefault.map { RuntimeModelChoice(model: $0) }, models: models,
            note: "Native Claude Code models. Changes apply to this session; the native default is preserved.")
    }

    private func sessionResult(_ session: Session) -> [String: Any] {
        var info = session.info; info["capabilities"] = Self.capabilities.merging(["steering": session.state.supportsSteering]) { _, new in new }
        info["capability_note"] = "Native Claude Code CLI. Resume keeps native history; complete history reconciliation is unavailable through this stream. Commercial subscription compatibility requires vendor clarification."
        return ["session_id": session.state.sessionID, "stored_session_id": session.state.sessionID, "cwd": session.cwd.path,
                "profile_id": profileID, "running": session.state.active || !session.state.children.isEmpty,
                "history_complete": false, "accepted_turn_ids": Array(session.steeringReceipts), "info": info, "catalog": session.catalog]
    }

    private func control(_ session: Session, _ body: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.controls[id] = continuation
                session.timeouts[id] = Task { @MainActor [weak self, weak session] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard let self, let session else { return }
                    self.failed(session, AppError("Claude Code did not answer a control request. Reconnect to check the saved session."))
                }
                do { try session.process.send(["type": "control_request", "request_id": id, "request": body]) }
                catch { failed(session, error) }
            }
        } onCancel: { Task { @MainActor [weak self, weak session] in if let self, let session { self.failed(session, CancellationError()) } } }
    }

    private func receive(_ frame: [String: Any], _ session: Session) {
        do {
            let type = frame["type"] as? String ?? ""
            if type == "control_response", let response = frame["response"] as? [String: Any], let id = response["request_id"] as? String,
               let pending = session.controls.removeValue(forKey: id) {
                session.timeouts.removeValue(forKey: id)?.cancel()
                if response["subtype"] as? String == "success" { pending.resume(returning: response["response"] as? [String: Any] ?? [:]) }
                else { pending.resume(throwing: AppError("Claude Code rejected a structured control request. Check native setup and CLI compatibility.")) }
                return
            }
            if type == "control_request" {
                guard (frame["request_id"] as? String)?.isEmpty == false else { throw AppError("Claude Code sent an interaction without a request identity.") }
                let translated = session.state.interaction(frame)
                for event in translated.events { emit(event) }
                if let reply = translated.reply { try session.process.send(reply) }
                return
            }
            let steeringID = type == "command_lifecycle" ? frame["command_uuid"] as? String : type == "user" ? frame["uuid"] as? String : nil
            let ownedSteer = steeringID.map { session.state.pendingSteering.contains($0) || session.steers[$0] != nil || session.steeringReceipts.contains($0) } ?? false
            let events = try session.state.receive(frame)
            if frame["parent_tool_use_id"] as? String == nil {
                let state = frame["state"] as? String ?? ""
                if ownedSteer, let id = steeringID, type == "user" || ["queued", "started", "completed", "refused", "cancelled", "discarded"].contains(state) {
                    if type == "user" || ["queued", "started", "completed"].contains(state) { session.steeringReceipts.insert(id) }
                    session.steerTimeouts.removeValue(forKey: id)?.cancel()
                    let pending = session.steers.removeValue(forKey: id)
                    if state == "refused" { pending?.resume(throwing: BusyInputRejection(message: "Claude Code refused this steering message.")) }
                    else if ["cancelled", "discarded"].contains(state) {
                        pending?.resume(throwing: AppError("Claude Code cancelled the steering message; delivery is unconfirmed."))
                        emit(session.state.event("runtime.notice", ["message": "Claude Code cancelled a steering message. Check the conversation before sending it again."]))
                    } else { pending?.resume(returning: ["steered": true, "turn_id": id]) }
                }
            }
            if (type == "user" && frame["uuid"] as? String == session.state.turnID) || type == "result" {
                session.sendTimeout?.cancel(); session.sendTimeout = nil
                let pending = session.send; session.send = nil; session.images.removeAll()
                pending?.resume(returning: ["accepted": true, "turn_id": session.state.turnID])
            }
            for event in events {
                if event.name == "session.info" {
                    if event.payload["context_reset"] as? Bool == true ||
                        (event.payload["model"] as? String).map({ $0 != session.info["model"] as? String }) == true {
                        session.info.removeValue(forKey: "usage")
                    }
                    session.info.merge(event.payload.filter { $0.key != "session_id" && $0.key != "turn_tokens" }) { _, new in new }
                }
                emit(event)
            }
        } catch { failed(session, error) }
    }

    private func emit(_ event: ClaudeProtocolState.Event) { onEvent?(event.name, event.payload) }
    private func failed(_ session: Session, _ error: Error) {
        guard sessions[session.state.sessionID] === session else { return }
        sessions.removeValue(forKey: session.state.sessionID); session.close(error)
        emit(session.state.event("session.disconnected", ["message": error.localizedDescription]))
    }
    func disconnect() {
        let owned = sessions.values; sessions.removeAll(); executable = nil
        for session in owned { session.close(AppError("Claude Code disconnected. Resume its native session before sending again.")) }
        onConnectionChange?(false, nil)
    }
}
