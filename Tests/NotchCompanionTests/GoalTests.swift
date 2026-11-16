import XCTest
@testable import NotchCompanion

@MainActor private final class GoalTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    var refuse = false

    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if method == "prompt.submit", refuse { throw CodexClientError.rpc(-32600, "Refused") }
        return [:]
    }
    var prompts: [String] { calls.filter { $0.0 == "prompt.submit" }.compactMap { $0.1["text"] as? String } }
}

@MainActor final class GoalTests: XCTestCase {
    private var folder: URL!
    private var transport: GoalTransport!
    private var model: AppModel!
    private var preferences: UserDefaults!
    private var suite: String!
    private var storage: URL { folder.appendingPathComponent("sessions.json") }
    private var id: String { model.currentID! }
    private var goal: SessionGoal? { model.current?.goal }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("goals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transport = GoalTransport()
        suite = "goals-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        model = AppModel(storageURL: storage, playsSounds: false, client: transport, preferences: preferences)
        await model.connect()
        model.sessions[0].runtime = .codex
        model.sessions[0].profileID = RuntimeRoute.defaultProfile(.codex)
        model.sessions[0].runtimeID = "live"
        model.sessions[0].storedID = "stored"
        model.sessions[0].state = .finished
        model.sessions[0].workspacePath = folder.path
        model.sessions[0].trustedProjectPath = folder.path
        model.sessions[0].nativeSubmissionAttempted = true
    }
    override func tearDown() async throws {
        model.shutdown()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    /// Waits for the next prompt, then ends its turn with `answer`.
    private func endTurn(_ answer: String, status: String = "complete", after count: Int, extra: [String: Any] = [:]) async throws {
        try await wait { transport.prompts.count == count && model.current?.isBusy == true }
        model.receive("message.start", payload: ["session_id": "live", "role": "assistant"])
        model.receive("message.complete", payload: ["session_id": "live", "text": answer, "status": status].merging(extra) { $1 })
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }

    func testTheMarkerCountsOnlyAsTheLastPlainLine() {
        XCTAssertEqual(SessionGoal.completion("All tests pass.\n\nGOAL COMPLETE"), "All tests pass.")
        XCTAssertEqual(SessionGoal.completion("Did it.\nGOAL COMPLETE  \n\n"), "Did it.")
        XCTAssertEqual(SessionGoal.completion("GOAL COMPLETE"), "")
        XCTAssertEqual(SessionGoal.completion("Intro\n\nShipped the fix\nand the test.\nGOAL COMPLETE"), "Intro\n\nShipped the fix\nand the test.".components(separatedBy: "\n\n").last)
        for answer in ["GOAL COMPLETE\n\nBut one test still fails.",
                       "Reply with GOAL COMPLETE on its own last line when it is fully done.",
                       "> GOAL COMPLETE",
                       "```\nGOAL COMPLETE\n```",
                       "```text\nGOAL COMPLETE",
                       "    GOAL COMPLETE",
                       "**GOAL COMPLETE**",
                       "`GOAL COMPLETE`",
                       "GOAL COMPLETE.",
                       "GOAL COMPLET",
                       "goal complete",
                       ""] {
            XCTAssertNil(SessionGoal.completion(answer), answer)
        }
    }

    func testAGoalContinuesUntilTheAgentReportsItComplete() async throws {
        model.startGoal(id, objective: "All tests pass", cap: 10)
        XCTAssertEqual(goal?.turns, 1)
        try await endTurn("Fixed two tests; one left.", after: 1)
        let first = try XCTUnwrap(model.current?.messages.first { $0.role == "user" })
        XCTAssertEqual(first.kind, ChatMessage.goal)
        XCTAssertEqual(first.agentLabel, "Goal")
        XCTAssertTrue(transport.prompts[0].hasPrefix("Goal: All tests pass"))
        XCTAssertTrue(transport.prompts[0].contains("GOAL COMPLETE"))

        // One follow-up, through the queue and labelled.
        try await endTurn("Fixed the last one.\n\nGOAL COMPLETE", after: 2)
        XCTAssertTrue(transport.prompts[1].hasPrefix("Continue working toward the goal: All tests pass"))
        XCTAssertEqual(model.current?.messages.filter { $0.kind == ChatMessage.goal }.count, 2)
        XCTAssertNil(goal, "Reached: the goal ends")
        let reached = try XCTUnwrap(model.current?.messages.last)
        XCTAssertEqual(reached.kind, ChatMessage.goalReached)
        XCTAssertTrue(reached.isSessionMarker)
        XCTAssertEqual(reached.text, "Fixed the last one.")
        try await settle()
        XCTAssertEqual(transport.prompts.count, 2, "Nothing more is sent")
        XCTAssertTrue(model.current?.queuedSends.isEmpty == true)
    }

    func testTheCapPausesAndContinueAllowsAnotherCap() async throws {
        model.startGoal(id, objective: "Ship it", cap: 2)
        try await endTurn("Working.", after: 1)
        XCTAssertEqual(model.current?.goalFooter, nil, "Not while idle")
        try await wait { model.current?.isBusy == true }
        XCTAssertEqual(model.current?.goalFooter, "Goal · turn 2 of 2")
        try await endTurn("Still working.", after: 2)
        try await settle()
        XCTAssertEqual(transport.prompts.count, 2)
        XCTAssertEqual(goal?.pause, .cap)
        XCTAssertEqual(goal?.pauseText, "Goal paused after 2 turns")
        model.resumeGoal(id)
        XCTAssertEqual(goal?.limit, 4)
        try await endTurn("More.", after: 3)
        XCTAssertEqual(goal?.progress, "4/4")
    }

    func testStopFailureAndDisconnectPauseWithoutAFollowUp() async throws {
        model.startGoal(id, objective: "Ship it", cap: 10)
        try await wait { transport.prompts.count == 1 && model.current?.isBusy == true }
        await model.interrupt()
        model.receive("message.complete", payload: ["session_id": "live", "text": "", "status": "interrupted"])
        try await settle()
        XCTAssertEqual(goal?.pause, .stopped)
        XCTAssertEqual(transport.prompts.count, 1)

        model.resumeGoal(id)
        try await endTurn("", status: "error", after: 2)
        try await settle()
        XCTAssertEqual(goal?.pause, .failed)
        XCTAssertEqual(transport.prompts.count, 2)

        model.resumeGoal(id)
        try await wait { transport.prompts.count == 3 && model.current?.isBusy == true }
        model.receive("runtime.connection", payload: ["route": model.current!.route.eventKey, "connected": false])
        XCTAssertEqual(goal?.pause, .interrupted)
        XCTAssertEqual(goal?.turns, 3)
    }

    func testAPauseOrClearStopsTheNextTurnAndARefusedSendIsNotRetried() async throws {
        model.startGoal(id, objective: "Ship it", cap: 10)
        try await wait { transport.prompts.count == 1 && model.current?.isBusy == true }
        model.pauseGoal(id)
        model.receive("message.start", payload: ["session_id": "live", "role": "assistant"])
        model.receive("message.complete", payload: ["session_id": "live", "text": "Done part.", "status": "complete"])
        try await settle()
        XCTAssertEqual(goal?.pause, .user)
        XCTAssertEqual(transport.prompts.count, 1)

        transport.refuse = true
        model.resumeGoal(id)
        try await wait { model.current?.goal?.pause == .failed }
        XCTAssertEqual(goal?.turns, 1, "The refused message is not counted")
        XCTAssertTrue(model.current?.queuedSends.isEmpty == true)
        model.clearGoal(id)
        XCTAssertNil(goal)
    }

    func testAQuestionOrABusyChildWaitsAndTheUsersOwnTurnContinues() async throws {
        model.startGoal(id, objective: "Ship it", cap: 10)
        try await wait { transport.prompts.count == 1 && model.current?.isBusy == true }
        model.receive("message.start", payload: ["session_id": "live", "role": "assistant"])
        model.receive("message.questions", payload: ["session_id": "live", "questions": [["title": "Which branch?", "options": []]]])
        model.receive("message.complete", payload: ["session_id": "live", "text": "Which branch?", "status": "complete"])
        try await settle()
        XCTAssertEqual(transport.prompts.count, 1, "An open question waits for the user")
        XCTAssertNil(goal?.pause)

        // The user's reply is their own turn; its end continues the goal.
        await model.submit(reply: "main")
        try await endTurn("Using main.", after: 2)
        try await wait { transport.prompts.count == 3 }
        XCTAssertTrue(transport.prompts[2].hasPrefix("Continue working toward the goal"))
        XCTAssertEqual(goal?.turns, 2, "The user's own turn is not counted")

        // A child still working keeps the session busy: no follow-up until its wake's turn ends.
        model.sessions[0].agents = [ChildAgent(id: "child", title: "Child", state: .working)]
        model.receive("message.start", payload: ["session_id": "live", "role": "assistant"])
        model.receive("message.complete", payload: ["session_id": "live", "text": "Waiting on the child.", "status": "complete"])
        try await settle()
        XCTAssertEqual(transport.prompts.count, 3)
        XCTAssertTrue(model.current?.queuedSends.isEmpty == true)
    }

    func testALimitPausesAndResumeAtResetCountsTowardTheGoal() async throws {
        model.startGoal(id, objective: "Ship it", cap: 10)
        model.receive("runtime.rateLimits", payload: ["runtime": "codex",
            "limits": [RuntimeRateLimit(name: "5-hour", usedPercent: 100, resetsAt: Date().addingTimeInterval(3_600), reached: true)]])
        try await endTurn("", status: "error", after: 1, extra: ["limit_reached": true])
        XCTAssertEqual(goal?.pause, .limit)
        let turn = try XCTUnwrap(model.current?.latestUserRowID)
        model.resumeAtReset(id, turn: turn)
        let entry = try XCTUnwrap(model.current?.queuedSends.first)
        model.sendResumeNow(entry.id)
        try await endTurn("Resumed and progressed.", after: 2)
        XCTAssertEqual(goal?.turns, 3, "The resumed turn counts, then the goal continues")
        try await wait { transport.prompts.count == 3 }
        XCTAssertNil(goal?.pause)
    }

    func testAGoalNeverSendsAtLaunchAndShowsAsPaused() async throws {
        model.startGoal(id, objective: "Ship it", cap: 10)
        try await endTurn("Progress.", after: 1)
        // A follow-up waiting at quit (the session still busy elsewhere) is dropped uncounted.
        model.sessions[0].queuedSends = [QueuedSend(id: "goal-next", text: "Continue", kind: ChatMessage.goal)]
        model.sessions[0].goal?.turns = 2
        XCTAssertTrue(model.save())
        model.shutdown()
        let reopened = AppModel(storageURL: storage, playsSounds: false, client: transport, preferences: preferences)
        defer { reopened.shutdown() }
        let session = try XCTUnwrap(reopened.sessions.first)
        XCTAssertEqual(session.goal?.pause, .quit)
        XCTAssertEqual(session.goal?.turns, 1)
        XCTAssertTrue(session.queuedSends.isEmpty)
        XCTAssertFalse(reopened.hasActiveWork)
    }

    func testGoalsAreOnlyForTopLevelSessionsAndOlderRegistriesDecode() throws {
        XCTAssertTrue(model.offersGoal(model.sessions[0]))
        var child = model.sessions[0]
        child.parentSessionID = "parent"
        XCTAssertFalse(model.offersGoal(child))
        child.parentSessionID = nil
        child.isLegacyPrivate = true
        XCTAssertFalse(model.offersGoal(child))

        let old = #"[{"id":"s","runtime":"codex"}]"#
        XCTAssertNil(try JSONDecoder().decode([CompanionSession].self, from: Data(old.utf8)).first?.goal)
        let future = #"[{"id":"s","runtime":"codex","title":"Kept","goal":{"objective":"x","cap":1,"limit":1,"pause":"someday"}}]"#
        let session = try XCTUnwrap(JSONDecoder().decode([CompanionSession].self, from: Data(future.utf8)).first)
        XCTAssertNil(session.goal, "An unreadable goal is dropped, not the conversation")
        XCTAssertEqual(session.title, "Kept")
    }
}
