import XCTest
@testable import NotchCompanion

final class CodexProtocolTests: XCTestCase {
    private func owned() throws -> CodexProtocolState {
        var state = CodexProtocolState()
        _ = try state.register(["id": "parent"])
        return state
    }

    func testUnownedNotificationsNeverBecomeCompanionSessions() throws {
        var state = try owned()
        XCTAssertTrue(state.notifications("turn/started", ["threadId": "external", "turn": ["id": "turn"]]).isEmpty)
        XCTAssertTrue(state.notifications("thread/started", ["thread": ["id": "external", "source": "appServer"]]).isEmpty)
        XCTAssertEqual(state.ownedThreads, ["parent"])
        let request = state.serverRequest(id: 1, method: "item/commandExecution/requestApproval", params: ["threadId": "external"])
        XCTAssertTrue(request.events.isEmpty)
        XCTAssertNotNil(request.reply?["error"])
    }

    func testStreamingCombinesCommentaryAndAnswerButCompletesOnlyAtTurnEnd() throws {
        var state = try owned()
        let start = state.notifications("turn/started", ["threadId": "parent", "turn": ["id": "t"]])
        XCTAssertEqual(start.map(\.name), ["message.start"])
        let first = state.notifications("item/agentMessage/delta", ["threadId": "parent", "itemId": "a", "delta": "Checking."])
        XCTAssertEqual(first.first?.payload["text"] as? String, "Checking.")
        XCTAssertTrue(state.notifications("item/completed", ["threadId": "parent", "item": ["type": "agentMessage", "id": "a", "text": "Checking."]]).isEmpty)
        let second = state.notifications("item/agentMessage/delta", ["threadId": "parent", "itemId": "b", "delta": "Done."])
        XCTAssertEqual(second.first?.payload["text"] as? String, "\n\nDone.")
        XCTAssertEqual(state.activeTurns["parent"], "t")
        let end = state.notifications("turn/completed", ["threadId": "parent", "turn": ["id": "t", "status": "completed"]])
        XCTAssertEqual(end.map(\.name), ["message.complete"])
        XCTAssertEqual(end.first?.payload["text"] as? String, "Checking.\n\nDone.")
        XCTAssertEqual(end.first?.payload["status"] as? String, "complete")
        XCTAssertNil(state.activeTurns["parent"])
    }

    func testProviderWithoutDeltasStillDisplaysCompletedMessage() throws {
        var state = try owned()
        let events = state.notifications("item/completed", ["threadId": "parent", "item": ["type": "agentMessage", "id": "a", "text": "Answer"]])
        XCTAssertEqual(events.map(\.name), ["message.delta"])
        XCTAssertEqual(events.first?.payload["text"] as? String, "Answer")
    }

    func testStaleTurnCannotAppendTextOrCompleteANewerTurn() throws {
        var state = try owned()
        _ = state.notifications("turn/started", ["threadId": "parent", "turn": ["id": "old"]])
        _ = state.notifications("turn/completed", ["threadId": "parent", "turn": ["id": "old", "status": "completed"]])
        _ = state.notifications("turn/started", ["threadId": "parent", "turn": ["id": "new"]])
        XCTAssertTrue(state.notifications("item/agentMessage/delta", ["threadId": "parent", "turnId": "old", "itemId": "x", "delta": "stale"]).isEmpty)
        XCTAssertTrue(state.notifications("turn/completed", ["threadId": "parent", "turn": ["id": "old", "status": "failed"]]).isEmpty)
        XCTAssertEqual(state.activeTurns["parent"], "new")
        let fresh = state.notifications("item/agentMessage/delta", ["threadId": "parent", "turnId": "new", "itemId": "y", "delta": "fresh"])
        XCTAssertEqual(fresh.first?.payload["text"] as? String, "fresh")
    }

    func testNativeResumeReconcilesAmbiguousSendAndIdleState() throws {
        var state = try owned()
        state.startingThreads.insert("parent")
        state.activeTurns["parent"] = "old"
        _ = try state.register(["id": "parent", "turns": [["id": "old", "status": "completed"]]])
        XCTAssertFalse(state.startingThreads.contains("parent"))
        XCTAssertNil(state.activeTurns["parent"])
        XCTAssertTrue(state.completedTurns.contains("parent:old"))
        _ = try state.register(["id": "parent", "turns": [["id": "new", "status": "inProgress"]]])
        XCTAssertEqual(state.activeTurns["parent"], "new")
    }

    func testFileApprovalIncludesActualDiffBeforeUserDecides() throws {
        var state = try owned()
        _ = state.notifications("item/started", ["threadId": "parent", "item": ["id": "patch", "type": "fileChange", "changes": [["path": "/workspace/file", "diff": "+ new contents"]]]])
        let request = state.serverRequest(id: 9, method: "item/fileChange/requestApproval", params: ["threadId": "parent", "itemId": "patch", "reason": "Apply patch"])
        let details = try XCTUnwrap(request.events.first?.payload["command"] as? String)
        XCTAssertTrue(details.contains("new contents"))
        XCTAssertTrue(details.contains("workspace"))
    }

