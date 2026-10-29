import XCTest
@testable import NotchCompanion

/// Opt-in installed-runtime startup checks. Only an authenticated connection is
/// opened: no sessions, prompts, tools, accounts, or provider requests are used.
@MainActor final class SharedHermesStartupTests: XCTestCase {
    func testAPIKeyOnlyRootProfileReachesAuthenticatedReadiness() async throws {
        try await connectFixture(named: false)
    }

    func testAPIKeyOnlyNamedProfileReachesAuthenticatedReadiness() async throws {
        try await connectFixture(named: true)
    }

    func testExistingProfileCatalogAndSessionEffortWithoutPrompt() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_HERMES_PROFILE_CHECK"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_HERMES_PROFILE_CHECK=1 for the existing profile's connection/catalog/session effort check; no prompts.")
        }
        let profile = URL(fileURLWithPath: RuntimeRoute.defaultProfile(.hermes))
        let protected = ["config.yaml", ".env", "auth.json", "SOUL.md", "gateway.pid", "gateway.lock"].map { profile.appendingPathComponent($0) }
        let before = protected.map { try? Data(contentsOf: $0) }
        let client = SharedHermesClient()
        defer { client.disconnect() }
        try await client.connect()
        let result = try await client.request("runtime.models", params: [:])
        let catalog = try XCTUnwrap(result["catalog"] as? RuntimeModelCatalog)
        XCTAssertNotNil(catalog.defaultModel)
        XCTAssertFalse(catalog.models.isEmpty)
        let option = try XCTUnwrap(catalog.models.first { $0.choice.model == catalog.defaultModel?.model && !$0.reasoningEfforts.isEmpty })
        let effort = option.reasoningEfforts.contains("high") ? "high" : option.reasoningEfforts[0]
        let created = try await client.request("session.create", params: ["title": "Notch Companion effort verification — no prompt", "cwd": FileManager.default.temporaryDirectory.path])
        let sid = try XCTUnwrap(created["session_id"] as? String)
        let applied = try await client.request("session.model.set", params: ["session_id": sid, "model": option.choice.model,
            "provider": try XCTUnwrap(option.choice.provider), "reasoning_effort": effort])
        XCTAssertNotEqual(applied["confirm_required"] as? Bool, true)
        let reported = try await client.request("config.get", params: ["session_id": sid, "key": "reasoning"])
        XCTAssertEqual(reported["value"] as? String, effort)
        _ = try await client.request("session.close", params: ["session_id": sid])
        XCTAssertEqual(before, protected.map { try? Data(contentsOf: $0) })
    }

    private func connectFixture(named: Bool) async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_HERMES_STARTUP_TESTS"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_HERMES_STARTUP_TESTS=1 for installed Hermes startup checks using fake credentials only.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-startup-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("Hermes")
        let namedProfile = root.appendingPathComponent("profiles/fixture")
        let profile = named ? namedProfile : root
        try FileManager.default.createDirectory(at: namedProfile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Managed Hermes requires an already configured dependency selection.
        // Reuse only its native installation state; fake profiles still own all
        // config/auth/session data and cannot provision packages during this test.
        let installs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/installs")
        if FileManager.default.fileExists(atPath: installs.path) {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("installs"), withDestinationURL: installs)
        }
        let configuration = """
        model:
          default: openai/gpt-4.1-mini
          provider: openrouter
          base_url: http://127.0.0.1:9/v1
        dashboard:
          turn_isolation: false
        sessions:
          auto_archive: false
        local_runtime:
          enabled: false
        """
        let environment = """
        OPENROUTER_API_KEY=fixture-openrouter-key-not-real
        OPENROUTER_BASE_URL=http://127.0.0.1:9/v1
        OPENAI_API_KEY=
        OPENAI_BASE_URL=http://127.0.0.1:9/v1
        HERMES_PROVIDER=openrouter
        """
        var protected: [URL: Data] = [:]
        for folder in [root, namedProfile] {
            // Native setup creates these before a profile is usable; startup
            // must not seed protected skills or identity on behalf of a user.
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("skills"), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            for (name, contents) in [("config.yaml", configuration), (".env", environment),
                                     ("SOUL.md", "Startup fixture identity. No tasks or provider calls.\n")] {
                let path = folder.appendingPathComponent(name)
                let data = Data(contents.utf8)
                try data.write(to: path)
                protected[path] = data
            }
        }
        let activeProfile = root.appendingPathComponent("active_profile")
        let activeData = Data((named ? "default\n" : "fixture\n").utf8)
        try activeData.write(to: activeProfile)
        protected[activeProfile] = activeData

        let client = SharedHermesClient(profileID: profile.resolvingSymlinksInPath().path)
        var connected = false
        var receivedReady = false
        client.onConnectionChange = { state, _ in connected = state }
        client.onEvent = { name, _ in if name == "gateway.ready" { receivedReady = true } }
        defer { client.disconnect() }
        let connection = Task { try await client.connect() }
        // Observe only this adapter's owned Process, allowing cleanup to be
        // verified without enumerating unrelated commands or adding app API.
        var ownedProcess: Process?
        for _ in 0..<100 where ownedProcess == nil {
            await Task.yield()
            ownedProcess = Mirror(reflecting: client).children.first { $0.label == "process" }?.value as? Process
            if ownedProcess == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        var startupError: Error?
        do { try await connection.value } catch { startupError = error }
        if startupError == nil {
            XCTAssertTrue(connected)
            XCTAssertTrue(receivedReady, "The native authenticated WebSocket must deliver gateway.ready.")
            XCTAssertTrue(ownedProcess?.isRunning == true)
        }
        client.disconnect()
        let deadline = Date().addingTimeInterval(35)
        while ownedProcess?.isRunning == true && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(connected)
        XCTAssertFalse(ownedProcess?.isRunning == true, "Disconnect must stop only the owned fixture frontend.")
        for (path, data) in protected { XCTAssertEqual(try Data(contentsOf: path), data, path.lastPathComponent) }
        for folder in [root, namedProfile] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("auth.json").path))
        }
        if let startupError { throw startupError }
        XCTAssertNotNil(ownedProcess, "The test must observe the owned frontend to verify cleanup.")
    }
}
