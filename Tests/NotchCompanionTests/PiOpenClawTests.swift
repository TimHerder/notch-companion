import XCTest
import CryptoKit
@testable import NotchCompanion

final class PiOpenClawTests: XCTestCase {
    func testPiWaitsForSettledAcrossRetryCompactionAndQueue() {
        var state = PiProtocolState(); state.begin()
        XCTAssertEqual(state.consume(["type": "agent_start"]).first?.0, "message.start")
        _ = state.consume(["type": "message_end", "message": ["role": "assistant", "content": [["type": "text", "text": "retry me"]], "stopReason": "error", "errorMessage": "overloaded"]])
        XCTAssertTrue(state.consume(["type": "agent_end", "willRetry": true]).isEmpty)
        XCTAssertTrue(state.busy)
        _ = state.consume(["type": "auto_retry_start"])
        _ = state.consume(["type": "compaction_start"])
        _ = state.consume(["type": "queue_update", "followUp": ["next"]])
        XCTAssertTrue(state.busy)
        _ = state.consume(["type": "message_end", "message": ["role": "assistant", "content": "finished", "stopReason": "stop"]])
        let result = state.consume(["type": "agent_settled"])
        XCTAssertEqual(result.first?.0, "message.complete")
        XCTAssertEqual(result.first?.1["status"] as? String, "complete")
        XCTAssertEqual(result.first?.1["text"] as? String, "finished")
        XCTAssertFalse(state.busy)
        XCTAssertTrue(state.consume(["type": "agent_settled"]).isEmpty)
    }
    func testPiAbortAndProviderFailureAreTerminalOnlyWhenSettled() {
        for (reason, status) in [("error", "error"), ("aborted", "interrupted")] {
            var state = PiProtocolState(); state.begin()
            _ = state.consume(["type": "message_end", "message": ["role": "assistant", "content": "", "stopReason": reason]])
            XCTAssertTrue(state.busy)
            XCTAssertEqual(state.consume(["type": "agent_settled"]).first?.1["status"] as? String, status)
        }
    }
    func testPiDialogsValidateChoicesAndPreserveMultilineEditor() throws {
        XCTAssertEqual(try PiProtocolState.dialogReply(["id": "c", "method": "confirm"], answer: "No")["confirmed"] as? Bool, false)
        XCTAssertThrowsError(try PiProtocolState.dialogReply(["id": "c", "method": "confirm"], answer: "allow"))
        XCTAssertThrowsError(try PiProtocolState.dialogReply(["id": "s", "method": "select", "options": ["A"]], answer: "B"))
        XCTAssertEqual(try PiProtocolState.dialogReply(["id": "e", "method": "editor"], answer: "a\nb")["value"] as? String, "a\nb")
    }
    func testPiUsageDoesNotExposeCumulativeTokenTotals() {
        let info = PiProtocolState.info(model: ["id": "test", "provider": "native", "contextWindow": 32000])
        XCTAssertEqual((info["usage"] as? [String: Any])?["context_max"] as? Int, 32000)
        XCTAssertNil((info["usage"] as? [String: Any])?["context_used"])
        let current = PiProtocolState.info(model: [:], stats: ["tokens": ["total": 900000], "contextUsage": ["tokens": 4200, "contextWindow": 32000]])
        XCTAssertEqual((current["usage"] as? [String: Any])?["context_used"] as? Int, 4200)
        let compacted = PiProtocolState.info(model: [:], stats: ["contextUsage": ["tokens": NSNull(), "contextWindow": 32000]])
        XCTAssertEqual(compacted["context_reset"] as? Bool, true)
        XCTAssertNil((compacted["usage"] as? [String: Any])?["context_used"])
    }

