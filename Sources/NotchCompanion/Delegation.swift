import Foundation
import CryptoKit

extension RuntimeKind {
    /// Harnesses that take the companion's delegation server through a supported
    /// per-run or per-session option. OpenCode does from 2.0 (`AppModel.hostsDelegation(_:)`);
    /// Antigravity takes it over ACP.
    var hostsDelegation: Bool { [.claude, .codex, .opencode, .deepseek, .pi, .cursor, .antigravity].contains(self) }
    /// Harnesses that accept input into a running turn.
    var steersTurns: Bool { self == .codex }
}

extension PermissionMode {
    /// T3 Code's ranking: Ask < Auto-edit < Full access, and Plan only narrows.
    var delegationRank: Int {
        switch self { case .plan: return 0; case .ask: return 1; case .autoEdit: return 2; case .fullAccess: return 3 }
    }
    /// T3 Code's `runtimeMode` name; Plan is its `interactionMode` instead.
    var runtimeModeName: String? {
        switch self { case .ask: return "approval-required"; case .autoEdit: return "auto-accept-edits"; case .fullAccess: return "full-access"; case .plan: return nil }
    }
}

/// Cross-agent delegation as T3 Code does it: names, limits and wording.
enum Delegation {
    static let next = "Completion wakes this session, so end your turn. Do not wait on it or poll it."
    static let inlineResultBytes = 16_000
    static let maxTaskCharacters = 120_000
    static let defaultWait: TimeInterval = 10 * 60
    static let maxWait: TimeInterval = 60 * 60
    static let roles = ["implementation", "research", "review", "design", "test", "general"]
    /// Pre-approved for a Plan session (T3's read-only set); the rest still
    /// ask. `task_status` and `notch_session_read` acknowledge results, so they are not.
    static let readOnlyTools = ["orchestrator_capabilities", "notch_session_list", "notch_session_wait", "pending_request_list", "pending_request_read"]
    static let maxBatchSessions = 20

    /// Appended to each hosting session's own instructions. Codex truncates
    /// one context entry above 4,000 bytes, so this stays well below.
    static let instructions = """
    ## Notch Companion delegation

    Notch Companion adds the `notch` tools. Ordinary work needs none of them.

    - Prefer your own subagent tool when the child would use your harness and model, needs no other settings, and you wait for it in this turn. Use `delegate_task` for another harness or model, settings the user asked for, or background work.
    - Call `orchestrator_capabilities` once before your first `delegate_task`, and again only after an error or when the user names another harness. Use only the harnesses and models it lists. If the one you need is unavailable, say so. Never switch harness or model unless the user asks.
    - Every new review or re-check is a new `delegate_task` with its brief, findings and objections. Fix small review findings yourself.
    - After an async `delegate_task`, follow its `next`: end your turn and the result arrives as a new message. Do not poll it with `task_status`, sleeps or watchers. Stop a delegate you replace or no longer need with `task_cancel`.
    - If you are a subagent or child, do the work yourself. Start no delegates unless your task says to.
    - `create_sessions` makes new top-level sessions, only when the user asks for a new session. "Subagent", "delegate" and "parallel" never mean one. Never use `notch_session_send` for a new review; stop a delegate with `task_cancel`, never `notch_session_interrupt`.
    - Given a session id, read it with `notch_session_read` before you answer about it.
    - A delegate's question arrives as a notice: answer it with `pending_request_respond` if you can, otherwise ask the user. Approvals are the user's alone.
    - These tools may be deferred behind tool search: load one by name before you call it.
    """

