import XCTest
@testable import NotchCompanion

@MainActor private final class PermissionFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if method == "session.create" || method == "session.resume" { return ["session_id": "live", "stored_session_id": "saved"] }
        return [:]
    }
}

@MainActor final class PermissionModeTests: XCTestCase {
    func testRegistryRoundTripKeepsModeAndUnknownModesFallBackToInherit() throws {
        var session = CompanionSession()
        session.runtime = .codex
        session.permissionMode = .autoEdit
        session.fullAccessConfirmed = true
        let data = try JSONEncoder().encode([session])
        let restored = try XCTUnwrap(JSONDecoder().decode([CompanionSession].self, from: data).first)
        XCTAssertEqual(restored.permissionMode, .autoEdit)
        XCTAssertTrue(restored.fullAccessConfirmed)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first!
        row["permissionMode"] = "futureMode"
        row.removeValue(forKey: "fullAccessConfirmed")
        let future = try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(future.permissionMode, "An unknown mode must not discard the conversation")
        XCTAssertFalse(future.fullAccessConfirmed)
        // Capabilities saved before this field existed still get the static mapping.
        var old = CompanionSession(); old.runtime = .claude
        old.runtimeInfo = RuntimeSessionInfo(capabilities: RuntimeCapabilities(resume: true))
        XCTAssertEqual(old.capabilities.supportedPermissionModes, PermissionMode.allCases)
        old.runtime = .hermes
        XCTAssertEqual(old.capabilities.supportedPermissionModes, [], "Harnesses without a mapping hide the picker")
    }

