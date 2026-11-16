import XCTest
@testable import NotchCompanion

@MainActor private final class ForkTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    var failing: [String: Error] = [:]
    var pauseCreate = false
    var paused: CheckedContinuation<Void, Never>?
    private var created = 0
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if let error = failing[method] { throw error }
        switch method {
        case "session.create":
            if pauseCreate { await withCheckedContinuation { paused = $0 } }
            created += 1
            return ["session_id": "live-\(created)", "stored_session_id": "fork-\(created)", "messages": []]
        case "session.resume": return ["session_id": "live-resumed", "stored_session_id": params["session_id"] ?? "", "messages": []]
        default: return [:]
        }
    }
}

@MainActor final class ForkTests: XCTestCase {
    private var folder: URL!
    private var transport: ForkTransport!
    private var model: AppModel!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transport = ForkTransport()
        suite = "fork-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport, preferences: preferences)
        await model.connect()
    }
    override func tearDown() async throws {
        model.shutdown()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Two finished turns; the first answer keeps a native message ID.
    private func source(_ runtime: RuntimeKind = .codex) -> CompanionSession {
        var session = CompanionSession(id: "source", runtimeID: "live-source", storedID: "thread-source", title: "Parser fix",
            messages: [ChatMessage(id: "u1", role: "user", text: "Fix the parser.", turnID: "u1"),
                       ChatMessage(id: "a1", role: "assistant", text: "Fixed it.", turnID: "u1", nativeID: "uuid-a1"),
                       ChatMessage(id: "hermes-item-2", role: "user", text: "Add a test.", turnID: "hermes-item-2"),
                       ChatMessage(id: "a2", role: "assistant", text: "Added one.", turnID: "hermes-item-2")],
            workspacePath: folder.path)
        session.runtime = runtime
        session.state = .finished
        session.tools = [ToolActivity(id: "t1", name: "Terminal", detail: "swift test", state: .finished, turnID: "u1"),
                         ToolActivity(id: "t2", name: "Terminal", detail: "swift build", state: .finished, turnID: "hermes-item-2")]
        session.permissionMode = .autoEdit
        session.modelOverride = RuntimeModelChoice(model: "gpt-fixture")
        return session
    }

    // MARK: Protocol fixtures

    func testCodexForkTurnMatchesClientItemOrTurnIDAndRefusesRunningTurns() {
        let thread: [String: Any] = ["turns": [
            ["id": "turn-1", "status": "completed", "items": [["type": "userMessage", "id": "item-1", "clientId": "u1"], ["type": "agentMessage", "text": "Fixed it."]]],
            ["id": "turn-2", "status": "completed", "items": [["type": "userMessage", "id": "item-2"], ["type": "userMessage", "id": "item-3", "clientId": "steer"]]],
            ["id": "turn-3", "status": "inProgress", "items": [["type": "userMessage", "id": "item-4", "clientId": "u4"]]]
        ]]
        XCTAssertEqual(CodexProtocolState.forkTurn(thread, userMessageIDs: ["u1"]), "turn-1")
        XCTAssertNil(CodexProtocolState.forkTurn(thread, userMessageIDs: ["hermes-item-2", "item-2"]), "a steer continued this answer's turn")
        XCTAssertEqual(CodexProtocolState.forkTurn(thread, userMessageIDs: ["steer"]), "turn-2", "the steer's answer ends the turn")
        XCTAssertEqual(CodexProtocolState.forkTurn(thread, userMessageIDs: ["turn-1"]), "turn-1")
        XCTAssertNil(CodexProtocolState.forkTurn(thread, userMessageIDs: ["u4"]), "a running turn cannot be forked through")
        XCTAssertNil(CodexProtocolState.forkTurn(thread, userMessageIDs: ["missing", ""]))
    }

    func testClaudeForkArgumentsResumeTheSourceUnderANewID() throws {
        let id = "8a7c9e3d-1f2b-4c5d-8e9f-0a1b2c3d4e5f", source = "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"
        let args = try ClaudeClient.arguments(id: id, resume: false, fork: (source: source, at: "msg-uuid"))
        XCTAssertTrue(args.contains("--session-id=\(id)"))
        XCTAssertTrue(args.contains("--resume=\(source)"))
        XCTAssertTrue(args.contains("--fork-session"))
        XCTAssertTrue(args.contains("--resume-session-at=msg-uuid"))
        let whole = try ClaudeClient.arguments(id: id, resume: false, fork: (source: source, at: nil))
        XCTAssertFalse(whole.contains { $0.hasPrefix("--resume-session-at") })
        XCTAssertFalse(try ClaudeClient.arguments(id: id, resume: false).contains("--fork-session"))
        XCTAssertThrowsError(try ClaudeClient.arguments(id: id, resume: false, fork: (source: "--continue", at: nil)))
    }

    func testClaudeCompletionReportsTheTurnsLastTopLevelAssistantUUID() throws {
        var state = ClaudeProtocolState(sessionID: "s")
        try state.begin("turn")
        _ = try state.receive(["type": "assistant", "uuid": "parent-1", "message": ["content": [["type": "tool_use", "id": "agent", "name": "Agent", "input": [:]]]]])
        _ = try state.receive(["type": "assistant", "uuid": "child-1", "parent_tool_use_id": "agent", "message": ["content": [["type": "text", "text": "child"]]]])
        _ = try state.receive(["type": "assistant", "uuid": "parent-2", "message": ["content": [["type": "text", "text": "Done."]]]])
        let events = try state.receive(["type": "result", "result": "Done."])
        let complete = try XCTUnwrap(events.first { $0.name == "message.complete" })
        XCTAssertEqual(complete.payload["native_message_id"] as? String, "parent-2")
    }

    // MARK: Availability

    func testForkPointFollowsEachHarnesssNativeFork() {
        let codex = source()
        XCTAssertEqual(model.forkPoint("a2", in: codex)?.userMessageIDs, ["hermes-item-2", "item-2"])
        XCTAssertEqual(model.forkPoint("a1", in: codex)?.latest, false)
        XCTAssertNil(model.forkPoint("u1", in: codex), "only answers fork")
        var claude = source(.claude)
        XCTAssertEqual(model.forkPoint("a1", in: claude)?.nativeMessageID, "uuid-a1")
        XCTAssertEqual(model.forkPoint("a2", in: claude)?.latest, true, "the latest answer forks the whole session")
        claude.messages.append(ChatMessage(id: "u3", role: "user", text: "Failed turn", turnID: "u3"))
        XCTAssertNil(model.forkPoint("a2", in: claude), "without its message ID an earlier answer cannot be forked")
        for runtime in [RuntimeKind.hermes, .opencode, .pi, .openclaw, .deepseek, .antigravity, .cursor, .copilot] {
            XCTAssertNil(model.forkPoint("a2", in: source(runtime)), runtime.rawValue)
        }
        var running = codex
        running.parentTurnComplete = false
        XCTAssertNil(model.forkPoint("a2", in: running), "the running turn's text is not finished")
        XCTAssertNotNil(model.forkPoint("a1", in: running))
        var unsaved = codex
        unsaved.storedID = nil
        XCTAssertNil(model.forkPoint("a2", in: unsaved))
    }

    func testCodexHidesAnAnswerALaterSteerContinued() {
        var session = source()
        session.messages.insert(ChatMessage(id: "steer", role: "user", text: "Also the docs.", turnID: "u1"), at: 2)
        session.messages.insert(ChatMessage(id: "a1b", role: "assistant", text: "Docs too.", turnID: "u1"), at: 3)
        XCTAssertNil(model.forkPoint("a1", in: session))
        XCTAssertEqual(model.forkPoint("a1b", in: session)?.userMessageIDs, ["steer", "u1"])
    }

    func testForkCreationCountsAsWorkForTheSourceAndTheFork() async throws {
        model.sessions = [source()]
        transport.pauseCreate = true
        let forking = Task { await model.forkFromHere("a1", in: "source") }
        for _ in 0..<100 where transport.paused == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(transport.paused, "the native fork is still opening")
        XCTAssertTrue(model.hasActiveWork)
        XCTAssertTrue(model.isSubmitting("source"))
        XCTAssertNotNil(model.forkBlocker(model.sessions.first { $0.id == "source" }!))
        let fork = try XCTUnwrap(model.sessions.first { $0.forkedFrom != nil }).id
        XCTAssertTrue(model.isSubmitting(fork))
        XCTAssertFalse(model.canArchiveSession(fork))
        transport.paused?.resume()
        await forking.value
        XCTAssertFalse(model.hasActiveWork)
        XCTAssertFalse(model.isSubmitting("source"))
    }

    func testAWholeSessionForkIsNotMadeAgainOnceTheSourceMovedOn() async throws {
        var fork = CompanionSession(id: "fork", storedID: "old", title: "Parser fix", workspacePath: folder.path)
        fork.runtime = .claude
        model.sessions = [source(.claude)]
        fork.forkedFrom = model.forkPoint("a2", in: model.sessions[0])
        XCTAssertNil(fork.forkedFrom?.nativeMessageID)
        model.sessions.append(fork)
        XCTAssertNil(model.reforkBlocker(fork.forkedFrom!))
        model.update("source") { $0.messages.append(ChatMessage(id: "u3", role: "user", text: "More", turnID: "u3")) }
        XCTAssertNotNil(model.reforkBlocker(fork.forkedFrom!))
        do { _ = try await model.ensureRuntime("fork"); XCTFail("re-forking a moved source must fail") } catch {}
        XCTAssertFalse(transport.calls.contains { $0.0 == "session.create" })
    }

    func testForkWaitsForTheTreeAndAnUnconfirmedSend() {
        model.sessions = [source()]
        XCTAssertNil(model.forkBlocker(model.sessions[0]))
        model.sessions[0].pendingSubmission = PendingSubmission(id: "p", draft: "x", userTurnCount: 2, attachmentIDs: [])
        XCTAssertEqual(model.forkBlocker(model.sessions[0]), "Check the last send first.")
        model.sessions[0].pendingSubmission = nil
        var child = CompanionSession(id: "child", title: "Review", state: .working, workspacePath: folder.path)
        child.parentSessionID = "source"
        model.sessions.append(child)
        XCTAssertNotNil(model.forkBlocker(model.sessions[0]), "a working child blocks the fork")
    }

    // MARK: Fork from here

    func testForkFromHereCreatesANativeForkAndLeavesTheSourceAlone() async throws {
        model.sessions = [source()]
        let before = model.sessions[0]
        await model.forkFromHere("a1", in: "source")
        XCTAssertEqual(model.sessions.count, 2)
        let fork = model.sessions[0]
        XCTAssertEqual(model.currentID, fork.id)
        XCTAssertNil(fork.parentSessionID)
        XCTAssertEqual(fork.messages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(fork.tools.map(\.id), ["t1"])
        XCTAssertEqual(fork.forkedFrom?.sourceSessionID, "source")
        XCTAssertEqual(fork.forkedFrom?.sourceTitle, "Parser fix")
        XCTAssertEqual(fork.storedID, "fork-1")
        XCTAssertEqual(fork.permissionMode, .autoEdit)
        XCTAssertEqual(fork.modelOverride?.model, "gpt-fixture")
        XCTAssertEqual(fork.workspacePath, folder.path)
        let create = try XCTUnwrap(transport.calls.first { $0.0 == "session.create" }?.1)
        let parameters = try XCTUnwrap(create["fork"] as? [String: Any])
        XCTAssertEqual(parameters["session_id"] as? String, "thread-source")
        XCTAssertEqual(parameters["message_ids"] as? [String], ["u1"])
        XCTAssertEqual(model.sessions[1], before, "the source session is never modified")
        XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
    }

    func testAFailedForkLeavesNothingBehind() async {
        model.sessions = [source()]
        transport.failing["session.create"] = AppError("No such turn")
        await model.forkFromHere("a1", in: "source")
        XCTAssertEqual(model.sessions.map(\.id), ["source"])
        XCTAssertTrue(model.errorMessage?.contains("No such turn") == true)
    }

    func testAnUnsentForkForksAgainOnReopenThenResumesOnceSent() async throws {
        var fork = CompanionSession(id: "fork", storedID: "fork-old", title: "Parser fix", workspacePath: folder.path)
        fork.runtime = .codex
        fork.forkedFrom = model.forkPoint("a1", in: source())
        model.sessions = [fork]
        _ = try await model.ensureRuntime("fork")
        XCTAssertNotNil(transport.calls.last { $0.0 == "session.create" }?.1["fork"])
        XCTAssertEqual(model.sessions[0].storedID, "fork-1")
        model.sessions[0].runtimeID = nil
        model.sessions[0].nativeSubmissionAttempted = true
        _ = try await model.ensureRuntime("fork")
        XCTAssertEqual(transport.calls.last?.0, "session.resume")
        XCTAssertNil(transport.calls.last?.1["fork"])
    }

    func testForkRecordsDecodeFromOlderRegistries() throws {
        let old = try JSONDecoder().decode(CompanionSession.self, from: Data(#"{"id":"old","messages":[{"id":"m","role":"assistant","text":"Hi","createdAt":0}]}"#.utf8))
        XCTAssertNil(old.forkedFrom)
        XCTAssertNil(old.messages[0].nativeID)
        var fork = source()
        fork.forkedFrom = model.forkPoint("a1", in: source())
        let decoded = try JSONDecoder().decode(CompanionSession.self, from: JSONEncoder().encode(fork))
        XCTAssertEqual(decoded.forkedFrom, fork.forkedFrom)
        XCTAssertEqual(decoded.messages[1].nativeID, "uuid-a1")
    }

    // MARK: Side chat

    func testSideChatLivesUnderItsParentAndBringsItsAnswerBackOnce() async throws {
        model.sessions = [source()]
        await model.openSideChat("source")
        let chat = try XCTUnwrap(model.sessions.first { $0.isSideChat })
        XCTAssertEqual(chat.parentSessionID, "source")
        XCTAssertEqual(chat.title, "Side chat")
        XCTAssertEqual(chat.messages.map(\.id), ["u1", "a1", "hermes-item-2", "a2"])
        XCTAssertFalse(model.topLevelSessions.contains { $0.id == chat.id })
        let row = try XCTUnwrap(model.sessions[0].agents.first { $0.sessionID == chat.id })
        XCTAssertEqual(row.role, "side chat")
        XCTAssertNil(model.bringBackAnswer(chat), "copied answers are already in the parent")

        // The side chat works: the parent counts it like a child and cannot fork meanwhile.
        model.update(chat.id) { $0.state = .working }
        model.syncDelegatedChildren()
        XCTAssertTrue(model.sessions[0].isBusy)
        XCTAssertNotNil(model.forkBlocker(model.sessions[0]))

        model.update(chat.id) {
            $0.state = .finished
            $0.messages += [ChatMessage(id: "q", role: "user", text: "Is it safe?", turnID: "q"),
                            ChatMessage(id: "answer", role: "assistant", text: "Yes, it is safe.", turnID: "q")]
        }
        model.syncDelegatedChildren()
        XCTAssertNil(model.sessions.first { $0.id == chat.id }?.delegation, "no wake: a side chat is not a delegated task")
        let side = try XCTUnwrap(model.sessions.first { $0.id == chat.id })
        let expected = try XCTUnwrap(model.bringBackAnswer(side))
        model.update("source") { $0.runtimeID = nil } // keep the parent from sending in this test
        model.bringBack(chat.id)
        model.bringBack(chat.id)
        let queued = model.sessions[0].queuedSends
        XCTAssertEqual(queued.count, 1, "Bring back is sent once")
        XCTAssertEqual(queued.first?.id, expected.id)
        XCTAssertEqual(queued.first?.kind, ChatMessage.sideChatMessage)
        XCTAssertEqual(queued.first?.text, "From side chat:\n\nYes, it is safe.")
        XCTAssertEqual(ChatMessage(role: "user", text: "", kind: ChatMessage.sideChatMessage).agentLabel, "From side chat")
        XCTAssertTrue(model.broughtBack(model.sessions.first { $0.id == chat.id }!))
        XCTAssertEqual(model.currentID, "source")

        model.closeSideChat(chat.id)
        let closed = try XCTUnwrap(model.sessions.first { $0.id == chat.id })
        XCTAssertTrue(closed.isArchived)
        XCTAssertEqual(closed.messages.last?.text, "Yes, it is safe.", "history is kept")
    }

    func testBringBackGoesThroughTheParentsNormalSendPath() async throws {
        model.sessions = [source()]
        model.connection = true
        await model.openSideChat("source")
        let chat = try XCTUnwrap(model.sessions.first { $0.isSideChat }).id
        model.update(chat) { $0.messages.append(ChatMessage(id: "answer", role: "assistant", text: "Use a lookup table.", turnID: "q")) }
        model.bringBack(chat)
        for _ in 0..<100 where !transport.calls.contains(where: { $0.0 == "prompt.submit" }) { try await Task.sleep(nanoseconds: 10_000_000) }
        let submit = try XCTUnwrap(transport.calls.first { $0.0 == "prompt.submit" }?.1)
        XCTAssertEqual(submit["text"] as? String, "From side chat:\n\nUse a lookup table.")
        let parent = try XCTUnwrap(model.sessions.first { $0.id == "source" })
        XCTAssertEqual(parent.messages.last?.kind, ChatMessage.sideChatMessage)
        XCTAssertTrue(parent.queuedSends.isEmpty)
        XCTAssertTrue(model.broughtBack(try XCTUnwrap(model.sessions.first { $0.id == chat })), "a delivered answer stays brought back")
    }

    func testSideChatQuestionsStayInTheSideChatAndItsResultMarksTheParentUnread() async throws {
        var parent = source()
        parent.completionID = "seen"
        parent.acknowledgedCompletionID = "seen"
        model.sessions = [parent]
        await model.openSideChat("source")
        let chat = try XCTUnwrap(model.sessions.first { $0.isSideChat }).id
        model.queueQuestionNotice(childID: chat, requestID: "question")
        XCTAssertTrue(model.sessions[0].queuedSends.isEmpty, "a side chat's question is not relayed to the parent")
        model.update(chat) { $0.state = .working }
        model.syncDelegatedChildren()
        model.update(chat) { $0.state = .finished; $0.completionID = "chat-done" }
        model.currentID = "source"
        model.syncDelegatedChildren()
        XCTAssertTrue(model.sessions.first { $0.id == "source" }!.hasUnreadCompletion)
    }

    func testSideChatIsOnlyOfferedOnTopLevelSessionsOfForkingHarnesses() {
        XCTAssertNotNil(model.sideChatPoint(source()))
        XCTAssertNil(model.sideChatPoint(source(.opencode)))
        var child = source()
        child.parentSessionID = "parent"
        XCTAssertNil(model.sideChatPoint(child))
    }
}
