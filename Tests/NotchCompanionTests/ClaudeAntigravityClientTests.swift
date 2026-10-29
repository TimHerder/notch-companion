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

    func testAntigravityProductionTransportExactNativeIdentityAndResult() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli").path
        let client = AntigravityClient(profileID: profile, executableURL: executable)
        defer { client.disconnect() }
        try await client.connect()
        let opened = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let id = try XCTUnwrap(opened["session_id"] as? String)
        var response: String?
        let selected = try await client.request("session.model.set", params: ["session_id": id, "model": "fixture-selected"])
        XCTAssertEqual(selected["session_id"] as? String, id)
        XCTAssertEqual((selected["info"] as? [String: Any])?["model"] as? String, "fixture-selected")
        client.onEvent = { name, payload in if name == "message.complete" { response = payload["text"] as? String } }
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "hello", "turn_id": "test-turn"])
        try await wait { response != nil }
        XCTAssertEqual(response, "fixture answer")
        client.disconnect(); try await client.connect()
        let resumed = try await client.request("session.resume", params: ["session_id": id, "cwd": directory.path, "project_trusted": true])
        XCTAssertEqual(resumed["stored_session_id"] as? String, id)
        XCTAssertNil(resumed["messages"])
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

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), "Fixture transport failed to settle")
    }

    private func fixture(ignoresEffort: Bool = false) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-native-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("native-cli")
        let source = #"""
        #!/usr/bin/env python3
        import json, sys, uuid
        def emit(value):
            print(json.dumps(value), flush=True)
        if 'models' in sys.argv or '/model' in sys.argv:
            name = 'models' if 'models' in sys.argv else 'model'
            data = {'models':[{'id':'fixture-model','label':'Default'},{'id':'fixture-selected','label':'Selected'}]} if name=='models' else {'id':'fixture-model'}
            emit({'status':'SUCCESS','command':{'name':name,'data':data}});sys.exit(0)
        claude = '--print' in sys.argv
        if claude:
            sid = next((a.split('=',1)[1] for a in sys.argv if a.startswith(('--session-id=','--resume='))), None)
            assert sid or {'--no-session-persistence','--strict-mcp-config'} <= set(sys.argv), 'A catalog probe must not save a session or start MCP servers'
            selected_model = 'fixture-model'
            effort = None
        else:
            sid = sys.argv[sys.argv.index('--conversation')+1] if '--conversation' in sys.argv else str(uuid.uuid4())
            selected_model = sys.argv[sys.argv.index('--model')+1] if '--model' in sys.argv else 'fixture-model'
            emit({'event':'init','conversation_id':sid,'init':{'cwd':'.','model':selected_model}})
        def finish():
            emit({'type':'assistant','session_id':sid,'message':{'model':selected_model,'content':[], 'usage':{'input_tokens':12,'cache_creation_input_tokens':70,'cache_read_input_tokens':110,'output_tokens':900}}})
            emit({'type':'result','session_id':sid,'is_error':False,'result':'fixture answer','usage':{'input_tokens':90000},'modelUsage':{selected_model:{'contextWindow':16000,'inputTokens':90000}}})
            emit({'type':'system','subtype':'session_state_changed','state':'idle','session_id':sid})
        for line in sys.stdin:
            frame=json.loads(line)
            if not claude:
                assert frame['event']=='user'
                emit({'event':'step_update','step_update':{'conversation_id':sid,'step_type':'user_input','state':'DONE'}})
                emit({'event':'step_update','step_update':{'conversation_id':sid,'step_type':'agent_response','state':'DONE','usage':{'input_tokens':12,'cache_read_tokens':80}}})
                emit({'event':'result','result':{'conversation_id':sid,'status':'SUCCESS','response':'fixture answer','usage':{'total_tokens':100000}}})
            elif frame['type']=='control_request':
                kind=frame['request']['subtype']
                if kind=='set_model':
                    selected_model=frame['request']['model']
                elif kind=='apply_flag_settings':
                    assert set(frame['request']['settings']) == {'effortLevel'}
                    effort=\#(ignoresEffort ? "None" : "frame['request']['settings']['effortLevel']")
                    assert effort in [None, 'low', 'high']
                else:
                    assert kind in ['initialize', 'get_settings'], 'Never write user or project settings'
                body={'models':[{'value':'default','resolvedModel':'fixture-model'},{'value':'fixture-selected','supportsEffort':True,'supportedEffortLevels':['low','high']}],'session_state':'idle'} if kind=='initialize' else {}
                if kind=='get_settings': body={'applied':{'model':selected_model,'effort':effort or 'medium'}}
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
                assert effort == {'approval':'high','question':'low','clear':None}[text], 'Apply or clear effort before sending'
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
