import XCTest
@testable import NotchCompanion

final class ACPProtocolTests: XCTestCase {
    func testBoundedFramingHandlesSplitUnicodeAndRejectsMalformedOutput() throws {
        var decoder = NativeJSONLines(limit: 32)
        let data = Data("{\"text\":\"ü\"}\n{\"id\":2}\r\n".utf8)
        XCTAssertTrue(try decoder.append(data.prefix(10)).isEmpty)
        let frames = try decoder.append(data.dropFirst(10))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?["text"] as? String, "ü")
        XCTAssertThrowsError(try decoder.append(Data("diagnostic, not JSON\n".utf8)))
        var small = NativeJSONLines(limit: 8)
        XCTAssertThrowsError(try small.append(Data(repeating: 65, count: 9)))
        var batch = NativeJSONLines(limit: 8)
        XCTAssertEqual(try batch.append(Data("{\"x\":1}\n{\"x\":2}\n".utf8)).count, 2)
    }

    func testOnlyOwnedActiveSessionsProduceLiveEventsAndTerminalReceipt() throws {
        var state = ACPProtocolState(); state.owned.insert("owned")
        try state.begin("owned")
        func update(_ sid: String, _ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            var update = fields; update["sessionUpdate"] = type
            return ["sessionId": sid, "update": update]
        }
        XCTAssertTrue(state.notification("session/update", update("external", "agent_message_chunk", ["content": ["type": "text", "text": "private"]])).isEmpty)
        let first = state.notification("session/update", update("owned", "agent_message_chunk", ["content": ["type": "text", "text": "Working"]]))
        XCTAssertEqual(first.map(\.name), ["message.start", "message.delta"])
        XCTAssertTrue(state.active.contains("owned"))
        XCTAssertThrowsError(try state.begin("owned"))
        let tool = state.notification("session/update", update("owned", "tool_call", ["toolCallId": "a", "title": "read", "status": "completed"]))
        XCTAssertEqual(tool.map(\.name), ["tool.start", "tool.complete"])
        XCTAssertTrue(state.active.contains("owned"))
        let done = state.finish("owned", stopReason: "end_turn")
        XCTAssertEqual(done.last?.name, "message.complete")
        XCTAssertEqual(done.last?.payload["text"] as? String, "Working")
        XCTAssertTrue(state.finish("owned", stopReason: "end_turn").isEmpty)
        XCTAssertTrue(state.notification("session/update", update("owned", "agent_message_chunk", ["content": ["text": "late"]])).isEmpty)
    }

    func testPermissionScopesAreOfferedNativeOptionsAndSessionBound() throws {
        var state = ACPProtocolState(); state.owned = ["one", "two"]; try state.begin("one")
        let result = state.serverRequest(id: 7, method: "session/request_permission", params: ["sessionId": "one", "toolCall": ["title": "Edit fixture"], "options": [
            ["optionId": "native-allow", "kind": "allow_once"], ["optionId": "native-always", "kind": "allow_always"], ["optionId": "native-deny", "kind": "reject_once"]]])
        XCTAssertNil(result.reply)
        XCTAssertEqual(result.events.first?.payload["choices"] as? [String], ["once", "deny"])
        XCTAssertThrowsError(try state.answer(["session_id": "two", "request_id": "n:7", "choice": "once"], approval: true))
        XCTAssertThrowsError(try state.answer(["session_id": "one", "request_id": "n:7", "choice": "session"], approval: true))
        let reply = try state.answer(["session_id": "one", "request_id": "n:7", "choice": "deny"], approval: true)
        let outcome = (reply?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "native-deny")
        XCTAssertThrowsError(try state.answer(["session_id": "one", "request_id": "n:7", "choice": "once"], approval: true))
        let external = state.serverRequest(id: 8, method: "session/request_permission", params: ["sessionId": "external"])
        XCTAssertNotNil(external.reply?["error"])
    }

    func testFormsAccumulateAnswersMapNativeValuesAndDeclineUnsupportedSchema() throws {
        var state = ACPProtocolState(); state.owned = ["one"]; try state.begin("one")
        let schema: [String: Any] = ["type": "object", "required": ["color", "name"], "properties": [
            "color": ["type": "string", "oneOf": [["const": "sage", "title": "Sage green"]]],
            "name": ["type": "string"]]]
        let result = state.serverRequest(id: "same", method: "elicitation/create", params: ["sessionId": "one", "requestedSchema": schema])
        XCTAssertEqual(result.events.first?.name, "clarify.request")
        XCTAssertNil(try state.answer(["session_id": "one", "request_id": "s:same", "question_id": "name", "answer": "fixture"], approval: false))
        XCTAssertThrowsError(try state.answer(["session_id": "one", "request_id": "s:same", "question_id": "color", "answer": "Blue"], approval: false))
        let reply = try state.answer(["session_id": "one", "request_id": "s:same", "question_id": "color", "answer": "Sage green"], approval: false)
        let content = (reply?["result"] as? [String: Any])?["content"] as? [String: String]
        XCTAssertEqual(content, ["color": "sage", "name": "fixture"])
        let unsupported = state.serverRequest(id: 3, method: "elicitation/create", params: ["sessionId": "one", "requestedSchema": ["type": "object", "properties": ["secret": ["type": "string", "format": "password"]]]])
        XCTAssertEqual((unsupported.reply?["result"] as? [String: Any])?["action"] as? String, "decline")
        XCTAssertEqual(unsupported.events.first?.name, "runtime.notice")
    }

    func testAntigravityQuestionsNeverBecomeApprovalsAndItsExactModelOutranksTheConfigFamily() throws {
        let options: [[String: Any]] = [["optionId": "a", "name": "Same", "kind": "allow_once"], ["optionId": "b", "name": "Same", "kind": "allow_once"]]
        let params: [String: Any] = ["sessionId": "one", "toolCall": ["toolCallId": "interaction_9", "title": "Pick one"], "options": options]
        var state = ACPProtocolState(antigravity: true); state.owned = ["one"]; try state.begin("one")
        let ambiguous = state.serverRequest(id: 1, method: "session/request_permission", params: params)
        XCTAssertEqual(ambiguous.events.map(\.name), ["runtime.notice"], "Indistinguishable answers are cancelled, not approved")
        XCTAssertEqual(((ambiguous.reply?["result"] as? [String: Any])?["outcome"] as? [String: Any])?["outcome"] as? String, "cancelled")
        var other = ACPProtocolState(); other.owned = ["one"]; try other.begin("one")
        XCTAssertEqual(other.serverRequest(id: 1, method: "session/request_permission", params: params).events.first?.name, "approval.request",
                       "Other agents' requests keep their permission meaning")

        state.models["one"] = ["availableModels": [["modelId": "gemini-3.8-flash-low", "name": "Low"]], "currentModelId": "gemini-3.8-flash-low"]
        let family = state.notification("session/update", ["sessionId": "one", "update": ["sessionUpdate": "config_option_update",
            "configOptions": [["id": "model", "currentValue": "gemini-3.8-flash", "options": [["value": "gemini-3.8-flash"]]]]]])
        XCTAssertTrue(family.isEmpty, "The model family must not replace the exact model")
        XCTAssertEqual(state.catalog("one").defaultModel?.model, "gemini-3.8-flash-low")
        XCTAssertEqual(state.catalog("two").note, "This ACP runtime has not reported a session model catalog.")
    }

    func testCursorRequestsWithoutAnAttributableSessionAreDeclined() throws {
        var state = ACPProtocolState(); state.owned = ["one", "two"]; try state.begin("one"); try state.begin("two")
        let result = state.serverRequest(id: 9, method: "cursor/create_plan", params: ["toolCallId": "unknown", "plan": "Edit"])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNotNil(result.reply?["error"])
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testNativeReplayPreservesMessageIDsAndNeverSignalsANewTurn() throws {
        var state = ACPProtocolState(); state.owned = ["one"]; state.loading = ["one"]
        func replay(_ id: String, _ text: String) -> [String: Any] {
            ["sessionId": "one", "update": ["sessionUpdate": "user_message_chunk", "messageId": id, "content": ["text": text]]]
        }
        XCTAssertTrue(state.notification("session/update", replay("u1", "first")).isEmpty)
        _ = state.notification("session/update", replay("u1", " continued"))
        _ = state.notification("session/update", replay("u2", "second"))
        XCTAssertEqual(state.history["one"]?.count, 2)
        XCTAssertEqual(state.history["one"]?.first?["text"] as? String, "first continued")
        XCTAssertFalse(state.historyWithoutMessageIDs.contains("one"))
        _ = state.notification("session/update", ["sessionId": "one", "update": ["sessionUpdate": "agent_message_chunk", "content": ["text": "legacy no ID"]]])
        XCTAssertTrue(state.historyWithoutMessageIDs.contains("one"))
        XCTAssertTrue(state.active.isEmpty)
    }

    func testModelCatalogAndCurrentContextUseNativeFields() throws {
        let options: [[String: Any]] = [["id": "model", "category": "model", "currentValue": "provider/custom", "options": [["group": "provider", "options": [["value": "provider/custom", "name": "Custom"]]]]]]
        let catalog = ACPProtocolState.catalog(options)
        XCTAssertEqual(catalog.defaultModel?.model, "provider/custom")
        XCTAssertEqual(catalog.models.first?.title, "Custom")
        XCTAssertNil(catalog.configuredContextWindow)
        var state = ACPProtocolState(); state.owned = ["one"]
        let result = state.notification("session/update", ["sessionId": "one", "update": ["sessionUpdate": "usage_update", "used": 150, "size": 4000, "cost": ["amount": 99]]])
        let usage = result.first?.payload["usage"] as? [String: Int]
        XCTAssertEqual(usage, ["context_used": 150, "context_max": 4000])
    }

    func testDelegatedActivityRemainsUnverifiedAfterParentReplyAndAcceptsLateChildPermission() throws {
        var state = ACPProtocolState(); state.owned = ["parent"]; try state.begin("parent")
        let meta: [String: Any] = ["opencode/child-session": ["id": "child", "parentID": "parent", "depth": 1, "title": "Research"]]
        let events = state.notification("session/update", ["sessionId": "parent", "update": ["sessionUpdate": "tool_call", "toolCallId": "child:tool", "title": "Research: read", "status": "in_progress", "_meta": meta]])
        XCTAssertTrue(events.contains { $0.name == "subagent.start" })
        XCTAssertTrue(events.contains { $0.name == "runtime.activity_unverified" })
        let parentDone = state.finish("parent", stopReason: "end_turn")
        XCTAssertTrue(parentDone.contains { $0.name == "runtime.activity_unverified" })
        XCTAssertFalse(parentDone.contains { $0.name == "subagent.complete" })
        XCTAssertTrue(parentDone.contains { $0.name == "subagent.thinking" && $0.payload["status"] as? String == "waiting" })
        XCTAssertThrowsError(try state.begin("parent"))
        let permission = state.serverRequest(id: "late", method: "session/request_permission", params: ["sessionId": "parent", "toolCall": ["title": "Late child permission", "_meta": meta], "options": [["optionId": "reject", "kind": "reject_once"]]])
        XCTAssertNil(permission.reply)
        XCTAssertTrue(permission.events.contains { $0.name == "approval.request" })
        let denied = try state.answer(["session_id": "parent", "request_id": "s:late", "choice": "deny"], approval: true)
        XCTAssertEqual(((denied?["result"] as? [String: Any])?["outcome"] as? [String: Any])?["optionId"] as? String, "reject")
        XCTAssertThrowsError(try state.begin("parent"), "Answering a permission is not evidence the child has terminated")
    }

    @MainActor
    func testDeepSeekRequiresExistingSelectedProfileAndDoesNotSubstituteComposition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profiles/my-native")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ACPRuntimeClient.deepSeekLaunch(profileID: root.path))
        XCTAssertThrowsError(try ACPRuntimeClient.deepSeekLaunch(profileID: profile.path))
        try Data("{}".utf8).write(to: profile.appendingPathComponent("package.json"))
        let launch = try ACPRuntimeClient.deepSeekLaunch(profileID: profile.path)
        XCTAssertEqual(launch.home, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(launch.arguments, ["--profile", "my-native"])
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent("package.json"), encoding: .utf8), "{}")
    }
}
