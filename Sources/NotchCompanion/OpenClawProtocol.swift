import Foundation

/// Pure Gateway projection. A Gateway broadcasts other frontends' activity;
/// only registered session keys and their explicitly linked children may enter.
struct OpenClawProtocolState {
    struct PendingInput {
        var session: String
        var method: String
        var record: [String: Any]
        var answers: [String: [String]] = [:]
    }
    var owned = Set<String>()
    var parents: [String: String] = [:]
    var active: [String: String] = [:]
    var unknownBusy = Set<String>()
    var starting = Set<String>()
    private var queuedInputs: [String: Set<String>] = [:]
    private var unknownQueuedInputs = Set<String>()
    private var queuedCounts: [String: Int] = [:]
    private var queuedErrors: [String: String] = [:]
    var requests: [String: PendingInput] = [:]
    private var resolvedRequests = Set<String>()
    private var terminal = Set<String>()
    private var sequence: [String: Int] = [:]
    private var texts: [String: String] = [:]
    private var runs: [String: String] = [:]
    private var emittedTools = Set<String>()
    private var activityRevisions: [String: Int] = [:]
    func activityRevision(_ key: String) -> Int { activityRevisions[key] ?? 0 }

    func root(_ key: String) -> String? { owned.contains(key) ? key : parents[key] }
    private func hasQueuedInput(_ key: String) -> Bool { !(queuedInputs[key] ?? []).isEmpty || unknownQueuedInputs.contains(key) }
    func busy(_ key: String) -> Bool {
        active[key] != nil || starting.contains(key) || unknownBusy.contains(key) || hasQueuedInput(key)
            || requests.values.contains { root($0.session) == key }
            || parents.contains { $0.value == key && (active[$0.key] != nil || unknownBusy.contains($0.key) || hasQueuedInput($0.key)) }
    }
    mutating func register(_ key: String, history: [String: Any], expectedRevision: Int? = nil) {
        owned.insert(key)
        if let expectedRevision, expectedRevision != activityRevision(key) { return }
        starting.remove(key); active.removeValue(forKey: key); unknownBusy.remove(key)
        let pending = (history["pendingInputs"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        queuedInputs[key] = Set(pending.compactMap { item in
            guard item["state"] as? String == "queued", let run = item["runId"] as? String, !terminal.contains(run) else { return nil }
            return run
        })
        unknownQueuedInputs.remove(key)
        queuedCounts[key] = (history["pendingInputs"] as? [String: Any])?["queuedCount"] as? Int
        if let count = queuedCounts[key], count > (queuedInputs[key]?.count ?? 0) { unknownQueuedInputs.insert(key) }
        let info = history["sessionInfo"] as? [String: Any] ?? [:]
        if let flight = history["inFlightRun"] as? [String: Any], let run = flight["runId"] as? String {
            active[key] = run; runs[run] = key; texts[run] = flight["text"] as? String ?? ""
        } else if info["hasActiveRun"] as? Bool == true || !(info["activeRunIds"] as? [String] ?? []).isEmpty {
            // A list of active IDs does not identify the owning run. Do not
            // adopt the first ID and risk interrupting unrelated native work.
            unknownBusy.insert(key)
        }
    }
    mutating func begin(_ key: String, run: String) { queuedErrors.removeValue(forKey: key); starting.insert(key); active[key] = run; runs[run] = key; texts[run] = "" }
    mutating func accepted(_ key: String, run: String) {
        starting.remove(key)
        if !terminal.contains(run) { active[key] = run; runs[run] = key }
    }
    mutating func rejected(_ key: String) { starting.remove(key); active.removeValue(forKey: key) }

    mutating func consume(_ event: String, _ payload: [String: Any]) -> [(String, [String: Any])] {
        if ["exec.approval.resolved", "plugin.approval.resolved", "question.resolved"].contains(event), let id = payload["id"] as? String {
            resolvedRequests.insert(id)
            guard let request = requests.removeValue(forKey: id), let parent = root(request.session) else { return [] }
            activityRevisions[parent, default: 0] += 1
            return [("clarify.expire", ["session_id": parent, "request_id": id])]
        }
        if ["exec.approval.requested", "plugin.approval.requested", "question.requested"].contains(event) {
            guard let id = payload["id"] as? String, !resolvedRequests.contains(id) else { return [] }
            let record = payload["request"] as? [String: Any] ?? payload
            guard let key = record["sessionKey"] as? String, let parent = root(key) else { return [] }
            if let run = record["runId"] as? String, terminal.contains(run) { return [] }
            if let expiration = payload["expiresAtMs"] as? Double, expiration <= Date().timeIntervalSince1970 * 1000 { return [] }
            activityRevisions[parent, default: 0] += 1
            if let run = record["runId"] as? String, active[key] == nil { active[key] = run; runs[run] = key }
            if event == "question.requested" {
                let questions = record["questions"] as? [[String: Any]] ?? []
                if questions.isEmpty || questions.contains(where: { $0["isSecret"] as? Bool == true || $0["secretStore"] != nil || $0["resource"] != nil || $0["url"] != nil }) {
                    return [("runtime.cancelQuestion", ["session_id": parent, "request_id": id])]
                }
                requests[id] = PendingInput(session: key, method: "question.resolve", record: record)
                return [("clarify.request", ["session_id": parent, "request_id": id, "questions": questions.map { question in
                    ["qid": question["questionId"] ?? "", "question": question["question"] ?? "", "choices": (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }, "multi_select": question["multiSelect"] as? Bool ?? false, "allows_free_text": question["isOther"] as? Bool ?? true]
                }])]
            }
            let method = event.hasPrefix("exec") ? "exec.approval.resolve" : "plugin.approval.resolve"
            requests[id] = PendingInput(session: key, method: method, record: record)
            let unavailable = record["unavailableDecisions"] as? [String] ?? []
            let allowed = (record["allowedDecisions"] as? [String] ?? ["allow-once", "allow-always", "deny"]).filter { !unavailable.contains($0) }
            let choices = allowed.compactMap { ["allow-once": "once", "allow-always": "always", "deny": "deny"][$0] }
            let description = record["command"] as? String ?? [record["title"] as? String, record["description"] as? String, record["detail"] as? String].compactMap { $0 }.joined(separator: "\n")
            return [("approval.request", ["session_id": parent, "request_id": id, "command": description, "choices": choices])]
        }
        guard let run = payload["runId"] as? String, !terminal.contains(run) else { return [] }
        var key = payload["sessionKey"] as? String ?? runs[run]
        var events: [(String, [String: Any])] = []
        if let candidate = key, root(candidate) == nil, let parent = payload["spawnedBy"] as? String, let owner = root(parent) {
            parents[candidate] = owner
            events.append(("subagent.start", ["session_id": owner, "subagent_id": candidate, "child_session_id": candidate, "name": "OpenClaw agent"]))
        }
        if key == nil { key = runs[run] }
        guard let key, let parent = root(key) else { return [] }
        if let expected = active[key], expected != run { return [] }
        let streamKey = event + ":" + run
        if let next = payload["seq"] as? Int {
            if let previous = sequence[streamKey] {
                if next <= previous { return [] }
                if next > previous + 1 { events.append(("runtime.reconcile", ["session_id": parent])) }
            }
            sequence[streamKey] = next
        }
        activityRevisions[parent, default: 0] += 1
        runs[run] = key
        let child = parent != key
        func normalized(_ name: String, _ fields: [String: Any]) -> (String, [String: Any]) {
            var value = fields; value["session_id"] = parent
            if child { value["subagent_id"] = key; value["child_session_id"] = key }
            return (name, value)
        }
        if active[key] == nil {
            active[key] = run
            events.append(normalized(child ? "subagent.thinking" : "message.start", [:]))
        }
        if event == "chat" {
            let status = payload["state"] as? String ?? ""
            if status == "delta" {
                let old = texts[run] ?? ""
                let replacement = (payload["message"] as? [String: Any]).map(PiProtocolState.text)
                let delta = payload["deltaText"] as? String
                let full = payload["replace"] as? Bool == true ? (delta ?? replacement ?? old) : (delta.map { old + $0 } ?? replacement ?? old)
                texts[run] = full
                let added = full.hasPrefix(old) ? String(full.dropFirst(old.count)) : ""
                if !added.isEmpty { events.append(normalized(child ? "subagent.text" : "message.delta", ["text": added])) }
            } else if ["final", "aborted", "error"].contains(status) {
                let text = (payload["message"] as? [String: Any]).map(PiProtocolState.text) ?? texts[run] ?? ""
                active.removeValue(forKey: key); unknownBusy.remove(key); starting.remove(key); queuedInputs[key]?.remove(run); terminal.insert(run)
                var outcome = status == "final" ? "complete" : status == "aborted" ? "interrupted" : "error"
                if outcome == "error" { queuedErrors[key] = payload["errorMessage"] as? String ?? "OpenClaw reported a failed queued run." }
                if hasQueuedInput(key) {
                    // A chat terminal event closes one run, not accepted work
                    // still waiting in the native session's queue.
                    events.append(normalized(child ? "subagent.thinking" : "message.interim", ["text": text, "already_streamed": true]))
                    if let error = queuedErrors[key] { events.append(normalized("runtime.notice", ["message": error])) }
                } else {
                    if queuedErrors[key] != nil { outcome = "error" }
                    let error = queuedErrors.removeValue(forKey: key) ?? payload["errorMessage"] as? String ?? ""
                    requests = requests.filter { _, request in
                        request.session != key || ((request.record["runId"] as? String).map { $0 != run } ?? false)
                    }
                    events.append(normalized(child ? "subagent.complete" : "message.complete", ["text": text, "summary": text, "status": outcome, "error": error]))
                }
            }
        } else if event == "agent" {
            let data = payload["data"] as? [String: Any] ?? [:]
            if payload["stream"] as? String == "tool", let toolID = data["toolCallId"] as? String {
                let phase = data["phase"] as? String
                let done = phase == "result" || phase == "end"
                if phase == "start", !emittedTools.insert(run + ":" + toolID).inserted { return events }
                if phase == "start" || done {
                    events.append(normalized(child ? "subagent.tool" : done ? "tool.complete" : "tool.start", ["tool_id": toolID, "name": data["name"] ?? "Tool", "tool_name": data["name"] ?? "Tool", "context": CodexProtocolState.describe(data["args"]), "result": CodexProtocolState.describe(data["result"]), "is_error": data["isError"] ?? false]))
                }
            }
        }
        return events
    }

    mutating func answer(_ params: [String: Any], session: String) throws -> (String, [String: Any])? {
        let id = params["request_id"] as? String ?? ""
        guard var request = requests[id], root(request.session) == session else { throw AppError("This OpenClaw request expired or belongs to another session.") }
        if request.method == "question.resolve" {
            let questions = request.record["questions"] as? [[String: Any]] ?? []
            let qid = params["question_id"] as? String ?? questions.first?["questionId"] as? String ?? ""
            guard let question = questions.first(where: { $0["questionId"] as? String == qid }) else { throw AppError("This OpenClaw question is no longer available.") }
            let answer = params["answer"] as? String ?? ""
            let options = question["options"] as? [[String: Any]] ?? []
            let values: [String]
            if question["multiSelect"] as? Bool == true {
                guard let selected = params["answers"] as? [String] else { throw AppError("This OpenClaw question needs the original selected answers. Reopen the question and choose its options again.") }
                values = selected
            } else { values = [answer] }
            request.answers[qid] = try values.map { value in
                if let option = options.first(where: { $0["label"] as? String == value }) { return option["value"] as? String ?? value }
                guard question["isOther"] as? Bool != false || options.isEmpty else { throw AppError("Choose one of the options offered by OpenClaw.") }
                return value
            }
            requests[id] = request
            guard questions.allSatisfy({ request.answers[$0["questionId"] as? String ?? ""] != nil }) else { return nil }
            return (request.method, ["id": id, "answers": ["answers": request.answers]])
        }
        let choice = params["choice"] as? String ?? "deny"
        guard let decision = ["once": "allow-once", "always": "allow-always", "deny": "deny"][choice],
              !(request.record["unavailableDecisions"] as? [String] ?? []).contains(decision),
              (request.record["allowedDecisions"] as? [String] ?? ["allow-once", "allow-always", "deny"]).contains(decision) else { throw AppError("This OpenClaw approval does not allow that choice.") }
        return (request.method, ["id": id, "decision": decision])
    }
    mutating func answered(_ id: String) { requests.removeValue(forKey: id); resolvedRequests.insert(id) }
    /// Gateway receipts are exact accepted-input custody independent of the
    /// truncated display transcript. Absence never proves non-delivery.
    static func acceptedReceipt(_ history: [String: Any], requestedID: String?) -> (ids: [String], queued: Bool) {
        guard let requestedID, !requestedID.isEmpty, requestedID.count <= 256 else { return ([], false) }
        if let receipts = history["inputReceipts"] as? [[String: Any]] {
            let matching = receipts.filter { $0["runId"] as? String == requestedID }
            // Conflicting/duplicate records are not an authoritative receipt.
            guard matching.count == 1, let receipt = matching.first else { return ([], false) }
            if receipt["state"] as? String == "consumed", receipt["cancelled"] == nil, let event = receipt["consumedByEventId"] as? String, !event.isEmpty { return ([requestedID], false) }
            if receipt["state"] as? String == "pending", receipt["cancelled"] as? Bool != true {
                let queued = receipt["queued"] as? Bool == true
                let active = (history["inFlightRun"] as? [String: Any])?["runId"] as? String == requestedID
                if queued || active { return ([requestedID], queued) }
            }
            return ([], false)
        }
        // Earlier v4 Gateways expose the consumed-only projection. It is safe
        // only when no newer receipt array contradicts it.
        if history["inputReceipts"] == nil,
           let receipts = history["inputConsumptions"] as? [[String: Any]],
           receipts.contains(where: { $0["runId"] as? String == requestedID && !($0["consumedByEventId"] as? String ?? "").isEmpty }) { return ([requestedID], false) }
        return ([], false)
    }
    mutating func adoptQueuedReceipt(_ key: String, id: String) {
        if !terminal.contains(id) {
            queuedInputs[key, default: []].insert(id)
            if let count = queuedCounts[key], (queuedInputs[key]?.count ?? 0) >= count { unknownQueuedInputs.remove(key) }
        }
    }
    static func history(_ payload: [String: Any]) -> [[String: Any]] {
        PiProtocolState.history(payload["messages"] as? [[String: Any]] ?? [])
    }
    static func info(_ row: [String: Any]) -> [String: Any] {
        var result: [String: Any] = ["model": row["model"] ?? "", "provider": row["modelProvider"] ?? "", "capabilities": ["resume": true, "attachments": true, "images": true, "approvals": true, "questions": true, "modelSelection": true, "contextUsage": false, "delegation": true]]
        // Session totalTokens may be cumulative billing. Only the actual
        // context window is shown until Gateway reports unambiguous occupancy.
        if let limit = row["contextTokens"] as? Int, limit > 0 { result["usage"] = ["context_max": limit] }
        return result
    }
}