    func testPiToolArgumentsAndNestedCallsReachTheTimeline() {
        var state = PiProtocolState(); state.begin()
        let events = state.consume(["type": "tool_execution_start", "toolCallId": "parent/1", "toolName": "read", "args": ["path": "marker.txt"]])
        XCTAssertEqual(events.first?.0, "tool.start")
        XCTAssertEqual(events.first?.1["tool_id"] as? String, "parent/1")
        XCTAssertTrue((events.first?.1["context"] as? String)?.contains("marker.txt") == true)
    }
    func testOpenClawUnknownExternalEventsCannotEnterRegistry() {
        var state = OpenClawProtocolState(); state.owned.insert("owned")
        XCTAssertTrue(state.consume("chat", ["runId": "outside", "sessionKey": "main", "seq": 1, "state": "delta", "deltaText": "private"]).isEmpty)
        XCTAssertTrue(state.consume("exec.approval.requested", ["id": "outside", "request": ["sessionKey": "main", "command": "private"]]).isEmpty)
        XCTAssertFalse(state.busy("owned"))
    }
    func testOpenClawDuplicateOldAndOutOfOrderTerminalEventsAreIgnored() {
        var state = OpenClawProtocolState(); state.owned.insert("owned"); state.begin("owned", run: "new")
        XCTAssertTrue(state.consume("chat", ["runId": "old", "sessionKey": "owned", "seq": 1, "state": "final"]).isEmpty)
        let delta: [String: Any] = ["runId": "new", "sessionKey": "owned", "seq": 1, "state": "delta", "deltaText": "hello"]
        XCTAssertEqual(state.consume("chat", delta).last?.1["text"] as? String, "hello")
        XCTAssertTrue(state.consume("chat", delta).isEmpty)
        let end: [String: Any] = ["runId": "new", "sessionKey": "owned", "seq": 2, "state": "final", "message": ["content": "final"]]
        XCTAssertEqual(state.consume("chat", end).last?.1["text"] as? String, "final")
        state.accepted("owned", run: "new")
        XCTAssertFalse(state.busy("owned"), "Late send acknowledgement must not reopen completed work")
        XCTAssertTrue(state.consume("chat", end).isEmpty)
    }
    func testOpenClawChildrenRemainBusyAfterParentCompletion() {
        var state = OpenClawProtocolState(); state.owned.insert("parent"); state.begin("parent", run: "p")
        let events = state.consume("chat", ["runId": "c", "sessionKey": "child", "spawnedBy": "parent", "seq": 1, "state": "delta", "deltaText": "working"])
        XCTAssertEqual(events.first?.0, "subagent.start")
        _ = state.consume("chat", ["runId": "p", "sessionKey": "parent", "seq": 1, "state": "final"])
        XCTAssertTrue(state.busy("parent"))
        XCTAssertEqual(state.consume("chat", ["runId": "c", "sessionKey": "child", "seq": 2, "state": "error"]).last?.0, "subagent.complete")
        XCTAssertFalse(state.busy("parent"))
    }
    func testOpenClawReconnectAdoptsExactInFlightRunAndRespectsUnknownOwner() {
        var state = OpenClawProtocolState()
        state.register("s", history: ["inFlightRun": ["runId": "run", "text": "buffer"]])
        XCTAssertEqual(state.active["s"], "run")
        state.register("s", history: ["sessionInfo": ["hasActiveRun": true, "activeRunIds": ["somebody"]]])
        XCTAssertNil(state.active["s"]); XCTAssertTrue(state.busy("s"))
        state.register("s", history: ["sessionInfo": ["hasActiveRun": false, "activeRunIds": [String]()]])
        XCTAssertFalse(state.busy("s"))
    }
    func testOpenClawOlderHistorySnapshotCannotClearNewNativeActivity() {
        var state = OpenClawProtocolState(); state.owned.insert("s")
        let revision = state.activityRevision("s")
        _ = state.consume("chat", ["runId": "new", "sessionKey": "s", "seq": 1, "state": "delta", "deltaText": "live"])
        state.register("s", history: ["sessionInfo": ["hasActiveRun": false]], expectedRevision: revision)
        XCTAssertTrue(state.busy("s"))
        XCTAssertEqual(state.active["s"], "new")
    }
    func testOpenClawApprovalsAreScopedAndHonorNativeDecisionLimits() throws {
        var state = OpenClawProtocolState(); state.owned.insert("a"); state.owned.insert("b")
        let payload: [String: Any] = ["id": "request", "request": ["sessionKey": "a", "command": "command", "unavailableDecisions": ["allow-always"]]]
        let event = state.consume("exec.approval.requested", payload).first
        XCTAssertEqual(event?.1["choices"] as? [String], ["once", "deny"])
        XCTAssertThrowsError(try state.answer(["request_id": "request", "choice": "once"], session: "b"))
        XCTAssertThrowsError(try state.answer(["request_id": "request", "choice": "always"], session: "a"))
        XCTAssertEqual(try state.answer(["request_id": "request", "choice": "deny"], session: "a")?.1["decision"] as? String, "deny")
        _ = state.consume("exec.approval.resolved", ["id": "request"])
        XCTAssertTrue(state.consume("exec.approval.requested", payload).isEmpty, "Backfill cannot resurrect a resolved request")
    }
    func testOpenClawQuestionsMapNativeValuesAndCancelUnsupportedSensitiveUI() throws {
        var state = OpenClawProtocolState(); state.owned.insert("s")
        let options = [["label": "Choice", "value": "native_value"]]
        let record: [String: Any] = ["id": "q", "sessionKey": "s", "questions": [["questionId": "first", "question": "Pick", "options": options, "isOther": false], ["questionId": "second", "question": "Explain", "options": []]]]
        XCTAssertEqual(state.consume("question.requested", record).first?.0, "clarify.request")
        XCTAssertNil(try state.answer(["request_id": "q", "question_id": "first", "answer": "Choice"], session: "s"))
        let reply = try XCTUnwrap(state.answer(["request_id": "q", "question_id": "second", "answer": "because"], session: "s"))
        XCTAssertEqual((reply.1["answers"] as? [String: [String: [String]]])?["answers"]?["first"], ["native_value"])
        XCTAssertEqual(state.consume("question.requested", ["id": "secret", "sessionKey": "s", "questions": [["questionId": "key", "isSecret": true]]]).first?.0, "runtime.cancelQuestion")
    }
    func testOpenClawMultipleChoicePreservesCommaContainingLabels() throws {
        var state = OpenClawProtocolState(); state.owned.insert("s")
        _ = state.consume("question.requested", ["id": "q", "sessionKey": "s", "questions": [["questionId": "pick", "question": "Pick", "multiSelect": true, "isOther": false, "options": [["label": "A, B", "value": "ab"], ["label": "C", "value": "c"]]]]])
        XCTAssertThrowsError(try state.answer(["request_id": "q", "answer": "A, B, C"], session: "s"))
        let reply = try XCTUnwrap(state.answer(["request_id": "q", "answers": ["A, B", "C"]], session: "s"))
        XCTAssertEqual((reply.1["answers"] as? [String: [String: [String]]])?["answers"]?["pick"], ["ab", "c"])
    }
    func testOpenClawSequenceGapRequestsRecoveryAndDoesNotGuessUsage() {
        var state = OpenClawProtocolState(); state.owned.insert("s"); state.begin("s", run: "r")
        _ = state.consume("chat", ["runId": "r", "sessionKey": "s", "seq": 1, "state": "delta", "deltaText": "a"])
        XCTAssertEqual(state.consume("chat", ["runId": "r", "sessionKey": "s", "seq": 4, "state": "delta", "deltaText": "b"]).first?.0, "runtime.reconcile")
        let info = OpenClawProtocolState.info(["totalTokens": 900000, "contextTokens": 100000])
        XCTAssertNil((info["usage"] as? [String: Any])?["context_used"])
    }
    func testOpenClawCanonicalAgentEntriesAndWorkspaceInheritance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("openclaw.json")
        try "{agents:{entries:{work:{},personal:{}},defaults:{workspace:'/native/root'},ownership:'explicit'}}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try OpenClawConfiguration.configuredAgents(profileID: directory.path), ["personal", "work"])
        XCTAssertThrowsError(try OpenClawConfiguration.defaultAgent(profileID: directory.path))
        XCTAssertEqual(try OpenClawConfiguration.workspace(profileID: directory.path, agent: "work"), "/native/root/work")
        try "{agents:{entries:{only:{}}}}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try OpenClawConfiguration.defaultAgent(profileID: directory.path), "only")
        XCTAssertEqual(try OpenClawConfiguration.workspace(profileID: directory.path, agent: "only"), directory.appendingPathComponent("workspace").path)
        try "{agents:{entries:{work:{},personal:{}}}}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try OpenClawConfiguration.workspace(profileID: directory.path, agent: "work"), directory.appendingPathComponent("workspace-work").path)
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try OpenClawConfiguration.configuredAgents(profileID: directory.path), ["main"])
        XCTAssertEqual(try OpenClawConfiguration.workspace(profileID: directory.path, agent: "main"), directory.appendingPathComponent("workspace").path)
    }
    func testOpenClawDeviceProofBindsChallengeTimestampAndIdentity() throws {
        let key = Curve25519.Signing.PrivateKey(), device = OpenClawDevice(privateKey: key.rawRepresentation)
        let proof = try device.proof(nonce: "challenge", timestamp: 12345, token: "fixture-token", scopes: ["operator.read"])
        let id = try XCTUnwrap(proof["id"] as? String)
        let payload = "v3|\(id)|gateway-client|ui|operator|operator.read|12345|fixture-token|challenge|macos|mac"
        let encoded = try XCTUnwrap(proof["signature"] as? String).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let signature = try XCTUnwrap(Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data(payload.utf8)))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: Data((payload + "wrong").utf8)))
        XCTAssertEqual(proof["signedAt"] as? Int, 12345)
        // The node link signs its own role and mode with the same device, and no operator scopes.
        let node = try device.proof(nonce: "challenge", timestamp: 12345, token: nil, scopes: [], mode: "node", role: "node")
        XCTAssertEqual(node["id"] as? String, id)
        let nodeEncoded = try XCTUnwrap(node["signature"] as? String).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let nodeSignature = try XCTUnwrap(Data(base64Encoded: nodeEncoded + String(repeating: "=", count: (4 - nodeEncoded.count % 4) % 4)))
        XCTAssertTrue(key.publicKey.isValidSignature(nodeSignature, for: Data("v3|\(id)|gateway-client|node|node||12345||challenge|macos|mac".utf8)))
    }
    func testOpenClawConfigReadsJSON5WithoutMutationAndRejectsUnsupportedRouting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("openclaw.json")
        let source = """
        { // Native profile fixture
          gateway: { port: 19001, auth: { mode: 'token', token: '${NATIVE_GATEWAY_TOKEN}' } },
          agents: { list: [{id: 'existing', default: true, workspace: '~/native-agent'}] },
        }
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let config = try OpenClawConfiguration.load(directory: directory.path)
        XCTAssertEqual(try config.endpoint().absoluteString, "ws://127.0.0.1:19001")
        XCTAssertEqual(try config.auth(environment: ["NATIVE_GATEWAY_TOKEN": "fixture"])["token"], "fixture")
        XCTAssertEqual(try OpenClawConfiguration.defaultAgent(profileID: directory.path), "existing")
        XCTAssertEqual(try OpenClawConfiguration.configuredAgents(profileID: directory.path), ["existing"])
        XCTAssertTrue(try OpenClawConfiguration.workspace(profileID: directory.path, agent: "existing")?.hasPrefix("/") == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        XCTAssertThrowsError(try config.auth(environment: [:]))
        try "{gateway: {$include: 'other.json'}}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenClawConfiguration.load(directory: directory.path))
    }
    @MainActor
    func testPiAdapterUsesPersistentNativeRPCAndWaitsForSettled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("pi-fixture")
        let source = #"""
        #!/usr/bin/python3
        import json,os,sys
        if '--version' in sys.argv: print('1.0.2');sys.exit(0)
        path=os.path.join(os.environ['PI_CODING_AGENT_DIR'],'native-session.jsonl')
        ephemeral='--no-session' in sys.argv
        with open(os.path.join(os.environ['PI_CODING_AGENT_DIR'],'launches'),'a') as f: f.write(str(ephemeral)+'\n')
        def send(value): print(json.dumps(value),flush=True)
        for line in sys.stdin:
          r=json.loads(line);t=r['type'];data={}
          if ephemeral: assert t in ('get_state','get_available_models')
          if t=='get_state': data={'sessionFile':None if ephemeral else path,'sessionId':'native-id','isStreaming':False,'isCompacting':False,'pendingMessageCount':0,'model':{'id':'configured','provider':'native'}}
          if t=='get_messages': data={'messages':[]}
          if t=='get_available_models': data={'models':[{'id':'configured','provider':'native'}]}
          if t=='prompt':
            with open(path,'w') as f: f.write(json.dumps({'type':'session','cwd':os.getcwd()})+'\n')
            if r['message']=='reject':
              send({'id':r['id'],'type':'response','command':t,'success':False,'error':'fixture rejected'});continue
            data={'disposition':'handled' if r['message']=='handled-with-work' else 'started'}
            if r['message']=='handled-with-work':send({'type':'agent_start'})
          send({'id':r['id'],'type':'response','command':t,'success':True,'data':data})
          if t=='prompt':
            send({'type':'agent_start'})
            if r['message']=='hold-for-steer': continue
          if t in ('prompt','steer'):
            if t=='steer': assert r['message']=='Change direction' and r['images']==[]
            send({'type':'message_start','message':{'role':'assistant'}})
            send({'type':'message_update','assistantMessageEvent':{'type':'text_delta','delta':'native answer'}})
            send({'type':'message_end','message':{'role':'assistant','content':'native answer','stopReason':'stop'}})
            send({'type':'agent_end'})
            send({'type':'compaction_start'})
            send({'type':'agent_settled'})
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = PiClient(profileID: directory.path, executable: script)
        defer { client.disconnect() }
        try await client.connect()
        let catalog = try await client.request("runtime.models", params: ["cwd": directory.path])["catalog"] as? RuntimeModelCatalog
        XCTAssertEqual(catalog?.defaultModel, RuntimeModelChoice(model: "configured", provider: "native"))
        XCTAssertEqual(catalog?.models.map(\.choice), [RuntimeModelChoice(model: "configured", provider: "native")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-session.jsonl").path))
        let created = try await client.request("session.create", params: ["cwd": directory.path])
        let id = try XCTUnwrap(created["stored_session_id"] as? String)
        XCTAssertEqual(id, directory.appendingPathComponent("native-session.jsonl").path)
        _ = try await client.request("runtime.models", params: ["cwd": directory.path])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8), "True\nFalse\n", "Reuse the persistent frontend for the same project")
        let settled = expectation(description: "Settled native lifecycle")
        settled.expectedFulfillmentCount = 2
        client.onEvent = { name, payload in
            if name == "message.complete" { XCTAssertEqual(payload["text"] as? String, "native answer"); settled.fulfill() }
        }
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "handled-with-work"])
        for _ in 0..<50 {
            let snapshot = try await client.request("session.resume", params: ["session_id": id])
            if snapshot["running"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "hello"])
        await fulfillment(of: [settled], timeout: 5)
        let steered = expectation(description: "Steering keeps the Pi run until settled")
        client.onEvent = { name, _ in if name == "message.complete" { steered.fulfill() } }
        _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "hold-for-steer"])
        _ = try await client.request("prompt.steer", params: ["session_id": id, "text": "Change direction"])
        await fulfillment(of: [steered], timeout: 5)
        do {
            _ = try await client.request("prompt.submit", params: ["session_id": id, "text": "reject"])
            XCTFail("Expected explicit native rejection")
        } catch { XCTAssertTrue(error is RuntimeDefinitiveRejection) }
        let resumed = try await client.request("session.resume", params: ["session_id": id])
        XCTAssertEqual(resumed["running"] as? Bool, false)
        XCTAssertEqual(resumed["history_complete"] as? Bool, false)
    }

    @MainActor
    func testPiCatalogDiscoveryIsProjectScopedAndClosesOnSuccessFailureAndDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("pi-catalog-fixture")
        let source = #"""
        #!/usr/bin/python3
        import json,os,sys
        if '--version' in sys.argv: print('1.0.2');sys.exit(0)
        assert '--no-session' in sys.argv and '--session' not in sys.argv
        assert '--extension' in sys.argv
        project=os.path.basename(os.getcwd())
        def send(value): print(json.dumps(value),flush=True)
        for line in sys.stdin:
          r=json.loads(line);t=r['type']
          with open('requests','a') as f: f.write(t+'\n')
          assert t in ('get_state','get_available_models')
          if t=='get_available_models' and project=='pending':
            open('waiting','w').close();continue
          model={'id':project,'provider':'native','contextWindow':123456}
          data={'model':model} if t=='get_state' else {'models':[model]}
          success=not (t=='get_available_models' and project=='failure')
          send({'id':r['id'],'type':'response','command':t,'success':success,'data':data,'error':'catalog rejected'})
        open('stopped','w').close()
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = PiClient(profileID: directory.path, executable: script)
        defer { client.disconnect() }
        client.onEvent = { name, _ in XCTFail("Catalog discovery must not publish conversation events: \(name)") }
        try await client.connect()
        for project in ["first", "second", "failure", "pending"] {
            let folder = directory.appendingPathComponent(project)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let request = Task { try await client.request("runtime.models", params: ["cwd": folder.path]) }
            if project == "pending" {
                for _ in 0..<200 {
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("waiting").path) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("waiting").path))
                client.disconnect()
            }
            do {
                let result = try await request.value
                XCTAssertFalse(["failure", "pending"].contains(project))
                let catalog = try XCTUnwrap(result["catalog"] as? RuntimeModelCatalog)
                XCTAssertEqual(catalog.defaultModel, RuntimeModelChoice(model: project, provider: "native"))
                XCTAssertEqual(catalog.models.map(\.choice), [RuntimeModelChoice(model: project, provider: "native")])
                XCTAssertEqual(catalog.configuredContextWindow, 123456)
            } catch {
                XCTAssertTrue(["failure", "pending"].contains(project), error.localizedDescription)
                if project == "failure" { XCTAssertTrue(error is PiRequestError) }
            }
            try await NativeJSONProcess.awaitPendingStops()
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stopped").path))
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("requests"), encoding: .utf8), "get_state\nget_available_models\n")
        }
    }
}

