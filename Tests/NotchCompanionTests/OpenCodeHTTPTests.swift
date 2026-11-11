import XCTest
@testable import NotchCompanion

final class OpenCodeHTTPTests: XCTestCase {
    func testV1VersionBoundarySSEFramingAndNativeMessageIdentity() throws {
        XCTAssertTrue(OpenCodeClient.supportsVersion("1.18.34"))
        for invalid in ["2.0.0", "1.18.33", "1.bad.18.34", "1.19.0", "1..18.34"] { XCTAssertFalse(OpenCodeClient.supportsVersion(invalid)) }
        var decoder = OpenCodeSSEDecoder(), frames: [[String: Any]] = []
        for byte in Data(": heartbeat\r\ndata: {\"type\":\r\ndata: \"server.connected\"}\r\n\r\n".utf8) {
            if let frame = try decoder.append(byte) { frames.append(frame) }
        }
        XCTAssertEqual(frames.first?["type"] as? String, "server.connected")
        var invalid = OpenCodeSSEDecoder()
        XCTAssertThrowsError(try Data("data: broken\n\n".utf8).forEach { _ = try invalid.append($0) })
        let id = UUID().uuidString
        let rows: [[String: Any]] = [["info": ["id": "msg_" + id, "sessionID": "ses_native", "role": "user"], "parts": [["type": "text", "text": "hello"]]]]
        XCTAssertEqual(OpenCodeClient.history(rows).first?["client_id"] as? String, id)
    }