    func testToolIdentityAndFailedExitCode() throws {
        var state = try owned()
        let item: [String: Any] = ["type": "commandExecution", "id": "tool", "command": "false", "status": "inProgress"]
        let start = state.notifications("item/started", ["threadId": "parent", "item": item])
        XCTAssertEqual(start.first?.payload["tool_id"] as? String, "tool")
        XCTAssertTrue(state.notifications("item/started", ["threadId": "parent", "item": item]).isEmpty)
        let end = state.notifications("item/completed", ["threadId": "parent", "item": item.merging(["status": "completed", "exitCode": 1, "aggregatedOutput": "failed"]) { _, new in new }])
        XCTAssertEqual(end.map(\.name), ["tool.complete"])
        XCTAssertEqual(end.first?.payload["is_error"] as? Bool, true)
        XCTAssertEqual(end.first?.payload["result"] as? String, "failed")
    }

    func testOnlyExplicitChildrenAreNestedUnderTheirParent() throws {
        var state = try owned()
        let events = state.notifications("thread/started", ["thread": ["id": "child", "parentThreadId": "parent", "agentNickname": "Scout"]])
        XCTAssertEqual(events.map(\.name), ["subagent.start"])
        XCTAssertEqual(events.first?.payload["session_id"] as? String, "parent")
        XCTAssertFalse(state.ownedThreads.contains("child"))
        let delta = state.notifications("item/agentMessage/delta", ["threadId": "child", "itemId": "m", "delta": "Found it"])
        XCTAssertEqual(delta.first?.name, "subagent.text")
        XCTAssertEqual(delta.first?.payload["subagent_id"] as? String, "child")
        let end = state.notifications("turn/completed", ["threadId": "child", "turn": ["id": "t", "status": "failed"]])
        XCTAssertEqual(end.last?.name, "subagent.complete")
        XCTAssertEqual(end.last?.payload["status"] as? String, "error")
    }

    func testCollabFinalFailureIsNotReportedAsSuccess() throws {
        var state = try owned()
        let events = state.notifications("item/completed", ["threadId": "parent", "item": ["type": "collabAgentToolCall", "id": "wait", "tool": "wait", "receiverThreadIds": ["child"], "agentsStates": ["child": ["status": "errored", "message": "Failed"]]]])
        let child = try XCTUnwrap(events.first(where: { $0.name == "subagent.complete" }))
        XCTAssertEqual(child.payload["status"] as? String, "error")
        XCTAssertEqual(child.payload["text"] as? String, "Failed")
    }

