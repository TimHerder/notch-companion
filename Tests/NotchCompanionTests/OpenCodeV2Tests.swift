import XCTest
@testable import NotchCompanion

final class OpenCodeV2Tests: XCTestCase {
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