    @MainActor
    func testLargeNativeCatalogLoadsWithoutStallingEventsAndKeepsResponseBound() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let large = fixture.home.appendingPathComponent("large-catalog")
        try Data().write(to: large)
        try Data().write(to: fixture.home.appendingPathComponent("arm-initial-idle-race"))
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var completed = false
        client.onEvent = { name, _ in if name == "message.complete" { completed = true } }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
        XCTAssertEqual(opened["running"] as? Bool, false, "A late idle event must not strand an empty native session as busy")
        XCTAssertEqual(opened["activity_verified"] as? Bool, true)
        let catalog = try XCTUnwrap(opened["catalog"] as? RuntimeModelCatalog)
        XCTAssertEqual(catalog.models.count, 2)
        let id = try XCTUnwrap(opened["session_id"] as? String)
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "ordinary", "turn_id": "large-catalog-turn"])
        try await eventually { completed }
        try FileManager.default.removeItem(at: large)
        try Data().write(to: fixture.home.appendingPathComponent("oversized-catalog"))
        do {
            _ = try await client.request("runtime.models", params: ["cwd": fixture.home.path])
            XCTFail("Native responses must remain bounded")
        } catch { XCTAssertTrue(error.localizedDescription.contains("32 MB"), error.localizedDescription) }
    }

    @MainActor
    func testChildCreatedDuringSnapshotCannotCompleteParentBeforeSSE() async throws {
        for text in ["delegate-during-snapshot", "delegate-during-nested-snapshot"] {
            let fixture = try peer()
            defer { try? FileManager.default.removeItem(at: fixture.home) }
            let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
            defer { client.disconnect() }
            var events: [(String, [String: Any])] = []
            client.onEvent = { events.append(($0, $1)) }
            try await client.connect()
            let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
            let id = try XCTUnwrap(opened["session_id"] as? String)
            _ = try await client.request("prompt.submit", params: ["session_id": id, "text": text, "turn_id": "snapshot-race"])
            try await eventually { events.contains { $0.0 == "approval.request" } }
            XCTAssertFalse(events.contains { $0.0 == "message.complete" }, "HTTP child discovery must be revalidated even when SSE has not arrived: \(text)")
            do {
                _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "must-not-submit"])
                XCTFail("The newly discovered child must block another prompt")
            } catch { XCTAssertTrue(error is RuntimeDefinitiveRejection) }
            _ = try await client.request("approval.respond", params: ["session_id": id, "request_id": "perm_child", "choice": "deny"])
            try await eventually {
                events.contains { $0.0 == "subagent.complete" && $0.1["subagent_id"] as? String == "ses_child" }
                    && events.contains { $0.0 == "message.complete" }
            }
            let childDone = try XCTUnwrap(events.firstIndex { $0.0 == "subagent.complete" && $0.1["subagent_id"] as? String == "ses_child" })
            let parentDone = try XCTUnwrap(events.firstIndex { $0.0 == "message.complete" })
            XCTAssertLessThan(childDone, parentDone)
            XCTAssertEqual(events.filter { $0.0 == "message.complete" }.count, 1)
        }
    }

    @MainActor
    func testLateIdleEventDuringPreflightDoesNotRejectOrDuplicatePrompt() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var completed = false
        client.onEvent = { name, _ in if name == "message.complete" { completed = true } }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        try Data().write(to: fixture.home.appendingPathComponent("arm-initial-idle-race"))
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "ordinary", "turn_id": "idle-race-prompt"])
        try await eventually { completed }
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.home.appendingPathComponent("http-native.json"))) as? [String: Any])
        let history = try XCTUnwrap(saved["history"] as? [String: [[String: Any]]])
        XCTAssertEqual(history[id]?.filter { ($0["info"] as? [String: Any])?["id"] as? String == "msg_idle-race-prompt" }.count, 1)
    }

    @MainActor
    func testOwnedHTTPPeerPreservesChildActivityQuestionsModelsAndExactResume() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path, "title": "Offline HTTP fixture"])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        XCTAssertEqual((opened["info"] as? [String: Any])?["interface"] as? String, "opencode-http-v1")
        XCTAssertNil((opened["info"] as? [String: Any])?["model"], "A global default catalog is not an effective session model")
        _ = try await client.request("session.model.set", params: ["session_id": id, "model": "selected", "provider": "native"])
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "ordinary", "turn_id": "owned-turn"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last(where: { $0.0 == "message.complete" })?.1["text"] as? String, "model:selected")
        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "delegate", "turn_id": "delegation-turn"])
        try await eventually { events.contains { $0.0 == "approval.request" } }
        XCTAssertFalse(events.contains { $0.0 == "message.complete" }, "A parent reply must not complete its active child")
        XCTAssertTrue(events.contains { $0.0 == "subagent.start" && $0.1["subagent_id"] as? String == "ses_child" })
        do { _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "duplicate"]); XCTFail("Child must block another native prompt") }
        catch { XCTAssertTrue(error is RuntimeDefinitiveRejection) }
        _ = try await client.request("approval.respond", params: ["session_id": id, "request_id": "perm_child", "choice": "deny"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        let childDone = try XCTUnwrap(events.firstIndex { $0.0 == "subagent.complete" })
        let parentDone = try XCTUnwrap(events.firstIndex { $0.0 == "message.complete" })
        XCTAssertLessThan(childDone, parentDone)
        events.removeAll()
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "question", "turn_id": "question-turn"])
        try await eventually { events.contains { $0.0 == "clarify.request" } }
        _ = try await client.request("clarify.respond", params: ["session_id": id, "request_id": "question_root", "question_id": "0", "answer": "Sage"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        client.disconnect()
        let resumed = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { resumed.disconnect() }
        try await resumed.connect()
        let snapshot = try await resumed.request("session.resume", params: ["session_id": id, "cwd": fixture.home.path])
        XCTAssertEqual(snapshot["history_complete"] as? Bool, true)
        XCTAssertEqual(snapshot["running"] as? Bool, false)
        XCTAssertEqual(snapshot["parent_complete"] as? Bool, true)
        XCTAssertEqual((snapshot["subagents"] as? [[String: Any]])?.first?["status"] as? String, "complete")
        XCTAssertEqual((snapshot["info"] as? [String: Any])?["model"] as? String, "selected")
        XCTAssertTrue((snapshot["messages"] as? [[String: Any]] ?? []).contains { $0["client_id"] as? String == "owned-turn" })
        do { _ = try await resumed.request("session.resume", params: ["session_id": id, "cwd": fixture.home.path, "activity_unverified": true]); XCTFail("Fresh HTTP status must not certify old ACP work") } catch {}
        var resumedEvents: [(String, [String: Any])] = []
        resumed.onEvent = { resumedEvents.append(($0, $1)) }
        _ = try await resumed.request("prompt.submit", params: ["session_id": id, "text": "hold", "turn_id": "hold-turn"])
        _ = try await resumed.request("session.interrupt", params: ["session_id": id])
        try await eventually { resumedEvents.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(resumedEvents.last(where: { $0.0 == "message.complete" })?.1["status"] as? String, "interrupted")
    }

    @MainActor
    func testOnlyOpenCodesGeneratedTitleIsReported() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "name-me", "turn_id": "title-turn"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.filter { $0.0 == "session.title" }.map { $0.1["title"] as? String }, ["Named by OpenCode"],
                       "The dated placeholder is never a title")
    }

    @MainActor
    func testV2HTTPIsRejectedBeforeCreatingNativeSession() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try Data().write(to: fixture.home.appendingPathComponent("bad-version"))
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        do { try await client.connect(); XCTFail("V2 must not be interpreted as V1") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("http-native.json").path))
    }

    @MainActor
    func testDelayedChildStartupAndStatusRaceCannotProduceFalseCompletion() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "delayed-child", "turn_id": "delayed"])
        try await eventually { events.contains { $0.0 == "subagent.start" } }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(events.contains { $0.0 == "subagent.complete" || $0.0 == "message.complete" }, "An empty child discovered before its startup event is not a terminal child")
        try Data().write(to: fixture.home.appendingPathComponent("release-child"))
        try await eventually { events.contains { $0.0 == "message.complete" } }
        events.removeAll()
        try Data().write(to: fixture.home.appendingPathComponent("arm-status-race"))
        do {
            _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "must-not-submit", "turn_id": "blocked"])
            XCTFail("A newer child-busy event must invalidate the older idle snapshot")
        } catch { XCTAssertTrue(error is RuntimeDefinitiveRejection) }
        XCTAssertFalse(events.contains { $0.0 == "subagent.complete" || $0.0 == "message.complete" })
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.home.appendingPathComponent("http-native.json"))) as? [String: Any]
        let history = saved?["history"] as? [String: [[String: Any]]]
        XCTAssertFalse(history?[id]?.contains { ($0["info"] as? [String: Any])?["id"] as? String == "msg_blocked" } ?? true)
        try Data().write(to: fixture.home.appendingPathComponent("release-child"))
        try await eventually { events.contains { $0.0 == "subagent.complete" } }
    }

    @MainActor
    func testQueueAcknowledgementWaitsForDurableNativeMessageIdentity() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var events: [String] = [], accepted = false
        client.onEvent = { name, _ in events.append(name) }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        for text in ["queued-rejection", "receipt-read-error"] {
            do {
                _ = try await client.request("prompt.submit", params: ["session_id": id, "text": text, "turn_id": "unconfirmed-input"])
                XCTFail("A queued failure cannot confirm a user message")
            } catch { XCTAssertFalse(error is RuntimeDefinitiveRejection, "An error after HTTP204 must preserve the uncertain send intent") }
            try await client.connect()
            _ = try await client.request("session.resume", params: ["session_id": id, "cwd": fixture.home.path])
        }
        XCTAssertFalse(events.contains("message.start") || events.contains("message.complete"))
        events.removeAll()
        let pending = Task { @MainActor in
            let result = try await client.request("prompt.submit", params: ["session_id": id, "text": "queued-delivery", "turn_id": "durable-input"])
            accepted = true
            return result
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(accepted)
        XCTAssertFalse(events.contains("message.start"), "HTTP204 alone is not a durable user-message receipt")
        _ = try await pending.value
        XCTAssertTrue(accepted)
        try await eventually { events.contains("message.complete") }
    }

    @MainActor
    func testTextBeforeANewCallStreamsAheadOfItAndLaterTextAfterIt() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "split-tail", "turn_id": "split-tail"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        func first(_ name: String, _ match: ([String: Any]) -> Bool) throws -> Int { try XCTUnwrap(events.firstIndex { $0.0 == name && match($0.1) }) }
        let tail = try first("message.delta") { ($0["text"] as? String)?.contains("now.") == true }
        let bash = try first("tool.start") { $0["name"] as? String == "bash" }
        let read = try first("tool.start") { $0["name"] as? String == "read" }
        let later = try first("message.delta") { ($0["text"] as? String)?.contains("Found it.") == true }
        XCTAssertLessThan(tail, bash, "A text tail polled with a new call stays before the call")
        XCTAssertLessThan(read, later, "Text written after a new call follows it")
        let text = events.filter { $0.0 == "message.delta" }.compactMap { $0.1["text"] as? String }.joined()
        XCTAssertEqual(text, "I'll run the tests now.\n\nFound it.")
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["text"] as? String, text)
    }

    @MainActor
    func testNativeFailureReasonReachesTheFailedCompletion() async throws {
        let fixture = try peer()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = OpenCodeClient(profileID: fixture.home.path, executableURL: fixture.executable, supervisorURL: supervisor)
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": fixture.home.path])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "session-error", "turn_id": "session-error"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        let complete = try XCTUnwrap(events.last { $0.0 == "message.complete" }?.1)
        XCTAssertEqual(complete["status"] as? String, "error")
        XCTAssertEqual(complete["error"] as? String, "Native provider credentials expired", "The runtime's reason, not the progress notice or raw JSON")

        // No session.error frame: the terminal message's own error is the reason.
        events.removeAll()
        let other = try await client.request("session.create", params: ["cwd": fixture.home.path])
        let otherID = try XCTUnwrap(other["session_id"] as? String)
        _ = try await client.request("prompt.submit", params: ["session_id": otherID, "text": "terminal-error", "turn_id": "terminal-error"])
        try await eventually { events.contains { $0.0 == "message.complete" } }
        let terminal = try XCTUnwrap(events.last { $0.0 == "message.complete" }?.1)
        XCTAssertEqual(terminal["status"] as? String, "error")
        XCTAssertEqual(terminal["error"] as? String, "Provider rejected the request")
        XCTAssertEqual(OpenCodeClient.failureReason(["name": "APIError", "message": "Top-level", "data": ["message": "Nested"]]), "Top-level")
        XCTAssertEqual(OpenCodeClient.failureReason(["name": "NativeTurnError", "data": ["message": ""]]), "NativeTurnError")
    }

    private var supervisor: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/NotchCompanion")
    }

    private func peer() throws -> (home: URL, executable: URL) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Offline HTTP peer needs system Python 3.") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/opencode_http.py")
        let executable = home.appendingPathComponent("opencode-http-peer")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (home, executable)
    }
    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("Native HTTP fixture did not reach expected state"); throw AppError("Offline HTTP fixture timeout")
    }
}