    func testApprovalHonorsAvailableScopesAndDoesNotOfferPersistentRules() throws {
        var state = try owned()
        let request = state.serverRequest(id: 10, method: "item/commandExecution/requestApproval", params: ["threadId": "parent", "command": "touch output", "availableDecisions": ["accept", "decline", ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["touch"]]]] as [Any]])
        XCTAssertEqual(request.events.first?.payload["choices"] as? [String], ["once", "deny"])
        XCTAssertThrowsError(try state.answer(["session_id": "parent", "request_id": "n:10", "choice": "session"], approval: true))
        let answer = try XCTUnwrap(state.answer(["session_id": "parent", "request_id": "n:10", "choice": "once"], approval: true))
        XCTAssertEqual((answer["result"] as? [String: String])?["decision"], "accept")
        XCTAssertEqual(answer["id"] as? Int, 10)
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testPermissionDenialNeverGrantsRequestedPermissions() throws {
        var state = try owned()
        _ = state.serverRequest(id: "permission", method: "item/permissions/requestApproval", params: ["threadId": "parent", "permissions": ["network": ["enabled": true]]])
        let answer = try XCTUnwrap(state.answer(["session_id": "parent", "request_id": "s:permission", "choice": "deny"], approval: true))
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        XCTAssertEqual((result["permissions"] as? [String: Any])?.count, 0)
        XCTAssertEqual(result["scope"] as? String, "turn")
    }

    func testDelegatedApprovalMarksThatChildWaitingAndRoutesToParent() throws {
        var state = try owned()
        state.parents["child"] = "parent"
        let request = state.serverRequest(id: 1, method: "item/commandExecution/requestApproval", params: ["threadId": "child", "command": "echo hello"])
        XCTAssertEqual(request.events.map(\.name), ["subagent.thinking", "approval.request"])
        XCTAssertEqual(request.events[0].payload["status"] as? String, "waiting")
        XCTAssertEqual(request.events[0].payload["subagent_id"] as? String, "child")
        XCTAssertEqual(request.events[1].payload["session_id"] as? String, "parent")
        let response = try state.answer(["session_id": "parent", "request_id": "n:1", "choice": "deny"], approval: true)
        XCTAssertEqual((response?["result"] as? [String: String])?["decision"], "decline")
    }

    func testStringAndIntegerRequestIDsCannotCollide() {
        XCTAssertNotEqual(CodexProtocolState.requestKey("7"), CodexProtocolState.requestKey(7))
    }

    func testClarificationWaitsForEveryQuestionAndEnforcesOfferedOptions() throws {
        var state = try owned()
        let questions: [[String: Any]] = [["id": "a", "question": "First?", "isOther": false, "options": [["label": "A", "description": "Choose A"]]], ["id": "b", "question": "Second?", "isOther": true]]
        let request = state.serverRequest(id: 1, method: "item/tool/requestUserInput", params: ["threadId": "parent", "questions": questions])
        let normalized = try XCTUnwrap(request.events.first?.payload["questions"] as? [[String: Any]])
        XCTAssertEqual(normalized[0]["allows_free_text"] as? Bool, false)
        XCTAssertEqual(normalized[1]["allows_free_text"] as? Bool, true)
        XCTAssertThrowsError(try state.answer(["session_id": "parent", "request_id": "n:1", "question_id": "a", "answer": "invalid"], approval: false))
        XCTAssertNil(try state.answer(["session_id": "parent", "request_id": "n:1", "question_id": "a", "answer": "A"], approval: false))
        let reply = try XCTUnwrap(state.answer(["session_id": "parent", "request_id": "n:1", "question_id": "b", "answer": "Free answer"], approval: false))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let answers = try XCTUnwrap(result["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["a"]?["answers"], ["A"])
        XCTAssertEqual(answers["b"]?["answers"], ["Free answer"])
    }

    func testResolvedQuestionRejectsLateAnswer() throws {
        var state = try owned()
        _ = state.serverRequest(id: "r", method: "item/tool/requestUserInput", params: ["threadId": "parent", "questions": [["id": "q", "question": "Question?"]]])
        let events = state.notifications("serverRequest/resolved", ["threadId": "parent", "requestId": "r"])
        XCTAssertEqual(events.first?.name, "clarify.expire")
        XCTAssertThrowsError(try state.answer(["session_id": "parent", "request_id": "s:r", "answer": "late"], approval: false))
    }

    func testUnsupportedElicitationIsExplicitlyDeclined() throws {
        var state = try owned()
        let result = state.serverRequest(id: "mcp", method: "mcpServer/elicitation/request", params: ["threadId": "parent", "mode": "openai/userVerification"])
        XCTAssertEqual(result.events.first?.name, "runtime.notice")
        XCTAssertEqual((result.reply?["result"] as? [String: String])?["action"], "decline")
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testSecretQuestionsAreNotShownInNormalComposer() throws {
        var state = try owned()
        let result = state.serverRequest(id: "secret", method: "item/tool/requestUserInput", params: ["threadId": "parent", "questions": [["id": "password", "isSecret": true]]])
        XCTAssertEqual(result.events.first?.name, "runtime.notice")
        XCTAssertNotNil(result.reply)
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testHistoryPreservesTurnsAndOmitsReasoningAndToolInternals() {
        let thread: [String: Any] = ["turns": [["id": "t", "items": [
            ["type": "userMessage", "id": "u", "content": [["type": "text", "text": "Hello"]]],
            ["type": "reasoning", "id": "r", "summary": ["private"]],
            ["type": "agentMessage", "id": "a", "text": "Checking"],
            ["type": "commandExecution", "id": "c", "aggregatedOutput": "secret"],
            ["type": "agentMessage", "id": "b", "text": "Answer"]
        ]]]]
        let rows = CodexProtocolState.history(thread)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["text"] as? String, "Hello")
        XCTAssertEqual(rows[1]["text"] as? String, "Checking\n\nAnswer")
        XCTAssertEqual(rows[1]["row_id"] as? String, "t")
    }

    @MainActor
    func testStandaloneEnvironmentPreservesHomeAndRemovesDesktopIdentity() {
        let environment = CodexClient.childEnvironment(["CODEX_HOME": "/old", "CODEX_THREAD_ID": "external", "CODEX_SESSION_ID": "external", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "CodexDesktop", "CODEX_APP_TOOLS_PIPE_PATH": "/private-pipe", "CUSTOM_RUNTIME_SETTING": "keep"], profileID: "/existing-codex")
        XCTAssertEqual(environment["CODEX_HOME"], "/existing-codex")
        XCTAssertEqual(environment["CUSTOM_RUNTIME_SETTING"], "keep")
        for key in ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_APP_TOOLS_PIPE_PATH"] { XCTAssertNil(environment[key]) }
    }
}