    func testBusySessionRejectsChangeAndFullAccessAsksOnceBeforeApplyingOnSend() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "notch-permission-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let transport = PermissionFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport, preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(model.showPermissionModes, "The control is off by default")
        await model.connect()
        await model.newSession(showPanel: false, runtime: .codex)
        let id = try XCTUnwrap(model.currentID)
        model.sessions[0].state = .working
        model.setPermissionMode(.plan, for: id)
        XCTAssertNil(model.current?.permissionMode, "A busy session rejects a change")
        model.sessions[0].state = .idle
        model.sessions[0].agents = [ChildAgent(id: "child", title: "Child", state: .working)]
        model.setPermissionMode(.plan, for: id)
        XCTAssertNil(model.current?.permissionMode, "A busy delegated child rejects a change")
        model.sessions[0].agents = []
        var prompts = 0
        model.fullAccessDecision = { _ in prompts += 1; return false }
        model.setPermissionMode(.fullAccess, for: id)
        XCTAssertNil(model.current?.permissionMode, "Declining keeps the previous mode")
        model.fullAccessDecision = { _ in prompts += 1; return true }
        model.setPermissionMode(.fullAccess, for: id)
        model.setPermissionMode(.plan, for: id)
        model.setPermissionMode(.fullAccess, for: id)
        XCTAssertEqual(prompts, 2, "Full access is confirmed once per session")
        XCTAssertEqual(model.current?.permissionMode, .fullAccess)
        XCTAssertTrue(transport.calls.isEmpty, "Choosing a mode sends nothing")
        model.draft = "Go"
        await model.send()
        // The model picker, on by default, also reads the catalog after create.
        XCTAssertEqual(transport.calls.map(\.0).filter { $0 != "runtime.models" }, ["session.create", "session.permission.set", "prompt.submit"])
        XCTAssertEqual(transport.calls[0].1["permission_mode"] as? String, "fullAccess")
        XCTAssertEqual(transport.calls[1].1["mode"] as? String, "fullAccess")
        model.sessions[0].state = .idle
        model.setPermissionMode(nil, for: id)
        XCTAssertNil(model.current?.permissionMode)
        model.draft = "Again"
        await model.send()
        let inherit = try XCTUnwrap(transport.calls.last(where: { $0.0 == "session.permission.set" })?.1)
        XCTAssertNil(inherit["mode"], "Inherit removes the override")
        await model.newSession(showPanel: false, runtime: .hermes)
        model.draft = "Hermes"
        let before = transport.calls.count
        await model.send()
        XCTAssertFalse(transport.calls[before...].contains { $0.0 == "session.permission.set" }, "Unmapped harnesses never receive a mode")
    }

    func testCodexOverrideGoesOnTurnStartOnlyWhenSetAndInheritRestoresOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-codex-permission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("codex-peer")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        for line in sys.stdin:
            frame = json.loads(line)
            if "id" not in frame: continue
            method, params = frame["method"], frame.get("params", {})
            with open(os.path.join(os.environ["CODEX_HOME"], "wire.jsonl"), "a") as f:
                f.write(json.dumps({"method": method, "params": params}) + "\n")
            result = {}
            if method == "thread/start":
                result = {"thread": {"id": "thread"}, "model": "thread-model", "approvalPolicy": "untrusted",
                          "sandbox": {"type": "workspaceWrite", "networkAccess": True, "writableRoots": ["/extra"]}}
            if method == "turn/start":
                result = {"turn": {"id": "turn", "status": "completed"}}
            print(json.dumps({"id": frame["id"], "result": result}), flush=True)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CodexClient(profileID: folder.path, executable: executable)
        defer { client.disconnect() }
        try await client.connect()
        let sid = try await client.request("session.create", params: [:])["session_id"] as! String
        for mode in [nil, "fullAccess", "plan", nil, nil, "autoEdit", "ask"] as [String?] {
            var params: [String: Any] = ["session_id": sid]
            if let mode { params["mode"] = mode }
            _ = try await client.request("session.permission.set", params: params)
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "fixture"])
        }
        let wire = try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(wire.compactMap { $0["method"] as? String }.filter { $0 != "initialize" },
                       ["thread/start"] + Array(repeating: "turn/start", count: 7), "Staging a mode sends nothing by itself")
        let turns = wire.filter { $0["method"] as? String == "turn/start" }.map { $0["params"] as! [String: Any] }
        func policy(_ turn: [String: Any]) -> String? { turn["approvalPolicy"] as? String }
        func sandbox(_ turn: [String: Any]) -> String? { (turn["sandboxPolicy"] as? [String: Any])?["type"] as? String }
        func plan(_ turn: [String: Any]) -> String? { (turn["collaborationMode"] as? [String: Any])?["mode"] as? String }
        XCTAssertNil(policy(turns[0])); XCTAssertNil(turns[0]["sandboxPolicy"]); XCTAssertNil(turns[0]["collaborationMode"])
        XCTAssertEqual(policy(turns[1]), "never"); XCTAssertEqual(sandbox(turns[1]), "dangerFullAccess")
        XCTAssertEqual(policy(turns[2]), "untrusted", "Plan returns approvals to the thread's own policy")
        XCTAssertEqual(plan(turns[2]), "plan")
        XCTAssertEqual(((turns[2]["collaborationMode"] as? [String: Any])?["settings"] as? [String: Any])?["model"] as? String, "thread-model")
        XCTAssertNil(policy(turns[3])); XCTAssertEqual(plan(turns[3]), "default", "Inherit leaves plan mode once")
        XCTAssertNil(policy(turns[4])); XCTAssertNil(turns[4]["collaborationMode"], "Then nothing is sent")
        XCTAssertEqual(policy(turns[5]), "on-request")
        XCTAssertEqual((turns[5]["sandboxPolicy"] as? [String: Any])?["writableRoots"] as? [String], ["/extra"], "Auto-edit keeps the profile's workspace roots")
        XCTAssertEqual(sandbox(turns[6]), "readOnly")
        do {
            _ = try await client.request("session.permission.set", params: ["session_id": sid, "mode": "unknown"])
            XCTFail("An unmapped mode must be rejected")
        } catch {}
    }

    func testCodexRejectedPermissionAndPlanResetsAreRetriedUntilAccepted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-codex-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("codex-peer")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        for line in sys.stdin:
            frame = json.loads(line)
            if "id" not in frame: continue
            method, params = frame["method"], frame.get("params", {})
            with open(os.path.join(os.environ["CODEX_HOME"], "wire.jsonl"), "a") as log:
                log.write(json.dumps({"method": method, "params": params}) + "\n")
            result = {}
            if method == "thread/start":
                result = {"thread": {"id": "thread"}, "model": "thread-model",
                          "approvalPolicy": "on-request", "sandbox": {"type": "readOnly"}}
            if method == "turn/start":
                if params["input"][0]["text"] == "unacknowledged override":
                    turn = {"id": str(frame["id"]), "status": "inProgress"}
                    print(json.dumps({"method": "turn/started", "params": {"threadId": "thread", "turn": turn}}), flush=True)
                    turn["status"] = "completed"
                    print(json.dumps({"method": "turn/completed", "params": {"threadId": "thread", "turn": turn}}), flush=True)
                    print(json.dumps({"id": frame["id"], "error": {"code": -32603, "message": "Lost successful reply"}}), flush=True)
                    continue
                if params["input"][0]["text"] == "reject reset":
                    print(json.dumps({"id": frame["id"], "error": {"code": -32600, "message": "Rejected before applying reset"}}), flush=True)
                    continue
                result = {"turn": {"id": "turn", "status": "completed"}}
            print(json.dumps({"id": frame["id"], "result": result}), flush=True)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CodexClient(profileID: folder.path, executable: executable)
        defer { client.disconnect() }
        try await client.connect()
        let created = try await client.request("session.create", params: [:])
        let sid = try XCTUnwrap(created["session_id"] as? String)
        for (index, mode) in ["fullAccess", "plan", "fullAccess", "plan"].enumerated() {
            _ = try await client.request("session.permission.set", params: ["session_id": sid, "mode": mode])
            do {
                _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": index < 2 ? "override" : "unacknowledged override"])
                XCTAssertLessThan(index, 2, "The last two overrides emit completion but no successful reply")
            } catch CodexClientError.rpc { XCTAssertGreaterThanOrEqual(index, 2) }
            _ = try await client.request("session.permission.set", params: ["session_id": sid])
            do {
                _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "reject reset"])
                XCTFail("The fixture must reject the first reset")
            } catch CodexClientError.rpc { }
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "retry"])
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "after reset"])
        }
        let turns = try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            .filter { $0["method"] as? String == "turn/start" }.map { $0["params"] as! [String: Any] }
        XCTAssertEqual(turns.count, 16)
        for index in [1, 2, 9, 10] {
            XCTAssertEqual(turns[index]["approvalPolicy"] as? String, "on-request")
            XCTAssertEqual((turns[index]["sandboxPolicy"] as? [String: Any])?["type"] as? String, "readOnly")
        }
        for index in [5, 6, 13, 14] {
            XCTAssertEqual((turns[index]["collaborationMode"] as? [String: Any])?["mode"] as? String, "default")
        }
        for index in [3, 7, 11, 15] {
            XCTAssertNil(turns[index]["approvalPolicy"])
            XCTAssertNil(turns[index]["sandboxPolicy"])
            XCTAssertNil(turns[index]["collaborationMode"], "An accepted reset is only sent once")
        }
    }

    func testClaudeDisconnectDuringFullAccessReopenDoesNotLaunchAnOrphan() async throws {
        for reconnect in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-claude-reopen-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let executable = folder.appendingPathComponent("claude-peer")
            let source = #"""
            #!/usr/bin/python3
            import json, pathlib, sys, time
            with open("launches", "a") as log: log.write("launch\n")
            for line in sys.stdin:
                frame = json.loads(line)
                if frame.get("type") != "control_request": continue
                kind = frame["request"]["subtype"]
                body = {}
                if kind == "initialize": body = {"models": []}
                if kind == "get_settings": body = {"effective": {"permissions": {"defaultMode": "default"}}}
                if kind == "set_permission_mode": body = {"mode": frame["request"]["mode"]}
                print(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": frame["request_id"], "response": body}}), flush=True)
            pathlib.Path("stopping").touch()
            deadline = time.monotonic() + 3
            while not pathlib.Path("release").exists() and time.monotonic() < deadline: time.sleep(0.01)
            """#
            try Data(source.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let client = ClaudeClient(profileID: folder.path, executableURL: executable)
            defer { client.disconnect() }
            try await client.connect()
            let created = try await client.request("session.create", params: ["cwd": folder.path, "project_trusted": true])
            let sid = try XCTUnwrap(created["session_id"] as? String)
            let reopen = Task { try await client.request("session.permission.set", params: ["session_id": sid, "mode": "fullAccess"]) }
            let marker = folder.appendingPathComponent("stopping")
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The old process must be retiring before disconnect")
            client.disconnect()
            if reconnect { try await client.connect() }
            try Data().write(to: folder.appendingPathComponent("release"))
            do { _ = try await reopen.value; XCTFail("A disconnected session must not reopen even if the adapter reconnects") }
            catch { XCTAssertTrue(error.localizedDescription.contains("connection changed"), error.localizedDescription) }
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("launches"), encoding: .utf8), "launch\n")
        }
    }

    func testClaudeAppliesModeByControlRestoresProfileModeAndReopensOnlyForFullAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-claude-permission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        let source = #"""
        #!/usr/bin/env python3
        import json, os, sys
        bypass = '--allow-dangerously-skip-permissions' in sys.argv
        log = open(os.path.join(os.getcwd(), 'wire.jsonl'), 'a')
        log.write(json.dumps({'launch': bypass}) + '\n'); log.flush()
        for line in sys.stdin:
            frame = json.loads(line)
            if frame['type'] != 'control_request': continue
            request = frame['request']; kind = request['subtype']
            log.write(json.dumps({'control': kind, 'mode': request.get('mode')}) + '\n'); log.flush()
            body = {}
            if kind == 'initialize': body = {'models': [], 'session_state': 'idle', 'current_permission_mode': 'plan'}
            if kind == 'get_settings': body = {'effective': {'permissions': {'defaultMode': 'acceptEdits'}}, 'applied': {'model': 'm', 'effort': None}}
            if kind == 'set_permission_mode':
                if request['mode'] == 'bypassPermissions' and not bypass:
                    print(json.dumps({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': frame['request_id'], 'error': 'bypass_not_launched'}}), flush=True)
                    continue
                body = {'mode': request['mode']}
            print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': body}}), flush=True)
        """#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let created = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(created["session_id"] as? String)
        XCTAssertEqual((created["info"] as? [String: Any])?["profile_permission_mode"] as? String, "plan", "Default first names the mode the process opened in")
        var restored: [String] = []
        client.onEvent = { name, payload in
            if name == "session.info", let mode = payload["profile_permission_mode"] as? String { restored.append(mode) }
        }
        for mode in [nil, "plan", nil, nil, "fullAccess", "fullAccess"] as [String?] {
            var params: [String: Any] = ["session_id": id]
            if let mode { params["mode"] = mode }
            _ = try await client.request("session.permission.set", params: params)
        }
        XCTAssertEqual(restored, ["autoEdit"], "Returning to Default names the configured mode it restored, not the opening one")
        let wire = try String(contentsOf: directory.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            .map { row -> String in
                if let launch = row["launch"] as? Bool { return launch ? "launch+bypass" : "launch" }
                return [row["control"] as? String, row["mode"] as? String].compactMap { $0 }.joined(separator: ":")
            }
        // Each launch first reads the profile's Ultracode.
        XCTAssertEqual(wire, ["launch", "initialize", "get_settings",
                              "get_settings", "set_permission_mode:plan",
                              "set_permission_mode:acceptEdits",
                              "get_settings", "launch+bypass", "initialize", "get_settings", "set_permission_mode:bypassPermissions",
                              "set_permission_mode:bypassPermissions"],
                       "Inherit sends nothing until an override exists, then restores the profile's mode once")
        let reopened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true, "permission_mode": "fullAccess"])
        XCTAssertNotNil(reopened["session_id"])
        XCTAssertEqual(try ClaudeClient.arguments(id: id, resume: true, allowBypass: true).last, "--allow-dangerously-skip-permissions")
        XCTAssertFalse(try ClaudeClient.arguments(id: id, resume: true).contains("--allow-dangerously-skip-permissions"))
    }

    func testACPOffersOnlyAdvertisedModesAndRestoresOpeningMode() async throws {
        XCTAssertEqual(ACPProtocolState.permissionModes(["availableModes": [["id": "default"], ["id": "plan"], ["id": "architect"]]]),
                       [.ask: "default", .plan: "plan"], "Unrecognised modes are not offered")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-acp-permission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("acp-peer")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        log = open(os.path.join(os.environ["OPENCODE_CONFIG_DIR"], "wire.jsonl"), "a")
        for line in sys.stdin:
            frame = json.loads(line)
            method, params = frame.get("method"), frame.get("params", {})
            log.write(json.dumps({"method": method, "mode": params.get("modeId")}) + "\n"); log.flush()
            result = {}
            if method == "initialize": result = {"protocolVersion": 1, "agentCapabilities": {}}
            if method == "session/new":
                result = {"sessionId": "native", "modes": {"currentModeId": "default",
                          "availableModes": [{"id": "default", "name": "Default"}, {"id": "acceptEdits", "name": "Accept edits"}]}}
            print(json.dumps({"jsonrpc": "2.0", "id": frame["id"], "result": result}), flush=True)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ACPRuntimeClient(runtime: .opencode, profileID: root.path, executableOverride: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": root.path])
        let sid = try XCTUnwrap(opened["session_id"] as? String)
        let capabilities = (opened["info"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertEqual(capabilities?["permissionModes"] as? [String], ["ask", "autoEdit"])
        _ = try await client.request("session.permission.set", params: ["session_id": sid])
        _ = try await client.request("session.permission.set", params: ["session_id": sid, "mode": "autoEdit"])
        _ = try await client.request("session.permission.set", params: ["session_id": sid])
        _ = try await client.request("session.permission.set", params: ["session_id": sid])
        do {
            _ = try await client.request("session.permission.set", params: ["session_id": sid, "mode": "plan"])
            XCTFail("A mode the agent did not advertise must be rejected")
        } catch {}
        let modes = try String(contentsOf: root.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            .filter { $0["method"] as? String == "session/set_mode" }.compactMap { $0["mode"] as? String }
        XCTAssertEqual(modes, ["acceptEdits", "default"])
    }
}
