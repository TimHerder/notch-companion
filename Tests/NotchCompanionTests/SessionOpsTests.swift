import XCTest
@testable import NotchCompanion

@MainActor private final class SessionOpsTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    var pausedMethod = "none"
    var pending: CheckedContinuation<[String: Any], Error>?
    var created = "fresh"
    var history: [[String: Any]] = []

    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if method == pausedMethod { return try await withCheckedThrowingContinuation { pending = $0 } }
        switch method {
        case "session.create": return ["session_id": "live-\(created)", "stored_session_id": created, "messages": []]
        case "session.resume": return ["session_id": "live-resumed", "stored_session_id": params["session_id"] ?? "", "messages": history]
        default: return [:]
        }
    }
    func finish(_ result: [String: Any]) { let continuation = pending; pending = nil; continuation?.resume(returning: result) }
    func methods(_ name: String) -> [[String: Any]] { calls.filter { $0.0 == name }.map(\.1) }
}

@MainActor final class SessionOpsTests: XCTestCase {
    private var folder: URL!
    private var transport: SessionOpsTransport!
    private var model: AppModel!
    private var preferences: UserDefaults!
    private var suite: String!
    private var storage: URL { folder.appendingPathComponent("sessions.json") }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("session-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transport = SessionOpsTransport()
        suite = "session-ops-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        model = AppModel(storageURL: storage, playsSounds: false, client: transport, preferences: preferences)
        await model.connect()
    }
    override func tearDown() async throws {
        model.shutdown()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A started, idle conversation with one finished turn.
    private func started(_ runtime: RuntimeKind = .codex) {
        model.sessions[0].runtime = runtime
        model.sessions[0].profileID = RuntimeRoute.defaultProfile(runtime)
        model.sessions[0].runtimeID = "live-old"
        model.sessions[0].storedID = "old"
        model.sessions[0].title = "Fix the build"
        model.sessions[0].state = .finished
        model.sessions[0].workspacePath = folder.path
        model.sessions[0].trustedProjectPath = folder.path
        model.sessions[0].messages = [ChatMessage(id: "u1", role: "user", text: "First", turnID: "u1"),
                                      ChatMessage(id: "a1", role: "assistant", text: "Done", turnID: "u1")]
        model.sessions[0].nativeSubmissionAttempted = true
        model.sessions[0].turnEndedAt["u1"] = Date()
        model.sessions[0].turnOutcome["u1"] = .finished
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    // MARK: Compact

    func testCompactIsOfferedOnlyWhereTheAppDrivesNativeCompaction() {
        started()
        for runtime in RuntimeKind.allCases {
            model.sessions[0].runtime = runtime
            XCTAssertEqual(model.offersCompact(model.sessions[0]), [.codex, .claude, .pi, .hermes].contains(runtime), runtime.rawValue)
        }
        model.sessions[0].runtime = .hermes
        model.sessions[0].isLegacyPrivate = true
        XCTAssertFalse(model.offersCompact(model.sessions[0]))
        XCTAssertFalse(model.offersStartFresh(model.sessions[0]), "Legacy Hermes cannot open a new native session")
    }

    func testCompactWaitsForBusyWorkUnconfirmedSendsAndQuestions() {
        started()
        XCTAssertTrue(model.canCompact(model.currentID!))
        model.sessions[0].state = .working
        XCTAssertFalse(model.canCompact(model.currentID!))
        model.sessions[0].state = .finished
        model.sessions[0].agents = [ChildAgent(id: "child", title: "Child", state: .working)]
        XCTAssertFalse(model.canCompact(model.currentID!), "A busy child blocks it")
        model.sessions[0].agents = []
        model.sessions[0].pendingSubmission = PendingSubmission(id: "x", draft: "x", userTurnCount: 2, attachmentIDs: [])
        XCTAssertFalse(model.canCompact(model.currentID!), "An unconfirmed send blocks it")
        XCTAssertFalse(model.canStartFresh(model.currentID!))
        model.sessions[0].pendingSubmission = nil
        model.requests = [PendingRequest(id: "q", kind: .clarification, title: "Q", detail: "?", choices: [], sessionID: "live-old")]
        XCTAssertFalse(model.canCompact(model.currentID!), "An open question blocks it")
        XCTAssertFalse(model.canStartFresh(model.currentID!))
        model.requests = []
        model.sessions[0].storedID = nil
        XCTAssertFalse(model.canCompact(model.currentID!), "Nothing to compact before the first message")
    }

    func testCompactRunsNativelyAndAddsAQuietRowWhileSendsWait() async throws {
        started()
        transport.pausedMethod = "session.compact"
        let task = Task { await model.compactContext(model.currentID!) }
        try await wait { transport.pending != nil }
        XCTAssertEqual(transport.methods("session.compact").first?["session_id"] as? String, "live-old")
        XCTAssertTrue(model.compactingSessionIDs.contains(model.currentID!))
        XCTAssertTrue(model.hasActiveWork, "Quit waits for a running compaction")
        model.draft = "Next"
        let sent = await model.submit(reply: nil)
        XCTAssertFalse(sent)
        XCTAssertEqual(model.errorMessage, "Wait for compaction to finish, then send.")
        XCTAssertTrue(transport.methods("prompt.submit").isEmpty)
        transport.finish(["summary": "Kept the plan and the failing test."])
        await task.value
        let marker = try XCTUnwrap(model.current?.messages.last)
        XCTAssertTrue(marker.isSessionMarker)
        XCTAssertEqual(marker.kind, ChatMessage.contextCompacted)
        XCTAssertEqual(marker.text, "Kept the plan and the failing test.")
        XCTAssertFalse(model.compactingSessionIDs.contains(model.currentID!))
        XCTAssertEqual(model.current?.latestResponse, "Done", "The row is not an answer")
        let timeline = ConversationTimeline.build(session: model.current!)
        XCTAssertEqual(timeline.last?.id, "message:\(marker.id)")
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: storage))[0]
        XCTAssertEqual(saved.messages.last?.kind, ChatMessage.contextCompacted)
    }

