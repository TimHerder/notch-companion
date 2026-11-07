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
    func testAntigravityHostsDelegationAnswersNativeQuestionsAndResumesOnlyListedConversations() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Offline agy peer needs system Python 3.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-agy-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/antigravity_acp.py")
        let executable = root.appendingPathComponent("agy")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli").path
        do {
            try await ACPRuntimeClient(runtime: .antigravity, profileID: root.path, executableOverride: executable).connect()
            XCTFail("Only the native profile")
        } catch {}
        let client = ACPRuntimeClient(runtime: .antigravity, profileID: profile, executableOverride: executable)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let trusted: [String: Any] = ["cwd": root.path, "project_trusted": true]
        let models = try await client.request("runtime.models", params: trusted)
        let discovered = try XCTUnwrap(models["catalog"] as? RuntimeModelCatalog)
        XCTAssertEqual(discovered.defaultModel?.model, "gemini-3.8-flash-high")
        do {
            _ = try await client.request("session.create", params: ["cwd": root.path])
            XCTFail("Native tools start only in a trusted project")
        } catch {}

        let delegation: [String: Any] = ["url": "http://127.0.0.1:9/mcp", "token": "tok", "bridge": "/bin/bridge", "instructions": Delegation.instructions]
        let session = try await client.request("session.create", params: trusted.merging(["delegation": delegation]) { $1 })
        let sid = try XCTUnwrap(session["session_id"] as? String)
        let reloaded = try await client.request("session.resume", params: trusted.merging(["session_id": sid, "native_submission_attempted": true]) { $1 })
        XCTAssertEqual(reloaded["stored_session_id"] as? String, sid, "A live reload (Check last send) needs no native list entry")
        let capabilities = try XCTUnwrap((session["info"] as? [String: Any])?["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["questions"] as? Bool, true)
        XCTAssertEqual(capabilities["permissionModes"] as? [String], [PermissionMode.autoEdit.rawValue, PermissionMode.plan.rawValue],
                       "`default` follows native settings, so it is Inherit, not Ask")
        let catalog = try XCTUnwrap(session["catalog"] as? RuntimeModelCatalog)
        XCTAssertEqual(catalog.models.map(\.choice.model), discovered.models.map(\.choice.model),
                       "A model picked before the first send stays valid once the session opens")
        do {
            _ = try await client.request("session.model.set", params: ["session_id": sid, "model": "gemini-3.8-flash"])
            XCTFail("A config family is not one of the session's exact models")
        } catch {}
        _ = try await client.request("session.model.set", params: ["session_id": sid, "model": "claude-sonnet-4-6"])

        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "ordinary"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["text"] as? String, "reply:claude-sonnet-4-6")
        let tool = try XCTUnwrap(events.first { $0.0 == "tool.start" }?.1["name"] as? String)
        XCTAssertEqual(ToolActivity.delegationTool(tool), "delegate_task", "Labelled as the companion's tool")

        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "question"])
        try await eventually { events.contains { $0.0 == "clarify.request" } }
        let question = try XCTUnwrap((events.first { $0.0 == "clarify.request" }?.1["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(question["choices"] as? [String], ["Sage", "Ink"])
        XCTAssertEqual(question["allows_free_text"] as? Bool, false)
        do {
            _ = try await client.request("approval.respond", params: ["session_id": sid, "request_id": "s:ask-1", "choice": "once"])
            XCTFail("A native question's options are answers, never an approval")
        } catch {}
        _ = try await client.request("clarify.respond", params: ["session_id": sid, "request_id": "s:ask-1", "question_id": "interaction_1", "answer": "Ink"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["text"] as? String, "opt-ink")

        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "permission"])
        try await eventually { events.contains { $0.0 == "approval.request" } }
        XCTAssertEqual(events.first { $0.0 == "approval.request" }?.1["choices"] as? [String], ["once", "deny"])
        _ = try await client.request("approval.respond", params: ["session_id": sid, "request_id": "s:perm-1", "choice": "deny"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["text"] as? String, "reject")
        client.disconnect()

        let resumed = ACPRuntimeClient(runtime: .antigravity, profileID: profile, executableOverride: executable)
        defer { resumed.disconnect() }
        try await resumed.connect()
        let reopened = try await resumed.request("session.resume", params: trusted.merging(["session_id": sid, "delegation": delegation,
                                                                                            "native_submission_attempted": true]) { $1 })
        XCTAssertEqual(reopened["stored_session_id"] as? String, sid)
        XCTAssertEqual(reopened["history_complete"] as? Bool, false)
        XCTAssertEqual((reopened["info"] as? [String: Any])?["model"] as? String, "gemini-3.8-flash-high", "A cold resume reports the native default")
        let missing = UUID().uuidString.lowercased()
        do {
            _ = try await resumed.request("session.resume", params: trusted.merging(["session_id": missing, "native_submission_attempted": true]) { $1 })
            XCTFail("An ID agy does not list would silently become an empty conversation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no longer lists")) }
        let neverPrompted = try await resumed.request("session.resume", params: trusted.merging(["session_id": missing, "native_submission_attempted": false]) { $1 })
        XCTAssertEqual(neverPrompted["stored_session_id"] as? String, missing, "Nothing was sent there, so its empty conversation keeps the ID")

        let wire = try String(contentsOf: root.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let opens = wire.filter { ["session/new", "session/resume"].contains($0["method"] as? String) }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(opens.count, 4, "The unlisted resume was refused before reaching agy")
        for open in opens.prefix(3) {
            XCTAssertEqual((open["mcpServers"] as? [[String: Any]])?.first?["name"] as? String, "notch", "A reload keeps its bridge")
            let meta = ((open["_meta"] as? [String: Any])?["antigravity"] as? [String: Any])?["systemPrompt"] as? [String: Any]
            XCTAssertEqual(meta?["append"] as? String, Delegation.instructions, "Appended on every open: agy keeps it only per process")
        }
        XCTAssertNil(opens[3]["_meta"], "No delegation, no appended instructions")
        XCTAssertTrue(wire.contains { $0["method"] as? String == "session/list" && ($0["params"] as? [String: Any])?["cursor"] != nil },
                      "The native list is followed across pages")
    }

    @MainActor
    func testAntigravityStopAnswersItsOpenQuestionSoTheTurnEnds() async throws {
        let (root, client) = try antigravityFixture()
        defer { client.disconnect(); try? FileManager.default.removeItem(at: root) }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let session = try await client.request("session.create", params: ["cwd": root.path, "project_trusted": true])
        let sid = try XCTUnwrap(session["session_id"] as? String)
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "question"])
        try await eventually { events.contains { $0.0 == "clarify.request" } }
        _ = try await client.request("session.interrupt", params: ["session_id": sid])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["status"] as? String, "interrupted")
        let wire = try wireLog(root)
        let cancel = try XCTUnwrap(wire.firstIndex { $0["method"] as? String == "session/cancel" })
        let answer = try XCTUnwrap(wire.firstIndex { $0["id"] as? String == "ask-1" })
        XCTAssertLessThan(cancel, answer)
        XCTAssertEqual(((wire[answer]["result"] as? [String: Any])?["outcome"] as? [String: Any])?["outcome"] as? String, "cancelled")
        do {
            _ = try await client.request("clarify.respond", params: ["session_id": sid, "request_id": "s:ask-1", "question_id": "interaction_1", "answer": "Ink"])
            XCTFail("A cancelled question cannot be answered again")
        } catch {}
    }

    @MainActor
    func testAntigravityPromptDeadlineSettlesOnlyThatTurnAndWaitsWhileTheUserIsAsked() async throws {
        let (root, client) = try antigravityFixture()
        defer { client.disconnect(); try? FileManager.default.removeItem(at: root) }
        client.promptTimeout = 0.3
        var events: [(String, [String: Any])] = []
        var disconnected = false
        client.onEvent = { events.append(($0, $1)) }
        client.onConnectionChange = { connected, _ in if !connected { disconnected = true } }
        try await client.connect()
        let session = try await client.request("session.create", params: ["cwd": root.path, "project_trusted": true])
        let sid = try XCTUnwrap(session["session_id"] as? String)

        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "question"])
        try await eventually { events.contains { $0.0 == "clarify.request" } }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(events.contains { $0.0 == "message.complete" }, "Time spent waiting on the user does not end the turn")
        _ = try await client.request("clarify.respond", params: ["session_id": sid, "request_id": "s:ask-1", "question_id": "interaction_1", "answer": "Ink"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["status"] as? String, "complete")

        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "slow"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["status"] as? String, "error")
        XCTAssertTrue((events.last { $0.0 == "runtime.notice" }?.1["message"] as? String)?.contains("did not finish this turn") == true)
        XCTAssertTrue(try wireLog(root).contains { $0["method"] as? String == "session/cancel" }, "The overdue turn is cancelled natively")
        XCTAssertFalse(disconnected, "The shared agy process keeps serving every session")
        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "ordinary"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["status"] as? String, "complete")
    }

    @MainActor
    private func antigravityFixture() throws -> (URL, ACPRuntimeClient) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Offline agy peer needs system Python 3.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-agy-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/antigravity_acp.py")
        let executable = root.appendingPathComponent("agy")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli").path
        return (root, ACPRuntimeClient(runtime: .antigravity, profileID: profile, executableOverride: executable))
    }

    private func wireLog(_ root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
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
