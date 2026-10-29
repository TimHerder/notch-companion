import XCTest
@testable import NotchCompanion

@MainActor
final class SharedHermesTests: XCTestCase {
    func testOptionalSharedAuthDirectoryNeverTurnsAnEmptyOverrideIntoAWriteDenial() {
        let home = URL(fileURLWithPath: "/fixture-user", isDirectory: true)
        for value in ["", "  \n"] {
            XCTAssertNil(SharedHermesClient.sharedAuthDirectory(environment: ["HERMES_SHARED_AUTH_DIR": value], userHome: home))
        }
        for value in ["~/auth", "auth", " /fixture-user/auth "] {
            XCTAssertEqual(SharedHermesClient.sharedAuthDirectory(environment: ["HERMES_SHARED_AUTH_DIR": value], userHome: home)?.path,
                           "/fixture-user/auth")
        }
    }

    func testFrontendEnvironmentCannotInheritGatewayOwnershipOrAlternateHome() {
        let env = SharedHermesClient.frontendEnvironment([
            "HERMES_DESKTOP": "1", "HERMES_HOME": "/wrong", "HERMES_PROFILE": "wrong",
            "HERMES_SESSION_ID": "external", "CODEX_HOME": "/wrong-codex",
            "PYTHONPATH": "/untrusted", "PYTHONHOME": "/untrusted", "PATH": "/custom/bin",
            "LOCAL_TOOL_SETTING": "kept", "HERMES_API_KEY": "fixture-key-not-a-secret",
            "HERMES_BASE_URL": "http://127.0.0.1:11434/v1", "HERMES_PROVIDER": "custom",
            "HERMES_BROWSER_BACKEND": "fixture-browser", "HERMES_GATEWAY_TOKEN": "discard",
            "HERMES_DASHBOARD_SESSION_TOKEN": "discard", "HERMES_PARENT_SESSION_ID": "discard",
            "HERMES_CONFIG_PATH": "/wrong/config.yaml", "HERMES_COMPUTE_HOST_CHILD": "1",
            "CODEX_APP_TOOLS_PIPE_PATH": "/wrong/pipe"
        ], profile: URL(fileURLWithPath: "/profile"), source: URL(fileURLWithPath: "/source"),
           userHome: URL(fileURLWithPath: "/user"), credential: "ephemeral-test-credential")
        XCTAssertEqual(env["HERMES_HOME"], "/profile")
        XCTAssertEqual(env["HERMES_DASHBOARD_SESSION_TOKEN"], "ephemeral-test-credential")
        XCTAssertEqual(env["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(env["LOCAL_TOOL_SETTING"], "kept")
        XCTAssertEqual(env["HERMES_API_KEY"], "fixture-key-not-a-secret")
        XCTAssertEqual(env["HERMES_BASE_URL"], "http://127.0.0.1:11434/v1")
        XCTAssertEqual(env["HERMES_PROVIDER"], "custom")
        XCTAssertEqual(env["HERMES_BROWSER_BACKEND"], "fixture-browser")
        for key in ["HERMES_DESKTOP", "HERMES_PROFILE", "HERMES_SESSION_ID", "CODEX_HOME", "PYTHONPATH", "PYTHONHOME",
                    "HERMES_GATEWAY_TOKEN", "HERMES_PARENT_SESSION_ID", "HERMES_CONFIG_PATH", "HERMES_COMPUTE_HOST_CHILD",
                    "CODEX_APP_TOOLS_PIPE_PATH"] {
            XCTAssertNil(env[key], key)
        }
        XCTAssertTrue(env["PATH"]!.hasSuffix("/custom/bin"))
    }

    func testReadinessRequiresValidNativeSentinelPort() {
        XCTAssertEqual(SharedHermesClient.readyPort(in: "HERMES_BACKEND_READY port=54321"), 54321)
        XCTAssertEqual(SharedHermesClient.readyPort(in: "HERMES_DASHBOARD_READY port=54322"), 54322)
        XCTAssertNil(SharedHermesClient.readyPort(in: "Listening on port 54321"))
        XCTAssertNil(SharedHermesClient.readyPort(in: "HERMES_BACKEND_READY port=0"))
        XCTAssertNil(SharedHermesClient.readyPort(in: "HERMES_BACKEND_READY port=99999"))
    }

    func testUnsupportedFrontendRequestsSettleWithoutCollectingSecrets() throws {
        for (type, field) in ["sudo.request": "password", "secret.request": "value",
                              "terminal.read.request": "text", "preview.read.request": "text",
                              "preview.act.request": "text", "window.read.request": "text",
                              "tour.request": "text", "mcp.setup.request": "result"] {
            let reply = try XCTUnwrap(SharedHermesClient.unavailableReply(type: type,
                payload: ["session_id": "owned", "request_id": "request", "prompt": "private prompt is not echoed"]))
            XCTAssertEqual(reply.method, String(type.dropLast("request".count)) + "respond")
            XCTAssertEqual(reply.params["session_id"] as? String, "owned")
            XCTAssertEqual(reply.params["request_id"] as? String, "request")
            let text = try XCTUnwrap(reply.params[field] as? String)
            XCTAssertFalse(text.contains("private prompt"))
            if ["sudo.request", "secret.request"].contains(type) {
                XCTAssertEqual(text, "")
            } else {
                let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
                XCTAssertEqual(result["status"], type == "mcp.setup.request" ? "declined" : "unavailable")
            }
        }
        XCTAssertNil(SharedHermesClient.unavailableReply(type: "approval.request", payload: ["request_id": "supported"]))
        XCTAssertNil(SharedHermesClient.unavailableReply(type: "clarify.request", payload: ["request_id": "supported"]))
        XCTAssertNil(SharedHermesClient.unavailableReply(type: "secret.request", payload: [:]))
    }

    /// Accepted keys copied from Hermes 0.21.6+387 typed wire contracts, which
    /// answer 4000 for any other key. Older builds ignored these routing fields.
    func testNativeParamsFitTypedHermesContracts() throws {
        let accepted: [String: Set<String>] = [
            "session.create": ["cwd", "title", "source", "follow_profile_config"],
            "session.resume": ["session_id"],
            "prompt.submit": ["session_id", "text", "surface"]
        ]
        let routing: [String: Any] = ["cwd": "/work", "project_trusted": true, "activity_unverified": false, "pending_turn_id": "turn"]
        let create = SharedHermesClient.nativeParams("session.create", routing.merging(["title": "New session"]) { a, _ in a })
        XCTAssertEqual(Set(create.keys), accepted["session.create"])
        XCTAssertEqual(create["cwd"] as? String, "/work")
        XCTAssertEqual(create["source"] as? String, "notch_companion")
        let resume = SharedHermesClient.nativeParams("session.resume", routing.merging(["session_id": "native"]) { a, _ in a })
        XCTAssertEqual(Set(resume.keys), accepted["session.resume"])
        let submit = SharedHermesClient.nativeParams("prompt.submit", ["session_id": "native", "text": "hi", "surface": "hud", "turn_id": "turn"])
        XCTAssertEqual(Set(submit.keys), accepted["prompt.submit"])
    }

    func testServerRequestsBecomeExistingEventsOrDeclineAtOnce() throws {
        guard case .event(let approval, let payload) = SharedHermesClient.serverRequestOutcome(id: "srq-a", method: "approval",
            params: ["session_id": "owned", "request_id": "queue", "command": "rm -rf build", "choices": ["once", "session", "deny"]]) else {
            return XCTFail("Approvals must reach the existing approval card")
        }
        XCTAssertEqual(approval, "approval.request")
        XCTAssertEqual(payload["request_id"] as? String, "srq-a")
        XCTAssertEqual(payload["command"] as? String, "rm -rf build")

        let questions: [[String: Any]] = [["qid": "q0", "question": "Colour?", "choices": ["Sage"], "multi_select": false],
                                          ["qid": "q1", "question": "Size?", "choices": [], "multi_select": false]]
        guard case .event(let clarify, let replay) = SharedHermesClient.serverRequestOutcome(id: "srq-c", method: "clarify",
            params: ["session_id": "owned", "questions": questions, "answers": ["q0": "Sage"]]) else {
            return XCTFail("Questions must reach the existing clarification card")
        }
        XCTAssertEqual(clarify, "clarify.request")
        XCTAssertEqual((replay["questions"] as? [[String: Any]])?.compactMap { $0["qid"] as? String }, ["q1"])
        XCTAssertNil(replay["answers"])

        for method in ["sudo", "secret", "vault.code", "terminal.read", "tour", "setup_choose", "unknown.future"] {
            guard case .decline(let frame, let notice) = SharedHermesClient.serverRequestOutcome(id: "srq-x", method: method,
                params: ["session_id": "owned", "prompt": "private prompt is not echoed"]) else {
                return XCTFail("\(method) must be declined")
            }
            XCTAssertEqual(frame["id"] as? String, "srq-x")
            XCTAssertEqual((frame["error"] as? [String: Any])?["code"] as? Int, -32601)
            XCTAssertNil(frame["result"])
            XCTAssertFalse(notice.contains("private prompt"))
            XCTAssertEqual(notice.contains("secure input"), ["sudo", "secret", "vault.code"].contains(method), method)
        }
    }

    func testServerRequestAnswersUseResponseFramesAndClarifyLocks() throws {
        guard case .respond(let frame)? = SharedHermesClient.serverRequestAnswer("approval.respond",
            ["session_id": "owned", "request_id": "srq-a", "choice": "once"]) else { return XCTFail("Approval must settle its request") }
        XCTAssertEqual(frame["id"] as? String, "srq-a")
        XCTAssertNil(frame["method"])
        XCTAssertEqual((frame["result"] as? [String: Any])?["choice"] as? String, "once")

        guard case .call(let lock, let params)? = SharedHermesClient.serverRequestAnswer("clarify.respond",
            ["session_id": "owned", "request_id": "srq-c", "question_id": "q1", "answer": "Large"]) else { return XCTFail("Answer must lock") }
        XCTAssertEqual(lock, "clarify.lock")
        XCTAssertEqual(Set(params.keys), ["request_id", "question_id", "answer"])
        XCTAssertEqual(params["answer"] as? String, "Large")
        guard case .call(_, let multi)? = SharedHermesClient.serverRequestAnswer("clarify.respond",
            ["request_id": "srq-c", "question_id": "q2", "answer": "A, B", "answers": ["A", "B"]]) else { return XCTFail() }
        XCTAssertEqual(multi["answer"] as? [String], ["A", "B"])

        // Older Hermes request IDs keep the original *.respond methods.
        XCTAssertNil(SharedHermesClient.serverRequestAnswer("approval.respond", ["request_id": "a1b2c3d4", "choice": "once"]))
        XCTAssertNil(SharedHermesClient.serverRequestAnswer("clarify.respond", ["request_id": "a1b2c3d4", "answer": "Sage"]))
    }

    func testProtectionAllowsNativeStoresAndMemoryButDeniesIdentityAndAuth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-shared-safety-\(UUID().uuidString)")
        let profile = directory.appendingPathComponent("profile")
        let source = directory.appendingPathComponent("source")
        let user = directory.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in [profile.appendingPathComponent("memories"), profile.appendingPathComponent("skills"),
                     profile.appendingPathComponent("profiles"), user.appendingPathComponent(".codex")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let sandbox = SharedHermesClient.protectionProfile(source: source, profile: profile, userHome: user)
        for (path, allowed) in [
            (profile.appendingPathComponent("state.db"), true),
            (profile.appendingPathComponent("memories/MEMORY.md"), true),
            (profile.appendingPathComponent("auth.json"), false),
            (profile.appendingPathComponent("config.yaml"), false),
            (profile.appendingPathComponent(".env"), false),
            (profile.appendingPathComponent("SOUL.md"), false),
            (profile.appendingPathComponent("gateway.pid"), false),
            (profile.appendingPathComponent("skills/new-skill"), false),
            (profile.appendingPathComponent("profiles/new-profile"), false),
            (source.appendingPathComponent("modified-source"), false),
            (user.appendingPathComponent(".codex/auth.json"), false)
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", sandbox, "/usr/bin/touch", path.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus == 0, allowed, path.lastPathComponent)
            XCTAssertEqual(FileManager.default.fileExists(atPath: path.path), allowed, path.lastPathComponent)
        }
    }

    func testProtectedSymlinkTargetsCannotBeWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-shared-symlink-\(UUID().uuidString)")
        let profile = directory.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real-auth.json")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("auth.json"), withDestinationURL: target)
        let sandbox = SharedHermesClient.protectionProfile(source: directory.appendingPathComponent("source"),
                                                           profile: profile, userHome: directory.appendingPathComponent("user"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", sandbox, "/usr/bin/touch", target.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }

    func testNamedProfileKeepsNativeStoresWritableAndProtectsSharedRootAndOtherProfiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-named-profile-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Custom Hermes")
        let profile = root.appendingPathComponent("profiles/work")
        let source = root.appendingPathComponent("hermes-agent")
        let user = directory.appendingPathComponent("user")
        let codex = directory.appendingPathComponent("Custom Codex")
        let sharedAuth = directory.appendingPathComponent("Shared auth")
        let cases: [(URL, Bool)] = [
            (profile.appendingPathComponent("state.db"), true),
            (profile.appendingPathComponent("memories/MEMORY.md"), true),
            (profile.appendingPathComponent("auth.json"), false),
            (profile.appendingPathComponent("config.yaml"), false),
            (profile.appendingPathComponent(".env"), false),
            (profile.appendingPathComponent(".anthropic_oauth.json"), false),
            (profile.appendingPathComponent("skills/changed"), false),
            (profile.appendingPathComponent("profiles/changed"), false),
            (root.appendingPathComponent("auth.json"), false),
            (root.appendingPathComponent("config.yaml"), false),
            (root.appendingPathComponent(".env"), false),
            (root.appendingPathComponent("active_profile"), false),
            (root.appendingPathComponent("shared/nous_auth.json"), false),
            (sharedAuth.appendingPathComponent("nous_auth.json"), false),
            (root.appendingPathComponent("profiles/other/state.db"), false),
            (root.appendingPathComponent("skills/changed"), false),
            (source.appendingPathComponent("changed.py"), false),
            (root.appendingPathComponent("tools/python/bin/changed"), false),
            (root.appendingPathComponent("installs/example/environments/current/venv/lib/changed.py"), false),
            (root.appendingPathComponent("installs/example/environments/current/.leases/owned"), true),
            (codex.appendingPathComponent("auth.json"), false),
            (user.appendingPathComponent(".codex/auth.json"), false),
            (user.appendingPathComponent(".claude/.credentials.json"), false),
            (user.appendingPathComponent(".qwen/oauth_creds.json"), false)
        ]
        for (path, _) in cases {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        XCTAssertEqual(SharedHermesClient.hermesRoot(profile: profile, userHome: user).path, root.resolvingSymlinksInPath().path)
        let sandbox = SharedHermesClient.protectionProfile(source: source, profile: profile, userHome: user,
                                                           codexHome: codex, sharedAuthDirectory: sharedAuth)
        for (path, allowed) in cases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", sandbox, "/usr/bin/touch", path.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus == 0, allowed, path.path)
            XCTAssertEqual(FileManager.default.fileExists(atPath: path.path), allowed, path.path)
        }
    }

    func testNamedProfileExceptionsCannotOpenSourceOrCodexProtectedTrees() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-profile-overlap-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root")
        let profile = root.appendingPathComponent("profiles/work")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        for (immutableRoot, sourceOwnsRoot) in [root, root.appendingPathComponent("profiles")].flatMap({ [($0, true), ($0, false)] }) {
            let sandbox = SharedHermesClient.protectionProfile(
                source: sourceOwnsRoot ? immutableRoot : directory.appendingPathComponent("source"),
                profile: profile, userHome: directory.appendingPathComponent("user"),
                codexHome: sourceOwnsRoot ? directory.appendingPathComponent("codex") : immutableRoot)
            let target = profile.appendingPathComponent("state.db")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", sandbox, "/usr/bin/touch", target.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testMissingProtectedDirectoryCannotBeCreatedThroughTemporaryAlias() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-shared-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sandbox = SharedHermesClient.protectionProfile(source: directory.appendingPathComponent("source"),
                                                           profile: directory, userHome: directory)
        for name in ["skills", "profiles", ".codex", "source"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", sandbox, "/bin/mkdir", directory.appendingPathComponent(name).path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
        }
    }
}