    // MARK: Start fresh

    func testStartFreshConfirmsThenOpensANewNativeSessionAndKeepsTheTranscript() async throws {
        started()
        var asked: String?
        model.startFreshDecision = { asked = $0; return false }
        model.startFresh(model.currentID!)
        XCTAssertEqual(model.current?.storedID, "old", "Declining changes nothing")
        XCTAssertTrue(asked?.contains("new Codex session") == true)

        model.startFreshDecision = { _ in true }
        model.startFresh(model.currentID!)
        let session = try XCTUnwrap(model.current)
        XCTAssertNil(session.storedID)
        XCTAssertNil(session.runtimeID)
        XCTAssertEqual(session.earlierStoredIDs, ["old"])
        XCTAssertEqual(session.messages.last?.kind, ChatMessage.newSession)
        XCTAssertEqual(session.messages.count, 3, "Everything before the divider stays")
        XCTAssertFalse(model.canStartFresh(model.currentID!), "Already fresh until the next message")

        transport.pausedMethod = "prompt.submit"
        model.draft = "Second"
        let send = Task { await model.submit(reply: nil) }
        try await wait { transport.pending != nil }
        XCTAssertTrue(transport.methods("session.resume").isEmpty, "The old native session is not resumed")
        let create = try XCTUnwrap(transport.methods("session.create").last)
        XCTAssertEqual(create["cwd"] as? String, folder.path, "Same folder")
        XCTAssertEqual(create["title"] as? String, "Fix the build", "The conversation keeps its name")
        XCTAssertEqual(model.current?.pendingSubmission?.userTurnCount, 1, "Counted within the new native session")
        transport.finish(["status": "streaming"])
        _ = await send.value
        XCTAssertEqual(model.current?.storedID, "fresh")
        XCTAssertEqual(model.current?.earlierStoredIDs, ["old"])

        // A later resume reads only the new native session's history.
        let secondID = try XCTUnwrap(model.current?.messages.last { $0.role == "user" }?.id)
        model.sessions[0].runtimeID = nil
        model.sessions[0].state = .finished
        model.sessions[0].parentTurnComplete = true
        transport.history = [["role": "user", "text": "Second"], ["role": "assistant", "text": "Fresh answer"]]
        _ = try await model.ensureRuntime(model.currentID!)
        XCTAssertEqual(transport.methods("session.resume").last?["session_id"] as? String, "fresh")
        XCTAssertEqual(model.current?.messages.map(\.text), ["First", "Done", "", "Second", "Fresh answer"])
        XCTAssertEqual(model.current?.messages[3].id, secondID)
        let items = ConversationTimeline.build(session: model.current!).map(\.id)
        XCTAssertTrue(items.contains("message:\(model.current!.messages[2].id)"), "The New session divider renders")
    }

