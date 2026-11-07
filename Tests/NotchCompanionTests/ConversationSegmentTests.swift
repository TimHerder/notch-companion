import XCTest
@testable import NotchCompanion

/// How streamed text becomes reply segments between tool calls, how a runtime's
/// authoritative text is reconciled with them, and how native history splits alike.
@MainActor final class ConversationSegmentTests: XCTestCase {
    private var model: AppModel!
    private var transport: SegmentTransport!
    private var folder: URL!
    private var suite = ""

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "notch-segments-\(UUID().uuidString)"
        transport = SegmentTransport()
        model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                         client: transport, preferences: UserDefaults(suiteName: suite)!)
        model.sessions[0].runtimeID = "live"
        model.sessions[0].messages = [ChatMessage(id: "u", role: "user", text: "Check it", turnID: "u")]
    }

    override func tearDown() async throws {
        model.shutdown()
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func send(_ name: String, _ payload: [String: Any] = [:]) {
        model.receive(name, payload: payload.merging(["session_id": "live"]) { old, _ in old })
    }
    private var replies: [String] { model.sessions[0].messages.filter { $0.role == "assistant" }.map(\.text) }
    private func works() -> [TurnWork] {
        ConversationTimeline.build(session: model.sessions[0]).compactMap { if case .work(let work) = $0 { return work }; return nil }
    }

    private func streamCommentaryToolAndAnswer() {
        send("message.start", ["role": "assistant"])
        send("message.delta", ["text": "Let me check."])
        send("tool.start", ["tool_id": "t1", "name": "terminal", "context": "swift test"])
        send("tool.complete", ["tool_id": "t1", "result": "ok"])
        // Codex separates its messages with a blank line.
        send("message.delta", ["text": "\n\nAll green."])
    }

    func testAToolCallSplitsTheReplyAndTheNewSegmentStartsAfterIt() throws {
        streamCommentaryToolAndAnswer()
        XCTAssertEqual(replies, ["Let me check.", "All green."])
        let answer = try XCTUnwrap(model.sessions[0].messages.last)
        XCTAssertGreaterThanOrEqual(answer.createdAt, model.sessions[0].tools[0].startedAt)
        XCTAssertEqual(answer.turnID, "u")
        send("message.delta", ["text": " Done."])
        XCTAssertEqual(replies, ["Let me check.", "All green. Done."], "Text without a call between stays one segment")
    }

    func testClaudeCompletionWithOnlyTheFinalMessageKeepsTheCommentary() {
        streamCommentaryToolAndAnswer()
        send("message.complete", ["text": "All green.", "status": "complete"])
        XCTAssertEqual(replies, ["Let me check.", "All green."])
        XCTAssertEqual(model.sessions[0].latestResponse, "All green.")
    }

    func testCodexCompletionWithEveryMessageJoinedKeepsTheSegments() {
        streamCommentaryToolAndAnswer()
        send("message.complete", ["text": "Let me check.\n\nAll green.", "status": "complete"])
        XCTAssertEqual(replies, ["Let me check.", "All green."])
    }

    func testDifferentCompletionTextReplacesOnlyTheCurrentSegment() {
        streamCommentaryToolAndAnswer()
        send("message.complete", ["text": "All 12 tests passed.", "status": "complete"])
        XCTAssertEqual(replies, ["Let me check.", "All 12 tests passed."])
    }

    func testUnstreamedAnswerAfterAToolBecomesItsOwnSegment() {
        send("message.start", ["role": "assistant"])
        send("message.delta", ["text": "Let me check."])
        send("tool.start", ["tool_id": "t1", "name": "terminal"])
        send("message.interim", ["text": "Let me check.", "already_streamed": true])
        send("message.complete", ["text": "All green.", "status": "complete"])
        XCTAssertEqual(replies, ["Let me check.", "All green."])
        XCTAssertEqual(model.sessions[0].tools[0].state, .finished)
        XCTAssertNotNil(model.sessions[0].tools[0].finishedAt, "A call the turn's end finished gets an end time")
    }

    func testPiInterimForEachMessageChangesNothingAlreadyStreamed() {
        send("message.start")
        send("message.delta", ["text": "Reading the file."])
        send("message.interim", ["text": "Reading the file.", "already_streamed": true])
        send("tool.start", ["tool_id": "t1", "name": "read_file"])
        send("message.start")
        send("message.delta", ["text": "It is fine."])
        send("message.interim", ["text": "It is fine.", "already_streamed": true])
        send("message.complete", ["text": "It is fine.", "status": "complete"])
        XCTAssertEqual(replies, ["Reading the file.", "It is fine."])
    }

    func testSteeredTurnCompletionDoesNotRepeatTextFromBeforeTheSteer() {
        send("message.start")
        send("message.delta", ["text": "First part."])
        model.sessions[0].messages.append(ChatMessage(id: "steer", role: "user", text: "Also check the docs", turnID: "u"))
        send("message.delta", ["text": "\n\nSecond part."])
        // Codex reports the whole native turn, text from before the steer included.
        send("message.complete", ["text": "First part.\n\nSecond part.", "status": "complete"])
        XCTAssertEqual(replies, ["First part.", "Second part."])
        XCTAssertNotNil(model.sessions[0].turnEndedAt["steer"], "The end belongs to the block the turn finished in")
        XCTAssertNil(model.sessions[0].turnEndedAt["u"])
    }

    func testAWakeTurnEndingLikeTheLastAnswerStillGetsItsOwn() {
        send("message.start")
        send("message.delta", ["text": "Tests pass. Done."])
        send("message.complete", ["text": "Tests pass. Done.", "status": "complete"])
        // A delegation wake shares the turn ID but starts a new native turn that streams nothing.
        model.sessions[0].messages.append(ChatMessage(id: "wake", role: "user", text: "Delegated task finished.", turnID: "u",
                                                      kind: ChatMessage.delegationResult))
        send("message.start")
        send("message.complete", ["text": "Done.", "status": "complete"])
        XCTAssertEqual(replies, ["Tests pass. Done.", "Done."])
    }

    func testTurnEndIsRecordedAndRoundTrips() throws {
        streamCommentaryToolAndAnswer()
        send("message.complete", ["text": "All green.", "status": "complete"])
        let ended = try XCTUnwrap(model.sessions[0].turnEndedAt["u"])
        XCTAssertGreaterThanOrEqual(ended, model.sessions[0].tools[0].startedAt)
        let data = try JSONEncoder().encode(model.sessions[0])
        XCTAssertEqual(try JSONDecoder().decode(CompanionSession.self, from: data).turnEndedAt, model.sessions[0].turnEndedAt)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "turnEndedAt")
        XCTAssertEqual(try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: legacy)).turnEndedAt, [:])
        model.sessions[0].messages.append(ChatMessage(id: "u2", role: "user", text: "Again", turnID: "u2"))
        send("error", ["message": "The provider is unavailable."])
        XCTAssertNotNil(model.sessions[0].turnEndedAt["u2"], "A failure ends its turn too")
    }

    func testTextAfterALaterToolDoesNotJoinAQuestionsOnlySegment() throws {
        send("message.start", ["role": "assistant"])
        send("tool.start", ["tool_id": "t1", "name": "terminal"])
        send("message.questions", ["questions": [["title": "Which branch?"]]])
        send("tool.start", ["tool_id": "t2", "name": "terminal"])
        send("message.delta", ["text": "Found the cause."])
        let assistant = model.sessions[0].messages.filter { $0.role == "assistant" }
        XCTAssertEqual(assistant.map(\.text), ["", "Found the cause."])
        XCTAssertEqual(assistant.first?.questions?.first?.title, "Which branch?")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(assistant.last).createdAt, model.sessions[0].tools[1].startedAt,
                                    "The text sorts after the call it followed")
    }

    func testQuestionsStayAnswerableWhileTheTurnGoesOnUntilAUserRowFollows() throws {
        send("message.start", ["role": "assistant"])
        send("message.delta", ["text": "Two questions while I start."])
        send("message.questions", ["questions": [["title": "Which branch?"], ["title": "Run the slow tests?"]]])
        send("tool.start", ["tool_id": "t1", "name": "terminal"])
        send("tool.complete", ["tool_id": "t1", "result": "ok"])
        send("message.delta", ["text": "\n\nStarted on it."])
        let question = try XCTUnwrap(model.sessions[0].messages.first { $0.questions != nil })
        XCTAssertNotEqual(model.sessions[0].messages.last?.id, question.id, "Later text took its own segment")
        XCTAssertTrue(ConversationTimeline.questionsOpen(question.id, in: model.sessions[0]))
        send("message.complete", ["text": "Two questions while I start.\n\nStarted on it.", "status": "complete"])
        XCTAssertTrue(ConversationTimeline.questionsOpen(question.id, in: model.sessions[0]))
        XCTAssertEqual(works().map(\.folds), [false], "Open questions above the answer keep the work unfolded")
        model.sessions[0].messages.append(ChatMessage(id: "reply", role: "user", text: "main", turnID: "reply"))
        XCTAssertFalse(ConversationTimeline.questionsOpen(question.id, in: model.sessions[0]), "A later message of yours closes them")
        XCTAssertEqual(works().map(\.folds), [true], "Answered, the work folds away")
    }

    func testARowTheCompanionSentDoesNotCloseQuestions() throws {
        send("message.start", ["role": "assistant"])
        send("message.delta", ["text": "Which branch should I use?"])
        send("message.questions", ["questions": [["title": "Which branch?"]]])
        // A delegated child's result, steered into the running turn.
        model.sessions[0].messages.append(ChatMessage(id: "wake", role: "user", text: "Delegated task \"Docs\" (sessionId c1) finished.",
                                                      turnID: "u", kind: ChatMessage.delegationResult))
        let question = try XCTUnwrap(model.sessions[0].messages.first { $0.questions != nil })
        XCTAssertTrue(ConversationTimeline.questionsOpen(question.id, in: model.sessions[0]), "A delegation result is not your answer")
        model.sessions[0].messages.append(ChatMessage(id: "reply", role: "user", text: "main", turnID: "reply"))
        XCTAssertFalse(ConversationTimeline.questionsOpen(question.id, in: model.sessions[0]))
    }

    func testATurnEndedWithoutItsRuntimeKeepsItsOutcome() async throws {
        streamCommentaryToolAndAnswer()
        // A local Stop the runtime never confirms; a send that then fails does not relabel it.
        model.sessions[0].state = .working
        await model.interrupt()
        XCTAssertEqual(model.sessions[0].turnOutcome["u"], .interrupted)
        model.sessions[0].state = .failed
        XCTAssertEqual(works().map(\.label), ["Stopped"])

        // The whole client disconnecting mid-turn.
        model.sessions[0].turnOutcome = [:]
        model.sessions[0].state = .working
        transport.onConnectionChange?(false, nil)
        XCTAssertEqual(model.sessions[0].turnOutcome["u"], .interrupted)

        // A quit mid-turn, and older saves whose last turn ended without an outcome.
        var busy = model.sessions[0]
        busy.turnOutcome = [:]
        busy.state = .working
        var failed = busy, childFailed = busy, recorded = busy
        (failed.id, failed.state) = ("failed", .failed)
        (childFailed.id, childFailed.state) = ("child-failed", .failed)
        childFailed.agents = [ChildAgent(id: "child", title: "Docs", state: .failed, turnID: "u")]
        (recorded.id, recorded.state, recorded.turnOutcome) = ("recorded", .failed, ["u": .finished])
        model.sessions = [busy, failed, childFailed, recorded]
        XCTAssertTrue(model.save())
        let relaunched = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                                  client: SegmentTransport(), preferences: UserDefaults(suiteName: suite)!)
        defer { relaunched.shutdown() }
        XCTAssertEqual(relaunched.sessions.map { $0.turnOutcome["u"] }, [.interrupted, .failed, nil, .finished],
                       "A failed child is not the turn's failure, and a recorded outcome is kept")
    }

    func testASendThatFailsBeforeItsRowDoesNotRelabelTheFinishedTurn() throws {
        streamCommentaryToolAndAnswer()
        send("message.complete", ["text": "All green.", "status": "complete"])
        XCTAssertEqual(model.sessions[0].turnOutcome["u"], .finished)
        // submit's catch when ensureRuntime or a guard throws before the new row is kept.
        model.sessions[0].state = .failed
        XCTAssertEqual(works().map(\.outcome), [.finished])
        XCTAssertTrue(try XCTUnwrap(works().first).label.hasPrefix("Worked for"))

        // A turn's own failure is kept with it, after later turns too, and is saved.
        model.sessions[0].messages.append(ChatMessage(id: "u2", role: "user", text: "Again", turnID: "u2"))
        send("error", ["message": "The provider is unavailable."])
        XCTAssertEqual(model.sessions[0].turnOutcome["u2"], .failed)
        model.sessions[0].messages.append(ChatMessage(id: "u3", role: "user", text: "Once more", turnID: "u3"))
        model.sessions[0].state = .finished
        XCTAssertEqual(works().map(\.outcome), [.finished, .failed])
        let data = try JSONEncoder().encode(model.sessions[0])
        XCTAssertEqual(try JSONDecoder().decode(CompanionSession.self, from: data).turnOutcome, model.sessions[0].turnOutcome)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "turnOutcome")
        XCTAssertEqual(try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: legacy)).turnOutcome, [:])
    }

    // MARK: Native history splits where live text split

    func testCodexHistorySplitsRepliesAtToolItemsWithUniqueIDs() {
        let rows = CodexProtocolState.history(["turns": [["id": "turn", "items": [
            ["type": "userMessage", "id": "u", "content": [["type": "text", "text": "Fix it"]]],
            ["type": "agentMessage", "id": "m1", "text": "Looking."],
            ["type": "commandExecution", "id": "c1", "command": "swift test"],
            ["type": "agentMessage", "id": "m2", "text": "Found it."],
            ["type": "agentMessage", "id": "m3", "text": "Fixed."]
        ]]]])
        XCTAssertEqual(rows.map { $0["text"] as? String }, ["Fix it", "Looking.", "Found it.\n\nFixed."])
        XCTAssertEqual(rows.map { $0["row_id"] as? String }, ["u", "turn", "turn:m2"], "The first reply keeps the turn's ID")
    }

    func testOpenCodeHistoryJoinsConsecutiveRepliesAndSplitsAtTools() {
        func row(_ id: String, _ role: String, _ parts: [[String: Any]]) -> [String: Any] { ["info": ["id": id, "role": role], "parts": parts] }
        let native = [row("msg_u", "user", [["type": "text", "text": "Fix it"]]),
                      row("a1", "assistant", [["type": "text", "text": "Looking."], ["type": "tool", "id": "p1"], ["type": "text", "text": "Found it."]]),
                      row("a2", "assistant", [["type": "text", "text": "Fixed."]])]
        let rows = OpenCodeClient.history(native)
        XCTAssertEqual(rows.map { $0["text"] as? String }, ["Fix it", "Looking.", "Found it.\n\nFixed."])
        XCTAssertEqual(rows.map { $0["row_id"] as? String }, ["msg_u", "a1", "a1:2"])
        XCTAssertEqual(rows.first?["client_id"] as? String, "u")
        XCTAssertEqual(OpenCodeClient.currentText(native), "Looking.\n\nFound it.\n\nFixed.", "Live delivery text is unchanged")
    }

    func testACPReplayJoinsAgentChunksUntilAToolCall() {
        var state = ACPProtocolState()
        state.owned = ["s"]; state.loading = ["s"]
        func update(_ kind: String, _ fields: [String: Any]) {
            _ = state.notification("session/update", ["sessionId": "s", "update": fields.merging(["sessionUpdate": kind]) { old, _ in old }])
        }
        update("user_message_chunk", ["messageId": "u", "content": ["text": "Fix it"]])
        update("agent_message_chunk", ["messageId": "m1", "content": ["text": "Looking."]])
        update("tool_call", ["toolCallId": "t1", "title": "Run tests"])
        update("agent_message_chunk", ["messageId": "m1", "content": ["text": "Found it."]])
        update("agent_message_chunk", ["messageId": "m2", "content": ["text": " Fixed."]])
        XCTAssertEqual(state.history["s"]?.map { $0["text"] as? String }, ["Fix it", "Looking.", "Found it. Fixed."])
        XCTAssertEqual(state.history["s"]?.map { $0["row_id"] as? String }, ["u", "m1", "m1-2"])
    }
}

@MainActor private final class SegmentTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws {}
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
