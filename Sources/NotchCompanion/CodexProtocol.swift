import Foundation

/// Translation only. Ownership is explicit; runtime source labels are never a
/// session filter (independent app-server threads can have source `vscode`).
struct CodexProtocolState {
    struct Event {
        var name: String
        var payload: [String: Any]
    }
    struct ServerRequest {
        var wireID: Any
        var method: String
        var threadID: String
        var params: [String: Any]
        var answers: [String: [String: [String]]] = [:]
    }

    var ownedThreads = Set<String>()
    var parents: [String: String] = [:]
    var activeTurns: [String: String] = [:]
    var startingThreads = Set<String>()
    var requests: [String: ServerRequest] = [:]
    var completedTurns = Set<String>()
    /// Parent-thread cumulative tokens seen in this process (0 for threads
    /// started here) and the total each turn started from.
    var tokenTotals: [String: Int] = [:]
    private var turnBaselines: [String: (turn: String, total: Int)] = [:]
    private var latestTurns: [String: String] = [:]
    private var messageOrder: [String: [String]] = [:]
    private var messageTexts: [String: [String: String]] = [:]
    private var emittedTools = Set<String>()
    private var toolDetails: [String: String] = [:]
    /// Agent messages that carry `request_user_input_async` questions. Their
    /// text is Codex's plain rendering of the questions, shown as a card instead.
    private var questionMessages = Set<String>()

    func root(for thread: String) -> String? {
        if ownedThreads.contains(thread) { return thread }
        return parents[thread]
    }

    mutating func register(_ thread: [String: Any]) throws -> String {
        guard let id = thread["id"] as? String, !id.isEmpty else {
            throw CodexClientError.unavailable("Codex returned an invalid native thread ID.")
        }
        ownedThreads.insert(id)
        // A fresh native resume/read is authoritative after a lost response.
        // Clear the speculative send gate instead of trapping an idle thread.
        startingThreads.remove(id)
        activeTurns.removeValue(forKey: id)
        let turns = thread["turns"] as? [[String: Any]] ?? []
        latestTurns[id] = turns.last?["id"] as? String
        for turn in turns where turn["status"] as? String != "inProgress" {
            if let turnID = turn["id"] as? String { completedTurns.insert(id + ":" + turnID) }
        }
        if let turn = turns.last,
           turn["status"] as? String == "inProgress", let turnID = turn["id"] as? String {
            activeTurns[id] = turnID
        }
        return id
    }