    func testStartFreshIsNotOfferedForDelegatedChildren() {
        started()
        model.sessions[0].parentSessionID = "parent"
        XCTAssertFalse(model.offersStartFresh(model.sessions[0]))
        model.startFreshDecision = { _ in XCTFail("Never asked"); return true }
        model.startFresh(model.currentID!)
        XCTAssertEqual(model.sessions[0].storedID, "old")
    }

    func testRestoringASegmentKeepsEarlierSegmentsAndCompactionRows() {
        let earlier = [ChatMessage(id: "u0", role: "user", text: "Old"), ChatMessage(id: "a0", role: "assistant", text: "Old answer"),
                       ChatMessage(id: "div", role: "system", text: "", kind: ChatMessage.newSession)]
        let current = [ChatMessage(id: "u1", role: "user", text: "One"), ChatMessage(id: "a1", role: "assistant", text: "Answer one"),
                       ChatMessage(id: "c1", role: "system", text: "Summary", kind: ChatMessage.contextCompacted),
                       ChatMessage(id: "u2", role: "user", text: "Two")]
        let rows: [[String: Any]] = [["role": "user", "text": "One"], ["role": "assistant", "text": "Answer one"],
                                     ["role": "user", "text": "Two"], ["role": "assistant", "text": "Answer two"]]
        let restored = SessionHistory.restoringSegment(rows, into: earlier + current)
        XCTAssertEqual(restored?.map(\.id).prefix(6), ["u0", "a0", "div", "u1", "a1", "c1"])
        XCTAssertEqual(restored?.map(\.text).suffix(2), ["Two", "Answer two"])
        XCTAssertNil(SessionHistory.restoringSegment([], into: earlier), "An empty new session keeps what was saved")
    }

    // MARK: Resume at reset

    private func limitStopped(reached: Bool = true) -> Date {
        started()
        model.sessions[0].runtimeID = "live-old"
        model.sessions[0].messages.append(ChatMessage(id: "u2", role: "user", text: "Keep going", turnID: "u2"))
        model.sessions[0].state = .working
        model.sessions[0].parentTurnComplete = false
        let reset = Date().addingTimeInterval(3_600)
        model.receive("runtime.rateLimits", payload: ["runtime": "codex",
            "limits": [RuntimeRateLimit(name: "5-hour", usedPercent: reached ? 100 : 40, resetsAt: reset, reached: reached)]])
        model.receive("message.start", payload: ["session_id": "live-old", "role": "assistant"])
        model.receive("message.complete", payload: ["session_id": "live-old", "text": "", "status": "error", "limit_reached": true])
        return reset
    }

