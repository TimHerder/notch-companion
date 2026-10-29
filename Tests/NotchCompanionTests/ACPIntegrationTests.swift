import XCTest
@testable import NotchCompanion

final class ACPIntegrationTests: XCTestCase {
    @MainActor
    func testRetirementBarrierWaitsForOwnedNativeFlushBeforeResume() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Offline flush peer needs system Python 3.") }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("native-flush-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = NativeJSONProcess()
        defer { process.stop() }
        let ready = expectation(description: "flush fixture has started")
        process.onFrame = { frame in if frame["ready"] as? Bool == true { ready.fulfill() } }
        try process.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys,time; print('{\"ready\":true}', flush=True); sys.stdin.read(); time.sleep(0.1); open(sys.argv[1], 'w').write('flushed')", marker.path], environment: [:], cwd: FileManager.default.temporaryDirectory)
        await fulfillment(of: [ready], timeout: 15)
        process.stop()
        try await NativeJSONProcess.awaitPendingStops()
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "flushed")
    }

    @MainActor
    func testFinalJSONFrameArrivesBeforeImmediateProcessExit() async throws {
        let process = NativeJSONProcess()
        defer { process.stop() }
        let ended = expectation(description: "native output reached EOF")
        var finalReceived = false
        process.onFrame = { frame in finalReceived = frame["id"] as? Int == 1 }
        process.onFailure = { _ in
            XCTAssertTrue(finalReceived, "Process exit must not discard the terminal native result")
            ended.fulfill()
        }
        try process.start(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["{\"id\":1,\"result\":{}}\n"], environment: [:], cwd: FileManager.default.temporaryDirectory)
        await fulfillment(of: [ended], timeout: 3)
    }

    @MainActor
    func testRealJSONLPipesPromptDenyQuestionModelCancelAndNativeResume() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Offline ACP peer needs system Python 3.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-acp-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/acp_runtime.py")
        let executable = root.appendingPathComponent("acp-peer")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ACPRuntimeClient(runtime: .opencode, profileID: root.path, executableOverride: executable)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let session = try await client.request("session.create", params: ["cwd": root.path])
        let sid = try XCTUnwrap(session["session_id"] as? String)
        XCTAssertEqual(sid, "native-fixture")
        _ = try await client.request("session.model.set", params: ["session_id": sid, "model": "provider/other"])
        let accepted = try await client.request("prompt.submit", params: ["session_id": sid, "text": "ordinary"])
        XCTAssertEqual(accepted["accepted"] as? Bool, true)
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last(where: { $0.0 == "message.complete" })?.1["text"] as? String, "reply:provider/other")
        XCTAssertTrue(events.contains { $0.0 == "tool.complete" })
        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "permission"])
        try await eventually { events.contains { $0.0 == "approval.request" } }
        let permission = try XCTUnwrap(events.first(where: { $0.0 == "approval.request" })?.1["request_id"] as? String)
        _ = try await client.request("approval.respond", params: ["session_id": sid, "request_id": permission, "choice": "deny"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last?.1["text"] as? String, "denied")
        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "question"])
        try await eventually { events.contains { $0.0 == "clarify.request" } }
        _ = try await client.request("clarify.respond", params: ["session_id": sid, "request_id": "s:question-1", "question_id": "color", "answer": "Sage"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "wait"])
        do {
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "duplicate"])
            XCTFail("Concurrent prompts must fail before native submission")
        } catch {}
        _ = try await client.request("session.interrupt", params: ["session_id": sid])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last?.1["status"] as? String, "interrupted")
        client.disconnect()
        let resumed = ACPRuntimeClient(runtime: .opencode, profileID: root.path, executableOverride: executable)
        defer { resumed.disconnect() }
        try await resumed.connect()
        let loaded = try await resumed.request("session.resume", params: ["session_id": sid, "cwd": root.path])
        XCTAssertEqual(loaded["stored_session_id"] as? String, sid)
        XCTAssertEqual(loaded["history_complete"] as? Bool, true)
        let rows = try XCTUnwrap(loaded["messages"] as? [[String: Any]])
        XCTAssertEqual(rows.filter { $0["role"] as? String == "user" }.count, 4)
        XCTAssertTrue(rows.contains { $0["text"] as? String == "Sage" })
        XCTAssertEqual((loaded["info"] as? [String: Any])?["model"] as? String, "provider/other")
    }

    @MainActor
    func testCursorAuthenticatesAndAnswersItsQuestionAndPlanRequests() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Offline Cursor peer needs system Python 3.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-cursor-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/cursor_acp.py")
        let executable = root.appendingPathComponent("cursor-agent")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ACPRuntimeClient(runtime: .cursor, profileID: root.path, executableOverride: executable)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let session = try await client.request("session.create", params: ["cwd": root.path])
        let sid = try XCTUnwrap(session["session_id"] as? String)
        let capabilities = try XCTUnwrap((session["info"] as? [String: Any])?["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["permissionModes"] as? [String], ["plan"], "Cursor's read-only ask mode is not ask-before-editing")
        XCTAssertEqual(capabilities["questions"] as? Bool, true)

        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "question"])
        try await eventually { events.contains { $0.0 == "clarify.request" } }
        XCTAssertEqual(events.first { $0.0 == "clarify.request" }?.1["session_id"] as? String, sid)
        _ = try await client.request("clarify.respond", params: ["session_id": sid, "request_id": "s:ask-1", "question_id": "q1",
                                                                 "answer": "Sage, Ink", "answers": ["Sage", "Ink"]])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["text"] as? String, "sage,ink")

        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "plan"])
        try await eventually { events.contains { $0.0 == "approval.request" } }
        XCTAssertTrue((events.first { $0.0 == "approval.request" }?.1["command"] as? String)?.contains("2. Edit") == true)
        _ = try await client.request("approval.respond", params: ["session_id": sid, "request_id": "s:plan-1", "choice": "deny"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["text"] as? String, "rejected")
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Offline ACP peer did not reach the expected protocol state")
        throw AppError("Offline ACP fixture timed out")
    }
}
