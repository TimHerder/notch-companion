import Foundation

enum ACPClientError: LocalizedError {
    case unavailable(String), rpc(Int, String)
    var errorDescription: String? {
        switch self { case .unavailable(let text), .rpc(_, let text): return text }
    }
}

/// ACP v1 translation. Only explicit new/resume operations establish ownership;
/// native session lists and notifications cannot import external conversations.
struct ACPProtocolState {
    struct Event { var name: String; var payload: [String: Any] }
    struct Interaction {
        var id: Any
        var session: String
        var method: String
        var options: [String: String] = [:]
        var questions: [[String: Any]] = []
        var values: [String: String] = [:]
        var picked: [String: [String]] = [:]
        var childID: String? = nil
    }
    /// Antigravity's dialect: "Running <tool>" titles and questions sent as `interaction_` permission requests.
    var antigravity = false
    var owned = Set<String>()
    var active = Set<String>()
    var started = Set<String>()
    var loading = Set<String>()
    var history: [String: [[String: Any]]] = [:]
    var historyWithoutMessageIDs = Set<String>()
    /// Sessions whose replayed reply was interrupted by a tool call.
    var historyBreaks = Set<String>()
    var text: [String: String] = [:]
    var requests: [String: Interaction] = [:]
    var tools = Set<String>()
    var config: [String: [[String: Any]]] = [:]
    /// The session `models` state where the adapter uses it (Antigravity): its IDs match `agy models`.
    var models: [String: [String: Any]] = [:]
    var children: [String: Set<String>] = [:]
    var parentEnded = Set<String>()

    mutating func begin(_ sid: String) throws {
        guard owned.contains(sid), !active.contains(sid), children[sid]?.isEmpty ?? true else { throw ACPClientError.unavailable("This session is unregistered, still working, or has delegated activity whose completion ACP cannot verify. Check the native runtime before sending.") }
        active.insert(sid); started.remove(sid); text[sid] = ""
        parentEnded.remove(sid)
        tools = tools.filter { !$0.hasPrefix(sid + "\u{0}") }
    }