    func testALimitStoppedTurnReadsItsResetAndResumesThroughTheQueue() async throws {
        let reset = limitStopped()
        let session = try XCTUnwrap(model.current)
        XCTAssertEqual(session.limitResets["u2"], reset)
        let work = ConversationTimeline.build(session: session).compactMap { item -> TurnWork? in if case .work(let work) = item { return work }; return nil }.last
        XCTAssertEqual(work?.label, "Limit reached · resets " + SnoozeChoice.time(reset))
        XCTAssertEqual(work?.turnRowID, "u2")
        XCTAssertTrue(model.canResumeAtReset(session.id, turn: "u2"))
        XCTAssertFalse(model.canResumeAtReset(session.id, turn: "u1"), "Only the limit-stopped turn")

        model.resumeAtReset(session.id, turn: "u2")
        let entry = try XCTUnwrap(model.current?.queuedSends.first)
        XCTAssertEqual(entry.text, "Continue where you left off.")
        XCTAssertEqual(entry.notBefore, reset)
        XCTAssertEqual(entry.resumesTurnID, "u2")
        XCTAssertFalse(model.canResumeAtReset(session.id, turn: "u2"), "One resume at a time")
        XCTAssertFalse(model.hasActiveWork, "A resume waiting for its time does not hold Quit")
        model.processDelegationWakes()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(transport.methods("prompt.submit").isEmpty, "Not before the reset")

        model.sendResumeNow(entry.id)
        try await wait { !transport.methods("prompt.submit").isEmpty }
        XCTAssertEqual(transport.methods("prompt.submit").last?["text"] as? String, "Continue where you left off.")
        try await wait { model.current?.queuedSends.isEmpty == true }
        XCTAssertEqual(model.current?.messages.last { $0.role == "user" }?.id, entry.id, "Sent through the normal send path")
    }

    func testAResumeNeverFollowsANewerMessageAnotherFailureOrAMissingReset() async throws {
        _ = limitStopped()
        let id = model.currentID!
        model.resumeAtReset(id, turn: "u2")
        XCTAssertEqual(model.current?.queuedSends.count, 1)
        // A message sent meanwhile supersedes it.
        model.draft = "Something else"
        await model.submit(reply: nil)
        XCTAssertTrue(model.current?.queuedSends.isEmpty == true)

        // One that came due after another row arrived is dropped at delivery.
        _ = limitStopped()
        model.resumeAtReset(id, turn: "u2")
        model.sessions[0].messages.append(ChatMessage(id: "wake", role: "user", text: "From another session", turnID: "wake", kind: ChatMessage.agentMessage))
        let entry = try XCTUnwrap(model.current?.queuedSends.first)
        let before = transport.methods("prompt.submit").count
        model.sendResumeNow(entry.id)
        try await wait { model.current?.queuedSends.isEmpty == true }
        XCTAssertEqual(transport.methods("prompt.submit").count, before)

        // Another failure reason or an unknown reset offers nothing.
        started()
        model.sessions[0].messages.append(ChatMessage(id: "u3", role: "user", text: "Again", turnID: "u3"))
        model.sessions[0].state = .working
        model.receive("message.complete", payload: ["session_id": "live-old", "text": "", "status": "error"])
        XCTAssertNil(model.current?.limitResets["u3"])
        XCTAssertFalse(model.canResumeAtReset(id, turn: "u3"))
    }

    func testResumeAutomaticallySchedulesAndSurvivesRestart() async throws {
        model.resumeAutomatically = true
        let reset = limitStopped()
        model.sessions[0].queuedSends.append(QueuedSend(id: "mine", text: "Queued by hand"))
        XCTAssertEqual(model.current?.queuedSends.first?.notBefore, reset)
        XCTAssertTrue(model.save())
        model.shutdown()

        let reopened = AppModel(storageURL: storage, playsSounds: false, client: transport, preferences: preferences)
        defer { reopened.shutdown() }
        XCTAssertTrue(reopened.resumeAutomatically)
        let queue = try XCTUnwrap(reopened.sessions.first?.queuedSends)
        XCTAssertNil(queue.first { $0.resumesTurnID != nil }?.paused, "Still sent once due after a restart")
        XCTAssertEqual(queue.first { $0.id == "mine" }?.paused, true, "Ordinary queued messages pause as before")
        XCTAssertNotNil(reopened.resumeTimer)
    }

