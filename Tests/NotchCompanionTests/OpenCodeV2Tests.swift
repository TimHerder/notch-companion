import XCTest
@testable import NotchCompanion

final class OpenCodeV2Tests: XCTestCase {
    func testDelegationServerRulesAndRegistrationStayPerSession() throws {
        let name = OpenCodeClient.delegationServerName("ses_e4c2624e2ffeYv6WLpCFFfisAQ")
        XCTAssertEqual(name, OpenCodeClient.delegationServerName("ses_e4c2624e2ffeYv6WLpCFFfisAQ"), "Stable across reconnects")
        XCTAssertNotEqual(name, OpenCodeClient.delegationServerName("ses_other"))
        XCTAssertNotNil(name.wholeMatch(of: #/notch-[0-9a-f]{16}/#))
        let longest = try XCTUnwrap(Delegation.tools.compactMap { $0["name"] as? String }.max { $0.count < $1.count })
        XCTAssertLessThanOrEqual((name + "_" + longest).count, 64, "OpenCode hides tools with longer names")

        let saved: [[String: Any]] = [["action": "bash", "resource": "rm *", "effect": "ask"],
                                      ["action": "notch-*", "resource": "*", "effect": "deny"],
                                      ["action": "notch-????????????????_*", "resource": "*", "effect": "deny"],
                                      ["action": OpenCodeClient.delegationServerName("ses_old") + "_*", "resource": "*", "effect": "allow"],
                                      ["action": "notch-docs_*", "resource": "*", "effect": "allow"]]
        let rules = OpenCodeClient.delegationRules(saved, server: name)
        let deny = "notch-????????????????_*"
        XCTAssertEqual(rules.compactMap { $0["action"] as? String }, ["bash", "notch-docs_*", deny, name + "_*"],
                       "The session's other rules stay; the companion's, old `notch-*` included, are replaced and come last, so they win")
        XCTAssertEqual(rules.suffix(2).compactMap { $0["effect"] as? String }, ["deny", "allow"])
        XCTAssertEqual(OpenCodeClient.delegationRules([], server: nil).compactMap { $0["action"] as? String }, [deny],
                       "A session without the tools still cannot use another session's")
        // OpenCode's wildcard: `*` any run, `?` one character, whole action `<server>_<tool>`.
        let matches = { (action: String) in
            action.range(of: "^" + NSRegularExpression.escapedPattern(for: deny).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$", options: .regularExpression) != nil
        }
        XCTAssertTrue(matches(OpenCodeClient.delegationServerName("ses_other") + "_delegate_task"), "Another session's companion tools stay denied")
        XCTAssertFalse(matches("notch-docs_search"), "A user's own `notch-…` server stays usable")

        let launch: [String: Any] = ["url": "http://127.0.0.1:9/mcp", "token": "secret-token", "instructions": "Rules."]
        let request = try XCTUnwrap(OpenCodeClient.delegationRegistration(launch, server: name, location: "/Users/me/My Project"))
        XCTAssertEqual(request.path, "/api/experimental/mcp/\(name)?location%5Bdirectory%5D=%2FUsers%2Fme%2FMy%20Project")
        let config = try XCTUnwrap(request.body["config"] as? [String: Any])
        XCTAssertEqual(config["type"] as? String, "remote")
        XCTAssertEqual(config["url"] as? String, "http://127.0.0.1:9/mcp")
        XCTAssertEqual(config["oauth"] as? Bool, false, "No OAuth discovery against the companion")
        XCTAssertEqual(config["headers"] as? [String: String], ["Authorization": "Bearer secret-token"])
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request.body), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "secret-token").count, 2, "The token appears once, in the header")
        XCTAssertFalse(request.path.contains("secret-token"))
        XCTAssertNil(OpenCodeClient.delegationRegistration([:], server: name, location: "/x"))
    }