    /// Retries with the same key reach the same task; without one every call is new work.
    static func derivedID(caller: String, operation: String, clientRequestID: String?) -> String {
        guard let clientRequestID else { return UUID().uuidString.lowercased() }
        let digest = Array(SHA256.hash(data: Data("\(caller)\u{0}\(operation)\u{0}\(clientRequestID)".utf8)))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)].joined(separator: "-")
    }

    static func clientRequestID(_ arguments: [String: Any]) throws -> String? {
        guard let value = arguments["clientRequestId"] else { return nil }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 256 else {
            throw DelegationFailure("invalid_request", "clientRequestId must be 1 to 256 characters.")
        }
        return text
    }

    /// T3's `runtimeMode` and `interactionMode`; nil inherits.
    static func requestedMode(_ arguments: [String: Any]) throws -> PermissionMode? {
        let interaction = arguments["interactionMode"] as? String ?? "inherit"
        let runtime = arguments["runtimeMode"] as? String ?? "inherit"
        guard ["inherit", "default", "plan"].contains(interaction) else { throw DelegationFailure("invalid_request", "interactionMode must be inherit, default or plan.") }
        if interaction == "plan" { return .plan }
        switch runtime {
        case "inherit": return nil
        case "approval-required": return .ask
        case "auto-accept-edits": return .autoEdit
        case "full-access": return .fullAccess
        default: throw DelegationFailure("invalid_request", "runtimeMode must be inherit, approval-required, auto-accept-edits or full-access.")
        }
    }

    /// A child inherits or narrows its parent's mode, never escalates. An
    /// inherited mode steps down to the broadest one the target maps; an
    /// explicit one the target lacks is rejected. Inherit's native rank is
    /// unknown, so below it only Plan and Ask can be proven narrower.
    static func childMode(parent: PermissionMode?, requested: PermissionMode?, supported: [PermissionMode], parentInteractionPlan: Bool = false) throws -> PermissionMode? {
        if let requested {
            let ceiling = parent?.delegationRank ?? PermissionMode.ask.delegationRank
            guard requested.delegationRank <= ceiling else {
                throw DelegationFailure(requested == .plan || parent == .plan ? "interaction_mode_escalation_denied" : "runtime_mode_escalation_denied",
                                        "A child may only keep or narrow this session's permission mode (\(parent?.title ?? "Inherit")).")
            }
            guard supported.contains(requested) else {
                throw DelegationFailure("invalid_request", "That harness does not offer \(requested.title).")
            }
            return requested
        }
        guard let parent else { return nil }
        if let mode = supported.filter({ $0.delegationRank <= parent.delegationRank }).max(by: { $0.delegationRank < $1.delegationRank }) {
            return mode
        }
        // The target's own settings are unknown, and may ask for nothing.
        guard parent == .fullAccess else {
            throw DelegationFailure(parent == .plan ? "interaction_mode_escalation_denied" : "runtime_mode_escalation_denied",
                                    "That harness has no permission mode at or below this session's (\(parent.title)), so a child could run without its limits.")
        }
        return nil
    }

    /// The prefix of `text` within `limit` UTF-8 bytes, and whether it was cut.
    static func prefix(_ text: String, bytes limit: Int) -> (String, Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var result = ""
        var used = 0
        for character in text {
            used += String(character).utf8.count
            if used > limit { break }
            result.append(character)
        }
        return (result, true)
    }

    static func worktreeName(title: String, taskID: String) -> String {
        let slug = title.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return String(slug.prefix(40)) + (slug.isEmpty ? "" : "-") + String(taskID.prefix(8))
    }

    /// A new worktree and `notch/<name>` branch from the folder's repository
    /// HEAD, as T3 Code prepares a child checkout; uncommitted edits stay out.
    /// Returns the folder's counterpart inside it.
    nonisolated static func makeWorktree(from folder: String, name: String, root: URL) throws -> String {
        let source = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath()
        guard let top = try? WorkspaceChanges.run(["rev-parse", "--show-toplevel"], at: source.path).trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else {
            throw DelegationFailure("invalid_request", "isolation worktree needs your folder to be in a Git repository.")
        }
        let repository = URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(repository.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let worktree = root.appendingPathComponent(repository.lastPathComponent + "-" + digest, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            _ = try WorkspaceChanges.run(["worktree", "add", "-b", "notch/" + name, worktree.path, "HEAD"], at: repository.path, timeout: 120)
        } catch {
            throw DelegationFailure("orchestration_error", "Git could not create a worktree for the child. The repository needs a commit, and the branch notch/\(name) must not exist.")
        }
        let relative = source.path == repository.path ? "" : String(source.path.dropFirst(repository.path.count + 1))
        return relative.isEmpty ? worktree.path : worktree.appendingPathComponent(relative).path
    }

    static let tools: [[String: Any]] = {
        let clientRequestID: [String: Any] = ["type": "string", "maxLength": 256, "description": "Reuse it to retry the same call. A new call gets a new key."]
        let taskID: [String: Any] = ["type": "string", "description": "The taskId delegate_task returned."]
        let sessionID: [String: Any] = ["type": "string", "description": "A sessionId from notch_session_list or delegate_task."]
        let target: [String: Any] = ["type": "object", "properties": [
            "runtime": ["type": "string", "description": "A runtime id from orchestrator_capabilities. Default: yours."],
            "model": ["type": "string", "description": "A model id from orchestrator_capabilities. Default: the harness's configured model, or yours on the same harness."],
            "options": ["type": "object", "properties": ["effort": ["type": "string"]], "description": "Options from orchestrator_capabilities, such as {effort:'high'}."]],
            "additionalProperties": false]
        let runtimeMode: [String: Any] = ["type": "string", "enum": ["inherit", "approval-required", "auto-accept-edits", "full-access"], "description": "Omit unless the user asks for a supervised session. Above yours is rejected."]
        let interactionMode: [String: Any] = ["type": "string", "enum": ["inherit", "default", "plan"]]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [], readOnly: Bool) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
        }
        return [
            tool("orchestrator_capabilities", "The harnesses and models a delegated child task can use here, your inherited harness, model and permission mode, and the delegation features. Call once before your first delegate_task.",
                 ["search": ["type": "string", "maxLength": 200, "description": "Match model ids and labels. Replaces the short list."]], readOnly: true),
            tool("delegate_task", "Start a child task in another configured harness or model, in a new Notch Companion session inside yours. The child gets only this task text, no history. Async by default: its result wakes you as a new message.",
                 ["task": ["type": "string", "maxLength": maxTaskCharacters, "description": "The complete brief. The child sees nothing else."],
                  "target": target,
                  "title": ["type": "string", "maxLength": 512],
                  "role": ["type": "string", "enum": roles],
                  "isolation": ["type": "string", "enum": ["shared", "worktree"], "description": "'shared' (default): your working folder. 'worktree': a new Git worktree and branch from your HEAD, for a separate checkout per child. Uncommitted edits stay out."],
                  "mode": ["type": "string", "enum": ["async", "wait"], "description": "Default 'async'. 'wait' only if this turn needs the result. A question or approval ends the wait."],
                  "timeoutMs": ["type": "number", "description": "Mode 'wait' only. Default 10 min, at most 60 min. A timeout does not cancel the child."],
                  "clientRequestId": clientRequestID,
                  "runtimeMode": runtimeMode, "interactionMode": interactionMode],
                 required: ["task"], readOnly: false),
            tool("task_status", "A delegated task's status and, once finished, its result. Reading a finished result here means it will not wake you. Do not poll.",
                 ["taskId": taskID], required: ["taskId"], readOnly: true),
            tool("task_cancel", "Stop a delegated task and its own delegated tasks. Drops its pending wake.",
                 ["taskId": taskID, "reason": ["type": "string", "maxLength": 2000], "clientRequestId": clientRequestID],
                 required: ["taskId"], readOnly: false),
            tool("create_sessions", "Create new top-level Notch Companion sessions in your project, only when the user asks for new sessions. Not delegation.",
                 ["sessions": ["type": "array", "minItems": 1, "maxItems": maxBatchSessions, "items": ["type": "object", "properties": [
                     "prompt": ["type": "string", "maxLength": maxTaskCharacters, "description": "Sent as the first message. Omit for an empty session."],
                     "title": ["type": "string", "maxLength": 512], "target": target,
                     "runtimeMode": runtimeMode, "interactionMode": interactionMode], "additionalProperties": false]],
                  "clientRequestId": clientRequestID], required: ["sessions"], readOnly: false),
            tool("notch_session_list", "List the Notch Companion sessions in a project, newest first. Omit projectPath for yours. Page with the cursor.",
                 ["projectPath": ["type": "string"], "statuses": ["type": "array", "items": ["type": "string"], "maxItems": 10],
                  "titleContains": ["type": "string", "maxLength": 256], "includeSubagents": ["type": "boolean"],
                  "cursor": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 100]], readOnly: true),
            tool("notch_session_read", "Read a session by id: its messages (default) or `activity` with tool calls. Omit sessionId for yours. Page with afterPosition=nextPosition. Reading a finished child's result marks it delivered.",
                 ["sessionId": sessionID, "view": ["type": "string", "enum": ["messages", "activity"]],
                  "afterPosition": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                  "maxCharsPerItem": ["type": "integer", "minimum": 1, "maximum": 50000]], readOnly: false),
            tool("notch_session_send", "Send a message to a session. It cannot run with broader modes than yours. `auto` starts an idle session, steers a running turn where the harness can, or queues. `queue`: after the current turn. `steer`: into the running turn. `restart`: interrupt, then send. A send to a finished child starts a fresh task there and returns its taskId.",
                 ["sessionId": sessionID, "message": ["type": "string", "maxLength": maxTaskCharacters],
                  "mode": ["type": "string", "enum": ["auto", "queue", "steer", "restart"]], "clientRequestId": clientRequestID],
                 required: ["sessionId", "message"], readOnly: false),
            tool("notch_session_wait", "Wait for a session's turn to end. Idle: at once. Default 10 min, at most 60. On timeout, with `next` end your turn; without, call again.",
                 ["sessionId": sessionID, "timeoutMs": ["type": "number"]], required: ["sessionId"], readOnly: true),
            tool("notch_session_interrupt", "Interrupt a top-level session's running turn. No effect when idle. For a delegate, use task_cancel.",
                 ["sessionId": sessionID, "reason": ["type": "string", "maxLength": 2000], "clientRequestId": clientRequestID],
                 required: ["sessionId"], readOnly: false),
            tool("notch_session_update", "Rename a session (`action: 'rename'` with `title`). Omit sessionId for yours.",
                 ["sessionId": sessionID, "action": ["type": "string", "enum": ["rename"]], "title": ["type": "string", "maxLength": 512]],
                 required: ["action", "title"], readOnly: false),
            tool("pending_request_list", "List a session's pending questions. Omit sessionId for yours. Approvals are not listed.",
                 ["sessionId": sessionID], readOnly: true),
            tool("pending_request_read", "Read one pending question. Answer it with pending_request_respond.",
                 ["sessionId": sessionID, "requestId": ["type": "string"]], required: ["requestId"], readOnly: true),
            tool("pending_request_respond", "Answer one pending question. This cannot approve a permission request.",
                 ["sessionId": sessionID, "requestId": ["type": "string"],
                  "answers": ["type": "object", "description": "Question id to its answer (a string, or strings for a multi-select question).",
                              "additionalProperties": ["anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]]]],
                 required: ["requestId", "answers"], readOnly: false)
        ]
    }()
}

extension AppModel {
    func configureDelegation() {
        delegationServer.instructions = Delegation.instructions
        delegationServer.tools = { _ in Delegation.tools } // Children get every tool, including delegate_task.
        delegationServer.isActive = { [weak self] id in self?.sessions.first { $0.id == id }?.isBusy == true }
        delegationServer.ownsNative = { [weak self] caller, native in
            guard let session = self?.sessions.first(where: { $0.id == caller.sessionID }) else { return false }
            return session.storedID == native || session.agents.contains { $0.nativeID == native }
        }
        delegationServer.call = { [weak self] caller, name, arguments in
            guard let self else { throw DelegationFailure("orchestration_error", "Notch Companion is closing.") }
            return try await self.handleDelegationTool(caller, name: name, arguments: arguments)
        }
        // A wake marked before a crash that never reached its parent is sent again.
        for child in sessions where child.delegation?.wakeMessageID != nil {
            guard let message = child.delegation?.wakeMessageID,
                  let parent = sessions.first(where: { $0.id == child.parentSessionID }) else { continue }
            if !parent.messages.contains(where: { $0.id == message }) && parent.pendingSubmission?.id != message {
                update(child.id) { $0.delegation?.wokenCompletionID = nil; $0.delegation?.wakeMessageID = nil }
            }
        }
        syncDelegatedChildren()
    }

    /// A hosting harness, unless its connected installation reported it cannot host.
    func hostsDelegation(_ route: RuntimeRoute) -> Bool { route.runtime.hostsDelegation && delegationHosting[route] != false }