    func testOlderRegistriesDecodeWithoutTheNewFields() throws {
        let json = #"[{"id":"s","runtime":"codex","queuedSends":[{"id":"q","text":"Later"}]}]"#
        let session = try XCTUnwrap(JSONDecoder().decode([CompanionSession].self, from: Data(json.utf8)).first)
        XCTAssertNil(session.earlierStoredIDs)
        XCTAssertEqual(session.limitResets, [:])
        XCTAssertNil(session.queuedSends.first?.notBefore)
        XCTAssertNil(session.queuedSends.first?.resumesTurnID)
        XCTAssertTrue(session.queuedSends.first?.isDue() == true)
    }
}

/// The harnesses' own compaction and limit signals, against protocol fixtures.
@MainActor final class SessionOpsProtocolTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-session-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func executable(_ source: String) throws -> URL {
        let url = directory.appendingPathComponent("fixture-cli")
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testCodexCompactsThroughItsOwnTurnWithoutAConversationTurnAndFlagsUsageLimits() async throws {
        let script = #"""
        #!/usr/bin/python3
        import json, sys
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            if "id" not in frame: continue
            method = frame["method"]
            result = {}
            if method == "thread/start": result = {"thread": {"id": "thread"}}
            if method == "turn/start": result = {"turn": {"id": "work", "status": "inProgress"}}
            send({"id": frame["id"], "result": result})
            if method == "thread/compact/start":
                send({"method": "turn/started", "params": {"threadId": "thread", "turn": {"id": "compact"}}})
                send({"method": "item/started", "params": {"threadId": "thread", "turnId": "compact", "item": {"type": "contextCompaction", "id": "c"}}})
                send({"method": "item/agentMessage/delta", "params": {"threadId": "thread", "turnId": "compact", "itemId": "m", "delta": "hidden"}})
                send({"method": "thread/tokenUsage/updated", "params": {"threadId": "thread", "turnId": "compact", "tokenUsage": {"total": {"totalTokens": 900}, "last": {"totalTokens": 12}}}})
                send({"method": "turn/completed", "params": {"threadId": "thread", "turn": {"id": "compact", "status": "completed"}}})
            if method == "turn/start":
                send({"method": "turn/started", "params": {"threadId": "thread", "turn": {"id": "work"}}})
                send({"method": "turn/completed", "params": {"threadId": "thread", "turn": {"id": "work", "status": "failed",
                      "error": {"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"}}}})
        """#
        let client = CodexClient(profileID: directory.path, executable: try executable(script))
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let created = try await client.request("session.create", params: [:])
        let sid = try XCTUnwrap(created["session_id"] as? String)
        let result = try await client.request("session.compact", params: ["session_id": sid])
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(events.contains { ["message.start", "message.delta", "message.complete", "tool.start"].contains($0.0) }, "\(events.map(\.0))")
        XCTAssertTrue(events.contains { $0.0 == "session.info" && $0.1["usage"] != nil }, "The gauge's next sample passes")
        XCTAssertFalse(events.contains { $0.1["turn_tokens"] != nil })
        _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": "go"])
        try await wait { events.contains { $0.0 == "message.complete" } }
        let complete = try XCTUnwrap(events.last { $0.0 == "message.complete" })
        XCTAssertEqual(complete.1["status"] as? String, "error")
        XCTAssertEqual(complete.1["limit_reached"] as? Bool, true)
    }

    func testCodexCompactionFailureIsReported() async throws {
        var state = CodexProtocolState()
        _ = try state.register(["id": "thread"])
        state.compactingThreads.insert("thread")
        XCTAssertTrue(state.notifications("turn/started", ["threadId": "thread", "turn": ["id": "c"]]).isEmpty)
        XCTAssertEqual(state.activeTurns["thread"], "c", "Sends wait for the compaction turn")
        XCTAssertTrue(state.notifications("error", ["threadId": "thread", "turnId": "c", "willRetry": false, "error": ["message": "boom"]]).isEmpty)
        let done = state.notifications("turn/completed", ["threadId": "thread", "turn": ["id": "c", "status": "failed", "error": ["message": "boom"]]])
        XCTAssertEqual(done.map(\.name), ["session.compacted"])
        XCTAssertEqual(done.first?.payload["error"] as? String, "boom")
        XCTAssertNil(state.activeTurns["thread"])
        let other = state.notifications("turn/completed", ["threadId": "thread", "turn": ["id": "w", "status": "failed", "error": ["message": "x", "codexErrorInfo": "rateLimitExceeded"]]])
        XCTAssertNil(other.last?.payload["limit_reached"], "A provider rate limit is not the account's usage limit")
    }

    func testClaudeCompactsWithItsSlashCommandAndNeedsTheBoundary() async throws {
        let script = #"""
        #!/usr/bin/env python3
        import json, sys
        sid = next(a.split('=',1)[1] for a in sys.argv if a.startswith('--session-id='))
        def emit(value):
            value['session_id'] = sid
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            if frame['type'] == 'control_request':
                emit({'type':'control_response','response':{'subtype':'success','request_id':frame['request_id'],'response':{'models':[]}}})
                continue
            content = frame['message']['content']
            text = content if isinstance(content, str) else content[0]['text']
            emit({'type':'system','subtype':'session_state_changed','state':'running'})
            if text == '/compact':
                emit({'type':'system','subtype':'status','status':'compacting'})
                emit({'type':'system','subtype':'compact_boundary','compact_metadata':{'trigger':'manual','pre_tokens':1000}})
                emit({'type':'assistant','message':{'content':[{'type':'text','text':'hidden'}]}})
                emit({'type':'result','result':'','is_error':False,'modelUsage':{}})
            elif text == '/compact-without-boundary':
                emit({'type':'result','result':'','is_error':False})
            else:
                emit({'type':'rate_limit_event','rate_limit_info':{'status':'rejected','rateLimitType':'five_hour','resetsAt':4102444800,'utilization':1.0}})
                emit({'type':'assistant','error':'rate_limit','message':{'content':[{'type':'text','text':'Limit reached'}]}})
                emit({'type':'result','result':'Limit reached','is_error':True})
            emit({'type':'system','subtype':'session_state_changed','state':'idle'})
        """#
        let client = ClaudeClient(profileID: directory.path, executableURL: try executable(script))
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let created = try await client.request("session.create", params: ["cwd": directory.path, "project_trusted": true])
        let sid = try XCTUnwrap(created["session_id"] as? String)
        events.removeAll()
        _ = try await client.request("session.compact", params: ["session_id": sid])
        XCTAssertFalse(events.contains { ["message.start", "message.delta", "message.complete", "session.error"].contains($0.0) }, "\(events.map(\.0))")
        XCTAssertTrue(events.contains { $0.0 == "session.info" && $0.1["context_reset"] as? Bool == true }, "The gauge clears until the next report")

        _ = try await client.request("prompt.submit", params: ["session_id": sid, "turn_id": "turn", "text": "go"])
        try await wait { events.contains { $0.0 == "message.complete" } }
        XCTAssertEqual(events.last { $0.0 == "message.complete" }?.1["limit_reached"] as? Bool, true)
        let limits = try XCTUnwrap(events.first { $0.0 == "runtime.rateLimits" }?.1["limits"] as? [RuntimeRateLimit])
        XCTAssertEqual(limits.first?.reached, true)
        XCTAssertEqual(limits.first?.resetsAt, Date(timeIntervalSince1970: 4_102_444_800))
    }

    func testClaudeCompactionStateRequiresTheNativeBoundary() throws {
        var state = ClaudeProtocolState(sessionID: "s")
        try state.beginCompaction("c")
        let events = try state.receive(["type": "result", "result": "", "is_error": false])
        XCTAssertEqual(events.map(\.name).filter { $0 != "session.info" }, ["session.compacted"])
        XCTAssertEqual(events.last?.payload["status"] as? String, "error")
        XCTAssertFalse(state.compacting)
    }

    func testHermesCompactsWithItsOwnCompressMethod() async throws {
        var sent: [(String, [String: Any])] = []
        // Result shapes from Hermes 0.22.3's `SessionCompressResult`.
        _ = try await SharedHermesClient.compact(sessionID: "live") { method, params in
            sent.append((method, params))
            return ["status": "compressed", "removed": 30, "summary": ["headline": "Compressed 40 → 10 messages", "noop": false, "aborted": false]]
        }
        XCTAssertEqual(sent.map(\.0), ["session.compress"])
        XCTAssertEqual(sent.first?.1 as? [String: String], ["session_id": "live"], "No companion-only fields")
        for refusal: [String: Any] in [["status": "aborted", "summary": ["aborted": true]],
                                       ["compressed": false, "lock_held": true, "message": "Another client is compressing this session."]] {
            do {
                _ = try await SharedHermesClient.compact(sessionID: "live") { _, _ in refusal }
                XCTFail("Only a compressed status succeeds")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testPiCompactsWithItsRPCCommandAndReturnsTheSummary() async throws {
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        if '--version' in sys.argv: print('1.0.2'); sys.exit(0)
        path = os.path.join(os.environ['PI_CODING_AGENT_DIR'], 'native-session.jsonl')
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            r = json.loads(line); t = r['type']; data = {}
            if t == 'get_state': data = {'sessionFile': path, 'isStreaming': False, 'isCompacting': False, 'pendingMessageCount': 0, 'model': {'id': 'm', 'provider': 'p'}}
            if t == 'get_messages': data = {'messages': []}
            if t == 'get_available_models': data = {'models': [{'id': 'm', 'provider': 'p'}]}
            if t == 'get_session_stats': data = {'contextUsage': {'tokens': 3000, 'contextWindow': 100000}}
            if t == 'compact':
                send({'type': 'compaction_start', 'reason': 'manual'})
                send({'type': 'compaction_end', 'reason': 'manual', 'result': {'summary': 'Kept the plan.'}, 'aborted': False, 'willRetry': False})
                data = {'summary': 'Kept the plan.', 'firstKeptEntryId': 'e', 'tokensBefore': 150000, 'estimatedTokensAfter': 3000}
            send({'id': r['id'], 'type': 'response', 'command': t, 'success': True, 'data': data})
        """#
        let client = PiClient(profileID: directory.path, executable: try executable(script))
        defer { client.disconnect() }
        var events: [(String, [String: Any])] = []
        client.onEvent = { events.append(($0, $1)) }
        try await client.connect()
        let created = try await client.request("session.create", params: ["cwd": directory.path])
        let id = try XCTUnwrap(created["stored_session_id"] as? String)
        let result = try await client.request("session.compact", params: ["session_id": id])
        XCTAssertEqual(result["summary"] as? String, "Kept the plan.")
        XCTAssertFalse(events.contains { ["runtime.notice", "message.start", "message.complete"].contains($0.0) }, "\(events.map(\.0))")
        try await wait { events.contains { $0.0 == "session.info" } }
        var state = PiProtocolState()
        state.compacting = true
        XCTAssertTrue(state.consume(["type": "compaction_start", "reason": "manual"]).isEmpty)
        XCTAssertFalse(state.busy, "The app's own compaction is not a run")
    }
}