extension PiOpenClawTests {
    @MainActor
    func testPiSupportedVersionBoundary() {
        XCTAssertTrue(PiClient.supportsVersion("1.0.2"))
        XCTAssertTrue(PiClient.supportsVersion("1.1.0"))
        for version in ["0.70.0", "1.0.1", "2.0.0", "1.0.2-beta", "unknown", "1.bad.0.2", "1..0.2", "vv1.0.2", "1.0.2v"] { XCTAssertFalse(PiClient.supportsVersion(version)) }
    }

    @MainActor
    func testOpenClawProductionWebSocketHandshakePromptModelQuestionsAndResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("gateway.py"), portFile = directory.appendingPathComponent("port")
        let source = #"""
        import socket,hashlib,base64,json,struct,sys
        server=socket.socket();server.bind(('127.0.0.1',0));server.listen(4)
        open(sys.argv[1],'w').write(str(server.getsockname()[1]))
        sessions={};current=None;approval_sent=False
        methods=['chat.send','chat.history','chat.abort','sessions.create','sessions.messages.subscribe','sessions.patch','question.resolve','question.list','exec.approval.resolve','exec.approval.list','models.list']
        scopes=['operator.read','operator.write','operator.approvals','operator.questions']
        def exact(c,n):
          result=b''
          while len(result)<n:
            part=c.recv(n-len(result))
            if not part: raise EOFError()
            result+=part
          return result
        def frame(c,value):
          data=json.dumps(value).encode();n=len(data)
          header=bytes([129,n]) if n<126 else bytes([129,126])+struct.pack('!H',n)
          c.sendall(header+data)
        def event(c,name,payload): frame(c,{'type':'event','event':name,'payload':payload})
        def reply(c,r,payload): frame(c,{'type':'res','id':r['id'],'ok':True,'payload':payload})
        def read(c):
          a,b=exact(c,2)
          if a&15==8: raise EOFError()
          n=b&127
          if n==126:n=struct.unpack('!H',exact(c,2))[0]
          elif n==127:n=struct.unpack('!Q',exact(c,8))[0]
          mask=exact(c,4) if b&128 else None;data=exact(c,n)
          if mask:data=bytes(x^mask[i%4] for i,x in enumerate(data))
          return json.loads(data)
        while True:
          c,_=server.accept()
          try:
            header=b''
            while b'\r\n\r\n' not in header:header+=c.recv(4096)
            key=[line.split(b':',1)[1].strip() for line in header.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:')][0]
            accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
            event(c,'connect.challenge',{'nonce':'fixture-challenge','ts':123456789})
            while True:
              r=read(c);m=r['method'];p=r['params']
              if m=='connect':
                assert p['minProtocol']==p['maxProtocol']==4
                assert p['device']['nonce']=='fixture-challenge' and p['device']['signedAt']==123456789
                assert p['client']['displayName']=='Notch Companion' and p['scopes']==scopes
                assert 'operator.admin' not in p['scopes'] and 'operator.pairing' not in p['scopes']
                reply(c,r,{'type':'hello-ok','protocol':4,'auth':{'scopes':scopes},'features':{'methods':methods},'policy':{'tickIntervalMs':30000,'maxPayload':16777216}})
              elif m=='sessions.create':
                key=p['key'];assert key.startswith('agent:existing:notch:')
                sessions[key]={'messages':[],'model':'default','modelProvider':'native','leaf':None,'receipts':{}}
                reply(c,r,{'key':key,'sessionId':'native-'+key})
              elif m=='sessions.messages.subscribe':
                if not approval_sent:
                  approval_sent=True;event(c,'exec.approval.requested',{'id':'early-owned','request':{'sessionKey':p['key'],'command':'owned fixture'}})
                reply(c,r,{})
              elif m=='chat.history':
                key=p['sessionKey'];s=sessions[key]
                reply(c,r,{'sessionKey':key,'sessionId':'native-'+key,'messages':[] if p.get('inputRunIds') else s['messages'],'inputReceipts':[s['receipts'][rid] for rid in p.get('inputRunIds',[]) if rid in s['receipts']],'leafEntryId':s['leaf'],'sessionInfo':{'hasActiveRun':False,'activeRunIds':[],'model':s['model'],'modelProvider':s['modelProvider']}})
              elif m=='exec.approval.list':reply(c,r,{'approvals':[{'id':'external','request':{'sessionKey':'main','command':'external'}}]})
              elif m=='question.list':reply(c,r,{'questions':[]})
              elif m=='exec.approval.resolve':
                assert p['id']=='early-owned' and p['decision']=='deny';reply(c,r,{})
                event(c,'exec.approval.resolved',{'id':'early-owned'})
              elif m=='models.list':reply(c,r,{'models':[{'id':'selected','provider':'native'}]})
              elif m=='sessions.patch':
                if 'model' in p:
                  provider,model=p['model'].split('/',1);sessions[p['key']]['model']=model;sessions[p['key']]['modelProvider']=provider
                reply(c,r,{'entry':sessions[p['key']]})
              elif m=='chat.send':
                key=p['sessionKey'];run=p['idempotencyKey'];current=(key,run)
                assert p.get('expectedLeafEntryId')==sessions[key]['leaf']
                if p['message']=='reject':
                  frame(c,{'type':'res','id':r['id'],'ok':False,'error':{'code':'INVALID_REQUEST','message':'fixture rejected'}});continue
                reply(c,r,{'runId':run})
                sessions[key]['messages'] += [{'role':'user','content':p['message']}]
                event(c,'agent',{'runId':run,'seq':1,'stream':'tool','data':{'phase':'start','toolCallId':'tool','name':'native_tool','args':{}}})
                event(c,'agent',{'runId':run,'seq':2,'stream':'tool','data':{'phase':'result','toolCallId':'tool','name':'native_tool','result':'ok'}})
                event(c,'question.requested',{'id':'question-'+run,'sessionKey':key,'runId':run,'questions':[{'questionId':'pick','header':'Pick','question':'Choose','options':[{'label':'Proceed','value':'native-choice'}],'isOther':False}]})
              elif m=='question.resolve':
                assert p['answers']['answers']['pick']==['native-choice'];reply(c,r,{'status':'answered'})
                key,run=current
                event(c,'question.resolved',{'id':'question-'+run,'status':'answered'})
                event(c,'chat',{'sessionKey':key,'runId':run,'seq':1,'state':'delta','deltaText':'native reply'})
                sessions[key]['messages'] += [{'role':'assistant','content':'native reply'}];sessions[key]['leaf']='leaf-'+run
                sessions[key]['receipts'][run]={'runId':run,'state':'consumed','consumedByEventId':'event-'+run}
                event(c,'chat',{'sessionKey':key,'runId':run,'seq':2,'state':'final','message':{'role':'assistant','content':'native reply'}})
              else:raise Exception('unhandled method '+m)
          except EOFError:pass
          finally:c.close()
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [script.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try XCTUnwrap(Int(String(contentsOf: portFile, encoding: .utf8)))
        let config: [String: Any] = ["gateway": ["port": port, "auth": ["mode": "none"]], "agents": ["list": [["id": "existing", "workspace": directory.path]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("openclaw.json"))
        let route = RuntimeProfileIdentity.openClaw(directory: directory.path, agent: "existing")
        let device = OpenClawDevice(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
        let client = OpenClawClient(profileID: route, device: device)
        defer { client.disconnect() }
        try await client.connect()
        var earlyApproval = false
        client.onEvent = { name, payload in
            if name == "approval.request", payload["request_id"] as? String == "early-owned" { earlyApproval = true }
        }
        let result = try await client.request("session.create", params: ["cwd": directory.path])
        let key = try XCTUnwrap(result["stored_session_id"] as? String)
        XCTAssertTrue(key.hasPrefix("agent:existing:notch:"))
        XCTAssertTrue(earlyApproval, "Owned input arriving before subscribe response must be retained")
        XCTAssertEqual(result["running"] as? Bool, true, "Pending owned input prevents an idle result")
        do {
            _ = try await client.request("prompt.submit", params: ["session_id": key, "text": "must not send"])
            XCTFail("A native request is still awaiting a reply")
        } catch { XCTAssertTrue(error is RuntimeDefinitiveRejection) }
        _ = try await client.request("approval.respond", params: ["session_id": key, "request_id": "early-owned", "choice": "deny"])
        let model = try await client.request("session.model.set", params: ["session_id": key, "model": "selected", "provider": "native"])
        XCTAssertEqual((model["info"] as? [String: Any])?["model"] as? String, "selected")
        let completed = expectation(description: "WebSocket native completion")
        completed.expectedFulfillmentCount = 2
        var tools = [String](), requests = 0
        client.onEvent = { name, payload in
            if name == "tool.start" || name == "tool.complete" { tools.append(name) }
            if name == "approval.request" { XCTFail("External approval escaped route filtering") }
            if name == "clarify.request" {
                requests += 1
                Task { @MainActor in
                    do { _ = try await client.request("clarify.respond", params: ["session_id": key, "request_id": payload["request_id"] as? String ?? "", "question_id": "pick", "answer": "Proceed"]) }
                    catch { XCTFail(error.localizedDescription) }
                }
            }
            if name == "message.complete" { XCTAssertEqual(payload["text"] as? String, "native reply"); completed.fulfill() }
        }
        _ = try await client.request("prompt.submit", params: ["session_id": key, "text": "fixture", "turn_id": "run-owned"])
        for _ in 0..<100 {
            if requests == 1 { try await Task.sleep(for: .milliseconds(50)); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await client.request("prompt.submit", params: ["session_id": key, "text": "second", "turn_id": "run-second"])
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(tools, ["tool.start", "tool.complete", "tool.start", "tool.complete"]); XCTAssertEqual(requests, 2)
        client.disconnect()
        XCTAssertTrue(server.isRunning, "Closing the adapter must preserve the existing Gateway")
        try await client.connect()
        let resumed = try await client.request("session.resume", params: ["session_id": key])
        XCTAssertEqual(resumed["running"] as? Bool, false)
        XCTAssertEqual((resumed["messages"] as? [[String: Any]])?.last?["text"] as? String, "native reply")
        let receipt = try await client.request("session.resume", params: ["session_id": key, "pending_turn_id": "run-second"])
        XCTAssertEqual(receipt["accepted_turn_ids"] as? [String], ["run-second"])
        XCTAssertTrue((receipt["messages"] as? [[String: Any]])?.isEmpty == true, "Positive exact receipts do not depend on display history")
        XCTAssertEqual(receipt["history_complete"] as? Bool, false)
        let absent = try await client.request("session.resume", params: ["session_id": key, "pending_turn_id": "never-delivered"])
        XCTAssertTrue((absent["accepted_turn_ids"] as? [String])?.isEmpty == true)
        do {
            _ = try await client.request("prompt.submit", params: ["session_id": key, "text": "reject"])
            XCTFail("Expected explicit native rejection")
        } catch { XCTAssertTrue(error is RuntimeDefinitiveRejection) }
        XCTAssertTrue(server.isRunning)
    }
}

extension PiOpenClawTests {
    func testOpenClawExactReceiptsConfirmOnlyRequestedAcceptedInput() {
        let consumed: [String: Any] = ["inputReceipts": [["runId": "wanted", "state": "consumed", "consumedByEventId": "native-event"]]]
        XCTAssertEqual(OpenClawProtocolState.acceptedReceipt(consumed, requestedID: "wanted").ids, ["wanted"])
        XCTAssertTrue(OpenClawProtocolState.acceptedReceipt(consumed, requestedID: "other").ids.isEmpty)
        let queued: [String: Any] = ["inputReceipts": [["runId": "wanted", "state": "pending", "queued": true]]]
        XCTAssertTrue(OpenClawProtocolState.acceptedReceipt(queued, requestedID: "wanted").queued)
        let active: [String: Any] = ["inFlightRun": ["runId": "wanted"], "inputReceipts": [["runId": "wanted", "state": "pending"]]]
        XCTAssertEqual(OpenClawProtocolState.acceptedReceipt(active, requestedID: "wanted").ids, ["wanted"])
        for record: [String: Any] in [
            ["runId": "wanted", "state": "pending", "queued": true, "cancelled": true],
            ["runId": "wanted", "state": "pending"],
            ["runId": "wanted", "state": "consumed", "consumedByEventId": "event", "cancelled": true],
            ["runId": "wanted", "state": "consumed"],
            ["runId": "wanted", "state": "consumed", "consumedByEventId": ""],
            ["runId": "wanted", "state": "unknown"]
        ] {
            XCTAssertTrue(OpenClawProtocolState.acceptedReceipt(["inputReceipts": [record]], requestedID: "wanted").ids.isEmpty)
        }
        XCTAssertTrue(OpenClawProtocolState.acceptedReceipt([:], requestedID: "wanted").ids.isEmpty)
        XCTAssertTrue(OpenClawProtocolState.acceptedReceipt(["inputReceipts": [["runId": "wanted", "state": "pending", "cancelled": true]], "inputConsumptions": [["runId": "wanted", "consumedByEventId": "older"]]], requestedID: "wanted").ids.isEmpty)
        XCTAssertEqual(OpenClawProtocolState.acceptedReceipt(["inputConsumptions": [["runId": "wanted", "consumedByEventId": "native-event"]]], requestedID: "wanted").ids, ["wanted"])
    }

    func testOpenClawQueuedReceiptKeepsBusyUntilItsOwnNativeTerminalEvent() {
        var state = OpenClawProtocolState(); state.owned.insert("s"); state.begin("s", run: "first")
        state.adoptQueuedReceipt("s", id: "second")
        let first = state.consume("chat", ["sessionKey": "s", "runId": "first", "seq": 1, "state": "final", "message": ["content": "first final"]])
        XCTAssertTrue(state.busy("s"))
        XCTAssertFalse(first.contains { $0.0 == "message.complete" }, "The normalized UI must stay busy while accepted input remains queued")
        XCTAssertEqual(first.last?.0, "message.interim")
        XCTAssertEqual(first.last?.1["text"] as? String, "first final")
        let second = state.consume("chat", ["sessionKey": "s", "runId": "second", "seq": 1, "state": "final"])
        XCTAssertTrue(second.contains { $0.0 == "message.complete" })
        XCTAssertFalse(state.busy("s"))
        state.adoptQueuedReceipt("s", id: "second")
        XCTAssertFalse(state.busy("s"), "A late receipt cannot resurrect a terminal run")
    }

    func testOpenClawTruncatedQueuePagesNeverProveIdle() {
        var state = OpenClawProtocolState()
        state.register("s", history: ["sessionInfo": ["hasActiveRun": false], "pendingInputs": ["queuedCount": 2, "items": [["id": "display-only", "state": "queued"]]]])
        XCTAssertTrue(state.busy("s"))
        _ = state.consume("chat", ["sessionKey": "s", "runId": "first", "seq": 1, "state": "delta", "deltaText": "work"])
        XCTAssertFalse(state.consume("chat", ["sessionKey": "s", "runId": "first", "seq": 2, "state": "final"]).contains { $0.0 == "message.complete" })
        state.register("s", history: ["sessionInfo": ["hasActiveRun": false], "pendingInputs": ["queuedCount": 0, "items": []]])
        XCTAssertFalse(state.busy("s"))
        state.register("s", history: ["pendingInputs": ["queuedCount": 1, "items": []]])
        state.adoptQueuedReceipt("s", id: "known")
        XCTAssertTrue(state.consume("chat", ["sessionKey": "s", "runId": "known", "seq": 1, "state": "final"]).contains { $0.0 == "message.complete" })
        XCTAssertFalse(state.busy("s"), "An exact receipt accounts for the previously unenumerated queued input")
    }

    func testOpenClawOwnedQuestionFencesStaleHistoryAndBusyUntilResolved() throws {
        var state = OpenClawProtocolState(); state.owned.insert("s")
        let revision = state.activityRevision("s")
        _ = state.consume("question.requested", ["id": "q", "sessionKey": "s", "runId": "native-run", "questions": [["questionId": "pick", "question": "Choose", "options": []]]])
        state.register("s", history: ["sessionInfo": ["hasActiveRun": false]], expectedRevision: revision)
        XCTAssertTrue(state.busy("s"))
        _ = state.consume("question.resolved", ["id": "q"])
        XCTAssertTrue(state.busy("s"), "Resolving input does not terminate its native run")
        _ = state.consume("chat", ["sessionKey": "s", "runId": "native-run", "seq": 1, "state": "final"])
        XCTAssertFalse(state.busy("s"))
    }

    func testOpenClawNativeIncludesMergeNestedFilesArraysAndSiblingOverrides() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("parts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appendingPathComponent("openclaw.json")
        let rootSource = "{$include:['parts/base.json5','parts/agents.json5'],gateway:{port:19123},notes:'literal $include is ordinary text'}"
        try rootSource.write(to: main, atomically: true, encoding: .utf8)
        try "{gateway:{$include:'auth.json5',port:19000},agents:{list:[{id:'one'}]}}".write(to: folder.appendingPathComponent("parts/base.json5"), atomically: true, encoding: .utf8)
        try "{auth:{mode:'none'}}".write(to: folder.appendingPathComponent("parts/auth.json5"), atomically: true, encoding: .utf8)
        try "{agents:{list:[{id:'two'}]},gateway:{auth:{token:'fixture'}}}".write(to: folder.appendingPathComponent("parts/agents.json5"), atomically: true, encoding: .utf8)
        let config = try OpenClawConfiguration.load(directory: folder.path, environment: [:])
        XCTAssertEqual(try config.endpoint().port, 19123)
        XCTAssertEqual(config.agents?.roster.map(\.id), ["one", "two"])
        XCTAssertTrue(try config.auth(environment: [:]).isEmpty)
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), rootSource)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenClawConfigIncludes.read(main, environment: [:])) as? [String: Any])
        XCTAssertEqual(object["notes"] as? String, "literal $include is ordinary text")
    }

    func testOpenClawIncludesEnforceCyclesDepthFileTypeAndAllowedRootBoundaries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }
        let main = folder.appendingPathComponent("openclaw.json")
        let external = outside.appendingPathComponent("outside.json5")
        try "{gateway:{port:19111}}".write(to: external, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["$include": external.path]).write(to: main)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        XCTAssertNoThrow(try OpenClawConfigIncludes.read(main, environment: ["OPENCLAW_INCLUDE_ROOTS": outside.path]))
        let link = folder.appendingPathComponent("link.json5")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        try "{$include:'link.json5'}".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        XCTAssertNoThrow(try OpenClawConfigIncludes.read(main, environment: ["OPENCLAW_INCLUDE_ROOTS": outside.path]))
        try "{$include:'openclaw.json'}".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        let hardlink = folder.appendingPathComponent("hardlink.json5")
        try FileManager.default.linkItem(at: external, to: hardlink)
        try "{$include:'hardlink.json5'}".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        try "{$include:'subdirectory'}".write(to: main, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("subdirectory"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        for index in 1...11 {
            let content = index == 11 ? "{}" : "{$include:'depth\(index + 1).json5'}"
            try content.write(to: folder.appendingPathComponent("depth\(index).json5"), atomically: true, encoding: .utf8)
        }
        try "{$include:'depth1.json5'}".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        try "{$include:'depth2.json5'}".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try OpenClawConfigIncludes.read(main, environment: [:]))
    }

    func testOpenClawIncludesRejectInvalidGrammarAndBoundExpansion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appendingPathComponent("openclaw.json")
        try "[]".write(to: folder.appendingPathComponent("array.json5"), atomically: true, encoding: .utf8)
        for content in ["{$include:7}", "{$include:['array.json5',7]}", "{$include:'array.json5',gateway:{}}"] {
            try content.write(to: main, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        }
        try "{}".write(to: folder.appendingPathComponent("small.json5"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["$include": Array(repeating: "small.json5", count: 129)]).write(to: main)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
        let oversized = Data(repeating: 32, count: 2 * 1024 * 1024 + 1)
        try oversized.write(to: folder.appendingPathComponent("large.json5"))
        try "{$include:'large.json5'}".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenClawConfigIncludes.read(main, environment: [:]))
    }
}

/// OpenClaw sessions host delegation through the companion's node link.
extension PiOpenClawTests {
    func testOpenClawNodeDescriptorsUseTheReservedNodeMCPShape() throws {
        let descriptors = OpenClawNodeLink.descriptors(Delegation.tools)
        XCTAssertEqual(descriptors.count, Delegation.tools.count)
        XCTAssertLessThanOrEqual(descriptors.count, 128, "The Gateway keeps at most 128 per node")
        let pattern = try NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_-]{0,63}$")
        for (descriptor, tool) in zip(descriptors, Delegation.tools) {
            let name = try XCTUnwrap(descriptor["name"] as? String), original = try XCTUnwrap(tool["name"] as? String)
            XCTAssertEqual(name, "notch_" + original)
            XCTAssertNotNil(pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), name)
            XCTAssertEqual(ToolActivity.delegationTool(name), original, "Tool rows keep their companion labels")
            // node-mcp is trusted only with this exact command and an MCP route.
            XCTAssertEqual(descriptor["pluginId"] as? String, "node-mcp")
            XCTAssertEqual(descriptor["command"] as? String, "mcp.tools.call.v1")
            XCTAssertEqual(descriptor["mcp"] as? [String: String], ["server": "notch", "tool": original])
            let description = try XCTUnwrap(descriptor["description"] as? String)
            XCTAssertTrue((1...1024).contains(description.count))
            XCTAssertEqual((descriptor["parameters"] as? [String: Any])?["type"] as? String, "object")
        }
        let old = try JSONSerialization.data(withJSONObject: ["privateKey": Data([1]).base64EncodedString(), "token": "operator", "scopes": ["operator.read"]])
        let device = try JSONDecoder().decode(OpenClawDevice.self, from: old)
        XCTAssertEqual(device.token, "operator", "An existing Keychain pairing still decodes")
        XCTAssertNil(device.nodeToken)
    }

    func testOpenClawNodeInvocationsOutsideTheCompanionAreRefused() async throws {
        func request(_ command: String = "mcp.tools.call.v1", server: String = "notch") -> [String: Any] {
            ["id": "i", "nodeId": "n", "command": command, "timeoutMs": 120_000, "sessionKey": "agent:main:notch:x",
             "paramsJSON": #"{"server":"\#(server)","tool":"task_status","arguments":{"taskId":"t"}}"#]
        }
        let grant = OpenClawNodeLink.Grant(url: URL(string: "http://127.0.0.1:9/mcp")!, token: "t")
        for refused in [request("system.run"), request(server: "other"), request().merging(["paramsJSON": "not json"] as [String: Any]) { _, new in new }] {
            let reply = await OpenClawNodeLink.call(refused, grant: grant)
            XCTAssertEqual(reply["ok"] as? Bool, false)
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "INVALID_REQUEST")
        }
        // Another agent on the same Gateway sees the tools, but has no companion grant behind it.
        let reply = await OpenClawNodeLink.call(request(), grant: nil)
        let payload = try XCTUnwrap(reply["payload"] as? [String: Any])
        XCTAssertEqual(payload["isError"] as? Bool, true)
        XCTAssertTrue(((payload["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").contains("capability_denied"))
    }

    @MainActor
    func testOpenClawNodeLinkPublishesToolsAndServesOnlyCompanionSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("gateway.py"), portFile = directory.appendingPathComponent("port"), log = directory.appendingPathComponent("node.log")
        // Two concurrent connections: the operator and the node. The first node
        // connect needs pairing; the second publishes before command approval.
        let source = #"""
        import socket,hashlib,base64,json,struct,sys,threading
        server=socket.socket();server.bind(('127.0.0.1',0));server.listen(8)
        open(sys.argv[1],'w').write(str(server.getsockname()[1]))
        log=open(sys.argv[2],'a');lock=threading.Lock();keys=[];nodes=[0]
        methods=['chat.send','chat.history','chat.abort','sessions.create','sessions.messages.subscribe','question.resolve','exec.approval.resolve']
        scopes=['operator.read','operator.write','operator.approvals','operator.questions']
        def record(kind,value):
          with lock: log.write(json.dumps({'kind':kind,'value':value})+'\n');log.flush()
        def exact(c,n):
          result=b''
          while len(result)<n:
            part=c.recv(n-len(result))
            if not part: raise EOFError()
            result+=part
          return result
        def frame(c,value):
          data=json.dumps(value).encode();n=len(data)
          header=bytes([129,n]) if n<126 else bytes([129,126])+struct.pack('!H',n)
          c.sendall(header+data)
        def event(c,name,payload): frame(c,{'type':'event','event':name,'payload':payload})
        def reply(c,r,payload): frame(c,{'type':'res','id':r['id'],'ok':True,'payload':payload})
        def read(c):
          a,b=exact(c,2)
          if a&15==8: raise EOFError()
          n=b&127
          if n==126:n=struct.unpack('!H',exact(c,2))[0]
          elif n==127:n=struct.unpack('!Q',exact(c,8))[0]
          mask=exact(c,4) if b&128 else None;data=exact(c,n)
          if mask:data=bytes(x^mask[i%4] for i,x in enumerate(data))
          return json.loads(data)
        def handle(c):
          node=None
          try:
            header=b''
            while b'\r\n\r\n' not in header:header+=c.recv(4096)
            key=[line.split(b':',1)[1].strip() for line in header.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:')][0]
            accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
            event(c,'connect.challenge',{'nonce':'fixture-challenge','ts':123456789})
            while True:
              r=read(c);m=r['method'];p=r['params']
              if m=='connect' and p['role']=='node':
                record('node.connect',p);node=p['device']['id']
                with lock: nodes[0]+=1;attempt=nodes[0]
                if attempt==1:
                  frame(c,{'type':'res','id':r['id'],'ok':False,'error':{'code':'NOT_PAIRED','message':'pairing required','details':{'code':'PAIRING_REQUIRED','requestId':'device-request-1'}}});return
                reply(c,r,{'type':'hello-ok','protocol':4,'auth':{'role':'node','scopes':[],'deviceToken':'node-token'},'features':{'methods':[]},'policy':{}})
              elif m=='connect':
                assert p['role']=='operator' and p['scopes']==scopes
                reply(c,r,{'type':'hello-ok','protocol':4,'auth':{'scopes':scopes},'features':{'methods':methods},'policy':{'tickIntervalMs':30000}})
              elif m=='sessions.create':
                with lock: keys.append(p['key'])
                reply(c,r,{'key':p['key'],'sessionId':'native-'+p['key']})
              elif m=='sessions.messages.subscribe':reply(c,r,{})
              elif m=='chat.history':reply(c,r,{'sessionKey':p['sessionKey'],'messages':[],'sessionInfo':{'hasActiveRun':False}})
              elif m=='node.pluginTools.update':
                record('node.pluginTools.update',p)
                reply(c,r,{'nodeId':node,'tools':[]})
                def invoke(i,key,command,call):
                  request={'id':i,'nodeId':node,'command':command,'paramsJSON':json.dumps(call),'timeoutMs':120000,'idempotencyKey':i}
                  if key: request['sessionKey']=key
                  event(c,'node.invoke.request',request)
                invoke('foreign','agent:existing:main','mcp.tools.call.v1',{'server':'notch','tool':'task_status','arguments':{'taskId':'t'}})
                invoke('owned',keys[1],'mcp.tools.call.v1',{'server':'notch','tool':'orchestrator_capabilities','arguments':{'search':'fixture'}})
                invoke('second',keys[2],'mcp.tools.call.v1',{'server':'notch','tool':'notch_session_list','arguments':{}})
                invoke('plain',keys[0],'mcp.tools.call.v1',{'server':'notch','tool':'notch_session_list','arguments':{}})
                invoke('command',keys[1],'system.run',{'server':'notch','tool':'orchestrator_capabilities'})
              elif m=='node.invoke.result':record('node.invoke.result',p);reply(c,r,{'ok':True})
              else:raise Exception('unhandled method '+m)
          except EOFError:pass
          finally:c.close()
        while True:
          c,_=server.accept();threading.Thread(target=handle,args=(c,),daemon=True).start()
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let gateway = Process(); gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); gateway.arguments = [script.path, portFile.path, log.path]
        gateway.standardOutput = FileHandle.nullDevice; gateway.standardError = FileHandle.nullDevice
        try gateway.run()
        defer { if gateway.isRunning { gateway.terminate() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try XCTUnwrap(Int(String(contentsOf: portFile, encoding: .utf8)))
        let config: [String: Any] = ["gateway": ["port": port, "auth": ["mode": "none"]], "agents": ["list": [["id": "existing", "workspace": directory.path]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("openclaw.json"))

        let server = DelegationServer()
        var calls: [(DelegationCaller, String, [String: Any])] = []
        server.tools = { _ in Delegation.tools }
        server.call = { caller, name, arguments in calls.append((caller, name, arguments)); return ["fixture": "answer"] }
        let url = try await server.start()
        defer { server.stop() }
        let first = server.issueToken(for: DelegationCaller(sessionID: "companion-1", runtime: .openclaw, subagent: false))
        let second = server.issueToken(for: DelegationCaller(sessionID: "companion-2", runtime: .openclaw, subagent: false))

        let client = OpenClawClient(profileID: RuntimeProfileIdentity.openClaw(directory: directory.path, agent: "existing"),
                                    device: OpenClawDevice(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation))
        defer { client.disconnect() }
        try await client.connect()
        var notices: [String] = []
        client.onEvent = { name, payload in if name == "runtime.notice" { notices.append(payload["message"] as? String ?? "") } }
        func frames(_ kind: String) -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                let row = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                return row?["kind"] as? String == kind ? row?["value"] as? [String: Any] : nil
            }
        }
        func eventually(_ condition: () -> Bool) async {
            for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        }

        _ = try await client.request("session.create", params: ["cwd": directory.path])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(frames("node.connect").isEmpty, "Without delegation no node link opens")
        _ = try await client.request("session.create", params: ["cwd": directory.path, "delegation": ["url": url.absoluteString, "token": first]])
        await eventually { notices.count == 1 }
        XCTAssertTrue(notices.first?.contains("device-request-1") == true, "\(notices)")
        XCTAssertTrue(notices.first?.contains("Chat keeps working") == true)
        // The next session that gets delegation tries again.
        _ = try await client.request("session.create", params: ["cwd": directory.path, "delegation": ["url": url.absoluteString, "token": second]])
        await eventually { frames("node.invoke.result").count == 5 }

        let connects = frames("node.connect")
        XCTAssertEqual(connects.count, 2)
        for connect in connects {
            XCTAssertEqual(connect["role"] as? String, "node")
            XCTAssertEqual((connect["client"] as? [String: Any])?["mode"] as? String, "node")
            XCTAssertEqual(connect["scopes"] as? [String], [])
            XCTAssertEqual(connect["commands"] as? [String], ["mcp.tools.call.v1"])
            XCTAssertEqual((connect["device"] as? [String: Any])?["nonce"] as? String, "fixture-challenge")
        }
        let published = try XCTUnwrap(frames("node.pluginTools.update").first?["tools"] as? [[String: Any]])
        XCTAssertEqual(published.compactMap { $0["name"] as? String }, OpenClawNodeLink.descriptors(Delegation.tools).compactMap { $0["name"] as? String })
        await eventually { notices.count == 2 }
        XCTAssertTrue(notices.last?.contains("openclaw nodes approve") == true, "Filtered tools need the user's approval in OpenClaw: \(notices)")

        let results = Dictionary(frames("node.invoke.result").map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        let node = (connects.last?["device"] as? [String: Any])?["id"] as? String
        XCTAssertNotNil(node)
        XCTAssertTrue(results.values.allSatisfy { $0["nodeId"] as? String == node })
        // A companion session opened without delegation is refused like a foreign one.
        for refused in ["foreign", "plain"] {
            let payload = try XCTUnwrap(results[refused]?["payload"] as? [String: Any], refused)
            XCTAssertEqual(payload["isError"] as? Bool, true, refused)
            XCTAssertTrue(((payload["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").contains("capability_denied"), refused)
        }
        let owned = try XCTUnwrap(results["owned"]?["payload"] as? [String: Any])
        XCTAssertEqual(owned["isError"] as? Bool, false)
        XCTAssertEqual((owned["structuredContent"] as? [String: Any])?["fixture"] as? String, "answer")
        XCTAssertEqual(results["command"]?["ok"] as? Bool, false)
        // Each call runs as the companion session that owns the calling key, with its own token.
        XCTAssertEqual(Set(calls.map { $0.0.sessionID + ":" + $0.1 }), ["companion-1:orchestrator_capabilities", "companion-2:notch_session_list"])
        XCTAssertEqual(calls.first { $0.1 == "orchestrator_capabilities" }?.2["search"] as? String, "fixture")
        XCTAssertTrue(gateway.isRunning, "The existing Gateway is never stopped")
    }
}