    /// The server, a fresh token and the instructions for a hosting session's launch.
    /// A session whose process still holds a live token keeps it.
    func delegationLaunch(for session: CompanionSession) async -> [String: Any]? {
        guard delegationEnabled, hostsDelegation(session.route), !session.isLegacyPrivate,
              !delegationServer.hasGrant(sessionID: session.id) else { return nil }
        guard let url = try? await delegationServer.start() else { return nil }
        let token = delegationServer.issueToken(for: DelegationCaller(sessionID: session.id, runtime: session.runtime,
                                                                       subagent: session.parentSessionID != nil))
        var launch: [String: Any] = ["url": url.absoluteString, "token": token, "instructions": Delegation.instructions,
                                     "read_only_tools": session.permissionMode == .plan ? Delegation.readOnlyTools : []]
        // ACP agents start this executable as their stdio bridge.
        if let bridge = Bundle.main.executableURL?.path { launch["bridge"] = bridge }
        return launch
    }

    func handleDelegationTool(_ caller: DelegationCaller, name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard delegationEnabled else { throw DelegationFailure("capability_denied", "Delegation is turned off in Notch Companion's settings.") }
        guard sessions.contains(where: { $0.id == caller.sessionID }) else { throw DelegationFailure("thread_not_found", "The calling session no longer exists.") }
        switch name {
        case "orchestrator_capabilities": return await delegationCapabilities(caller, search: arguments["search"] as? String)
        case "delegate_task": return try await delegateTask(caller, arguments)
        case "task_status":
            let child = try ownedTask(caller, arguments)
            acknowledgeDelegatedResult(child.id)
            return taskResult(child.id)
        case "task_cancel":
            let child = try ownedTask(caller, arguments)
            let settled = isDelegationSettled(child)
            await cancelDelegatedTree(child.id)
            return ["taskId": child.delegation?.taskID ?? "", "status": settled ? taskResult(child.id)["status"] ?? "cancelled" : "cancel_requested"]
        case "create_sessions": return try await createSessions(caller, arguments)
        case "notch_session_list": return try listSessions(caller, arguments)
        case "notch_session_read": return try readSession(caller, arguments)
        case "notch_session_send": return try await sendToSession(caller, arguments)
        case "notch_session_wait": return try await waitForSession(caller, arguments)
        case "notch_session_interrupt":
            let target = try targetSession(caller, arguments, control: true)
            // Delegates stop with task_cancel, which also drops their wakes.
            guard target.parentSessionID == nil else { throw DelegationFailure("thread_not_interruptible", "This is a delegated task. Use task_cancel.") }
            guard target.runtimeID != nil, target.isBusyIgnoringDelegates else { return ["sessionId": target.id, "status": "no_active_run"] }
            await interrupt(sessionID: target.id, cascade: false)
            return ["sessionId": target.id, "status": "interrupt_requested"]
        case "notch_session_update":
            let target = try targetSession(caller, arguments, control: false)
            guard arguments["action"] as? String == "rename",
                  let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                throw DelegationFailure("invalid_request", "Pass action 'rename' with a title.")
            }
            renameSession(target.id, title: title)
            return sessionSummary(sessions.first { $0.id == target.id } ?? target)
        case "pending_request_list":
            let target = try targetSession(caller, arguments, control: false)
            return ["sessionId": target.id, "requestIds": questionRequests(target).map(\.0)]
        case "pending_request_read":
            let (target, id, questions) = try pendingQuestion(caller, arguments)
            return ["sessionId": target.id, "requestId": id, "questions": questions.map { request -> [String: Any] in
                ["id": request.questionID ?? "0", "header": request.title, "question": request.detail,
                 "options": request.choices.map { ["label": $0, "description": request.choiceDetails[$0] ?? ""] },
                 "multiSelect": request.multiSelect, "allowCustomAnswer": request.allowsFreeText]
            }]
        case "pending_request_respond":
            let (target, id, questions) = try pendingQuestion(caller, arguments)
            let answers = arguments["answers"] as? [String: Any] ?? [:]
            for request in questions {
                let value = answers[request.questionID ?? "0"] ?? (questions.count == 1 ? answers.values.first : nil)
                let list = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
                guard !list.isEmpty else { throw DelegationFailure("invalid_request", "Answer question \(request.questionID ?? "0").") }
                await answer(request, choice: list.joined(separator: ", "), answers: request.multiSelect ? list : nil)
            }
            let open = questionRequests(sessions.first { $0.id == target.id } ?? target).contains { $0.0 == id }
            if open { throw DelegationFailure("orchestration_error", "The harness did not accept the answer.") }
            return ["sessionId": target.id, "requestId": id, "answered": true]
        default: throw DelegationFailure("invalid_request", "Unknown tool \(name).")
        }
    }

    // MARK: Tools

    /// Ready harnesses, plus the caller's own.
    func delegationRuntimes(for parent: CompanionSession) -> [RuntimeKind] {
        var runtimes = readyRuntimes
        if parent.runtime.isSupported, !parent.isLegacyPrivate, !runtimes.contains(parent.runtime) { runtimes.insert(parent.runtime, at: 0) }
        return runtimes
    }

    private func delegationCatalogKey(_ runtime: RuntimeKind, parent: CompanionSession) -> ModelCatalogKey {
        ModelCatalogKey(route: RuntimeRoute(runtime: runtime, profileID: RuntimeRoute.defaultProfile(runtime, defaults: preferences)),
                        cwd: parent.workspacePath ?? workspacePath)
    }

    private func trustsProject(_ runtime: RuntimeKind, path: String?) -> Bool {
        guard runtime.requiresProjectTrust else { return true }
        let canonical = URL(fileURLWithPath: path ?? workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
        return sessions.contains { $0.runtime == runtime && $0.trustedProjectPath == canonical }
    }

    func delegationCapabilities(_ caller: DelegationCaller, search: String?) async -> [String: Any] {
        guard let parent = sessions.first(where: { $0.id == caller.sessionID }) else { return [:] }
        let runtimes = delegationRuntimes(for: parent)
        await withTaskGroup(of: Void.self) { group in
            for runtime in runtimes where runtime.capabilities.modelSelection {
                let key = delegationCatalogKey(runtime, parent: parent)
                if modelCatalogs[key] == nil { group.addTask { @MainActor in await self.loadModels(for: key) } }
            }
        }
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = query.isEmpty ? 12 : 50
        let rows: [[String: Any]] = runtimes.map { runtime in
            let catalog = modelCatalogs[delegationCatalogKey(runtime, parent: parent)]
            let models = catalog?.matchingModels(query) ?? []
            let modes = runtime.capabilities.supportedPermissionModes
            var constraints: [String] = []
            if !trustsProject(runtime, path: parent.workspacePath) {
                constraints.append("The user must trust this project for \(runtime.title) in Notch Companion first.")
            }
            let modeAllowed = (try? Delegation.childMode(parent: parent.permissionMode, requested: nil, supported: modes)) != nil
                || parent.permissionMode == nil || parent.permissionMode == .fullAccess
            if !modeAllowed { constraints.append("It has no permission mode within yours, so it cannot run your child tasks.") }
            if !hostsDelegation(delegationCatalogKey(runtime, parent: parent).route) { constraints.append("Its children cannot delegate further.") }
            return ["runtime": runtime.rawValue, "displayName": runtime.title,
                    "defaultModel": catalog?.defaultModel?.model as Any? ?? NSNull(),
                    "models": models.prefix(limit).map { option -> [String: Any] in
                        var row: [String: Any] = ["id": option.choice.model]
                        if option.title != option.choice.model { row["label"] = option.title }
                        if !option.reasoningEfforts.isEmpty { row["options"] = [["id": "effort", "values": option.reasoningEfforts]] }
                        return row
                    },
                    "omittedModels": max(0, models.count - limit),
                    "runtimeModes": modes.compactMap(\.runtimeModeName),
                    "interactionModes": modes.contains(.plan) ? ["default", "plan"] : ["default"],
                    "canRunChildTask": modeAllowed && trustsProject(runtime, path: parent.workspacePath),
                    "canRunCrossProviderChildTask": true, "constraints": constraints]
        }
        return ["parentSessionId": parent.id, "inheritedRuntime": parent.runtime.rawValue,
                "inheritedModel": parent.runtimeInfo?.model ?? parent.modelOverride?.model as Any? ?? NSNull(),
                "runtimeMode": parent.permissionMode?.runtimeModeName ?? "inherit",
                "interactionMode": parent.permissionMode == .plan ? "plan" : "default",
                "runtimes": rows,
                "features": ["appOwnedSubagents": true, "asyncPolling": true, "cancellation": true,
                             "batchThreadCreation": true, "threadManagement": true, "incrementalThreadRead": true,
                             "scheduledTasks": false, "maxBatchThreads": Delegation.maxBatchSessions]]
    }

    func delegateTask(_ caller: DelegationCaller, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard let task = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty,
              task.count <= Delegation.maxTaskCharacters else {
            throw DelegationFailure("invalid_request", "task is required, at most 120,000 characters.")
        }
        let clientRequestID = try Delegation.clientRequestID(arguments)
        let mode = arguments["mode"] as? String ?? "async"
        guard ["async", "wait"].contains(mode) else { throw DelegationFailure("invalid_request", "mode must be async or wait.") }
        guard ["shared", "worktree"].contains(arguments["isolation"] as? String ?? "shared") else {
            throw DelegationFailure("invalid_request", "isolation must be shared or worktree.")
        }
        let role = arguments["role"] as? String
        guard role.map(Delegation.roles.contains) ?? true else { throw DelegationFailure("invalid_request", "role must be one of \(Delegation.roles.joined(separator: ", ")).") }
        let timeout = Self.waitTimeout(arguments)
        let taskID = Delegation.derivedID(caller: caller.sessionID, operation: "delegate_task", clientRequestID: clientRequestID)
        // A retry reaches the same task; never a second child.
        if let creating = delegationCreations[taskID] { _ = try await creating.task.value }
        if let existing = sessions.first(where: { $0.delegation?.taskID == taskID && $0.parentSessionID == caller.sessionID }) {
            return mode == "wait" ? try await waitForDelegatedTask(existing.id, timeout: timeout) : taskResult(existing.id)
        }
        guard let parent = sessions.first(where: { $0.id == caller.sessionID }) else { throw DelegationFailure("thread_not_found", "The calling session no longer exists.") }
        guard !parent.parentTurnComplete else {
            throw DelegationFailure("parent_not_active", "delegate_task needs an active turn in the calling session.")
        }
        let creation = Task { @MainActor in try await self.createDelegatedTask(parent: parent, task: task, taskID: taskID, clientRequestID: clientRequestID,
                                                                             role: role, mode: mode, arguments: arguments) }
        delegationCreations[taskID] = (parent.id, creation)
        defer {
            delegationCreations.removeValue(forKey: taskID)
            scheduleDeferredOperationIfIdle()
        }
        let childID = try await creation.value
        return mode == "wait" ? try await waitForDelegatedTask(childID, timeout: timeout) : taskResult(childID)
    }

    /// A new session for an agent: its harness, model and mode within the
    /// caller's limits, in the caller's folder or a new worktree of it.
    private func newAgentSession(parent: CompanionSession, arguments: [String: Any]) async throws -> CompanionSession {
        let target = arguments["target"] as? [String: Any] ?? [:]
        let runtime = try (target["runtime"] as? String).map { raw -> RuntimeKind in
            guard let kind = RuntimeKind(rawValue: raw), delegationRuntimes(for: parent).contains(kind) else {
                throw DelegationFailure("provider_unavailable", "\(raw) is not set up in Notch Companion. Call orchestrator_capabilities for the harnesses available here.")
            }
            return kind
        } ?? parent.runtime
        guard delegationRuntimes(for: parent).contains(runtime) else {
            throw DelegationFailure("provider_unavailable", "\(runtime.title) is not available here.")
        }
        var choice: RuntimeModelChoice?
        if let model = target["model"] as? String, !model.isEmpty {
            let key = delegationCatalogKey(runtime, parent: parent)
            if modelCatalogs[key] == nil { await loadModels(for: key) }
            guard let option = modelCatalogs[key]?.models.first(where: { $0.choice.model == model || $0.choice.id == model }) else {
                throw DelegationFailure("model_unavailable", "\(runtime.title) does not offer \(model) here. Call orchestrator_capabilities for its models.")
            }
            choice = option.choice
            if let effort = (target["options"] as? [String: Any])?["effort"] as? String {
                guard option.reasoningEfforts.contains(effort) else { throw DelegationFailure("invalid_request", "\(model) does not offer effort \(effort).") }
                choice?.reasoningEffort = effort
            }
        } else if runtime == parent.runtime { choice = parent.modelOverride }
        let permission = try Delegation.childMode(parent: parent.permissionMode, requested: Delegation.requestedMode(arguments),
                                                  supported: runtime.capabilities.supportedPermissionModes)
        var session = CompanionSession()
        session.runtime = runtime
        session.profileID = RuntimeRoute.defaultProfile(runtime, defaults: preferences)
        session.workspacePath = parent.workspacePath ?? workspacePath
        applyNativeWorkspace(to: &session)
        if runtime.requiresProjectTrust {
            // Project trust is the user's decision for that harness and folder.
            guard trustsProject(runtime, path: session.workspacePath) else {
                throw DelegationFailure("capability_denied", "The user has not trusted this project for \(runtime.title) in Notch Companion. Ask them to, or choose another harness.")
            }
            session.trustedProjectPath = URL(fileURLWithPath: session.workspacePath ?? workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        session.permissionMode = permission
        session.fullAccessConfirmed = permission == .fullAccess // the user confirmed it on the parent
        session.modelOverride = choice
        return session
    }

    private func createDelegatedTask(parent: CompanionSession, task: String, taskID: String, clientRequestID: String?,
                                     role: String?, mode: String, arguments: [String: Any]) async throws -> String {
        try Task.checkCancellation()
        let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = title?.isEmpty == false ? String(title!.prefix(160)) : String((task.components(separatedBy: .newlines).first ?? task).prefix(64))
        // Every check runs before Git creates anything.
        var child = try await newAgentSession(parent: parent, arguments: arguments)
        try Task.checkCancellation()
        if arguments["isolation"] as? String == "worktree" {
            let folder = parent.workspacePath ?? workspacePath
            let root = worktreesDirectory
            let name = Delegation.worktreeName(title: named, taskID: taskID)
            let worktree = try await Task.detached { try Delegation.makeWorktree(from: folder, name: name, root: root) }.value
            try Task.checkCancellation()
            child.workspacePath = worktree
            // A worktree checks out the same project, so the folder's trust carries over.
            if child.trustedProjectPath != nil { child.trustedProjectPath = URL(fileURLWithPath: worktree).standardizedFileURL.resolvingSymlinksInPath().path }
        }
        child.title = named
        child.parentSessionID = parent.id
        child.delegation = DelegationRecord(taskID: taskID, clientRequestID: clientRequestID, role: role, completionWake: mode == "async")
        guard sessions.contains(where: { $0.id == parent.id }) else { throw DelegationFailure("thread_not_found", "The calling session no longer exists.") }
        sessions.append(child)
        update(parent.id) {
            $0.agents.append(ChildAgent(id: "delegation:" + taskID, title: child.title, turnID: $0.latestUserTurnID,
                                        sessionID: child.id, runtime: child.runtime, role: role))
        }
        save()
        let prompt = (role.map { "Act as the \($0) sub-agent for this task.\n\n" } ?? "") + task
        let sent = await submit(reply: prompt, target: child.id)
        if !sent, sessions.first(where: { $0.id == child.id })?.pendingSubmission == nil {
            // Never delivered: the caller gets the error now, not a later wake.
            update(child.id) { $0.delegation?.completionWake = false }
            save()
            syncDelegatedChildren()
            throw DelegationFailure("orchestration_error", backgroundSendErrors[child.id] ?? "The child task could not be started.")
        }
        syncDelegatedChildren()
        return child.id
    }

    /// Child worktrees live beside the registry, like SnapShots.
    var worktreesDirectory: URL { storageURL.deletingLastPathComponent().appendingPathComponent("Worktrees", isDirectory: true) }

    /// Labels an app-owned child's own changes in the parent turn that delegated
    /// it. One level: a grandchild's group stays with its own parent, the child.
    func foldDelegatedChanges(_ childID: String) {
        guard let child = sessions.first(where: { $0.id == childID }), let parentID = child.parentSessionID,
              let turnID = sessions.first(where: { $0.id == parentID })?.agents.first(where: { $0.sessionID == childID })?.turnID else { return }
        let worktree = child.workspacePath?.hasPrefix(worktreesDirectory.path + "/") == true
        let label = [child.title, child.runtime.title, worktree ? "worktree" : nil].compactMap { $0 }.joined(separator: " · ")
        let group = TurnChanges.group(child.changes, id: childID, label: label)
        update(parentID) { parent in
            guard let index = parent.changes.firstIndex(where: { $0.id == turnID }) else { return }
            var groups = parent.changes[index].delegated ?? []
            if let group, group.isVisible {
                if let row = groups.firstIndex(where: { $0.id == childID }) { groups[row] = group } else { groups.append(group) }
            } else { groups.removeAll { $0.id == childID } }
            parent.changes[index].delegated = groups.isEmpty ? nil : groups
        }
    }

    static func waitTimeout(_ arguments: [String: Any]) -> TimeInterval {
        guard let milliseconds = (arguments["timeoutMs"] as? NSNumber)?.doubleValue, milliseconds.isFinite else { return Delegation.defaultWait }
        return min(Delegation.maxWait, max(0, milliseconds / 1000))
    }

    /// Blocks until the child settles, or returns early on its question,
    /// approval or the timeout. An early return makes the task wake its parent.
    func waitForDelegatedTask(_ childID: String, timeout: TimeInterval, returnsOnQuestion: Bool = true) async throws -> [String: Any] {
        guard let parentID = sessions.first(where: { $0.id == childID })?.parentSessionID else { throw DelegationFailure("task_not_found", "The task no longer exists.") }
        delegationWaits[parentID, default: 0] += 1
        // Only a wait that returns the question stands in for its notice.
        if returnsOnQuestion { delegationWaitTargets[childID, default: 0] += 1 }
        defer {
            delegationWaits[parentID, default: 1] -= 1
            if delegationWaits[parentID] == 0 { delegationWaits.removeValue(forKey: parentID) }
            if returnsOnQuestion {
                delegationWaitTargets[childID, default: 1] -= 1
                if delegationWaitTargets[childID] == 0 { delegationWaitTargets.removeValue(forKey: childID) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            guard let child = sessions.first(where: { $0.id == childID }) else { throw DelegationFailure("task_not_found", "The task no longer exists.") }
            // A caller that went away never received the result, so it must still wake.
            if Task.isCancelled { break }
            if isDelegationSettled(child) {
                acknowledgeDelegatedResult(childID)
                return taskResult(childID)
            }
            if returnsOnQuestion, child.runtimeID.map({ id in requests.contains { $0.sessionID == id } }) == true { break }
            if Date() >= deadline || Task.isCancelled { timedOut = !Task.isCancelled; break }
            // shortcut: polls the session every 250 ms; use continuations if many waits run at once.
            try? await Task.sleep(for: .milliseconds(250))
        }
        update(childID) { $0.delegation?.completionWake = true }
        save()
        return taskResult(childID, waitTimedOut: timedOut)
    }

    private func ownedTask(_ caller: DelegationCaller, _ arguments: [String: Any]) throws -> CompanionSession {
        guard let id = arguments["taskId"] as? String,
              let child = sessions.first(where: { $0.delegation?.taskID == id && $0.parentSessionID == caller.sessionID }) else {
            throw DelegationFailure("task_not_found", "No task with this taskId belongs to this session.")
        }
        return child
    }

    func isDelegationSettled(_ child: CompanionSession) -> Bool {
        !child.isBusy && !isSubmitting(child.id) && child.stagedSubmission == nil
            && (child.pendingSubmission == nil || child.runtimeID == nil)
    }

    func acknowledgeDelegatedResult(_ childID: String) {
        guard let child = sessions.first(where: { $0.id == childID }), isDelegationSettled(child), let completion = child.completionID,
              child.delegation?.readCompletionID != completion else { return }
        update(childID) { $0.delegation?.readCompletionID = completion }
        save()
        syncDelegatedChildren()
    }

    func taskResult(_ childID: String, waitTimedOut: Bool = false) -> [String: Any] {
        guard let child = sessions.first(where: { $0.id == childID }), let record = child.delegation else { return [:] }
        let settled = isDelegationSettled(child)
        let pending = child.runtimeID.map { id in requests.filter { $0.sessionID == id } } ?? []
        let approval = pending.first { $0.kind == .approval }
        let status: String
        if settled {
            switch child.displayState {
            case .finished: status = "completed"
            case .failed: status = "failed"
            case .idle: status = record.cancelled ? "cancelled" : "queued"
            default: status = record.cancelled ? "cancelled" : "interrupted"
            }
        } else {
            status = !pending.isEmpty || child.displayState == .waiting ? "waiting" : "running"
        }
        let ownWork = child.isBusyIgnoringDelegates || isSubmitting(child.id) || child.state == .working && !child.parentTurnComplete
        var result: [String: Any] = [
            "taskId": record.taskID, "childSessionId": child.id, "runtime": child.runtime.rawValue,
            "model": child.runtimeInfo?.model ?? child.modelOverride?.model as Any? ?? NSNull(),
            "title": child.title, "status": status,
            "workState": settled ? "result_available" : (ownWork ? "working" : "waiting_for_children"),
            "summary": settled && !child.latestResponse.isEmpty ? child.latestResponse : NSNull(),
            "hasPendingQuestion": pending.contains { $0.kind == .clarification },
            "pendingApproval": approval.map { ["requestId": $0.requestID ?? $0.id, "kind": "approval"] } as Any? ?? NSNull(),
            "waitTimedOut": waitTimedOut]
        if !settled, record.completionWake { result["next"] = Delegation.next }
        return result
    }

    // MARK: Navigation

    /// An app-owned child's own conversation, where the user may reply.
    func openDelegatedSession(_ id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectSession(id)
    }

    func openDelegationParent() {
        guard let parent = current?.parentSessionID, sessions.contains(where: { $0.id == parent }) else { return }
        selectSession(parent)
        page = .team
    }

    // MARK: Lifecycle

    func delegatedChildren(of id: String) -> [String] { sessions.filter { $0.parentSessionID == id }.map(\.id) }

    func delegatedDescendants(of id: String) -> [String] {
        delegatedChildren(of: id).flatMap { [$0] + delegatedDescendants(of: $0) }
    }

    /// Stop on a parent stops its children depth-first and drops their wakes.
    func stopDelegatedChildren(of id: String) async {
        cancelDelegationPreparations(parentID: id)
        for child in delegatedChildren(of: id) { await cancelDelegatedTree(child) }
    }

    /// Registered children use their durable cancelled flag and native interrupt
    /// path; cancelling their submit task would turn a normal Stop into a failure.
    func cancelDelegationPreparations(parentID: String? = nil) {
        for (taskID, creation) in delegationCreations where parentID == nil || creation.parentID == parentID {
            if !sessions.contains(where: { $0.delegation?.taskID == taskID && $0.parentSessionID == creation.parentID }) {
                creation.task.cancel()
            }
        }
    }

    func cancelDelegatedTree(_ id: String) async {
        await stopDelegatedChildren(of: id)
        update(id) { $0.delegation?.cancelled = true; $0.delegation?.completionWake = false; $0.queuedSends.removeAll() }
        save()
        if let session = sessions.first(where: { $0.id == id }), session.runtimeID != nil, session.isBusyIgnoringDelegates {
            await interrupt(sessionID: id, cascade: false)
        }
        syncDelegatedChildren()
    }

    private func mirrorState(_ child: CompanionSession) -> WorkState {
        if isSubmitting(child.id) || child.stagedSubmission != nil { return .working }
        // A child whose first message never went out (a crash before it) is not working.
        return child.displayState == .idle ? .interrupted : child.displayState
    }

    /// The finished child result that still has to wake its parent.
    func pendingWake(_ child: CompanionSession) -> String? {
        guard let record = child.delegation, record.completionWake, !failedDeliveries.contains(child.id), isDelegationSettled(child),
              [.finished, .failed].contains(child.displayState), let completion = child.completionID,
              record.readCompletionID != completion, record.wokenCompletionID != completion else { return nil }
        return completion
    }

    /// Mirrors each app-owned child into its parent's team, settles a parent
    /// whose own turn ended once its children do, then sends due wakes.
    func syncDelegatedChildren() {
        guard sessions.contains(where: { $0.parentSessionID != nil || !$0.queuedSends.isEmpty }) else { return }
        // A grandchild settles its parent's row, which settles the next one up.
        for _ in 0..<32 {
            var changed = false
            let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in sessions.indices where sessions[index].agents.contains(where: { $0.sessionID != nil }) {
                var parent = sessions[index]
                for row in parent.agents.indices {
                    guard let id = parent.agents[row].sessionID else { continue }
                    let child = byID[id]
                    let state = child.map(mirrorState) ?? .interrupted
                    if parent.agents[row].state != state { parent.agents[row].state = state }
                    if let child {
                        if parent.agents[row].title != child.title { parent.agents[row].title = child.title }
                        if parent.agents[row].text != child.latestResponse { parent.agents[row].text = child.latestResponse }
                    }
                }
                let ownRequests = parent.runtimeID.map { id in requests.contains { $0.sessionID == id } } ?? false
                if parent.parentTurnComplete, [.working, .waiting].contains(parent.state), parent.nativeActivityUnverified == nil, !ownRequests {
                    if parent.agents.contains(where: { $0.state == .waiting }) { parent.state = .waiting }
                    else if parent.agents.contains(where: { $0.state == .working })
                                || delegatedChildren(of: parent.id).contains(where: { byID[$0].flatMap(pendingWake) != nil }) {
                        parent.state = .working // a wake starts the parent's next turn
                    } else {
                        parent.state = parent.failedCurrentAgents.isEmpty ? .finished : .failed
                        if parent.state == .finished {
                            parent.completionID = UUID().uuidString
                            if parent.parentSessionID == nil {
                                lastCompletion[parent.id] = Date()
                                play(.complete)
                                announce(.finished, sessionID: parent.id)
                            }
                        } else if !parent.hasUnreadFailure { parent.completionID = UUID().uuidString }
                    }
                }
                if parent != sessions[index] { sessions[index] = parent; changed = true }
            }
            if !changed { break }
        }
        scheduleSave()
        processDelegationWakes()
    }

    /// The session's own turn is over and nothing else is being sent to it.
    func acceptsDelegationSend(_ session: CompanionSession) -> Bool {
        session.runtime.isSupported && !isSubmitting(session.id) && session.pendingSubmission == nil && session.nativeActivityUnverified == nil
            && !session.isBusyIgnoringDelegates && !unfinishedParents.contains(session.id) && (unfinishedChildren[session.id]?.isEmpty ?? true)
    }

    /// A finished result is queued to its parent after the parent's own turn,
    /// or steers that turn where the harness supports it. Queued messages
    /// and question notices go after the turn.
    func processDelegationWakes() {
        for session in sessions where session.queuedSends.contains(where: { !failedDeliveries.contains($0.id) && $0.paused != true && (!$0.isUserMessage || !session.isBusy) }) && acceptsDelegationSend(session) {
            Task { @MainActor in await self.deliverQueued(session.id) }
        }
        for child in sessions {
            guard let completion = pendingWake(child), let parentID = child.parentSessionID,
                  let parent = sessions.first(where: { $0.id == parentID }), parent.runtime.isSupported,
                  !isSubmitting(parentID), parent.pendingSubmission == nil, parent.nativeActivityUnverified == nil else { continue }
            let idle = !parent.isBusyIgnoringDelegates && !unfinishedParents.contains(parentID) && (unfinishedChildren[parentID]?.isEmpty ?? true)
            let steer = !idle && parent.runtime.steersTurns && parent.runtimeID != nil && parent.state == .working && !parent.parentTurnComplete
                && !steerRefused.contains(parentID)
            guard idle || steer else { continue }
            if idle { steerRefused.remove(parentID) }
            let messageID = UUID().uuidString
            update(child.id) { $0.delegation?.wokenCompletionID = completion; $0.delegation?.wakeMessageID = messageID }
            guard save() else {
                update(child.id) { $0.delegation?.wokenCompletionID = nil; $0.delegation?.wakeMessageID = nil }
                continue
            }
            Task { @MainActor in await self.deliverWake(childID: child.id, parentID: parentID, messageID: messageID, steer: steer) }
        }
    }

    private func deliverQueued(_ id: String) async {
        guard let session = sessions.first(where: { $0.id == id }), acceptsDelegationSend(session),
              var next = session.queuedSends.first(where: { $0.paused != true && !failedDeliveries.contains($0.id) && (!$0.isUserMessage || !session.isBusy) }) else { return }
        // Already delivered before a restart, or a question answered meanwhile.
        let answered = next.requestID.map { request in
            let asker = sessions.first { $0.id == next.questionSessionID }?.runtimeID
            return !requests.contains { ($0.requestID ?? $0.id) == request && $0.sessionID == asker }
        } ?? false
        if answered || session.messages.contains(where: { $0.id == next.id }) {
            update(id) { $0.queuedSends.removeAll { $0.id == next.id } }
            save()
            processDelegationWakes()
            return
        }
        if next.kind == ChatMessage.delegationNotice, let request = next.requestID { next.text = questionNoticeText(next.questionSessionID, request) ?? next.text }
        let sent = await submit(reply: next.text, target: id, kind: next.kind, turnID: next.id, queuedAttachments: next.attachments)
        let after = sessions.first { $0.id == id }
        if sent || after?.messages.contains(where: { $0.id == next.id }) == true || after?.pendingSubmission?.id == next.id {
            update(id) { $0.queuedSends.removeAll { $0.id == next.id } }
            save()
        } else {
            // Kept for a later run rather than retried on every event.
            failedDeliveries.insert(next.id)
            if next.isUserMessage { pauseQueuedSends(id); save() }
        }
        processDelegationWakes()
    }

    // MARK: Questions

    /// A child's question reaches its parent as a queued notice, unless a
    /// blocking wait on that child already returns it.
    func queueQuestionNotice(childID: String, requestID: String) {
        guard let child = sessions.first(where: { $0.id == childID }), let parentID = child.parentSessionID,
              sessions.contains(where: { $0.id == parentID }), delegationWaitTargets[childID] == nil,
              let text = questionNoticeText(childID, requestID) else { return }
        update(parentID) {
            guard !$0.queuedSends.contains(where: { $0.requestID == requestID && $0.questionSessionID == childID }) else { return }
            $0.queuedSends.append(QueuedSend(id: UUID().uuidString, text: text, kind: ChatMessage.delegationNotice,
                                             requestID: requestID, questionSessionID: childID))
        }
        save()
        processDelegationWakes()
    }

    func questionNoticeText(_ childID: String?, _ requestID: String) -> String? {
        guard let child = sessions.first(where: { $0.id == childID }), let runtimeID = child.runtimeID else { return nil }
        let questions = requests.filter { ($0.requestID ?? $0.id) == requestID && $0.sessionID == runtimeID && $0.kind == .clarification }
        guard !questions.isEmpty else { return nil }
        return "Delegated task \"\(child.title)\" (taskId \(child.delegation?.taskID ?? ""), sessionId \(child.id)) asks:\n\n"
            + questions.map { "- " + $0.detail + ($0.choices.isEmpty ? "" : " (" + $0.choices.joined(separator: " / ") + ")") }.joined(separator: "\n")
            + "\n\nRead it with pending_request_read (sessionId \(child.id), requestId \(requestID)) and answer with pending_request_respond. If you cannot answer it, ask the user."
    }

    /// A session's pending questions by request; approvals are never listed.
    func questionRequests(_ session: CompanionSession) -> [(String, [PendingRequest])] {
        guard let runtimeID = session.runtimeID else { return [] }
        var groups: [(String, [PendingRequest])] = []
        for request in requests where request.sessionID == runtimeID && request.kind == .clarification {
            let id = request.requestID ?? request.id
            if let index = groups.firstIndex(where: { $0.0 == id }) { groups[index].1.append(request) } else { groups.append((id, [request])) }
        }
        return groups
    }

    private func pendingQuestion(_ caller: DelegationCaller, _ arguments: [String: Any]) throws -> (CompanionSession, String, [PendingRequest]) {
        let target = try targetSession(caller, arguments, control: false)
        guard let id = arguments["requestId"] as? String else { throw DelegationFailure("invalid_request", "Pass a requestId.") }
        if requests.contains(where: { ($0.requestID ?? $0.id) == id && $0.sessionID == target.runtimeID && $0.kind == .approval }) {
            throw DelegationFailure("capability_denied", "This is an approval. Only the user grants approvals; these tools grant no approval rights.")
        }
        guard let questions = questionRequests(target).first(where: { $0.0 == id })?.1 else {
            throw DelegationFailure("run_not_found", "No pending question with this requestId in that session.")
        }
        return (target, id, questions)
    }

    // MARK: Sessions

    /// T3's ceiling: a session the caller controls runs with no broader mode than the caller's own.
    func withinModeCeiling(caller: PermissionMode?, target: PermissionMode?) -> Bool {
        switch (caller, target) {
        case (nil, nil): return true
        case (nil, let mode?): return mode.delegationRank <= PermissionMode.ask.delegationRank
        case (let mode?, nil): return mode == .fullAccess
        case (let mode?, let other?): return other.delegationRank <= mode.delegationRank
        }
    }

    private func targetSession(_ caller: DelegationCaller, _ arguments: [String: Any], control: Bool) throws -> CompanionSession {
        let id = arguments["sessionId"] as? String ?? caller.sessionID
        guard let target = sessions.first(where: { $0.id == id }), let own = sessions.first(where: { $0.id == caller.sessionID }) else {
            throw DelegationFailure("thread_not_found", "No Notch Companion session has this sessionId.")
        }
        if control, id != caller.sessionID, !withinModeCeiling(caller: own.permissionMode, target: target.permissionMode) {
            throw DelegationFailure("runtime_mode_escalation_denied", "That session runs with a broader permission mode than yours.")
        }
        return target
    }

    func sessionStatus(_ session: CompanionSession) -> String {
        if session.isBusy || isSubmitting(session.id) {
            return session.displayState == .waiting || !questionRequests(session).isEmpty ? "waiting" : "running"
        }
        switch session.displayState {
        case .finished: return "completed"
        case .failed: return "failed"
        case .interrupted: return session.delegation?.cancelled == true ? "cancelled" : "interrupted"
        case .waiting: return "waiting"
        case .working: return "running"
        case .idle: return "idle"
        }
    }

    func sessionSummary(_ session: CompanionSession) -> [String: Any] {
        let dates = ISO8601DateFormatter()
        var row: [String: Any] = ["sessionId": session.id, "title": session.title, "runtime": session.runtime.rawValue,
            "model": session.runtimeInfo?.model ?? session.modelOverride?.model as Any? ?? NSNull(), "status": sessionStatus(session),
            "runtimeMode": session.permissionMode?.runtimeModeName ?? "inherit", "interactionMode": session.permissionMode == .plan ? "plan" : "default",
            "projectPath": projectPath(of: session), "parentSessionId": session.parentSessionID as Any? ?? NSNull(),
            "relationshipToParent": session.parentSessionID == nil ? NSNull() : "subagent" as Any,
            "messageCount": session.messages.filter(SessionHistory.isVisibleConversation).count, "archived": session.isArchived,
            "createdAt": dates.string(from: session.createdAt), "updatedAt": dates.string(from: session.updatedAt)]
        if let task = session.delegation?.taskID { row["taskId"] = task }
        return row
    }

    func listSessions(_ caller: DelegationCaller, _ arguments: [String: Any]) throws -> [String: Any] {
        let own = try targetSession(caller, [:], control: false)
        let project = (arguments["projectPath"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? projectPath(of: own)
        let statuses = arguments["statuses"] as? [String]
        let title = (arguments["titleContains"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subagents = arguments["includeSubagents"] as? Bool ?? false
        let rows = sessions.filter { session in
            projectPath(of: session) == project && (subagents || session.parentSessionID == nil)
                && (title.isEmpty || session.title.localizedCaseInsensitiveContains(title))
                && (statuses.map { $0.contains(sessionStatus(session)) } ?? true)
        }.sorted { $0.updatedAt > $1.updatedAt }
        let cursor = max(0, (arguments["cursor"] as? NSNumber)?.intValue ?? 0)
        let limit = min(100, max(1, (arguments["limit"] as? NSNumber)?.intValue ?? 20))
        let page = Array(rows.dropFirst(cursor).prefix(limit))
        return ["projectPath": project, "currentSessionId": own.id, "sessions": page.map(sessionSummary),
                "nextCursor": cursor + page.count < rows.count ? cursor + page.count : NSNull() as Any, "total": rows.count]
    }

    func readSession(_ caller: DelegationCaller, _ arguments: [String: Any]) throws -> [String: Any] {
        let target = try targetSession(caller, arguments, control: false)
        let view = arguments["view"] as? String ?? "messages"
        guard ["messages", "activity"].contains(view) else { throw DelegationFailure("invalid_request", "view must be messages or activity.") }
        let limit = min(100, max(1, (arguments["limit"] as? NSNumber)?.intValue ?? 20))
        let characters = min(50_000, max(1, (arguments["maxCharsPerItem"] as? NSNumber)?.intValue ?? 4_000))
        let after = (arguments["afterPosition"] as? NSNumber)?.intValue ?? -1
        let dates = ISO8601DateFormatter()
        func text(_ value: String) -> [String: Any] {
            ["text": String(value.prefix(characters)), "textTruncated": value.count > characters]
        }
        var items: [(Date, [String: Any])] = target.messages.filter(SessionHistory.isVisibleConversation).map { message in
            var row: [String: Any] = ["type": "message", "id": message.id, "role": message.role, "createdAt": dates.string(from: message.createdAt)]
            if let kind = message.kind { row["kind"] = kind }
            return (message.createdAt, row.merging(text(message.text)) { $1 })
        }
        if view == "activity" {
            items += target.tools.map { tool in
                (tool.startedAt, ["type": "tool", "id": tool.id, "name": tool.name, "title": tool.displayName, "status": tool.state.rawValue,
                                  "detail": String(tool.detail.prefix(characters)), "createdAt": dates.string(from: tool.startedAt)]
                    .merging(text(tool.output)) { $1 })
            }
            items.sort { $0.0 < $1.0 }
        }
        let positioned = items.enumerated().map { $0.element.1.merging(["position": $0.offset]) { $1 } }
        let page = Array(positioned.filter { ($0["position"] as? Int ?? 0) > after }.prefix(limit))
        // Reading a finished child's final answer delivers it, like task_status.
        if target.parentSessionID == caller.sessionID,
           let final = target.messages.last(where: { $0.role == "assistant" })?.id, page.contains(where: { $0["id"] as? String == final }) {
            acknowledgeDelegatedResult(target.id)
        }
        let last = page.last?["position"] as? Int
        return ["session": sessionSummary(target), "items": page, "nextPosition": last as Any? ?? NSNull(),
                "hasMore": (last ?? after) < positioned.count - 1]
    }

    func sendToSession(_ caller: DelegationCaller, _ arguments: [String: Any]) async throws -> [String: Any] {
        let target = try targetSession(caller, arguments, control: true)
        guard let message = (arguments["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty,
              message.count <= Delegation.maxTaskCharacters else { throw DelegationFailure("invalid_request", "message is required, at most 120,000 characters.") }
        let mode = arguments["mode"] as? String ?? "auto"
        guard ["auto", "queue", "steer", "restart"].contains(mode) else { throw DelegationFailure("invalid_request", "mode must be auto, queue, steer or restart.") }
        let key = try Delegation.clientRequestID(arguments)
        let messageID = Delegation.derivedID(caller: caller.sessionID, operation: "notch_session_send", clientRequestID: key)
        func result(_ delivery: String) -> [String: Any] {
            var row: [String: Any] = ["sessionId": target.id, "messageId": messageID, "delivery": delivery,
                                      "status": sessions.first { $0.id == target.id }.map(sessionStatus) ?? "idle"]
            if let task = sessions.first(where: { $0.id == target.id })?.delegation?.taskID { row["taskId"] = task }
            return row
        }
        // A retry with the same key sends nothing new.
        if target.messages.contains(where: { $0.id == messageID }) || target.pendingSubmission?.id == messageID || target.stagedSubmission?.message.id == messageID {
            return result("started")
        }
        if target.queuedSends.contains(where: { $0.id == messageID }) { return result("queued") }
        guard target.runtime.isSupported, !target.isLegacyPrivate else { throw DelegationFailure("thread_not_sendable", "\(target.runtime.title) cannot be reached here.") }
        // A finished child starts a fresh task, which wakes its parent. A send
        // that fails puts the record back, so the old result cannot wake again.
        let previous = target.delegation
        if previous != nil, isDelegationSettled(target) {
            let task = Delegation.derivedID(caller: caller.sessionID, operation: "notch_session_send.task", clientRequestID: key)
            update(target.id) {
                $0.delegation?.taskID = task; $0.delegation?.completionWake = true; $0.delegation?.cancelled = false
                $0.delegation?.readCompletionID = nil; $0.delegation?.wokenCompletionID = nil; $0.delegation?.wakeMessageID = nil
            }
            failedDeliveries.remove(target.id)
        }
        func fail(_ failure: DelegationFailure) -> DelegationFailure {
            update(target.id) { $0.delegation = previous }
            save()
            return failure
        }
        let running = target.runtimeID != nil && !target.parentTurnComplete
        if mode == "steer" || (mode == "auto" && running && target.runtime.steersTurns && target.state == .working) {
            guard running, target.runtime.steersTurns, let sid = target.runtimeID else {
                throw fail(DelegationFailure("thread_not_sendable", "\(target.runtime.title) has no running turn that accepts input here."))
            }
            do {
                _ = try await client.request("prompt.steer", params: ["session_id": sid, "text": message, "turn_id": messageID])
                update(target.id) { $0.messages.append(ChatMessage(id: messageID, role: "user", text: message, turnID: $0.latestUserTurnID ?? messageID, kind: ChatMessage.agentMessage)) }
                save()
                return result("steered")
            } catch where mode == "steer" {
                throw fail(DelegationFailure("thread_not_sendable", error.localizedDescription))
            } catch {}
        }
        var delivery = "started"
        if mode == "restart", running {
            await interrupt(sessionID: target.id, cascade: false)
            delivery = "restarted"
            for _ in 0..<120 where !acceptsDelegationSend(sessions.first { $0.id == target.id } ?? target) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let current = sessions.first(where: { $0.id == target.id }), acceptsDelegationSend(current), current.queuedSends.isEmpty else {
            update(target.id) { $0.queuedSends.append(QueuedSend(id: messageID, text: message, kind: ChatMessage.agentMessage)) }
            save()
            syncDelegatedChildren()
            return result("queued")
        }
        let sent = await submit(reply: message, target: target.id, kind: ChatMessage.agentMessage, turnID: messageID)
        guard sent || sessions.first(where: { $0.id == target.id })?.pendingSubmission?.id == messageID else {
            throw fail(DelegationFailure("thread_not_sendable", backgroundSendErrors[target.id] ?? "The message could not be sent."))
        }
        syncDelegatedChildren()
        return result(delivery)
    }

    func waitForSession(_ caller: DelegationCaller, _ arguments: [String: Any]) async throws -> [String: Any] {
        let target = try targetSession(caller, arguments, control: false)
        if target.parentSessionID == caller.sessionID, target.delegation != nil {
            let result = try await waitForDelegatedTask(target.id, timeout: Self.waitTimeout(arguments), returnsOnQuestion: false)
            var row: [String: Any] = ["sessionId": target.id, "status": sessionStatus(sessions.first { $0.id == target.id } ?? target),
                                      "timedOut": result["waitTimedOut"] as? Bool ?? false]
            if let next = result["next"] { row["next"] = next }
            return row
        }
        let deadline = Date().addingTimeInterval(Self.waitTimeout(arguments))
        delegationWaits[caller.sessionID, default: 0] += 1
        defer {
            delegationWaits[caller.sessionID, default: 1] -= 1
            if delegationWaits[caller.sessionID] == 0 { delegationWaits.removeValue(forKey: caller.sessionID) }
        }
        while let session = sessions.first(where: { $0.id == target.id }), session.isBusy || isSubmitting(session.id) || !session.queuedSends.isEmpty {
            guard Date() < deadline, !Task.isCancelled else { return ["sessionId": target.id, "status": sessionStatus(session), "timedOut": true] }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ["sessionId": target.id, "status": sessions.first { $0.id == target.id }.map(sessionStatus) ?? "idle", "timedOut": false]
    }

    func createSessions(_ caller: DelegationCaller, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard let parent = sessions.first(where: { $0.id == caller.sessionID }) else { throw DelegationFailure("thread_not_found", "The calling session no longer exists.") }
        guard !parent.parentTurnComplete else { throw DelegationFailure("parent_not_active", "create_sessions needs an active turn in the calling session.") }
        guard let rows = arguments["sessions"] as? [[String: Any]], (1...Delegation.maxBatchSessions).contains(rows.count) else {
            throw DelegationFailure("invalid_request", "sessions takes 1 to 20 entries.")
        }
        let key = try Delegation.clientRequestID(arguments)
        var created: [[String: Any]] = []
        for (index, row) in rows.enumerated() {
            let prompt = (row["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard prompt.count <= Delegation.maxTaskCharacters else { throw DelegationFailure("invalid_request", "A prompt is at most 120,000 characters.") }
            let id = Delegation.derivedID(caller: caller.sessionID, operation: "create_sessions.\(index)", clientRequestID: key)
            if let existing = sessions.first(where: { $0.id == id }) { created.append(sessionSummary(existing)); continue }
            var session = try await newAgentSession(parent: parent, arguments: row)
            session.id = id
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            session.title = !title.isEmpty ? String(title.prefix(160)) : prompt.isEmpty ? "New session" : String((prompt.components(separatedBy: .newlines).first ?? prompt).prefix(64))
            // An ordinary top-level session: it lists, searches and notifies like any other.
            sessions.insert(session, at: 0)
            save()
            if !prompt.isEmpty { await submit(reply: prompt, target: id) }
            created.append(sessionSummary(sessions.first { $0.id == id } ?? session))
        }
        return ["sessions": created]
    }

    func wakeText(_ child: CompanionSession) -> String {
        let record = child.delegation
        let outcome = child.displayState == .failed ? "failed" : "completed"
        let who = [child.runtime.title, record?.role].compactMap { $0 }.joined(separator: ", ")
        var text = "Delegated task \"\(child.title)\" (taskId \(record?.taskID ?? ""), sessionId \(child.id), \(who)) \(outcome)."
        let (result, cut) = Delegation.prefix(child.latestResponse, bytes: Delegation.inlineResultBytes)
        if cut { text += "\n\nIts result is longer than 16,000 bytes. Use task_status with this taskId to read it." }
        else if !result.isEmpty { text += "\n\n" + result }
        return text
    }

    private func deliverWake(childID: String, parentID: String, messageID: String, steer: Bool) async {
        guard let child = sessions.first(where: { $0.id == childID }) else { return }
        let text = wakeText(child)
        if steer, let sid = sessions.first(where: { $0.id == parentID })?.runtimeID {
            do {
                _ = try await client.request("prompt.steer", params: ["session_id": sid, "text": text, "turn_id": messageID])
                // Part of the running turn: its changes, tokens and child failures stay together.
                update(parentID) { $0.messages.append(ChatMessage(id: messageID, role: "user", text: text, turnID: $0.latestUserTurnID ?? messageID, kind: ChatMessage.delegationResult)) }
                save()
                return
            } catch {
                // The turn ended or would not take input: queue it after the turn instead.
                steerRefused.insert(parentID)
                update(childID) { $0.delegation?.wokenCompletionID = nil; $0.delegation?.wakeMessageID = nil }
                save()
                syncDelegatedChildren()
                return
            }
        }
        guard let parent = sessions.first(where: { $0.id == parentID }), acceptsDelegationSend(parent) else {
            // Another send got there first: try again once the parent's turn ends.
            update(childID) { $0.delegation?.wokenCompletionID = nil; $0.delegation?.wakeMessageID = nil }
            save()
            return
        }
        let sent = await submit(reply: text, target: parentID, kind: ChatMessage.delegationResult, turnID: messageID)
        let after = sessions.first(where: { $0.id == parentID })
        if !sent, after?.messages.contains(where: { $0.id == messageID }) != true, after?.pendingSubmission?.id != messageID {
            // Not delivered: keep it for a later run rather than retrying in a loop.
            failedDeliveries.insert(childID)
            update(childID) { $0.delegation?.wokenCompletionID = nil; $0.delegation?.wakeMessageID = nil }
            save()
            syncDelegatedChildren()
        }
    }
}
