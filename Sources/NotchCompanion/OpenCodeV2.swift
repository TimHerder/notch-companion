import Foundation

/// V2 wire shapes normalized for the existing owned-session lifecycle.
enum OpenCodeV2 {
    static let requiredPaths = ["/api/info", "/api/session", "/api/session/active", "/api/session/{sessionID}",
        "/api/session/{sessionID}/message", "/api/session/{sessionID}/prompt", "/api/session/{sessionID}/inbox",
        "/api/session/{sessionID}/inbox/{inboxID}", "/api/session/{sessionID}/interrupt", "/api/session/{sessionID}/model",
        "/api/session/{sessionID}/permission", "/api/session/{sessionID}/permission/{requestID}/reply",
        "/api/session/{sessionID}/form", "/api/session/{sessionID}/form/{formID}",
        "/api/session/{sessionID}/form/{formID}/reply", "/api/model", "/api/model/default", "/api/event"]

    static func session(_ value: [String: Any]) -> [String: Any] {
        var result = value
        result["directory"] = (value["location"] as? [String: Any])?["directory"]
        return result
    }

    static func catalog(_ rows: [[String: Any]], current: [String: Any]) -> RuntimeModelCatalog {
        func choice(_ row: [String: Any]) -> RuntimeModelChoice? {
            guard let id = row["id"] as? String, let provider = row["providerID"] as? String else { return nil }
            return .init(model: id, provider: provider)
        }
        var seen = Set<String>()
        let options = rows.compactMap { row -> RuntimeModelOption? in
            guard row["enabled"] as? Bool == true, let value = choice(row), seen.insert(value.id).inserted else { return nil }
            return RuntimeModelOption(choice: value, title: row["name"] as? String ?? value.model)
        }
        return RuntimeModelCatalog(defaultModel: choice(current), models: options.sorted { $0.title < $1.title },
            configuredContextWindow: (current["limit"] as? [String: Any])?["context"] as? Int)
    }

    static func message(_ value: [String: Any], sessionID: String) -> [String: Any]? {
        guard let type = value["type"] as? String, let id = value["id"] as? String,
              ["user", "assistant", "idle", "compaction"].contains(type) else { return nil }
        var info = value
        info["sessionID"] = sessionID
        info["role"] = type == "user" ? "user" : "assistant"
        if let model = value["model"] as? [String: Any] { info["modelID"] = model["id"]; info["providerID"] = model["providerID"] }
        if type == "idle" {
            info["time"] = ["completed": (value["time"] as? [String: Any])?["created"] ?? 0]
            if value["outcome"] as? String == "failed" { info["error"] = value["error"] ?? ["name": "NativeTurnError"] }
            if value["outcome"] as? String == "interrupted" { info["error"] = ["name": "MessageAbortedError"] }
        }
        var parts: [[String: Any]] = []
        if type == "user" { parts = [["type": "text", "text": value["text"] as? String ?? ""]] }
        if type == "assistant" {
            parts = (value["content"] as? [[String: Any]] ?? []).map { content in
                guard content["type"] as? String == "tool" else { return content }
                var part = content, state = content["state"] as? [String: Any] ?? [:]
                part["tool"] = content["name"]
                state["output"] = (state["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                part["state"] = state
                return part
            }
        }
        info["id"] = id
        return ["info": info, "parts": parts]
    }

    static func event(_ value: [String: Any]) -> [String: Any] {
        let type = value["type"] as? String ?? ""
        var data = value["data"] as? [String: Any] ?? [:]
        if type == "session.created" {
            var info = data; info["id"] = data["sessionID"]
            data["info"] = session(info)
        }
        return ["type": type, "properties": data]
    }

    static func question(_ form: [String: Any]) -> [String: Any] {
        var result = form
        let fields = form["fields"] as? [[String: Any]] ?? []
        result["questions"] = fields.map { field -> [String: Any] in
            let type = field["type"] as? String ?? ""
            let supported = ["string", "multiselect", "boolean"].contains(type)
                && field["hidden"] as? Bool != true && field["when"] == nil
            let options = type == "boolean" ? [["label": "Yes", "value": "true"], ["label": "No", "value": "false"]]
                : field["options"] as? [[String: Any]] ?? []
            return ["question": [field["title"] as? String ?? field["key"] as? String ?? "Question", field["description"] as? String].compactMap { $0 }.joined(separator: "\n"),
                "header": form["title"] as? String ?? "", "options": options, "multiple": type == "multiselect",
                "custom": type != "boolean" && (options.isEmpty || field["custom"] as? Bool == true), "isSecret": !supported]
        }
        return result
    }

    static func formAnswer(_ form: [String: Any], answers: [[String]]) throws -> [String: Any] {
        let fields = form["fields"] as? [[String: Any]] ?? []
        guard fields.count == answers.count else { throw AppError("The native form changed. Reload its questions before answering.") }
        var values: [String: Any] = [:]
        for (index, field) in fields.enumerated() {
            guard let key = field["key"] as? String else { throw AppError("OpenCode returned an invalid form field.") }
            let mapped = answers[index].map { answer in
                (field["options"] as? [[String: Any]] ?? []).first { $0["label"] as? String == answer }?["value"] as? String ?? answer
            }
            switch field["type"] as? String {
            case "multiselect": values[key] = mapped
            case "boolean":
                guard mapped.count == 1, ["Yes", "No"].contains(mapped[0]) else { throw AppError("Choose Yes or No for this native question.") }
                values[key] = mapped[0] == "Yes"
            case "string":
                guard mapped.count == 1 else { throw AppError("This native question needs one answer.") }
                values[key] = mapped[0]
            default: throw AppError("This native form needs OpenCode's own interface.")
            }
        }
        return ["answer": values]
    }
}
