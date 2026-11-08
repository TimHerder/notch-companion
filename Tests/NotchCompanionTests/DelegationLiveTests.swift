import XCTest
@testable import NotchCompanion

/// Opt-in checks against the installed harnesses. The connection checks send
/// no prompt: Codex opens an ephemeral thread, Claude a session without
/// persistence, Antigravity an empty conversation, each in a temporary folder
/// with the existing profile.
@MainActor final class DelegationLiveTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_DELEGATION_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_DELEGATION_TEST=1 to check the installed Claude Code, Codex and Antigravity CLI.")
        }
    }

    /// Runs a Python driver without blocking the main actor, which serves the MCP requests.
    private func drive(_ script: String, _ arguments: [String]) async throws -> [String: Any] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-live-delegation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let driver = folder.appendingPathComponent("driver.py")
        try Data(script.utf8).write(to: driver)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", driver.path, folder.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        try process.run()
        let data = await reader.value
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() }
        }
        let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any], last)
    }

    private func server() async throws -> (DelegationServer, [String: Any]) {
        let server = DelegationServer()
        server.tools = { _ in Delegation.tools }
        server.instructions = Delegation.instructions
        let url = try await server.start()
        let token = server.issueToken(for: DelegationCaller(sessionID: "live", runtime: .codex, subagent: false))
        return (server, ["url": url.absoluteString, "token": token, "instructions": Delegation.instructions, "read_only_tools": [String]()])
    }

    /// Account-backed: a Claude Code parent delegates to Codex and is woken by
    /// the result, in clearly named sessions in a temporary folder.
    func testClaudeDelegatesToCodexAndIsWokenByTheResult() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_LIVE_DELEGATION_E2E"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_LIVE_DELEGATION_E2E=1 for one account-backed Claude → Codex delegation.")
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/notch-delegation-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "notch-delegation-live-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(Dictionary(uniqueKeysWithValues: [RuntimeKind.claude, .codex].map { ($0.rawValue, RuntimeRoute.defaultProfile($0, defaults: preferences)) }),
                        forKey: "runtime.configuredProfiles")
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: RuntimeRouter(), preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        await model.connect()
        await model.newSession(showPanel: false, runtime: .claude)
        let parentID = try XCTUnwrap(model.currentID)
        let marker = "NOTCH" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        model.renameSession(parentID, title: "Notch Companion delegation verification \(marker)")
        model.update(parentID) { $0.workspacePath = folder.path; $0.trustedProjectPath = folder.standardizedFileURL.resolvingSymlinksInPath().path }
        model.draft = """
        This is an automated check of Notch Companion's delegation tools. Load the notch tools (orchestrator_capabilities, delegate_task) with tool search if they are deferred.
        Call orchestrator_capabilities once, then delegate_task once with target {"runtime": "codex"}, mode "async", title "Notch delegation check \(marker)" and this task: "Reply with exactly \(marker)-CHILD and nothing else. Do not use tools or edit files."
        Then end your turn. When the delegation result arrives, reply with exactly the child's reply and nothing else. Do not edit files.
        """
        await model.send()
        let deadline = Date().addingTimeInterval(300)
        func parent() -> CompanionSession? { model.sessions.first { $0.id == parentID } }
        while Date() < deadline {
            if let session = parent(), !session.isBusy, session.messages.contains(where: \.isDelegationResult),
               session.latestResponse.contains("\(marker)-CHILD") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let child = try XCTUnwrap(model.sessions.first { $0.parentSessionID == parentID }, model.errorMessage ?? "No child was created")
        XCTAssertEqual(child.runtime, .codex)
        XCTAssertTrue(child.latestResponse.contains("\(marker)-CHILD"), child.latestResponse)
        XCTAssertFalse(model.visibleSessions.contains { $0.id == child.id })
        let session = try XCTUnwrap(parent())
        XCTAssertTrue(session.tools.contains { ToolActivity.delegationTool($0.name) == "delegate_task" }, "\(session.tools.map(\.name))")
        XCTAssertTrue(session.messages.contains(where: \.isDelegationResult), "The result woke the parent")
        XCTAssertTrue(session.latestResponse.contains("\(marker)-CHILD"), session.latestResponse)
        XCTAssertFalse(model.hasActiveWork)
    }

    /// No prompt: an owned OpenCode 2 server opens one session in a temporary
    /// folder. Its data, state and cache live in that folder, so the disposable
    /// session stays out of the user's history; the native configuration is
    /// only read.
    func testInstalledOpenCodeConnectsTheSessionsOwnServer() async throws {
        try requireLive()
        let supervisor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/NotchCompanion")
        guard FileManager.default.isExecutableFile(atPath: supervisor.path) else { throw XCTSkip("Build the app product first.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-live-opencode-\(UUID().uuidString)")
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = RuntimeRoute.defaultProfile(.opencode)
        func configuration() -> [String] {
            (FileManager.default.subpaths(atPath: profile) ?? []).sorted().map { path in
                let values = try? FileManager.default.attributesOfItem(atPath: profile + "/" + path)
                return "\(path) \((values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(values?[.size] ?? 0)"
            }
        }
        let before = configuration()
        let keys = ["XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]
        let saved = keys.map { ProcessInfo.processInfo.environment[$0] }
        for key in keys { setenv(key, folder.appendingPathComponent(key).path, 1) }
        defer { for (key, value) in zip(keys, saved) { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }

        let server = DelegationServer()
        defer { server.stop() }
        let caller = DelegationCaller(sessionID: "live-opencode", runtime: .opencode, subagent: false)
        var listedBy: [DelegationCaller] = []
        server.tools = { listedBy.append($0); return Delegation.tools }
        server.instructions = Delegation.instructions
        let url = try await server.start()
        let client = OpenCodeClient(profileID: profile, supervisorURL: supervisor)
        var notices: [String] = []
        client.onEvent = { name, payload in if name == "runtime.notice" { notices.append(payload["message"] as? String ?? "") } }
        defer { client.disconnect() }
        try await client.connect()
        let result = try await client.request("session.create", params: [
            "cwd": project.path, "title": "Notch Companion delegation check",
            "delegation": ["url": url.absoluteString, "token": server.issueToken(for: caller), "instructions": Delegation.instructions]])
        guard result["hosts_delegation"] as? Bool == true else { throw XCTSkip("The installed OpenCode cannot host delegation (1.x).") }
        let deadline = Date().addingTimeInterval(20)
        while listedBy.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(listedBy.first, caller, "OpenCode connected the session's own server with its token")
        XCTAssertEqual(notices, [], "Rules, instructions and the server were all accepted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("XDG_DATA_HOME").path), "The session stayed in the temporary data folder")
        client.disconnect()
        XCTAssertEqual(configuration(), before, "The native configuration is unchanged")
    }

    func testInstalledPiLoadsTheExtensionAndListsTheTools() async throws {
        try requireLive()
        let server = DelegationServer()
        defer { server.stop() }
        let caller = DelegationCaller(sessionID: "live-pi", runtime: .pi, subagent: false)
        var listedBy: [DelegationCaller] = []
        server.tools = { listedBy.append($0); return Delegation.tools }
        server.instructions = Delegation.instructions
        let url = try await server.start()
        let executable = try RuntimeInstallation.executable(for: .pi)
        var environment = RuntimeEnvironment.native(runtime: .pi, profileID: RuntimeRoute.defaultProfile(.pi))
        let arguments = ["--mode", "rpc", "--no-session"]
            + PiClient.delegationArguments(["url": url.absoluteString, "token": server.issueToken(for: caller)], environment: &environment)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-live-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = folder
        let input = Pipe()
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(30)
        while listedBy.isEmpty, Date() < deadline, process.isRunning { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertEqual(listedBy.first, caller, "Pi loaded the extension, which listed the tools with this session's token")
    }

    func testInstalledCodexConnectsToTheServerFromItsThreadConfig() async throws {
        try requireLive()
        let (server, delegation) = try await server()
        defer { server.stop() }
        let executable = try RuntimeInstallation.codex(environment: ProcessInfo.processInfo.environment,
                                                       userHome: FileManager.default.homeDirectoryForCurrentUser, configuredExecutable: nil)
        let config = String(decoding: try JSONSerialization.data(withJSONObject: CodexClient.delegationConfig(delegation)), as: UTF8.self)
        let result = try await drive(#"""
        import json, subprocess, sys, os
        folder, codex, home, config = sys.argv[1:5]
        env = dict(os.environ, CODEX_HOME=home)
        for key in [k for k in env if k.startswith(("CODEX_THREAD_", "CODEX_SESSION_", "CODEX_INTERNAL_"))]: env.pop(key)
        p = subprocess.Popen([codex, "app-server", "--listen", "stdio://"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd=folder, text=True)
        def rpc(i, method, params):
            p.stdin.write(json.dumps({"id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
            while True:
                frame = json.loads(p.stdout.readline())
                if frame.get("id") == i: return frame
        rpc(1, "initialize", {"clientInfo": {"name": "notch_companion_live_check", "version": "0"}, "capabilities": {"experimentalApi": True}})
        p.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n"); p.stdin.flush()
        thread = rpc(2, "thread/start", {"ephemeral": True, "cwd": folder, "config": json.loads(config)})["result"]["thread"]["id"]
        status = rpc(3, "mcpServerStatus/list", {"threadId": thread, "serverName": "notch"})
        p.stdin.close(); p.wait(timeout=10)
        print(json.dumps(status))
        """#, [executable.path, RuntimeRoute.defaultProfile(.codex), config])
        let rows = try XCTUnwrap((result["result"] as? [String: Any])?["data"] as? [[String: Any]], "\(result)")
        let notch = try XCTUnwrap(rows.first { $0["name"] as? String == "notch" }, "\(rows)")
        let tools = (notch["tools"] as? [String: Any]).map { Array($0.keys) } ?? (notch["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(tools.contains("delegate_task"), "\(notch)")
    }

    func testInstalledClaudeConnectsToTheServerSentOverStdin() async throws {
        try requireLive()
        let (server, delegation) = try await server()
        defer { server.stop() }
        let executable = try RuntimeInstallation.executable(for: .claude)
        let arguments = try ClaudeClient.arguments(id: UUID().uuidString.lowercased(), resume: false, delegation: delegation) + ["--no-session-persistence"]
        let servers = String(decoding: try JSONSerialization.data(withJSONObject: ClaudeClient.delegationServers(delegation)), as: UTF8.self)
        let result = try await drive(#"""
        import json, subprocess, sys, os
        folder, claude, servers, instructions = sys.argv[1:5]
        args = json.loads(sys.argv[5])
        env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT")}
        p = subprocess.Popen([claude] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd=folder, text=True)
        def control(i, request):
            p.stdin.write(json.dumps({"type": "control_request", "request_id": i, "request": request}) + "\n"); p.stdin.flush()
            while True:
                frame = json.loads(p.stdout.readline())
                if frame.get("type") == "control_response" and frame["response"].get("request_id") == i: return frame["response"]
        control("1", {"subtype": "initialize", "forwardSubagentText": True, "appendSystemPrompt": instructions})
        added = control("2", {"subtype": "mcp_set_servers", "servers": json.loads(servers)})
        status = control("3", {"subtype": "mcp_status"})
        p.stdin.close(); p.wait(timeout=20)
        print(json.dumps({"added": added, "status": status}))
        """#, [executable.path, servers, Delegation.instructions,
               String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)])
        let added = (result["added"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(added?["added"] as? [String], ["notch"], "\(result)")
        XCTAssertTrue((added?["errors"] as? [String: Any])?.isEmpty ?? true, "\(result)")
        let status = ((result["status"] as? [String: Any])?["response"] as? [String: Any])?["mcpServers"] as? [[String: Any]] ?? []
        let notch = try XCTUnwrap(status.first { $0["name"] as? String == "notch" }, "\(result)")
        XCTAssertEqual(notch["status"] as? String, "connected", "\(notch)")
    }

    /// No prompt: `agy acp` opens one empty conversation in a temporary folder, starts
    /// the companion's stdio bridge from `session/new` and lists the tools with the session's token.
    func testInstalledAntigravityStartsTheBridgeFromItsACPSession() async throws {
        try requireLive()
        let bridge = ProcessInfo.processInfo.environment["NOTCH_TEST_APP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/NotchCompanion")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else { throw XCTSkip("Build the app product first.") }
        let server = DelegationServer()
        defer { server.stop() }
        var listed: [DelegationCaller] = []
        server.tools = { caller in listed.append(caller); return Delegation.tools }
        server.instructions = Delegation.instructions
        let url = try await server.start()
        let caller = DelegationCaller(sessionID: "live-antigravity", runtime: .antigravity, subagent: false)
        let delegation: [String: Any] = ["url": url.absoluteString, "token": server.issueToken(for: caller), "bridge": bridge.path,
                                         "instructions": Delegation.instructions]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-live-antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = ACPRuntimeClient(runtime: .antigravity, profileID: RuntimeRoute.defaultProfile(.antigravity))
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": folder.path, "project_trusted": true, "delegation": delegation])
        XCTAssertNotNil(opened["session_id"] as? String)
        for _ in 0..<150 where listed.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(listed.first, caller, "agy started the bridge with this session's token and listed the tools")
    }
}
