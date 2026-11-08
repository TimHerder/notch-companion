import Foundation

/// The installed CLI's bidirectional stream-json protocol, without an SDK agent
/// or overrides to its system prompt, settings or native tools. Permissions
/// change only through a session's explicit permission mode.
struct ClaudeProtocolState {
    struct Event { var name: String; var payload: [String: Any] }
    struct Interaction { var input: [String: Any]; var tool: String; var answers: [String: String] = [:] }
    let sessionID: String
    var active = false
    var turnID = ""
    var nativeState: String?
    var result: [String: Any]?
    var requests: [String: Interaction] = [:]
    var children = Set<String>()
    var taskAliases: [String: String] = [:]
    var tools = Set<String>()
    var partialMessages = Set<String>()
    var text = ""
    var failedChild = false
    var interrupted = false
    var errorCategory: String?
    var supportsSteering = false
    var pendingSteering = Set<String>()
    private var contextModel: String?
    private var contextUsed: Int?
    private var contextWindow: Int?
    /// modelUsage is cumulative for this process; each result adds the difference.
    private var processTokens = 0

    init(sessionID: String) { self.sessionID = sessionID }

    static func supportsSteering(version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return false }
        let parts = components.compactMap { Int($0) }
        return parts.count == 3 && parts[0] == 2 && (parts[1] > 1 || (parts[1] == 1 && parts[2] >= 286))
    }

    mutating func begin(_ id: String) throws {
        guard !active, children.isEmpty, requests.isEmpty else { throw AppError("Claude Code still has active work or a pending interaction.") }
        active = true; turnID = id; result = nil; text = ""; failedChild = false; interrupted = false; errorCategory = nil
        partialMessages.removeAll(); tools.removeAll(); taskAliases.removeAll()
        contextUsed = nil
        if nativeState != nil { nativeState = "running" }
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) -> Event {
        var fields = fields; fields["session_id"] = sessionID
        return Event(name: name, payload: fields)
    }

    private mutating func contextModelChanged(_ model: String) {
        if contextModel != model { contextModel = model; contextUsed = nil; contextWindow = nil }
    }

    private func contextInfo(reset: Bool = false) -> Event {
        var info: [String: Any] = ["context_reset": reset]
        if let contextModel { info["model"] = contextModel }
        var usage: [String: Any] = ["context_estimated": true]
        if let contextUsed { usage["context_used"] = contextUsed }
        if let contextWindow { usage["context_max"] = contextWindow }
        if contextUsed != nil || contextWindow != nil { info["usage"] = usage }
        return event("session.info", info)
    }

    private static func requestInputTokens(_ usage: [String: Any]) -> Int? {
        // Claude's native percentage uses only the latest request's input,
        // including cache reads/writes. Result/modelUsage token totals do not.
        var total = 0
        for key in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
            guard let count = tokenCount(usage[key]) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = value as? Int, count >= 0 else { return nil }
        return count
    }

    static func response(_ id: String, _ body: [String: Any]) -> [String: Any] {
        ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": body]]
    }

    mutating func interaction(_ frame: [String: Any]) -> (events: [Event], reply: [String: Any]?) {
        guard let id = frame["request_id"] as? String, !id.isEmpty else { return ([], nil) }
        let request = frame["request"] as? [String: Any] ?? [:]
        if request["subtype"] as? String == "request_user_dialog" {
            // An undeclared kind must stay unanswered: the CLI discards errors and settles it itself.
            guard request["dialog_kind"] as? String == Self.computerUseDialog, let payload = request["payload"] as? [String: Any] else { return ([], nil) }
            guard requests[id] == nil else { return ([], nil) }
            // No turn is listening, so nothing is granted.
            guard active else { return ([], Self.response(id, ["behavior": "completed", "result": Self.computerUseGrant(nil)])) }
            // Missing macOS access: the CLI rechecks it and tells Claude once this settles.
            if let tcc = payload["tccState"] as? [String: Any] {
                let missing = [("Accessibility", "accessibility"), ("Screen Recording", "screenRecording")].filter { tcc[$0.1] as? Bool != true }.map(\.0)
                return ([event("runtime.notice", ["message": "Claude computer use needs \(missing.joined(separator: " and ")) for Notch Companion. Allow it in System Settings → Privacy & Security, then ask Claude again."])],
                        Self.response(id, ["behavior": "completed", "result": Self.computerUseGrant(nil)]))
            }
            requests[id] = Interaction(input: payload, tool: Self.computerUseDialog)
            // The grant lasts for the CLI session, so it is never offered as Allow once.
            return ([event("approval.request", ["request_id": id, "choices": ["session", "deny"],
                "command": Self.describeComputerUse(payload), "plan": false])], nil)
        }
        guard active, request["subtype"] as? String == "can_use_tool",
              let name = request["tool_name"] as? String, let input = request["input"] as? [String: Any] else {
            return ([event("runtime.notice", ["message": "Claude Code requested an unsupported interaction. It was declined; complete it in the native CLI if needed."])],
                    ["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Unsupported companion interaction"]])
        }
        guard requests[id] == nil else { return ([], nil) }
        if name == "AskUserQuestion" {
            let questions = input["questions"] as? [[String: Any]] ?? []
            guard !questions.isEmpty, questions.count <= 16,
                  Set(questions.compactMap { $0["question"] as? String }).count == questions.count,
                  questions.allSatisfy({ ($0["question"] as? String)?.isEmpty == false && $0["isSecret"] as? Bool != true }) else {
                return ([event("runtime.notice", ["message": "Claude Code requested a question format this companion cannot display. It was declined."])],
                        Self.response(id, ["behavior": "deny", "message": "Unsupported question format or secret input"]))
            }
            requests[id] = Interaction(input: input, tool: name)
            let rows = questions.enumerated().map { offset, q -> [String: Any] in
                let options = q["options"] as? [[String: Any]] ?? []
                var row: [String: Any] = ["qid": String(offset), "question": q["question"] as? String ?? "",
                                          "choices": options.compactMap { $0["label"] as? String }, "choice_details": CodexProtocolState.choiceDetails(options),
                                          "multi_select": q["multiSelect"] as? Bool ?? false, "allows_free_text": true]
                if let header = q["header"] as? String, !header.isEmpty { row["header"] = header }
                return row
            }
            return ([event("clarify.request", ["request_id": id, "questions": rows])], nil)
        }
        requests[id] = Interaction(input: input, tool: name)
        return ([event("approval.request", ["request_id": id, "choices": ["once", "deny"],
            "command": Self.describeTool(name, input), "plan": name == "ExitPlanMode"])], nil)
    }

    /// What a permission request will do, in the words of its arguments. Known
    /// tools show their command, file or plan; others show readable JSON.
    static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        func text(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let summary: String?
        switch name {
        case "Bash": summary = text("command").map { "$ " + $0 + (text("description").map { "\n\n" + $0 } ?? "") }
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": summary = text("file_path") ?? text("notebook_path")
        case "WebFetch": summary = text("url").map { $0 + (text("prompt").map { "\n\n" + $0 } ?? "") }
        case "WebSearch": summary = text("query")
        case "ExitPlanMode": summary = text("plan").map { "Start with this plan?\n\n" + $0 }
        default: summary = nil
        }
        if let summary { return name + "\n\n" + summary }
        guard !input.isEmpty, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return name }
        return name + "\n\n" + String(json.prefix(8_000))
    }

    static let computerUseDialog = "computer_use_approval"

    /// The apps and extras a computer-use grant covers, as the CLI's own dialog lists them.
    static func describeComputerUse(_ payload: [String: Any]) -> String {
        let apps = payload["apps"] as? [[String: Any]] ?? []
        func list(_ title: String, _ include: (_ resolved: Bool, _ granted: Bool) -> Bool) -> String? {
            let rows = apps.filter { include($0["resolved"] is [String: Any], $0["alreadyGranted"] as? Bool == true) }.map { app -> String in
                let resolved = app["resolved"] as? [String: Any]
                let name = resolved?["displayName"] as? String ?? app["requestedName"] as? String ?? "App"
                return "• " + name + ((resolved?["bundleId"] as? String).map { " (\($0))" } ?? "")
            }
            return rows.isEmpty ? nil : ([title] + rows).joined(separator: "\n")
        }
        let flags = payload["requestedFlags"] as? [String: Any] ?? [:]
        let extras = [("clipboardRead", "• Read the clipboard"), ("clipboardWrite", "• Write the clipboard"), ("systemKeyCombos", "• System key combinations")]
            .filter { flags[$0.0] as? Bool == true }.map(\.1)
        let hidden = (payload["willHide"] as? [Any])?.count ?? 0
        let sections: [String?] = [
            // Only the reason is shortened, so every app and extra that Allow grants stays listed.
            "Computer use", (payload["reason"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(2_000)) },
            list("Control these apps for this session:") { $0 && !$1 }, list("Already allowed:") { $0 && $1 }, list("Not installed:") { !$0 && !$1 },
            extras.isEmpty ? nil : (["Also:"] + extras).joined(separator: "\n"),
            hidden > 0 ? "\(hidden) other \(hidden == 1 ? "app" : "apps") will be hidden while Claude works." : nil]
        return sections.compactMap { $0 }.joined(separator: "\n\n")
    }

    /// The CLI's own result shape. Nil grants nothing, as the CLI's Deny does.
    static func computerUseGrant(_ payload: [String: Any]?, at date: Date = Date()) -> [String: Any] {
        var flags = ["clipboardRead": false, "clipboardWrite": false, "systemKeyCombos": false]
        var granted = [[String: Any]](), denied = [[String: Any]]()
        guard let payload else { return ["granted": granted, "denied": denied, "flags": flags] }
        let requested = payload["requestedFlags"] as? [String: Any] ?? [:]
        for key in flags.keys where requested[key] as? Bool == true { flags[key] = true }
        let grantedAt = Int(date.timeIntervalSince1970 * 1000)
        for app in payload["apps"] as? [[String: Any]] ?? [] {
            if let resolved = app["resolved"] as? [String: Any], let bundle = resolved["bundleId"] as? String {
                guard app["alreadyGranted"] as? Bool != true, !granted.contains(where: { $0["bundleId"] as? String == bundle }) else { continue }
                granted.append(["bundleId": bundle, "displayName": resolved["displayName"] as? String ?? bundle, "grantedAt": grantedAt])
            } else if let name = app["requestedName"] as? String {
                denied.append(["bundleId": name, "reason": "not_installed"])
            }
        }
        return ["granted": granted, "denied": denied, "flags": flags]
    }

    mutating func answer(_ params: [String: Any], approval: Bool) throws -> [String: Any]? {
        let id = params["request_id"] as? String ?? ""
        guard params["session_id"] as? String == sessionID, var pending = requests[id] else { throw AppError("This Claude Code request has expired.") }
        if approval {
            let computerUse = pending.tool == Self.computerUseDialog
            guard pending.tool != "AskUserQuestion", let choice = params["choice"] as? String, (computerUse ? ["session", "deny"] : ["once", "deny"]).contains(choice) else {
                throw AppError(computerUse ? "Claude Code offered only Allow this session or Deny for computer use." : "Claude Code offered only Allow once or Deny for this action.")
            }
            requests.removeValue(forKey: id)
            if computerUse {
                return Self.response(id, ["behavior": "completed", "result": Self.computerUseGrant(choice == "session" ? pending.input : nil)])
            }
            return Self.response(id, choice == "once" ? ["behavior": "allow", "updatedInput": pending.input] : ["behavior": "deny", "message": "The user denied this action."])
        }
        let questions = pending.input["questions"] as? [[String: Any]] ?? []
        guard pending.tool == "AskUserQuestion", let index = Int(params["question_id"] as? String ?? ""), questions.indices.contains(index),
              let question = questions[index]["question"] as? String, let answer = params["answer"] as? String, !answer.isEmpty else { throw AppError("Choose an answer to this Claude Code question.") }
        pending.answers[question] = answer
        requests[id] = pending
        guard pending.answers.count == questions.count else { return nil }
        requests.removeValue(forKey: id)
        var input = pending.input; input["answers"] = pending.answers
        return Self.response(id, ["behavior": "allow", "updatedInput": input])
    }

    mutating func receive(_ frame: [String: Any]) throws -> [Event] {
        let child = frame["parent_tool_use_id"] as? String
        if let child, !tools.contains(child) { return [] }
        if child == nil, let id = frame["session_id"] as? String, !id.isEmpty, id != sessionID { throw AppError("Claude Code returned a different native session. No further messages were sent.") }
        let type = frame["type"] as? String ?? ""
        if child == nil, let id = frame["command_uuid"] as? String, type == "command_lifecycle", pendingSteering.contains(id) {
            let state = frame["state"] as? String ?? ""
            if ["started", "completed", "cancelled", "discarded", "refused"].contains(state) {
                pendingSteering.remove(id)
                if state == "started" {
                    // An input can be admitted just as the original turn ends.
                    // Its new result must arrive before the session settles.
                    self.result = nil
                    return []
                }
                return completeIfSettled()
            }
        }
        if child == nil, type == "user", let id = frame["uuid"] as? String, pendingSteering.remove(id) != nil { result = nil }
        if type == "rate_limit_event", let info = frame["rate_limit_info"] as? [String: Any] {
            return [event("runtime.rateLimits", ["limits": RuntimeRateLimit.claude(info)])]
        }
        if type == "control_cancel_request", let id = frame["request_id"] as? String {
            requests.removeValue(forKey: id)
            return [event("clarify.expire", ["request_id": id])]
        }
        if type == "system" {
            let subtype = frame["subtype"] as? String ?? ""
            if subtype == "init" {
                guard child == nil else { return [] }
                supportsSteering = Self.supportsSteering(version: frame["claude_code_version"] as? String ?? "")
                if let model = frame["model"] as? String { contextModelChanged(model) }
                var info: [String: Any] = ["capabilities": ["steering": supportsSteering]]; info["model"] = frame["model"]
                var events = [event("session.info", info)]
                if !(frame["plugin_errors"] as? [[String: Any]] ?? []).isEmpty || !(frame["mcp_server_errors"] as? [[String: Any]] ?? []).isEmpty {
                    events.append(event("runtime.notice", ["message": "Some native Claude Code plugins or MCP servers did not load. Check the native CLI setup."]))
                }
                return events
            }
            if child == nil, subtype == "compact_boundary" || (subtype == "status" && frame["status"] as? String == "compacting") {
                contextUsed = nil
                return [contextInfo(reset: true)]
            }
            if subtype == "session_state_changed" {
                nativeState = frame["state"] as? String
                if nativeState == "running", !active {
                    active = true; result = nil; text = ""
                    return [event("message.start", ["role": "assistant"])]
                }
                return completeIfSettled()
            }
            guard active else { return [] }
            if subtype == "permission_denied" { return [event("runtime.notice", ["message": "Claude Code denied a tool under the native permission policy."])] }
            if subtype == "api_retry" { return [event("runtime.notice", ["message": "Claude Code is retrying its provider request."])] }
            if let id = frame["task_id"] as? String {
                if subtype == "task_started" {
                    children.insert(id)
                    let alias = frame["tool_use_id"] as? String ?? id
                    taskAliases[id] = alias; tools.insert(alias)
                    return [event("subagent.start", ["subagent_id": alias, "name": frame["description"] as? String ?? "Claude agent"])]
                }
                let patch = frame["patch"] as? [String: Any] ?? [:]
                let status = frame["status"] as? String ?? patch["status"] as? String ?? ""
                if children.contains(id), subtype == "task_notification" || (subtype == "task_updated" && ["completed", "failed", "stopped"].contains(status)) {
                    children.remove(id); failedChild = failedChild || status == "failed"
                    return [event("subagent.complete", ["subagent_id": taskAliases[id] ?? id, "status": status == "failed" ? "error" : status == "stopped" ? "interrupted" : "complete", "text": frame["summary"] as? String ?? ""])] + completeIfSettled()
                }
            }
            return []
        }
        guard active else { return [] }
        if type == "stream_event" {
            let data = frame["event"] as? [String: Any] ?? [:]
            let delta = data["delta"] as? [String: Any] ?? [:]
            if delta["type"] as? String == "text_delta", let chunk = delta["text"] as? String {
                partialMessages.insert(child ?? "parent")
                if let child { return [event("subagent.text", ["subagent_id": child, "text": chunk])] }
                text += chunk
                return [event("message.delta", ["text": chunk])]
            }
            return []
        }
        if ["assistant", "user"].contains(type) {
            if child == nil, let category = frame["error"] as? String { errorCategory = category }
            let message = frame["message"] as? [String: Any] ?? [:]
            let content = message["content"] as? [[String: Any]] ?? []
            var events: [Event] = []
            if type == "assistant", child == nil, frame["error"] == nil,
               let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<") {
                contextModelChanged(model)
                contextUsed = Self.requestInputTokens(message["usage"] as? [String: Any] ?? [:])
                events.append(contextInfo(reset: contextUsed == nil))
            }
            for block in content {
                if block["type"] as? String == "text", type == "assistant", !partialMessages.contains(child ?? "parent"), let value = block["text"] as? String {
                    if let child { events.append(event("subagent.text", ["subagent_id": child, "text": value])) }
                    else { text += value; events.append(event("message.delta", ["text": value])) }
                }
                if block["type"] as? String == "tool_use", let id = block["id"] as? String, tools.insert(id).inserted {
                    events.append(event(child == nil ? "tool.start" : "subagent.tool", ["tool_id": id, "subagent_id": child ?? "", "name": block["name"] as? String ?? "Tool", "context": CodexProtocolState.describe(block["input"])]))
                }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    events.append(event("tool.complete", ["tool_id": id, "result": CodexProtocolState.describe(block["content"]), "is_error": block["is_error"] as? Bool ?? false]))
                }
            }
            if type == "assistant" { partialMessages.remove(child ?? "parent") }
            return events
        }
        if type == "result", child == nil {
            var events: [Event] = []
            if let model = contextModel, let rows = frame["modelUsage"] as? [String: [String: Any]] {
                let matches = rows.values.filter { $0["canonicalModel"] as? String == model }
                let row = rows[model] ?? (matches.count == 1 ? matches.first : nil)
                if let limit = Self.tokenCount(row?["contextWindow"]), limit > 0 {
                    contextWindow = limit; events.append(contextInfo())
                }
            }
            if let rows = frame["modelUsage"] as? [String: [String: Any]] {
                let total = rows.values.reduce(0) { sum, row in
                    sum + ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"].compactMap { Self.tokenCount(row[$0]) }.reduce(0, +)
                }
                if total >= processTokens { events.append(event("session.info", ["turn_tokens": total - processTokens])) }
                processTokens = total
            }
            result = frame
            return events + completeIfSettled()
        }
        return []
    }

    private mutating func completeIfSettled() -> [Event] {
        guard active, let result, children.isEmpty, requests.isEmpty, pendingSteering.isEmpty,
              nativeState == nil || nativeState == "idle" else { return [] }
        active = false; self.result = nil
        let failed = result["is_error"] as? Bool == true || failedChild
        var events: [Event] = []
        if failed && !interrupted {
            let message = errorCategory == "authentication_failed"
                ? "Claude Code authentication failed. Sign in again with the native claude CLI, then reconnect this saved conversation."
                : errorCategory == "billing_error" ? "Claude Code reported a billing issue. Check your account in its native setup."
                : errorCategory == "rate_limit" ? "Claude Code reached its native account limit. Try again when the limit resets."
                : "Claude Code could not complete this turn. Check native permissions or provider availability."
            events.append(event("session.error", ["message": message]))
        }
        events.append(event("message.complete", ["text": result["result"] as? String ?? text, "status": interrupted ? "interrupted" : failed ? "error" : "complete", "completion_id": result["uuid"] as? String ?? turnID]))
        return events
    }
}
