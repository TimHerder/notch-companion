import XCTest
@testable import NotchCompanion

final class AntigravityProtocolTests: XCTestCase {
    let id = "ba614d3b-5758-478d-9da5-ed622e34cf7d"

    func testExactIdentityStreamingAndCumulativeUsageIsNotContext() throws {
        var state = AntigravityProtocolState(expectedID: id)
        _ = try state.receive(["event": "init", "conversation_id": id, "init": ["cwd": "/tmp"]])
        try state.begin("turn")
        let delta = try state.receive(["event": "step_update", "step_update": ["conversation_id": id, "step_type": "agent_response", "text_delta": "Hello", "state": "ACTIVE"]])
        XCTAssertEqual(delta.first?.payload["text"] as? String, "Hello")
        let done = try state.receive(["event": "result", "result": ["conversation_id": id, "status": "SUCCESS", "response": "Hello", "usage": ["total_tokens": 100000]]])
        XCTAssertEqual(done.last?.name, "message.complete")
        XCTAssertNil(done.last?.payload["usage"])
        XCTAssertFalse(state.active)
        XCTAssertThrowsError(try state.receive(["event": "init", "conversation_id": UUID().uuidString]))
    }

    func testNonterminalResultsAndUnsettledDelegationCannotReportSuccess() throws {
        for status in ["WAITING", "RUNNING", "future-status"] {
            var state = AntigravityProtocolState(sessionID: id); try state.begin("turn")
            XCTAssertThrowsError(try state.receive(["event": "result", "result": ["status": status]]))
            XCTAssertTrue(state.active)
        }
        var state = AntigravityProtocolState(sessionID: id); try state.begin("turn")
        _ = try state.receive(["event": "step_update", "step_update": ["step_index": 1, "state": "ACTIVE", "subagent_info": ["subagents": [["conversation_id": "child"]]]]])
        XCTAssertThrowsError(try state.receive(["event": "result", "result": ["status": "SUCCESS"]]))
    }

    func testDeniedToolsAndInvalidResultsRemainVisible() throws {
        var state = AntigravityProtocolState(sessionID: id); try state.begin("turn")
        let events = try state.receive(["event": "step_update", "step_update": ["step_index": 0, "state": "DONE", "step_type": "tool", "tool_name": "run_command", "tool_info": ["error": ["type": "permission_denied"]]]])
        XCTAssertEqual(events.map(\.name), ["tool.start", "tool.complete", "runtime.notice"])
        XCTAssertEqual(events[1].payload["is_error"] as? Bool, true)
        let result = try state.receive(["event": "result", "result": ["status": "INVALID"]])
        XCTAssertEqual(result.last?.payload["status"] as? String, "error")
    }

    @MainActor func testOnlyExactResumeAndNoPermissionBypass() throws {
        let args = try AntigravityClient.arguments(resume: id)
        XCTAssertEqual(args, ["--input-format", "stream-json", "--output-format", "stream-json", "--conversation", id])
        XCTAssertThrowsError(try AntigravityClient.arguments(resume: "latest"))
        XCTAssertEqual(AntigravityClient.capabilities["approvals"], false)
        XCTAssertEqual(AntigravityClient.capabilities["contextUsage"], true)
    }

    func testLatestParentStepUsageReplacesTotalsAndIgnoresCheckpoint() throws {
        var state = AntigravityProtocolState(sessionID: id); try state.begin("turn")
        for (input, cache) in [(100, 300), (50, 20)] {
            let events = try state.receive(["event": "step_update", "step_update": ["step_type": "agent_response", "state": "DONE", "usage": ["input_tokens": input, "cache_read_tokens": cache, "total_tokens": 999999]]])
            XCTAssertEqual((events.first?.payload["usage"] as? [String: Any])?["context_used"] as? Int, input + cache)
        }
        _ = try state.receive(["event": "step_update", "step_update": ["step_type": "checkpoint", "state": "DONE", "usage": ["input_tokens": 2000, "cache_read_tokens": 0]]])
        XCTAssertEqual(state.contextUsed, 70)
        let events = try state.receive(["event": "step_update", "step_update": ["step_type": "agent_response", "state": "DONE", "usage": ["input_tokens": Int.max, "cache_read_tokens": 1]]])
        XCTAssertTrue(events.isEmpty)
        let opaque = try state.receive(["event": "step_update", "step_update": ["step_type": "unknown", "state": "DONE"]])
        XCTAssertEqual(opaque.first?.name, "runtime.notice")
        XCTAssertFalse(opaque.contains { $0.name == "clarify.request" }, "The CLI supplies no question or reply ID; never invent one")
    }
}