    func testVersionCatalogAndNativeWorkspace() {
        XCTAssertTrue(OpenCodeClient.supportsVersion("2.0.30"))
        XCTAssertFalse(OpenCodeClient.supportsVersion("2.1.0"))
        let row: [String: Any] = ["id": "selected", "modelID": "provider-wire-name", "providerID": "native", "enabled": true, "name": "Selected", "limit": ["context": 200000]]
        let catalog = OpenCodeV2.catalog([row, row, ["id": "unavailable", "providerID": "native", "enabled": false]], current: row)
        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertEqual(catalog.models.first?.choice.model, "selected", "Use the native selection ID, not the provider's wire name")
        XCTAssertEqual(catalog.configuredContextWindow, 200000)
        XCTAssertEqual(OpenCodeV2.session(["location": ["directory": "/native/project"]])["directory"] as? String, "/native/project")
    }

    func testToolTextReceiptAndTerminalOutcomes() throws {
        let input = try XCTUnwrap(OpenCodeV2.message(["type": "user", "id": "msg_exact-send", "text": "hello"], sessionID: "ses_owned"))
        let output = try XCTUnwrap(OpenCodeV2.message(["type": "assistant", "id": "msg_answer", "model": ["id": "chosen", "providerID": "native"], "content": [
            ["type": "text", "text": "Answer"], ["type": "tool", "id": "call_read", "name": "read", "state": ["status": "completed", "input": ["path": "marker.txt"], "content": [["type": "text", "text": "contents"]]]]
        ]], sessionID: "ses_owned"))
        XCTAssertEqual(OpenCodeClient.history([input]).first?["client_id"] as? String, "exact-send")
        XCTAssertEqual(OpenCodeClient.currentText([input, output]), "Answer")
        let tool = try XCTUnwrap((output["parts"] as? [[String: Any]])?.last)
        XCTAssertEqual(tool["tool"] as? String, "read")
        XCTAssertEqual((tool["state"] as? [String: Any])?["output"] as? String, "contents")
        for (native, normalized) in [("succeeded", "complete"), ("failed", "error"), ("interrupted", "interrupted")] {
            let idle = try XCTUnwrap(OpenCodeV2.message(["type": "idle", "id": "msg_idle", "outcome": native, "time": ["created": 2]], sessionID: "ses_owned"))
            XCTAssertEqual(OpenCodeClient.terminal(idle["info"] as? [String: Any] ?? [:], cancelled: false), normalized)
            XCTAssertEqual(OpenCodeClient.currentText([input, output, idle]), "Answer")
        }
    }

    func testNativeFormValuesMultiselectAndUnsupportedFields() throws {
        let form: [String: Any] = ["id": "frm_owned", "sessionID": "ses_owned", "title": "Pick", "fields": [
            ["key": "color", "type": "string", "title": "Color?", "options": [["label": "Sage", "value": "native-green", "description": "Quiet"]]],
            ["key": "parts", "type": "multiselect", "options": [["label": "A, B", "value": "ab"], ["label": "C", "value": "c"]]],
            ["key": "confirm", "type": "boolean"]
        ]]
        let projected = OpenCodeV2.question(form)
        let questions = try XCTUnwrap(projected["questions"] as? [[String: Any]])
        XCTAssertEqual(questions[0]["custom"] as? Bool, false)
        XCTAssertEqual(questions[1]["multiple"] as? Bool, true)
        let reply = try OpenCodeV2.formAnswer(form, answers: [["Sage"], ["A, B", "C"], ["No"]])["answer"] as? [String: Any]
        XCTAssertEqual(reply?["color"] as? String, "native-green")
        XCTAssertEqual(reply?["parts"] as? [String], ["ab", "c"])
        XCTAssertEqual(reply?["confirm"] as? Bool, false)
        XCTAssertThrowsError(try OpenCodeV2.formAnswer(form, answers: [["Sage"]]))
        for field: [String: Any] in [["key": "secret", "type": "external"], ["key": "hidden", "type": "string", "hidden": true], ["key": "conditional", "type": "string", "when": []]] {
            let unsupported = OpenCodeV2.question(["fields": [field]])["questions"] as? [[String: Any]]
            XCTAssertEqual(unsupported?.first?["isSecret"] as? Bool, true, "Unsupported native forms must be declined, not silently answered")
        }
    }
}