    mutating func notifications(_ method: String, _ params: [String: Any]) -> [Event] {
        if method == "account/rateLimits/updated" {
            return [Event(name: "runtime.rateLimits", payload: ["limits": RuntimeRateLimit.codex(params)])]
        }
        if method == "thread/started", let thread = params["thread"] as? [String: Any],
           let id = thread["id"] as? String, let parent = thread["parentThreadId"] as? String,
           let root = root(for: parent) {
            parents[id] = root
            return [Event(name: "subagent.start", payload: ["session_id": root, "subagent_id": id,
                "name": thread["agentNickname"] as? String ?? thread["agentRole"] as? String ?? "Codex agent"])]
        }
        guard let tid = params["threadId"] as? String, let sid = root(for: tid) else { return [] }
        let incomingTurn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        if let incomingTurn {
            if method == "thread/tokenUsage/updated" {
                if let latest = latestTurns[tid], latest != incomingTurn { return [] }
            } else if completedTurns.contains(tid + ":" + incomingTurn) { return [] }
            if let active = activeTurns[tid], active != incomingTurn { return [] }
        }
        let child = tid != sid
        func event(_ name: String, _ fields: [String: Any] = [:]) -> Event {
            var payload = fields
            payload["session_id"] = sid
            if child { payload["subagent_id"] = tid }
            return Event(name: name, payload: payload)
        }
        switch method {
        case "turn/diff/updated":
            // The parent aggregate is authoritative; adding child aggregates
            // could count the same shared-worktree edit twice.
            guard !child, let incomingTurn, activeTurns[tid] == incomingTurn,
                  let diff = params["diff"] as? String else { return [] }
            return [event("turn.changes", ["diff": diff])]
        case "thread/tokenUsage/updated":
            guard !child, let usage = params["tokenUsage"] as? [String: Any] else { return [] }
            var info: [String: Any] = ["usage": usage]
            if let total = (usage["total"] as? [String: Any])?["totalTokens"] as? Int {
                // Without a starting total from this process the turn stays unreported.
                if let base = turnBaselines[tid], base.turn == incomingTurn, total >= base.total { info["turn_tokens"] = total - base.total }
                tokenTotals[tid] = total
            }
            return [event("session.info", info)]
        case "model/rerouted":
            guard !child, let model = params["toModel"] as? String else { return [] }
            return [event("session.info", ["model": model])]
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return [] }
            activeTurns[tid] = id
            latestTurns[tid] = id
            if !child { turnBaselines[tid] = tokenTotals[tid].map { (id, $0) } }
            startingThreads.remove(tid)
            messageOrder[tid] = []
            messageTexts[tid] = [:]
            return [event(child ? "subagent.thinking" : "message.start", ["role": "assistant"])]
        case "item/agentMessage/delta":
            let id = params["itemId"] as? String ?? "message"
            if questionMessages.contains(tid + ":" + id) { return [] }
            let delta = params["delta"] as? String ?? ""
            let isNew = !(messageOrder[tid] ?? []).contains(id)
            if isNew { messageOrder[tid, default: []].append(id) }
            let prefix = isNew && (messageOrder[tid]?.count ?? 0) > 1 ? "\n\n" : ""
            messageTexts[tid, default: [:]][id, default: ""] += delta
            return [event(child ? "subagent.text" : "message.delta", ["text": prefix + delta])]
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else { return [] }
            let complete = method == "item/completed"
            let id = item["id"] as? String ?? ""
            if type == "agentMessage", let questions = AsyncQuestion.decode(item["questions"]) {
                // The question tool returns at once; any reply is the next user message.
                questionMessages.insert(tid + ":" + id)
                messageOrder[tid]?.removeAll { $0 == id }
                messageTexts[tid]?.removeValue(forKey: id)
                guard complete, !child else { return [] }
                return [event("message.questions", ["item_id": id, "questions": questions.map(\.payload)])]
            }
            if type == "imageGeneration", complete, let path = item["savedPath"] as? String, path.hasPrefix("/") {
                // A generated image is shown in the conversation, like an answer.
                let key = "image:" + id
                guard !(messageOrder[tid] ?? []).contains(key) else { return [] }
                messageOrder[tid, default: []].append(key)
                let text = Self.imageMarkdown(path)
                messageTexts[tid, default: [:]][key] = text
                let prefix = (messageOrder[tid]?.count ?? 0) > 1 ? "\n\n" : ""
                var events = [event(child ? "subagent.text" : "message.delta", ["text": prefix + text])]
                if !emittedTools.contains(tid + ":" + id) {
                    emittedTools.insert(tid + ":" + id)
                    events.insert(event(child ? "subagent.tool" : "tool.start", ["tool_id": id, "name": Self.toolName(type), "context": item["revisedPrompt"] as? String ?? ""]), at: 0)
                }
                if !child { events.append(event("tool.complete", ["tool_id": id, "name": Self.toolName(type), "is_error": false, "result": path])) }
                return events
            }
            if type == "agentMessage" {
                guard complete else { return [] }
                let prior = messageTexts[tid]?[id] ?? ""
                let text = item["text"] as? String ?? ""
                let isNew = !(messageOrder[tid] ?? []).contains(id)
                if isNew { messageOrder[tid, default: []].append(id) }
                messageTexts[tid, default: [:]][id] = text
                // Some providers emit only completed items. Stream that text
                // now; turn/completed remains the sole completion receipt.
                if prior.isEmpty && !text.isEmpty {
                    let prefix = isNew && (messageOrder[tid]?.count ?? 0) > 1 ? "\n\n" : ""
                    return [event(child ? "subagent.text" : "message.delta", ["text": prefix + text])]
                }
                return []
            }
            if type == "subAgentActivity" {
                guard let agentID = item["agentThreadId"] as? String else { return [] }
                parents[agentID] = sid
                let kind = item["kind"] as? String ?? "started"
                let finished = ["completed", "interrupted"].contains(kind)
                return [Event(name: finished ? "subagent.complete" : "subagent.start", payload: [
                    "session_id": sid, "subagent_id": agentID, "name": item["agentPath"] as? String ?? "Codex agent",
                    "status": kind == "interrupted" ? "interrupted" : "complete"])]
            }
            var events: [Event] = []
            if type == "collabAgentToolCall" {
                let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
                for agentID in item["receiverThreadIds"] as? [String] ?? [] {
                    parents[agentID] = sid
                    let state = states[agentID] ?? [:]
                    let status = state["status"] as? String ?? "running"
                    let terminal = ["completed", "errored", "shutdown", "notFound", "interrupted"].contains(status)
                    events.append(Event(name: terminal ? "subagent.complete" : "subagent.start", payload: [
                        "session_id": sid, "subagent_id": agentID,
                        "name": item["prompt"] as? String ?? "Codex agent",
                        "status": Self.status(status), "text": state["message"] as? String ?? ""]))
                }
            }
            guard Self.toolTypes.contains(type), !id.isEmpty else { return events }
            let key = tid + ":" + id
            let name = item["tool"] as? String ?? Self.toolName(type)
            let detail = Self.describe(item["command"] ?? item["arguments"] ?? item["query"] ?? item["changes"] ?? item["path"])
            toolDetails[key] = detail
            if !emittedTools.contains(key) {
                emittedTools.insert(key)
                events.append(event(child ? "subagent.tool" : "tool.start", ["tool_id": id, "name": name, "context": detail, "tool_preview": detail]))
            }
            if complete && !child {
                let status = item["status"] as? String ?? "completed"
                let failed = ["failed", "declined"].contains(status) || (item["exitCode"] as? Int).map { $0 != 0 } == true
                events.append(event("tool.complete", ["tool_id": id, "name": name, "is_error": failed,
                    "result": Self.describe(item["aggregatedOutput"] ?? item["result"] ?? item["error"] ?? item["contentItems"] ?? item["changes"])]))
            }
            return events
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = Self.status(turn["status"] as? String ?? "failed")
            activeTurns.removeValue(forKey: tid)
            startingThreads.remove(tid)
            if let incomingTurn { completedTurns.insert(tid + ":" + incomingTurn) }
            let text = (messageOrder[tid] ?? []).compactMap { messageTexts[tid]?[$0] }.joined(separator: "\n\n")
            var events = requests.filter { $0.value.threadID == tid }.map { event("clarify.expire", ["request_id": $0.key]) }
            requests = requests.filter { $0.value.threadID != tid }
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
                events.append(event("runtime.notice", ["message": message]))
            }
            events.append(event(child ? "subagent.complete" : "message.complete", ["text": text, "status": status]))
            return events
        case "serverRequest/resolved":
            let id = Self.requestKey(params["requestId"])
            requests.removeValue(forKey: id)
            return [event("clarify.expire", ["request_id": id])]
        case "error":
            let error = params["error"] as? [String: Any] ?? [:]
            // Retrying errors are progress, not terminal session failure.
            return [event(params["willRetry"] as? Bool == true ? "runtime.notice" : "session.error",
                          ["message": error["message"] as? String ?? "Codex encountered an error."])]
        default: return []
        }
    }

    mutating func serverRequest(id: Any, method: String, params: [String: Any]) -> (events: [Event], reply: [String: Any]?) {
        guard let tid = params["threadId"] as? String, let sid = root(for: tid) else {
            return ([], ["id": id, "error": ["code": -32601, "message": "Request is not associated with a companion-owned thread."]])
        }
        let key = Self.requestKey(id)
        var fields: [String: Any] = ["session_id": sid, "request_id": key]
        if tid != sid { fields["subagent_id"] = tid }
        let childWaiting = tid == sid ? [] : [Event(name: "subagent.thinking", payload: ["session_id": sid, "subagent_id": tid, "status": "waiting"])]
        let approvalMethods = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"]
        if approvalMethods.contains(method) {
            var choices = ["once", "deny"]
            if method != "item/permissions/requestApproval", let decisions = params["availableDecisions"] as? [Any] {
                choices = decisions.compactMap { decision in
                    switch decision as? String { case "accept": return "once"; case "acceptForSession": return "session"; case "decline": return "deny"; case "cancel": return "cancel"; default: return nil }
                }
                if choices.isEmpty { choices = ["deny"] }
            }
            fields["choices"] = choices
            fields["command"] = [params["command"] as? String, params["reason"] as? String,
                                  params["permissions"].map(Self.describe), params["grantRoot"] as? String,
                                  method == "item/fileChange/requestApproval" ? toolDetails[tid + ":" + (params["itemId"] as? String ?? "")] : nil,
                                  params["cwd"] as? String].compactMap { $0 }.joined(separator: "\n\n")
            if (fields["command"] as? String)?.isEmpty != false { fields["command"] = "Allow Codex to apply these file changes?" }
            requests[key] = ServerRequest(wireID: id, method: method, threadID: tid, params: params)
            return (childWaiting + [Event(name: "approval.request", payload: fields)], nil)
        }
        if method == "item/tool/requestUserInput" {
            let questions = params["questions"] as? [[String: Any]] ?? []
            // The companion composer is not a secret-entry surface.
            guard !questions.contains(where: { $0["isSecret"] as? Bool == true }) else {
                return ([Event(name: "runtime.notice", payload: ["session_id": sid, "message": "Codex requested secret input. Complete account authentication in Codex's native sign-in flow."])],
                        ["id": id, "result": ["answers": [:]]])
            }
            fields["questions"] = questions.map { question -> [String: Any] in
                let options = question["options"] as? [[String: Any]] ?? []
                var row: [String: Any] = ["qid": question["id"] as? String ?? "", "question": question["question"] as? String ?? "",
                                          "choices": options.compactMap { $0["label"] as? String }, "choice_details": Self.choiceDetails(options),
                                          "multi_select": false, "allows_free_text": question["isOther"] as? Bool == true || options.isEmpty]
                if let header = question["header"] as? String, !header.isEmpty { row["header"] = header }
                return row
            }
            requests[key] = ServerRequest(wireID: id, method: method, threadID: tid, params: params)
            return (childWaiting + [Event(name: "clarify.request", payload: fields)], nil)
        }
        let message = "Codex requested an interaction this companion cannot render (\(method)). It was declined; use Codex's native interface if needed."
        let reply: [String: Any]
        if method == "mcpServer/elicitation/request" { reply = ["id": id, "result": ["action": "decline"]] }
        else { reply = ["id": id, "error": ["code": -32601, "message": message]] }
        return ([Event(name: "runtime.notice", payload: ["session_id": sid, "message": message])], reply)
    }

    mutating func answer(_ params: [String: Any], approval: Bool) throws -> [String: Any]? {
        let key = params["request_id"] as? String ?? ""
        guard var request = requests[key], root(for: request.threadID) == params["session_id"] as? String else {
            throw CodexClientError.unavailable("That Codex request has expired.")
        }
        if approval {
            let choice = params["choice"] as? String ?? "deny"
            let decision = ["once": "accept", "session": "acceptForSession", "deny": "decline", "cancel": "cancel"][choice]
            guard let decision else { throw CodexClientError.unavailable("Unsupported Codex approval choice.") }
            if let available = request.params["availableDecisions"] as? [Any], !available.contains(where: { $0 as? String == decision }), decision != "decline" {
                throw CodexClientError.unavailable("That approval scope is not offered by Codex.")
            }
            requests.removeValue(forKey: key)
            if request.method == "item/permissions/requestApproval" {
                return ["id": request.wireID, "result": ["permissions": choice == "once" ? request.params["permissions"] as? [String: Any] ?? [:] : [:], "scope": "turn"]]
            }
            return ["id": request.wireID, "result": ["decision": decision]]
        }
        guard request.method == "item/tool/requestUserInput" else { throw CodexClientError.unavailable("This request is not a clarification.") }
        let questions = request.params["questions"] as? [[String: Any]] ?? []
        let qid = params["question_id"] as? String ?? (questions.first?["id"] as? String ?? "")
        guard questions.contains(where: { $0["id"] as? String == qid }) else { throw CodexClientError.unavailable("That Codex question has expired.") }
        let question = questions.first(where: { $0["id"] as? String == qid }) ?? [:]
        let options = question["options"] as? [[String: Any]] ?? []
        let answer = params["answer"] as? String ?? ""
        if question["isOther"] as? Bool != true, !options.isEmpty, !options.contains(where: { $0["label"] as? String == answer }) {
            throw CodexClientError.unavailable("Choose one of the answers offered by Codex.")
        }
        request.answers[qid] = ["answers": [answer]]
        requests[key] = request
        guard questions.allSatisfy({ request.answers[$0["id"] as? String ?? ""] != nil }) else { return nil }
        requests.removeValue(forKey: key)
        return ["id": request.wireID, "result": ["answers": request.answers]]
    }

    static func history(_ thread: [String: Any]) -> [[String: Any]] {
        (thread["turns"] as? [[String: Any]] ?? []).flatMap { turn -> [[String: Any]] in
            var rows: [[String: Any]] = []
            var texts: [String] = []
            var questions: [[String: Any]] = []
            func flush() {
                guard !texts.isEmpty || !questions.isEmpty else { return }
                var row: [String: Any] = ["role": "assistant", "text": texts.joined(separator: "\n\n"), "row_id": turn["id"] as? String ?? ""]
                if !questions.isEmpty { row["questions"] = questions }
                rows.append(row); texts = []; questions = []
            }
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "userMessage" {
                    flush()
                    let content = item["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { part -> String? in
                        if let text = part["text"] as? String { return text }
                        if let path = part["path"] as? String { return "Attached: " + URL(fileURLWithPath: path).lastPathComponent }
                        return nil
                    }.joined(separator: "\n\n")
                    var row: [String: Any] = ["role": "user", "text": text, "row_id": item["id"] as? String ?? ""]
                    if let clientID = item["clientId"] as? String { row["client_id"] = clientID }
                    rows.append(row)
                } else if item["type"] as? String == "agentMessage", let asked = AsyncQuestion.decode(item["questions"]) {
                    questions += asked.map(\.payload)
                } else if item["type"] as? String == "agentMessage", let text = item["text"] as? String, !text.isEmpty { texts.append(text) }
                else if item["type"] as? String == "imageGeneration", let path = item["savedPath"] as? String, path.hasPrefix("/") {
                    texts.append(imageMarkdown(path))
                }
            }
            flush()
            return rows
        }
    }

    /// Angle brackets keep a path with spaces a single Markdown destination.
    static func imageMarkdown(_ path: String) -> String { "![Generated image](<\(path)>)" }

    /// Native option descriptions keyed by their label, for display under each choice.
    static func choiceDetails(_ options: [[String: Any]]) -> [String: String] {
        var details: [String: String] = [:]
        for option in options {
            guard let label = option["label"] as? String,
                  let detail = (option["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { continue }
            details[label] = detail
        }
        return details
    }

    static func requestKey(_ id: Any?) -> String {
        if let string = id as? String { return "s:" + string }
        if let number = id as? NSNumber { return "n:" + number.stringValue }
        return ""
    }
    static func status(_ status: String) -> String {
        switch status { case "completed", "shutdown": return "complete"; case "interrupted": return "interrupted"; case "failed", "errored", "notFound": return "error"; default: return status }
    }
    static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(32_000))
    }
    static let toolTypes: Set<String> = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch", "imageView", "imageGeneration", "sleep"]
    static func toolName(_ type: String) -> String {
        ["commandExecution": "Terminal", "fileChange": "Edit files", "webSearch": "Web search", "imageView": "View image", "imageGeneration": "Generate image", "sleep": "Wait"][type] ?? type
    }
}
