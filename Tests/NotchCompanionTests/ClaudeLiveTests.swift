import XCTest
@testable import NotchCompanion

@MainActor
final class ClaudeLiveTests: XCTestCase {
    func testCatalogBeforeFirstMessageSavesNoSession() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_CLAUDE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_CLAUDE_LIVE_TESTS=1 after signing into the existing native Claude Code CLI.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-claude-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = URL(fileURLWithPath: RuntimeRoute.defaultProfile(.claude)).appendingPathComponent("projects")
        let before = try FileManager.default.contentsOfDirectory(atPath: projects.path)
        let client = ClaudeClient(profileID: RuntimeRoute.defaultProfile(.claude))
        defer { client.disconnect() }
        try await client.connect()
        for trusted in [true, false] {
            let result = try await client.request("runtime.models", params: ["cwd": directory.path, "project_trusted": trusted])
            let catalog = try XCTUnwrap(result["catalog"] as? RuntimeModelCatalog)
            XCTAssertNotNil(catalog.defaultModel)
            XCTAssertTrue(catalog.models.contains { !$0.reasoningEfforts.isEmpty }, "Native effort levels are listed")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: projects.path), before, "A catalog read saves no native session")
    }

    /// Uses the real CLI/profile. Normal runs skip; failed native login must be
    /// repaired by the user in Claude, never by manipulating credentials here.
    func testNativeFileReadAndExactResume() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_CLAUDE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_CLAUDE_LIVE_TESTS=1 after signing into the existing native Claude Code CLI.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-claude-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "NOTCH_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let file = directory.appendingPathComponent("marker.txt")
        try Data(marker.utf8).write(to: file)
        let profile = RuntimeRoute.defaultProfile(.claude)
        var client = ClaudeClient(profileID: profile)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["stored_session_id"] as? String)
        var result: [String: Any]?
        var diagnostic: String?
        var info = RuntimeSessionInfo()
        var title: String?
        client.onEvent = { name, payload in
            if name == "session.info" { info.merge(payload, runtime: .claude) }
            if name == "session.title" { title = payload["title"] as? String }
            if name == "message.complete" { result = payload }
            if name == "session.error" || name == "session.disconnected" { diagnostic = payload["message"] as? String }
            if name == "approval.request" || name == "clarify.request" {
                diagnostic = "Live validation requires a native interaction; respond through the app before claiming this path verified."
            }
        }
        let attachment = try await client.request("file.attach", params: ["session_id": id, "path": file.path])
        _ = try await client.request("prompt.submit", params: ["session_id": id, "turn_id": UUID().uuidString,
            "text": "Read marker.txt and reply with only its exact contents. Do not modify files or memory.\n\n" + (attachment["ref_text"] as? String ?? "")])
        try await wait { result != nil || diagnostic != nil }
        XCTAssertEqual(result?["status"] as? String, "complete", diagnostic ?? "Native Claude did not complete")
        guard result?["status"] as? String == "complete" else { return }
        XCTAssertTrue((result?["text"] as? String)?.contains(marker) == true)
        try await wait { title != nil }
        XCTAssertFalse(title?.isEmpty ?? true, "Claude names a session created without a title")
        XCTAssertGreaterThan(info.context?.used ?? 0, 0)
        XCTAssertGreaterThan(info.context?.limit ?? 0, 0)
        XCTAssertEqual(info.context?.estimated, true)
        client.disconnect()
        client = ClaudeClient(profileID: profile); try await client.connect()
        result = nil; diagnostic = nil; info = RuntimeSessionInfo()
        client.onEvent = { name, payload in
            if name == "session.info" { info.merge(payload, runtime: .claude) }
            if name == "message.complete" { result = payload }
            if name == "session.error" || name == "session.disconnected" { diagnostic = payload["message"] as? String }
        }
        let resumed = try await client.request("session.resume", params: ["session_id": id, "cwd": directory.path, "project_trusted": true])
        XCTAssertEqual(resumed["stored_session_id"] as? String, id)
        _ = try await client.request("prompt.submit", params: ["session_id": id, "turn_id": UUID().uuidString,
            "text": "Repeat the exact marker from the previous turn using conversation context. Do not use tools or change memory."])
        try await wait { result != nil || diagnostic != nil }
        XCTAssertEqual(result?["status"] as? String, "complete", diagnostic ?? "Native Claude resume did not complete")
        XCTAssertTrue((result?["text"] as? String)?.contains(marker) == true)
        XCTAssertGreaterThan(info.context?.used ?? 0, 0)
        XCTAssertGreaterThan(info.context?.limit ?? 0, 0)
    }

    private func wait(_ settled: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        while !settled(), Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(settled(), "Native Claude turn did not settle within 90 seconds")
    }
}
