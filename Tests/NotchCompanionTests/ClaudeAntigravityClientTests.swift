import XCTest
@testable import NotchCompanion

@MainActor
final class ClaudeAntigravityClientTests: XCTestCase {
    func testClaudeSteeringUsesHumanPriorityAndExactReceiptsWithoutEndingOriginalWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-claude-steer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude-fixture")
        try #"""
        #!/usr/bin/env python3
        import json, sys, time
        sid=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--session-id='))
        def emit(value):
            value['session_id']=sid
            print(json.dumps(value),flush=True)
        for line in sys.stdin:
            frame=json.loads(line)
            if frame['type']=='control_request':
                emit({'type':'control_response','response':{'subtype':'success','request_id':frame['request_id'],'response':{'models':[]}}})
                continue
            text=frame['message']['content'][0]['text']
            if text=='Original':
                emit({'type':'system','subtype':'init','claude_code_version':'2.1.287','model':'fixture'})
                emit({'type':'system','subtype':'session_state_changed','state':'running'})
                emit(frame)
                emit({'type':'assistant','message':{'content':[{'type':'tool_use','id':'sleep','name':'Bash','input':{'command':'sleep 8'}}]}})
                continue
            assert frame['priority']=='now' and frame['origin']=={'kind':'human'}
            assert frame['uuid']!='original' and frame['parent_tool_use_id'] is None
            if text=='refuse':
                emit({'type':'command_lifecycle','command_uuid':frame['uuid'],'state':'refused'})
                continue
            assert frame['message']['content'][1]['source']['media_type']=='image/png'
            emit({'type':'command_lifecycle','command_uuid':'unrelated','state':'queued'})
            emit({'type':'result','result':'Original result must not settle pending input','is_error':False})
            emit({'type':'command_lifecycle','command_uuid':frame['uuid'],'state':'queued'})
            emit({'type':'command_lifecycle','command_uuid':frame['uuid'],'state':'started'})
            emit({'type':'system','subtype':'task_started','task_id':'background-shell','tool_use_id':'sleep','description':'Running command'})
            emit({'type':'result','result':'Steered answer','is_error':False})
            emit({'type':'system','subtype':'session_state_changed','state':'idle'})
            time.sleep(0.05)
            emit({'type':'system','subtype':'task_notification','task_id':'background-shell','status':'completed'})
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let sid = try XCTUnwrap(opened["session_id"] as? String)
        XCTAssertTrue((opened["info"] as? [String: Any])?["profile_permission_mode"] is NSNull, "A CLI without the field clears a saved mode")
        var completions: [String] = []
        client.onEvent = { name, payload in if name == "message.complete" { completions.append(payload["text"] as? String ?? "") } }
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "turn_id": "original", "text": "Original"])
        do {
            _ = try await client.request("prompt.steer", params: ["session_id": sid, "turn_id": "refused", "text": "refuse"])
            XCTFail("A refused steer is a definitive rejection")
        } catch { XCTAssertTrue(error is RuntimeDefinitiveRejection) }
        XCTAssertTrue(completions.isEmpty)
        let image = directory.appendingPathComponent("image.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN2kAAAAASUVORK5CYII=")!.write(to: image)
        let receipt = try await client.request("prompt.steer", params: ["session_id": sid, "turn_id": "steer", "text": "Steer", "images": [image.path]])
        XCTAssertEqual(receipt["steered"] as? Bool, true)
        try await wait { !completions.isEmpty }
        XCTAssertEqual(completions, ["Steered answer"])
        let resumed = try await client.request("session.resume", params: ["session_id": sid, "cwd": directory.path, "project_trusted": true])
        XCTAssertEqual(resumed["accepted_turn_ids"] as? [String], ["steer"])
        XCTAssertEqual(resumed["running"] as? Bool, false)
        let caps = (resumed["info"] as? [String: Any])?["capabilities"] as? [String: Bool]
        XCTAssertEqual(caps?["steering"], true)
    }

    func testClaudeProductionTransportQuestionApprovalModelAndResume() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        for trusted in [true, false] {
            let before = try await client.request("runtime.models", params: ["cwd": directory.path, "project_trusted": trusted])
            XCTAssertTrue((before["catalog"] as? RuntimeModelCatalog)?.contains(RuntimeModelChoice(model: "fixture-selected", reasoningEffort: "high")) == true,
                          "The catalog is readable before the first message")
        }
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        let catalog = try XCTUnwrap(opened["catalog"] as? RuntimeModelCatalog)
        XCTAssertTrue(catalog.contains(RuntimeModelChoice(model: "fixture-selected", reasoningEffort: "high")))
        XCTAssertNil(opened["messages"])
        var completions = 0
        var interactions: [String] = []
        var failures: [String] = []
        var reportedModels: [String] = []
        client.onEvent = { name, payload in
            if name == "message.complete" { completions += 1 }
            if name == "session.info", let model = payload["model"] as? String { reportedModels.append(model) }
            if name == "session.disconnected" { failures.append(payload["message"] as? String ?? "Disconnected") }
            if name == "approval.request" || name == "clarify.request" {
                interactions.append(name)
                Task { @MainActor in
                    do {
                        var params: [String: Any] = ["session_id": id, "request_id": payload["request_id"] ?? ""]
                        if name == "approval.request" { params["choice"] = "deny" }
                        else { params["question_id"] = "0"; params["answer"] = "Blue" }
                        _ = try await client.request(name == "approval.request" ? "approval.respond" : "clarify.respond", params: params)
                    } catch { failures.append(error.localizedDescription) }
                }
            }
        }
        do {
            _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "unsupported"])
            XCTFail("An effort outside the native catalog must be rejected before sending controls")
        } catch {}
        let selected = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "high"])
        XCTAssertEqual(selected["model_override_accepted"] as? Bool, true)
        XCTAssertTrue(reportedModels.isEmpty, "An acknowledgement must not invent effective model metadata")
        let beforeMetadata = try await client.request("session.resume", params: ["session_id": id, "cwd": directory.path, "project_trusted": true])
        XCTAssertNil((beforeMetadata["info"] as? [String: Any])?["model"], "A catalog default is not a session's effective model")
        for (index, text) in ["approval", "question", "clear"].enumerated() {
            if text == "question" {
                _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "low"])
            } else if text == "clear" {
                _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected"])
            }
            _ = try await client.request("prompt.submit", params: ["session_id": id, "text": text, "turn_id": UUID().uuidString])
            try await wait { completions == index + 1 || !failures.isEmpty }
        }
        XCTAssertEqual(interactions, ["approval.request", "clarify.request"])
        XCTAssertEqual(completions, 3)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        XCTAssertEqual(Set(reportedModels), ["fixture-selected"])
        XCTAssertGreaterThanOrEqual(reportedModels.count, 2)
        let afterMetadata = try await client.request("session.resume", params: ["session_id": id, "cwd": directory.path, "project_trusted": true])
        XCTAssertEqual((afterMetadata["info"] as? [String: Any])?["model"] as? String, "fixture-selected")
        let usage = (afterMetadata["info"] as? [String: Any])?["usage"] as? [String: Any]
        XCTAssertEqual(usage?["context_used"] as? Int, 192)
        XCTAssertEqual(usage?["context_max"] as? Int, 16000)
        client.disconnect()
        try await client.connect()
        let resumed = try await client.request("session.resume", params: ["session_id": id, "cwd": directory.path, "project_trusted": true])
        XCTAssertEqual(resumed["stored_session_id"] as? String, id)
        XCTAssertEqual(resumed["history_complete"] as? Bool, false)
    }

    func testClaudeRejectsUnappliedEffort() async throws {
        let (directory, executable) = try fixture(ignoresEffort: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        do {
            _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "high"])
            XCTFail("An acknowledgement alone does not prove the effort was applied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not apply"))
        }
    }

    func testClaudeAppliesUltracodeBesideEffort() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        let catalog = try XCTUnwrap(opened["catalog"] as? RuntimeModelCatalog)
        XCTAssertTrue(catalog.contains(RuntimeModelChoice(model: "fixture-selected", ultracode: true)))
        XCTAssertFalse(catalog.contains(RuntimeModelChoice(model: "fixture-model", ultracode: true)), "Only models with xhigh offer Ultracode")
        var completions = 0
        client.onEvent = { name, _ in if name == "message.complete" { completions += 1 } }
        _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "high", "ultracode": true])
        // The fixture drops Ultracode on an effort change unless the adapter restates it.
        _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "low", "ultracode": true])
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "ultracode", "turn_id": UUID().uuidString])
        try await wait { completions == 1 }
        // Clearing the choice returns to the profile's own, here off.
        _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "low"])
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "off", "turn_id": UUID().uuidString])
        try await wait { completions == 2 }
    }

    func testClaudeNamesTheProfilesOwnPermissionMode() {
        XCTAssertEqual(ClaudeClient.profilePermission("bypassPermissions"), "fullAccess")
        XCTAssertEqual(ClaudeClient.profilePermission("manual"), "ask")
        XCTAssertEqual(ClaudeClient.profilePermission("auto"), "Auto")
        XCTAssertNil(ClaudeClient.profilePermission(nil), "An older CLI reports nothing, so Default stays unnamed")
        var info = RuntimeSessionInfo()
        info.merge(["profile_permission_mode": "fullAccess"], runtime: .claude)
        XCTAssertEqual(info.profilePermissionMode, .fullAccess)
        info.merge(["profile_permission_mode": "Auto"], runtime: .claude)
        XCTAssertNil(info.profilePermissionMode)
        XCTAssertEqual(info.profilePermissionTitle, "Auto")
        info.merge(["model": "other"], runtime: .claude)
        XCTAssertEqual(info.profilePermission, "Auto", "Unrelated reports keep it")
        info.merge(["profile_permission_mode": NSNull()], runtime: .claude)
        XCTAssertNil(info.profilePermission, "A process that cannot report it clears it")
    }

    func testClaudeKeepsTheProfilesOwnUltracodeUntilChosen() async throws {
        let (directory, executable) = try fixture(nativeUltracode: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        // Opened on a model without Ultracode, the profile's own still reads on.
        XCTAssertEqual((opened["info"] as? [String: Any])?["profile_ultracode"] as? Bool, true, "The row shows the profile's own Ultracode")
        XCTAssertEqual((opened["info"] as? [String: Any])?["profile_permission_mode"] as? String, "fullAccess", "Default permissions names the mode the profile opened in")
        var completions = 0
        client.onEvent = { name, _ in if name == "message.complete" { completions += 1 } }
        // An effort change alone would drop it.
        _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "low"])
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "ultracode", "turn_id": UUID().uuidString])
        try await wait { completions == 1 }
        _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "low", "ultracode": false])
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "off", "turn_id": UUID().uuidString])
        try await wait { completions == 2 }
        // A reopened process starts from the profile again, and an unset choice keeps it.
        client.disconnect()
        try await client.connect()
        let resumed = try await client.request("session.resume", params: ["session_id": id, "cwd": directory.path, "project_trusted": true])
        XCTAssertEqual((resumed["info"] as? [String: Any])?["profile_ultracode"] as? Bool, true)
        _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "reasoning_effort": "low"])
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "ultracode", "turn_id": UUID().uuidString])
        try await wait { completions == 3 }
    }

    func testClaudeOpenFailsWhenTheProcessStopsDuringTheSettingsRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-claude-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude-fixture")
        try #"""
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            frame=json.loads(line)
            if frame['request']['subtype']=='get_settings': sys.exit(1)
            print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':frame['request_id'],'response':{'models':[]}}}),flush=True)
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        do {
            // With delegation, the next control used to wait on the stopped process forever.
            _ = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true,
                                                                    "delegation": ["url": "http://127.0.0.1:9/mcp", "token": "tok"]])
            XCTFail("A process that stopped while opening is not an open session")
        } catch {}
    }

    func testClaudeWithoutUltracodeFieldRefusesItButStillSends() async throws {
        let (directory, executable) = try fixture(reportsUltracode: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        do {
            _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "ultracode": true])
            XCTFail("A CLI that does not report Ultracode cannot confirm it")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not report Ultracode"), error.localizedDescription)
        }
        var completions = 0
        client.onEvent = { name, _ in if name == "message.complete" { completions += 1 } }
        for ultracode in [false, nil] as [Bool?] {
            var params: [String: Any] = ["session_id": id, "model": "fixture-selected", "reasoning_effort": "low"]
            params["ultracode"] = ultracode
            _ = try await client.request("session.model.set", params: params)
        }
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "off", "turn_id": UUID().uuidString])
        try await wait { completions == 1 }
    }

    func testClaudeExplainsUltracodeWithoutWorkflows() async throws {
        let (directory, executable) = try fixture(workflows: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(profileID: directory.path, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        do {
            _ = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected", "ultracode": true])
            XCTFail("Ultracode that Claude Code did not turn on must leave the message unsent")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("dynamic workflows"), error.localizedDescription)
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), "Fixture transport failed to settle")
    }

    private func fixture(ignoresEffort: Bool = false, workflows: Bool = true, nativeUltracode: Bool = false, reportsUltracode: Bool = true) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-native-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("native-cli")
        let source = #"""
        #!/usr/bin/env python3
        import json, sys
        def emit(value):
            print(json.dumps(value), flush=True)
        sid = next((a.split('=',1)[1] for a in sys.argv if a.startswith(('--session-id=','--resume='))), None)
        assert sid or {'--no-session-persistence','--strict-mcp-config'} <= set(sys.argv), 'A catalog probe must not save a session or start MCP servers'
        selected_model = 'fixture-model'
        effort = None
        ultracode = \#(nativeUltracode ? "True" : "False")
        workflows = \#(workflows ? "True" : "False")
        reports = \#(reportsUltracode ? "True" : "False")
        def finish():
            emit({'type':'assistant','session_id':sid,'message':{'model':selected_model,'content':[], 'usage':{'input_tokens':12,'cache_creation_input_tokens':70,'cache_read_input_tokens':110,'output_tokens':900}}})
            emit({'type':'result','session_id':sid,'is_error':False,'result':'fixture answer','usage':{'input_tokens':90000},'modelUsage':{selected_model:{'contextWindow':16000,'inputTokens':90000}}})
            emit({'type':'system','subtype':'session_state_changed','state':'idle','session_id':sid})
        for line in sys.stdin:
            frame=json.loads(line)
            if frame['type']=='control_request':
                kind=frame['request']['subtype']
                if kind=='set_model':
                    selected_model=frame['request']['model']
                elif kind=='apply_flag_settings':
                    settings=frame['request']['settings']
                    assert set(settings) in [{'effortLevel'}, {'effortLevel','ultracode'}]
                    requested=\#(ignoresEffort ? "None" : "settings['effortLevel']")
                    assert requested in [None, 'low', 'high', 'xhigh']
                    # Like Claude Code, an effort change alone drops Ultracode; an older CLI ignores the flag.
                    ultracode=settings['ultracode'] and workflows and reports if 'ultracode' in settings else ultracode and requested==effort
                    effort=requested
                else:
                    assert kind in ['initialize', 'get_settings'], 'Never write user or project settings'
                body={'models':[{'value':'default','resolvedModel':'fixture-model'},{'value':'fixture-selected','supportsEffort':True,'supportedEffortLevels':['low','high','xhigh']}],'session_state':'idle','current_permission_mode':'bypassPermissions'} if kind=='initialize' else {}
                if kind=='get_settings':
                    body={'applied':{'model':selected_model,'effort':effort or 'medium'}}
                    # Like Claude Code, the applied state holds only on a model with xhigh; the request is the profile's own.
                    offers=workflows and selected_model=='fixture-selected'
                    if reports: body['applied'].update(ultracode=ultracode and offers, ultracodeRequested=ultracode, ultracodeAvailable=offers)
                emit({'type':'control_response','response':{'subtype':'success','request_id':frame['request_id'],'response':body}})
            elif frame['type']=='control_response':
                body=frame['response']['response']
                assert body.get('behavior')=='deny' or body.get('updatedInput',{}).get('answers')=={'Color?':'Blue'}
                finish()
            else:
                assert sid, 'A catalog probe must never send a prompt'
                assert selected_model == 'fixture-selected', 'The selected model must apply to subsequent native sends'
                emit({'type':'system','subtype':'init','model':selected_model,'session_id':sid})
                emit({'type':'system','subtype':'session_state_changed','state':'running','session_id':sid})
                emit(frame)
                text=frame['message']['content'][0]['text']
                assert (effort, ultracode) == {'approval':('high',False),'question':('low',False),'clear':(None,False),
                    'ultracode':('low',True),'off':('low',False)}[text], 'Apply or clear effort and Ultracode before sending'
                if text=='approval':
                    emit({'type':'control_request','request_id':'approval','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'must not run'}}})
                elif text=='question':
                    emit({'type':'control_request','request_id':'question','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':[{'question':'Color?','options':[{'label':'Blue'}]}]}}})
                else:
                    finish()
        """#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
