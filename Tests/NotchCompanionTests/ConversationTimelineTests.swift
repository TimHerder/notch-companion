import XCTest
@testable import NotchCompanion

final class ConversationTimelineTests: XCTestCase {
    private func message(_ id: String, _ role: String, _ second: Double, text: String? = nil, turn: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text ?? id, createdAt: Date(timeIntervalSince1970: second), turnID: turn)
    }

    private func tool(_ id: String, _ second: Double, turn: String? = nil, state: WorkState = .working) -> ToolActivity {
        ToolActivity(id: id, name: "read_file", detail: id, state: state, startedAt: Date(timeIntervalSince1970: second), turnID: turn)
    }

    /// Top-level items, with a folded turn's work spliced in where it sits.
    private func flattened(_ timeline: [ConversationTimelineItem]) -> [ConversationTimelineItem] {
        timeline.flatMap { item -> [ConversationTimelineItem] in
            if case .work(let work) = item { return work.entries }
            return [item]
        }
    }

    private func groups(_ timeline: [ConversationTimelineItem]) -> [ToolCallGroup] {
        flattened(timeline).compactMap { if case .tools(let group) = $0 { return group }; return nil }
    }

    private func messages(_ timeline: [ConversationTimelineItem]) -> [ChatMessage] {
        flattened(timeline).compactMap {
            switch $0 {
            case .message(let message), .commentary(let message): return message
            default: return nil
            }
        }
    }

    private func works(_ timeline: [ConversationTimelineItem]) -> [TurnWork] {
        timeline.compactMap { if case .work(let work) = $0 { return work }; return nil }
    }

    func testCompletedTurnsFoldTheirOwnWorkAboveTheirAnswers() {
        var session = CompanionSession()
        session.id = "session"
        session.messages = [message("u1", "user", 10), message("a1", "assistant", 11),
                            message("u2", "user", 20), message("a2", "assistant", 21)]
        session.tools = [tool("t1", 12), tool("t2", 22), tool("t3", 23)]
        session.state = .finished
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["message:u1", "work:session:u1", "message:a1",
                                            "message:u2", "work:session:u2", "message:a2"])
        XCTAssertEqual(messages(timeline), session.messages)
        XCTAssertEqual(groups(timeline).map { $0.tools.map(\.id) }, [["t1"], ["t2", "t3"]])
        XCTAssertEqual(groups(timeline).flatMap(\.olderTools), session.tools)
        XCTAssertTrue(groups(timeline).allSatisfy { !$0.isLive && $0.liveTools.isEmpty })
        XCTAssertTrue(works(timeline).allSatisfy(\.folds))
        // Turns from before end times were saved say how much work they hold.
        XCTAssertEqual(works(timeline).map(\.label), ["Worked · 1 step", "Worked · 2 steps"])
    }

    func testLiveTextAndToolsInterleaveInTheOrderTheyBegan() {
        var session = CompanionSession()
        session.id = "session"
        session.state = .working
        session.parentTurnComplete = false
        session.messages = [message("u", "user", 10), message("look", "assistant", 11, text: "Let me look."),
                            message("found", "assistant", 14, text: "Found it; testing."), message("answer", "assistant", 17, text: "All green.")]
        session.tools = [tool("t1", 12, state: .finished), tool("t2", 13, state: .finished), tool("t3", 15, state: .finished), tool("t4", 16)]
        let live = ConversationTimeline.build(session: session)
        XCTAssertEqual(live.map(\.id), ["message:u", "message:look", "tools:session:run:t1",
                                        "message:found", "tools:session:run:t3", "message:answer"])
        guard case .commentary = live[1], case .commentary = live[3], case .message = live[5] else {
            return XCTFail("Text followed by tools is commentary; the newest text reads as the answer")
        }
        XCTAssertEqual(groups(live).map(\.isLive), [false, true], "Only the newest run is live")
        XCTAssertEqual(groups(live).last?.liveTools.map(\.id), ["t3", "t4"])

        session.state = .finished
        session.parentTurnComplete = true
        session.turnEndedAt["u"] = Date(timeIntervalSince1970: 10 + 134)
        let finished = ConversationTimeline.build(session: session)
        XCTAssertEqual(finished.map(\.id), ["message:u", "work:session:u", "message:answer"])
        let work = try? XCTUnwrap(works(finished).first)
        XCTAssertEqual(work?.entries.map(\.id), ["message:look", "tools:session:run:t1", "message:found", "tools:session:run:t3"])
        XCTAssertEqual(work?.label, "Worked for 2:14")
        XCTAssertEqual(work?.folds, true)
        XCTAssertEqual(groups(finished).map(\.id), groups(live).map(\.id), "Runs keep their identity when the turn folds")
        XCTAssertTrue(groups(finished).allSatisfy { !$0.isLive })
    }

    func testFourthCallRollsOldestIntoHistoryWithoutChangingRemainingIDs() {
        var session = CompanionSession()
        session.state = .working
        session.messages = [message("u", "user", 10), message("placeholder", "assistant", 11, text: "")]
        session.tools = [tool("t1", 12), tool("t2", 13), tool("t3", 14)]
        let first = groups(ConversationTimeline.build(session: session))[0]
        session.tools.append(tool("t4", 15))
        let next = groups(ConversationTimeline.build(session: session))[0]
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(next.liveTools.map(\.id), ["t2", "t3", "t4"])
        XCTAssertEqual(next.olderTools.map(\.id), ["t1"])
        XCTAssertEqual(next.olderTools + next.liveTools, next.tools)
        XCTAssertEqual(next.tools, session.tools)
        XCTAssertEqual(messages(ConversationTimeline.build(session: session)).map(\.id), ["u"])
    }

    func testOldTurnNeverBecomesLiveWhenNewTurnHasNoTools() {
        var session = CompanionSession()
        session.messages = [message("u1", "user", 10), message("a1", "assistant", 11), message("u2", "user", 20)]
        session.tools = [tool("old", 12)]
        session.state = .waiting
        let group = groups(ConversationTimeline.build(session: session))[0]
        XCTAssertFalse(group.isLive)
        XCTAssertTrue(group.liveTools.isEmpty)
        XCTAssertEqual(group.olderTools.map(\.id), ["old"])
    }

    func testCompletionCollapsesLiveRowsWithoutChangingGroupIdentityOrLosingCalls() {
        var session = CompanionSession()
        session.state = .working
        session.messages = [message("u", "user", 10)]
        session.tools = (1...12).map { tool("t\($0)", Double(10 + $0)) }
        let live = groups(ConversationTimeline.build(session: session))[0]
        session.state = .finished
        session.messages.append(message("final", "assistant", 30))
        let timeline = ConversationTimeline.build(session: session)
        let finished = groups(timeline)[0]
        XCTAssertEqual(live.id, finished.id)
        XCTAssertEqual(live.liveTools.count, 3)
        XCTAssertEqual(live.olderTools.count, 9)
        XCTAssertTrue(finished.liveTools.isEmpty)
        XCTAssertEqual(finished.olderTools, session.tools)
        XCTAssertEqual(timeline.last?.id, "message:final")
    }

    func testEqualTimestampsUseCanonicalMessageAndToolOrder() {
        var session = CompanionSession()
        session.id = "session"
        session.messages = [message("u1", "user", 10), message("a1", "assistant", 10),
                            message("u2", "user", 10), message("a2", "assistant", 10)]
        session.tools = [tool("z-first", 10), tool("a-second", 10)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(messages(timeline), session.messages)
        XCTAssertEqual(timeline.map(\.id), ["message:u1", "message:a1", "message:u2", "work:session:u2", "message:a2"])
        XCTAssertEqual(groups(timeline).count, 1)
        XCTAssertEqual(groups(timeline)[0].tools.map(\.id), ["z-first", "a-second"])
    }

    func testPartialHistoryRetainsUnassignedCallsAndExcludesNonConversationRoles() {
        var session = CompanionSession()
        session.messages = [message("private", "reasoning", 1), message("system", "system", 2),
                            message("raw", "tool", 3), message("u", "user", 20), message("a", "assistant", 21)]
        session.tools = [tool("orphan", 5), tool("current", 22)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(messages(timeline).map(\.id), ["u", "a"])
        XCTAssertEqual(groups(timeline).flatMap(\.tools).map(\.id), ["orphan", "current"])
        XCTAssertEqual(timeline.first?.id, "tools:\(session.id):run:orphan")
        XCTAssertEqual(Set(timeline.map(\.id)).count, timeline.count)
    }

    func testFinishedTurnFoldsCommentaryAndToolsInTrueOrderAboveTheAnswer() {
        var session = CompanionSession()
        session.messages = [message("u", "user", 10), message("commentary", "assistant", 11), message("answer", "assistant", 13)]
        session.tools = [tool("call", 12)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["message:u", "work:\(session.id):u", "message:answer"])
        XCTAssertEqual(works(timeline).first?.entries.map(\.id), ["message:commentary", "tools:\(session.id):run:call"])
        guard case .commentary = works(timeline).first?.entries.first else { return XCTFail("Folded text is commentary") }
        XCTAssertEqual(messages(timeline), session.messages)
    }

    func testOnlyLatestTurnIsLiveWhileDelegatedChildContinues() {
        var session = CompanionSession()
        session.state = .finished
        session.parentTurnComplete = true
        session.agents = [ChildAgent(id: "child", title: "Research", state: .working)]
        session.messages = [message("u", "user", 10), message("a", "assistant", 11)]
        session.tools = [tool("delegate", 12)]
        XCTAssertTrue(groups(ConversationTimeline.build(session: session))[0].isLive)
        session.agents[0].state = .finished
        XCTAssertFalse(groups(ConversationTimeline.build(session: session))[0].isLive)
    }

    func testEmptyAndMessageOnlyHistoryNeedsNoArtificialToolGroup() {
        var session = CompanionSession()
        XCTAssertTrue(ConversationTimeline.build(session: session).isEmpty)
        session.messages = [message("u", "user", 10), message("a", "assistant", 11)]
        XCTAssertEqual(ConversationTimeline.build(session: session), session.messages.map(ConversationTimelineItem.message))
    }

    func testExplicitTurnIdentityWinsOverRestoredOrCoarseTimestamps() {
        var session = CompanionSession()
        session.id = "session"
        var firstUser = message("hermes-restored-u1", "user", 100)
        firstUser.turnID = "original-u1"
        session.messages = [firstUser, message("a1", "assistant", 101), message("u2", "user", 200), message("a2", "assistant", 201)]
        session.tools = [tool("first-tool", 500, turn: "original-u1"), tool("second-tool", 5, turn: "u2")]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["message:hermes-restored-u1", "work:session:hermes-restored-u1", "message:a1",
                                            "message:u2", "work:session:u2", "message:a2"])
        XCTAssertEqual(groups(timeline).map { $0.tools.map(\.id) }, [["first-tool"], ["second-tool"]])
    }

    func testMissingExplicitOwnerDoesNotAttachToAnUnrelatedNewerTurn() {
        var session = CompanionSession()
        session.messages = [message("u", "user", 10)]
        session.tools = [tool("retained", 20, turn: "missing-prior-user")]
        session.state = .working
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["tools:\(session.id):run:retained", "message:u"])
        let group = groups(timeline)[0]
        XCTAssertFalse(group.isLive)
        XCTAssertEqual(group.olderTools.map(\.id), ["retained"])
    }

    // MARK: Steering, wakes and outcomes

    func testSteerInsideATurnDoesNotMoveEarlierTools() {
        var session = CompanionSession()
        session.id = "session"
        session.messages = [message("u", "user", 10, turn: "u"), message("a1", "assistant", 11, turn: "u"),
                            message("steer", "user", 20, turn: "u"), message("a2", "assistant", 21, turn: "u"),
                            message("final", "assistant", 23, turn: "u")]
        session.tools = [tool("before", 12, turn: "u"), tool("after", 22, turn: "u")]
        session.changes = [TurnChanges(id: "u", workspace: "/project", files: [ChangedFile(path: "a.txt", additions: 1, deletions: 0)])]
        session.state = .working
        let live = ConversationTimeline.build(session: session)
        XCTAssertEqual(live.map(\.id), ["message:u", "message:a1", "tools:session:run:before", "message:steer",
                                        "message:a2", "tools:session:run:after", "message:final", "changes:u"])
        XCTAssertEqual(groups(live).map(\.isLive), [false, true])

        session.state = .finished
        session.turnEndedAt["steer"] = Date(timeIntervalSince1970: 30)
        let finished = ConversationTimeline.build(session: session)
        XCTAssertEqual(finished.map(\.id), ["message:u", "work:session:u", "message:a1", "message:steer",
                                            "work:session:steer", "message:final", "changes:u"])
        // The steered block ended when the steer arrived; the turn's changes follow its last answer.
        XCTAssertEqual(works(finished).map(\.label), ["Worked for 10s", "Worked for 10s"])
        XCTAssertEqual(works(finished).map { $0.entries.map(\.id) }, [["tools:session:run:before"], ["message:a2", "tools:session:run:after"]])
    }

    func testTurnThatEndedBeforeWritingKeepsItsWorkOpenUnderItsOutcome() {
        var session = CompanionSession()
        session.id = "session"
        session.messages = [message("u", "user", 10)]
        session.tools = [tool("broken", 12, state: .failed)]
        session.state = .failed
        session.turnEndedAt["u"] = Date(timeIntervalSince1970: 73)
        let failed = ConversationTimeline.build(session: session)
        XCTAssertEqual(failed.map(\.id), ["message:u", "work:session:u"])
        let work = works(failed)[0]
        XCTAssertFalse(work.folds, "With no answer to fold above, the work stays open")
        XCTAssertEqual(work.label, "Failed after 1:03")
        XCTAssertEqual(work.entries.map(\.id), ["tools:session:run:broken"])
        session.state = .interrupted
        session.turnEndedAt = [:]
        XCTAssertEqual(works(ConversationTimeline.build(session: session)).first?.label, "Stopped")

        // A failed turn that wrote text keeps it as its answer, under a fold that says how it ended.
        session.messages.append(message("partial", "assistant", 13, text: "Halfway: the build passes."))
        session.state = .failed
        session.turnEndedAt["u"] = Date(timeIntervalSince1970: 73)
        XCTAssertEqual(ConversationTimeline.build(session: session).map(\.id), ["message:u", "work:session:u", "message:partial"])
        XCTAssertEqual(works(ConversationTimeline.build(session: session)).first?.label, "Failed after 1:03")
        // A failed delegated child is not the turn's own failure.
        session.agents = [ChildAgent(id: "child", title: "Docs", state: .failed, turnID: session.latestUserTurnID)]
        XCTAssertEqual(works(ConversationTimeline.build(session: session)).first?.label, "Worked for 1:03")
        // Once a later turn exists only its own outcome is known.
        session.agents = []
        session.messages.append(message("u2", "user", 100))
        session.messages.append(message("a2", "assistant", 101))
        XCTAssertEqual(works(ConversationTimeline.build(session: session)).first?.outcome, .finished)
    }

    func testTurnStartRunsFromThePromptASteerOrSteeredWakeContinued() {
        var session = CompanionSession()
        session.messages = [message("old", "user", 1, turn: "old"), message("a0", "assistant", 2, turn: "old"),
                            message("u", "user", 10, turn: "u"), message("a1", "assistant", 11, turn: "u"),
                            message("steer", "user", 20, turn: "u")]
        session.turnEndedAt["old"] = Date(timeIntervalSince1970: 5)
        XCTAssertEqual(SessionDigest.turnStart(session), Date(timeIntervalSince1970: 10), "A steer keeps the turn's clock")
        session.messages.append(ChatMessage(id: "wake", role: "user", text: "Delegated task finished.",
                                            createdAt: Date(timeIntervalSince1970: 30), turnID: "u", kind: ChatMessage.delegationResult))
        XCTAssertEqual(SessionDigest.turnStart(session), Date(timeIntervalSince1970: 10), "So does a steered wake")
        session.turnEndedAt["steer"] = Date(timeIntervalSince1970: 25)
        XCTAssertEqual(SessionDigest.turnStart(session), Date(timeIntervalSince1970: 30), "A wake after the turn ended starts its own")
    }

    func testWorkDurationFormatAndEndFallbacks() {
        XCTAssertEqual([8, 59, 60, 134, 3_730].map { TurnWork.format(TimeInterval($0)) }, ["8s", "59s", "1:00", "2:14", "1:02:10"])
        var session = CompanionSession()
        session.id = "session"
        session.messages = [message("u1", "user", 10, turn: "u1"), message("a1", "assistant", 11, turn: "u1"),
                            message("wake", "user", 50, turn: "u1"), message("a2", "assistant", 51, turn: "u1"),
                            message("u3", "user", 200, turn: "u3"), message("a3", "assistant", 201, turn: "u3")]
        // A turn with only an answer still shows how long it took, when that is known.
        session.turnEndedAt["wake"] = Date(timeIntervalSince1970: 58)
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["message:u1", "work:session:u1", "message:a1", "message:wake", "work:session:wake",
                                            "message:a2", "message:u3", "message:a3"])
        // The first block ends when the wake that shares its turn begins; u3's end is unknown.
        XCTAssertEqual(works(timeline).map(\.label), ["Worked for 40s", "Worked for 8s"])
        XCTAssertTrue(works(timeline).allSatisfy { !$0.folds && $0.entries.isEmpty }, "Nothing to fold is a quiet line")
        session.turnEndedAt["u1"] = Date(timeIntervalSince1970: 12)
        XCTAssertEqual(works(ConversationTimeline.build(session: session)).first?.label, "Worked for 2s", "A saved end wins")
    }

    func testRestorationWithoutTimestampsPreservesOrderedFilePromptIdentity() {
        var user = message("local-user", "user", 10, text: "Read this file\n\nAttached: note.txt")
        user.turnID = "local-user"
        var assistant = message("local-assistant", "assistant", 11, text: "The result")
        assistant.turnID = "local-user"
        let rows: [[String: Any]] = [
            ["role": "user", "text": "Read this file\n\n@file:note.txt", "row_id": 30],
            ["role": "assistant", "text": "The result", "row_id": 31]
        ]
        let restored = SessionHistory.messages(rows, preserving: [user, assistant])
        XCTAssertEqual(restored.map(\.id), ["local-user", "local-assistant"])
        XCTAssertEqual(restored.map(\.createdAt), [user.createdAt, assistant.createdAt])
        XCTAssertEqual(restored.map(\.turnID), ["local-user", "local-user"])
        XCTAssertEqual(restored.first?.text, user.text)
        var session = CompanionSession()
        session.messages = restored
        session.tools = [tool("legacy-without-turn-id", 12)]
        XCTAssertEqual(groups(ConversationTimeline.build(session: session)).first?.tools.map(\.id), ["legacy-without-turn-id"])
        XCTAssertEqual(ConversationTimeline.build(session: session).map(\.id),
                       ["message:local-user", "work:\(session.id):local-user", "message:local-assistant"], "The call stays in its turn")
    }

    func testRestorationRetainsRepeatedMessagesByTheirOrderedOccurrences() {
        let previous = [message("u1", "user", 10, text: "hi"), message("a1", "assistant", 11, text: "hello"),
                        message("u2", "user", 20, text: "hi"), message("a2", "assistant", 21, text: "hello")]
        let rows = previous.map { ["role": $0.role, "text": $0.text] as [String: Any] }
        let restored = SessionHistory.messages(rows, preserving: previous)
        XCTAssertEqual(restored.map(\.id), previous.map(\.id))
        XCTAssertEqual(restored.map(\.createdAt), previous.map(\.createdAt))
        XCTAssertEqual(restored.map(\.turnID), ["u1", "u1", "u2", "u2"])
    }

    func testExtraRestoredCommentaryDoesNotLoseFileTurnUserTimestamp() {
        let previous = [message("u", "user", 10, text: "Read it\nAttached: file"), message("a", "assistant", 11, text: "Done")]
        let rows: [[String: Any]] = [["role": "user", "text": "Read it @file:document"],
                                    ["role": "assistant", "text": "Checking the document"],
                                    ["role": "assistant", "text": "Done"]]
        let restored = SessionHistory.messages(rows, preserving: previous)
        XCTAssertEqual(restored.first?.id, "u")
        XCTAssertEqual(restored.first?.createdAt, previous[0].createdAt)
        XCTAssertEqual(restored.last?.id, "a")
        XCTAssertEqual(restored.map(\.turnID), ["u", "u", "u"])
    }

    func testDifferentRoleCountsDoNotGuessUnrelatedMessageIdentities() {
        let previous = [message("prior-user", "user", 10, text: "Unrelated old question")]
        let rows: [[String: Any]] = [["role": "user", "text": "First new question", "row_id": 1],
                                    ["role": "assistant", "text": "Answer", "row_id": 2],
                                    ["role": "user", "text": "Second new question", "row_id": 3]]
        let restored = SessionHistory.messages(rows, preserving: previous)
        XCTAssertEqual(restored.map(\.id), ["hermes-1", "hermes-2", "hermes-3"])
        XCTAssertEqual(restored.map(\.turnID), ["hermes-1", "hermes-1", "hermes-3"])
    }

    private var delegationEnvelope: String {
        "[ASYNC DELEGATION BATCH COMPLETE — deleg_test]\nA background fan-out unit you dispatched earlier — 1 subagent(s) — has finished; its consolidated results are below.\nSummary: Done"
    }

    func testBackendMetadataFiltersOperationalRowsButKeepsRealSkillInvocations() {
        let rows: [[String: Any]] = [
            ["role": "user", "text": "Real request"],
            ["role": "user", "text": "Operational payload", "display_kind": "async_delegation_complete"],
            ["role": "user", "text": "Recovery payload", "display_kind": "auto_continue"],
            ["role": "user", "text": "Switch payload", "display_kind": "model_switch"],
            ["role": "user", "text": "Hidden payload", "display_kind": "hidden"],
            ["role": "user", "text": "/work improve the app", "display_kind": "skill_invocation"],
            ["role": "user", "text": "Future visible data", "display_kind": "future_kind"],
            ["role": "assistant", "text": "Actual answer"]
        ]
        XCTAssertEqual(SessionHistory.messages(rows).map(\.text), ["Real request", "/work improve the app", "Future visible data", "Actual answer"])
    }

    func testLegacyEnvelopeFilteringDoesNotHideOrdinaryDiscussionOrAssistantText() {
        XCTAssertFalse(SessionHistory.isVisibleConversation(message("synthetic", "user", 20, text: delegationEnvelope)))
        XCTAssertTrue(SessionHistory.isVisibleConversation(message("question", "user", 20, text: "What does ASYNC DELEGATION BATCH COMPLETE mean?")))
        XCTAssertTrue(SessionHistory.isVisibleConversation(message("quoted-header", "user", 20, text: "[ASYNC DELEGATION BATCH COMPLETE — deleg_test]\nPlease explain this header.")))
        XCTAssertTrue(SessionHistory.isVisibleConversation(message("answer", "assistant", 20, text: delegationEnvelope)))
        XCTAssertTrue(SessionHistory.isVisibleConversation(message("system-question", "user", 20, text: "[System: example] is this a log entry?")))
    }

    func testExtraDelegationEnvelopeDoesNotShiftUserIdentityOrToolGroup() {
        var session = CompanionSession()
        session.id = "session"
        session.messages = [message("u1", "user", 10, text: "Research this"), message("a1", "assistant", 11, text: "Delegating"),
                            message("synthetic", "user", 20, text: delegationEnvelope), message("a2", "assistant", 21, text: "Result"),
                            message("u2", "user", 30, text: "Next task")]
        var oldCall = tool("post-delegation-call", 22)
        oldCall.turnID = "synthetic"
        session.tools = [oldCall]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(messages(timeline).map(\.id), ["u1", "a1", "a2", "u2"])
        XCTAssertEqual(timeline.map(\.id), ["message:u1", "work:session:u1", "message:a2", "message:u2"])
        XCTAssertEqual(groups(timeline).first?.tools.map(\.id), [oldCall.id])
        XCTAssertEqual(SessionHistory.syntheticTurnAliases(in: session.messages), ["synthetic": "u1"])
        session.messages.removeLast()
        XCTAssertEqual(session.latestUserTurnID, "u1")
        let rows = session.messages.map { ["role": $0.role, "text": $0.text] as [String: Any] }
        let restored = SessionHistory.messages(rows, preserving: session.messages)
        XCTAssertEqual(restored.map(\.id), ["u1", "a1", "a2"])
        XCTAssertEqual(restored.map(\.createdAt), [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 11), Date(timeIntervalSince1970: 21)])
    }

    func testMatchedFileMessageKeepsUserDisplayDespiteBackendWarningsAndChangedTimestamp() {
        let prior = message("u", "user", 10, text: "Read this\n\nAttached: report.txt")
        let raw = "Read this\n\n@file:/outside/report.txt\n\n--- Context Warnings ---\n- @file:/outside/report.txt: path is outside the allowed workspace"
        let restored = SessionHistory.messages([["role": "user", "text": raw, "timestamp": 500.0]], preserving: [prior])
        XCTAssertEqual(restored.first?.text, prior.text)
        XCTAssertEqual(restored.first?.id, prior.id)
        XCTAssertEqual(restored.first?.createdAt, prior.createdAt)
    }

    func testOldSavedExpandedAttachmentIsProjectedWithoutChangingUnderlyingText() {
        let raw = "Read this\n\n@file:`/outside/my report.txt`\n\n--- Context Warnings ---\n- @file:`/outside/my report.txt`: path is outside the allowed workspace"
        let original = message("u", "user", 10, text: raw)
        let projected = SessionHistory.projectedMessage(original)
        XCTAssertEqual(projected.text, "Read this\n\nAttached: my report.txt")
        XCTAssertEqual(projected.id, original.id)
        XCTAssertEqual(projected.createdAt, original.createdAt)
        XCTAssertEqual(original.text, raw)
        let deliberateQuote = message("quote", "user", 10, text: "Explain this section:\n\n--- Context Warnings ---\n- This is my actual text.")
        XCTAssertEqual(SessionHistory.projectedMessage(deliberateQuote), deliberateQuote)
        let inlineRef = message("inline", "user", 10, text: "Explain @file:report.txt and this heading\n\n--- Context Warnings ---\n- @file:report.txt: example")
        XCTAssertEqual(SessionHistory.projectedMessage(inlineRef), inlineRef)
    }

    func testLiveEmptyAssistantKeepsToolGroupAfterEarlierVisibleCommentary() {
        var session = CompanionSession()
        session.state = .working
        session.messages = [message("u", "user", 10), message("commentary", "assistant", 11, text: "I will inspect the file."),
                            message("placeholder", "assistant", 12, text: "")]
        session.tools = [tool("call", 13)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["message:u", "message:commentary", "tools:\(session.id):run:call"])
        // A segment's time is when its first text arrived, after the call.
        session.messages[2].text = "Here is the result"
        session.messages[2].createdAt = Date(timeIntervalSince1970: 14)
        let streaming = ConversationTimeline.build(session: session)
        XCTAssertEqual(streaming.map(\.id), ["message:u", "message:commentary", "tools:\(session.id):run:call", "message:placeholder"])
    }

    func testUnmatchedRestoredRepliesStayAtTheirTurnStartInsteadOfNow() {
        // An older save kept one merged reply; native history now has two.
        let previous = [message("u", "user", 10, text: "Fix it", turn: "u"), message("merged", "assistant", 11, text: "Looking.\n\nFixed.", turn: "u")]
        let rows: [[String: Any]] = [["role": "user", "text": "Fix it"], ["role": "assistant", "text": "Looking."], ["role": "assistant", "text": "Fixed."]]
        let restored = SessionHistory.messages(rows, preserving: previous)
        XCTAssertEqual(restored.first?.id, "u")
        XCTAssertEqual(restored.map(\.createdAt), Array(repeating: Date(timeIntervalSince1970: 10), count: 3))
        XCTAssertEqual(restored.map(\.turnID), ["u", "u", "u"])
        var session = CompanionSession()
        session.messages = restored
        session.tools = [tool("call", 12, turn: "u", state: .finished)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.last?.id, "message:\(restored[2].id)", "The answer stays last, below its folded work")
    }
}