    mutating func notification(_ method: String, _ params: [String: Any]) -> [Event] {
        guard method == "session/update", let sid = params["sessionId"] as? String,
              owned.contains(sid), let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return [] }
        let content = update["content"] as? [String: Any] ?? [:]
        let metadata = Self.childMetadata(update)
        if kind == "config_option_update" {
            guard metadata == nil else { return [] }
            config[sid] = update["configOptions"] as? [[String: Any]] ?? []
            // A model state names the exact model; its config option holds only the family.
            if models[sid] == nil, let model = Self.catalog(config[sid] ?? []).defaultModel?.model {
                return [event("session.info", sid, ["model": model])]
            }
            return []
        }
        // Native load replay is authoritative history, never new live activity.
        if loading.contains(sid) {
            if metadata != nil { return [] }
            // Replies split where they streamed: at tool calls, not at message IDs.
            if kind == "tool_call" { historyBreaks.insert(sid) }
            if ["user_message_chunk", "agent_message_chunk"].contains(kind), let chunk = content["text"] as? String {
                let role = kind == "user_message_chunk" ? "user" : "assistant"
                let messageID = update["messageId"] as? String
                if messageID == nil { historyWithoutMessageIDs.insert(sid) }
                let toolBetween = historyBreaks.remove(sid) != nil
                if let last = history[sid]?.indices.last, history[sid]?[last]["role"] as? String == role,
                   role == "assistant" ? !toolBetween : messageID == nil || history[sid]?[last]["row_id"] as? String == messageID {
                    let previous = history[sid]?[last]["text"] as? String ?? ""
                    history[sid]?[last]["text"] = previous + chunk
                } else {
                    let count = history[sid]?.count ?? 0
                    let reused = messageID.map { id in history[sid]?.contains { $0["row_id"] as? String == id } == true } ?? false
                    let rowID = messageID.map { reused ? "\($0)-\(count)" : $0 } ?? "acp-\(count)"
                    history[sid, default: []].append(["role": role, "text": chunk, "row_id": rowID])
                }
            }
            return []
        }
        if kind == "usage_update" {
            guard metadata == nil else { return [] }
            var usage: [String: Any] = [:]
            if let used = update["used"] as? Int, used >= 0 { usage["context_used"] = used }
            if let size = update["size"] as? Int, size > 0 { usage["context_max"] = size }
            return usage.isEmpty ? [] : [event("session.info", sid, ["usage": usage])]
        }
        guard active.contains(sid) || !(children[sid]?.isEmpty ?? true) || (metadata != nil && parentEnded.contains(sid)) else { return [] }
        var events: [Event] = []
        var childID: String?
        if let metadata {
            guard let registered = registerChild(metadata, sid: sid) else { return [] }
            childID = registered.id; events += registered.events
        }
        if active.contains(sid), !started.contains(sid), ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"].contains(kind) {
            started.insert(sid); events.append(event("message.start", sid, ["role": "assistant"]))
        }
        // ACP forwards child activity but has no independent terminal child
        // event. Track the child conservatively; parent settlement never proves
        // that child stopped. Stable tools remain in the parent's full history.
        if kind == "agent_message_chunk", let chunk = content["text"] as? String {
            if let childID { events.append(event("subagent.text", sid, ["subagent_id": childID, "text": chunk])) }
            else if !parentEnded.contains(sid) { text[sid, default: ""] += chunk; events.append(event("message.delta", sid, ["text": chunk])) }
        } else if kind == "tool_call" || kind == "tool_call_update" {
            guard let id = update["toolCallId"] as? String, !id.isEmpty else { return events }
            let key = sid + "\u{0}" + id
            let detail = Self.describe(update["rawInput"] ?? update["locations"] ?? update["content"])
            if tools.insert(key).inserted {
                var name = update["title"] as? String ?? update["kind"] as? String ?? "Tool"
                // Antigravity titles every call, MCP tools included, "Running <bare tool name>".
                if antigravity, name.hasPrefix("Running ") { name.removeFirst(8) }
                events.append(event("tool.start", sid, ["tool_id": id, "name": name, "context": detail]))
            }
            let status = update["status"] as? String ?? "pending"
            if status == "completed" || status == "failed" {
                events.append(event("tool.complete", sid, ["tool_id": id, "is_error": status == "failed", "result": Self.describe(update["rawOutput"] ?? update["content"])]))
            }
        }
        return events
    }

    mutating func finish(_ sid: String, stopReason: String, error: String? = nil) -> [Event] {
        guard active.remove(sid) != nil else { return [] }
        parentEnded.insert(sid)
        started.remove(sid)
        let keys = requests.filter { $0.value.session == sid && $0.value.childID == nil }.map(\.key)
        var result = keys.map { event("clarify.expire", sid, ["request_id": $0]) }
        for key in keys { requests.removeValue(forKey: key) }
        if let error { result.append(event("runtime.notice", sid, ["message": error])) }
        else if stopReason != "end_turn" && stopReason != "cancelled" {
            result.append(event("runtime.notice", sid, ["message": "The native runtime ended this turn: \(stopReason). Review the response before continuing."]))
        }
        if let unresolved = children[sid], !unresolved.isEmpty {
            result += unresolved.sorted().map { event("subagent.thinking", sid, ["subagent_id": $0, "status": "waiting"]) }
            result.append(event("runtime.activity_unverified", sid, ["subagent_ids": unresolved.sorted(), "message": Self.childLimitation]))
        }
        result.append(event("message.complete", sid, ["text": text[sid] ?? "", "status": error != nil ? "error" : stopReason == "cancelled" ? "interrupted" : "complete"]))
        return result
    }

    mutating func serverRequest(id: Any, method: String, params: [String: Any]) -> (events: [Event], reply: [String: Any]?) {
        let incomingChild = Self.childMetadata(params["toolCall"] as? [String: Any] ?? params)
        let cursor = method.hasPrefix("cursor/")
        guard let sid = params["sessionId"] as? String ?? (cursor ? cursorSession(params["toolCallId"] as? String) : nil), owned.contains(sid),
              active.contains(sid) || !(children[sid]?.isEmpty ?? true) || (incomingChild != nil && parentEnded.contains(sid)) else {
            return ([], Self.failure(id, "Request is not associated with active companion-owned work."))
        }
        let key = Self.requestKey(id)
        if requests[key] != nil { return ([], Self.failure(id, "Duplicate pending request ID.")) }
        var childEvents: [Event] = [], childID: String?
        if let metadata = incomingChild {
            guard let registered = registerChild(metadata, sid: sid) else { return ([], Self.failure(id, "Child does not belong to this companion session.")) }
            childID = registered.id; childEvents = registered.events
            if let childID { childEvents.append(event("subagent.thinking", sid, ["subagent_id": childID, "status": "waiting"])) }
        }
        if method == "session/request_permission", antigravity, let tool = params["toolCall"] as? [String: Any],
           (tool["toolCallId"] as? String)?.hasPrefix("interaction_") == true {
            // Antigravity's own questions: the options are answers, never approvals.
            guard let question = Self.antigravityQuestion(tool, params["options"]) else {
                let message = "Antigravity asked a question the companion cannot show, so it was cancelled. Ask it to write the question in its message."
                return (childEvents + [event("runtime.notice", sid, ["message": message])], Self.reply(id, ["outcome": ["outcome": "cancelled"]]))
            }
            requests[key] = Interaction(id: id, session: sid, method: "antigravity/question", questions: [question], childID: childID)
            return (childEvents + [event("clarify.request", sid, ["request_id": key, "questions": [question]])], nil)
        }
        if method == "session/request_permission" {
            var choices: [String: String] = [:]
            for option in params["options"] as? [[String: Any]] ?? [] {
                guard let id = option["optionId"] as? String, let kind = option["kind"] as? String else { continue }
                if kind == "allow_once" { choices["once"] = id }
                if kind == "reject_once" || kind == "reject_always" { choices["deny"] = id }
            }
            // Never present allow_always as the narrower UI "session" choice.
            requests[key] = Interaction(id: id, session: sid, method: method, options: choices, childID: childID)
            let tool = params["toolCall"] as? [String: Any] ?? [:]
            let detail = [tool["title"] as? String ?? "Tool permission", Self.describe(tool["rawInput"] ?? tool["content"])].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return (childEvents + [event("approval.request", sid, ["request_id": key, "choices": choices["once"] == nil ? ["deny"] : ["once", "deny"], "command": detail])], nil)
        }
        if method == "elicitation/create", params["mode"] as? String ?? "form" == "form",
           let schema = params["requestedSchema"] as? [String: Any], let questions = Self.questions(schema, message: params["message"] as? String ?? "") {
            requests[key] = Interaction(id: id, session: sid, method: method, questions: questions, childID: childID)
            return (childEvents + [event("clarify.request", sid, ["request_id": key, "questions": questions])], nil)
        }
        if method == "cursor/ask_question", let rows = params["questions"] as? [[String: Any]], (1...16).contains(rows.count) {
            let questions = rows.compactMap { row -> [String: Any]? in
                guard let qid = row["id"] as? String, let prompt = row["prompt"] as? String else { return nil }
                var map: [String: String] = [:], labels: [String] = []
                for option in row["options"] as? [[String: Any]] ?? [] {
                    guard let value = option["id"] as? String, let label = option["label"] as? String, map[label] == nil else { return nil }
                    map[label] = value; labels.append(label)
                }
                guard !labels.isEmpty else { return nil }
                var question: [String: Any] = ["qid": qid, "question": prompt, "choices": labels, "allows_free_text": false,
                                               "multi_select": row["allowMultiple"] as? Bool ?? false, "value_map": map]
                if let title = params["title"] as? String, !title.isEmpty { question["header"] = title }
                return question
            }
            if questions.count == rows.count, Set(questions.compactMap { $0["qid"] as? String }).count == rows.count {
                requests[key] = Interaction(id: id, session: sid, method: method, questions: questions, childID: childID)
                return (childEvents + [event("clarify.request", sid, ["request_id": key, "questions": questions])], nil)
            }
        }
        if method == "cursor/create_plan", let plan = params["plan"] as? String {
            requests[key] = Interaction(id: id, session: sid, method: method, options: ["once": "accepted"], childID: childID)
            let detail = ["Start with this plan?", params["name"] as? String, params["overview"] as? String, plan]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return (childEvents + [event("approval.request", sid, ["request_id": key, "choices": ["once", "deny"], "command": detail])], nil)
        }
        let message = "The runtime requested an unsupported interaction (\(method)); it was declined. Use the native interface for this feature."
        let reply = method == "elicitation/create" ? Self.reply(id, ["action": "decline"])
            : cursor ? Self.reply(id, ["outcome": ["outcome": "cancelled"]]) : Self.failure(id, message)
        return (childEvents + [event("runtime.notice", sid, ["message": message])], reply)
    }

    mutating func answer(_ params: [String: Any], approval: Bool) throws -> [String: Any]? {
        let key = params["request_id"] as? String ?? ""
        guard var request = requests[key], request.session == params["session_id"] as? String else { throw ACPClientError.unavailable("That native request has expired or belongs to another session.") }
        if approval {
            guard ["session/request_permission", "cursor/create_plan"].contains(request.method) else { throw ACPClientError.unavailable("This request is not a permission request.") }
            let choice = params["choice"] as? String ?? "deny"
            guard choice == "deny" || request.options[choice] != nil else { throw ACPClientError.unavailable("The runtime did not offer that permission scope.") }
            requests.removeValue(forKey: key)
            if request.method == "cursor/create_plan" { return Self.reply(request.id, ["outcome": ["outcome": choice == "deny" ? "rejected" : "accepted"]]) }
            guard let option = request.options[choice] else { return Self.reply(request.id, ["outcome": ["outcome": "cancelled"]]) }
            return Self.reply(request.id, ["outcome": ["outcome": "selected", "optionId": option]])
        }
        guard ["elicitation/create", "cursor/ask_question", "antigravity/question"].contains(request.method) else { throw ACPClientError.unavailable("This request is not a question.") }
        let qid = params["question_id"] as? String ?? ""
        guard let question = request.questions.first(where: { $0["qid"] as? String == qid }), let value = params["answer"] as? String else { throw ACPClientError.unavailable("That question has expired.") }
        let choices = question["choices"] as? [String] ?? []
        let picked = params["answers"] as? [String] ?? [value]
        guard choices.isEmpty || picked.allSatisfy(choices.contains) else { throw ACPClientError.unavailable("Choose an answer offered by the runtime.") }
        request.values[qid] = value; request.picked[qid] = picked; requests[key] = request
        guard request.questions.allSatisfy({ request.values[$0["qid"] as? String ?? ""] != nil }) else { return nil }
        requests.removeValue(forKey: key)
        if request.method == "antigravity/question" {
            let option = (question["value_map"] as? [String: String])?[value]
            return Self.reply(request.id, ["outcome": option.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]])
        }
        if request.method == "cursor/ask_question" {
            let answers = request.questions.map { question -> [String: Any] in
                let qid = question["qid"] as? String ?? "", map = question["value_map"] as? [String: String] ?? [:]
                return ["questionId": qid, "selectedOptionIds": (request.picked[qid] ?? []).compactMap { map[$0] }]
            }
            return Self.reply(request.id, ["outcome": ["outcome": "answered", "answers": answers]])
        }
        var values = request.values
        for question in request.questions {
            let qid = question["qid"] as? String ?? ""
            if let map = question["value_map"] as? [String: String], let label = values[qid], let native = map[label] { values[qid] = native }
        }
        return Self.reply(request.id, ["action": "accept", "content": values])
    }

    /// After `session/cancel` ACP requires every open request to be answered as cancelled.
    mutating func cancelRequests(_ sid: String) -> [[String: Any]] {
        requests.filter { $0.value.session == sid }.keys.compactMap { requests.removeValue(forKey: $0) }.map {
            Self.reply($0.id, $0.method == "elicitation/create" ? ["action": "cancel"] : ["outcome": ["outcome": "cancelled"]])
        }
    }

    static func questions(_ schema: [String: Any], message: String) -> [[String: Any]]? {
        guard schema["type"] as? String == "object", let properties = schema["properties"] as? [String: [String: Any]], !properties.isEmpty, properties.count <= 16 else { return nil }
        let required = Set(schema["required"] as? [String] ?? Array(properties.keys))
        var result: [[String: Any]] = []
        for key in properties.keys.sorted() {
            guard let field = properties[key] else { continue }
            // Optional custom-choice companion properties can be omitted. Forms
            // requiring them or richer JSON Schema validation are declined.
            if key.hasSuffix("_custom"), !required.contains(key) { continue }
            guard field["type"] as? String == "string", field["format"] == nil,
                  field["writeOnly"] as? Bool != true,
                  !["pattern", "minLength", "maxLength", "anyOf", "allOf"].contains(where: { field[$0] != nil }) else { return nil }
            var choices = field["enum"] as? [String] ?? [], mapping: [String: String] = [:]
            if let variants = field["oneOf"] as? [[String: Any]] {
                for variant in variants {
                    guard let value = variant["const"] as? String else { return nil }
                    let title = variant["title"] as? String ?? value
                    guard mapping[title] == nil else { return nil }
                    mapping[title] = value; choices.append(title)
                }
            }
            result.append(["qid": key, "question": [message, field["title"] as? String ?? key, field["description"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"), "choices": choices, "allows_free_text": choices.isEmpty, "multi_select": false, "value_map": mapping])
        }
        return result.isEmpty ? nil : result
    }

    /// Advertised ACP session modes that match a companion permission mode.
    /// Unrecognised modes are not offered.
    static func permissionModes(_ modes: [String: Any]?) -> [PermissionMode: String] {
        let known: [String: PermissionMode] = ["default": .ask, "ask": .ask, "manual": .ask,
            "acceptEdits": .autoEdit, "accept-edits": .autoEdit, "auto-edit": .autoEdit, "autoEdit": .autoEdit,
            "plan": .plan, "bypassPermissions": .fullAccess, "full-access": .fullAccess, "fullAccess": .fullAccess, "yolo": .fullAccess]
        var result: [PermissionMode: String] = [:]
        for row in modes?["availableModes"] as? [[String: Any]] ?? [] {
            if let id = row["id"] as? String, let mode = known[id], result[mode] == nil { result[mode] = id }
        }
        return result
    }

    static func catalog(_ options: [[String: Any]]) -> RuntimeModelCatalog {
        guard let model = options.first(where: { $0["category"] as? String == "model" || $0["id"] as? String == "model" }) else {
            return RuntimeModelCatalog(note: "This ACP runtime has not reported a session model catalog.")
        }
        var rows: [[String: Any]] = []
        for entry in model["options"] as? [[String: Any]] ?? [] {
            rows += entry["options"] as? [[String: Any]] ?? [entry]
        }
        var seen = Set<String>()
        return RuntimeModelCatalog(defaultModel: (model["currentValue"] as? String).map { RuntimeModelChoice(model: $0) }, models: rows.compactMap {
            guard let id = $0["value"] as? String, seen.insert(id).inserted else { return nil }
            return RuntimeModelOption(choice: RuntimeModelChoice(model: id), title: $0["name"] as? String ?? id)
        }, note: "Models reported by this native session; changing one does not change the global profile.")
    }

    /// The session's `models` state (exact IDs) when the adapter keeps one, else its model config option.
    func catalog(_ sid: String) -> RuntimeModelCatalog {
        Self.catalog(models: models[sid]) ?? Self.catalog(config[sid] ?? [])
    }

    static func catalog(models: [String: Any]?) -> RuntimeModelCatalog? {
        var seen = Set<String>()
        let options = (models?["availableModels"] as? [[String: Any]] ?? []).compactMap { row -> RuntimeModelOption? in
            guard let id = row["modelId"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return RuntimeModelOption(choice: RuntimeModelChoice(model: id), title: row["name"] as? String ?? id)
        }
        guard !options.isEmpty else { return nil }
        return RuntimeModelCatalog(defaultModel: (models?["currentModelId"] as? String).map { RuntimeModelChoice(model: $0) }, models: options,
                                   note: "Models reported by this native session; changing one does not change the global profile.")
    }

    /// One single-choice question whose answers are the request's options, labelled by their names.
    static func antigravityQuestion(_ tool: [String: Any], _ options: Any?) -> [String: Any]? {
        var map: [String: String] = [:], labels: [String] = []
        for option in options as? [[String: Any]] ?? [] {
            guard let id = option["optionId"] as? String, !id.isEmpty else { return nil }
            let label = (option["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            guard map[label] == nil else { return nil }
            map[label] = id; labels.append(label)
        }
        guard !labels.isEmpty, let qid = tool["toolCallId"] as? String else { return nil }
        return ["qid": qid, "question": tool["title"] as? String ?? "Choose an option.", "choices": labels,
                "allows_free_text": false, "multi_select": false, "value_map": map]
    }

    /// Cursor's extension requests name a tool call, not a session. Attribute one
    /// only to the session that streamed that call, or to the sole active session.
    private func cursorSession(_ call: String?) -> String? {
        if let call, let key = tools.first(where: { $0.hasSuffix("\u{0}" + call) }) { return String(key.prefix { $0 != "\u{0}" }) }
        return active.count == 1 ? active.first : nil
    }
    private static func childMetadata(_ value: [String: Any]) -> [String: Any]? {
        (value["_meta"] as? [String: Any])?["opencode/child-session"] as? [String: Any]
    }
    private mutating func registerChild(_ metadata: [String: Any], sid: String) -> (id: String, events: [Event])? {
        guard let id = metadata["id"] as? String, !id.isEmpty, id != sid,
              let parent = metadata["parentID"] as? String,
              parent == sid || children[sid]?.contains(parent) == true else { return nil }
        let fresh = children[sid, default: []].insert(id).inserted
        var result = fresh ? [event("subagent.start", sid, ["subagent_id": id, "name": metadata["title"] as? String ?? "OpenCode agent"])] : []
        if fresh || parentEnded.contains(sid) { result.append(event("runtime.activity_unverified", sid, ["subagent_ids": Array(children[sid] ?? []).sorted(), "message": Self.childLimitation])) }
        return (id, result)
    }
    static let childLimitation = "OpenCode reported delegated activity, but ACP does not report when each child stops. The parent response is saved; this session remains protected from another send or an idle claim. Check and stop the delegated work in native OpenCode."

    func event(_ name: String, _ sid: String, _ fields: [String: Any]) -> Event {
        var payload = fields; payload["session_id"] = sid; return Event(name: name, payload: payload)
    }
    static func requestKey(_ id: Any) -> String { (id as? String).map { "s:" + $0 } ?? "n:" + String(describing: id) }
    static func reply(_ id: Any, _ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    static func failure(_ id: Any, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": message]] }
    static func describe(_ value: Any?) -> String { CodexProtocolState.describe(value) }
}
