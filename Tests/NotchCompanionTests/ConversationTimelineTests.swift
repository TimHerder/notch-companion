import XCTest
@testable import NotchCompanion

final class ConversationTimelineTests: XCTestCase {
    private func message(_ id: String, _ role: String, _ second: Double, text: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text ?? id, createdAt: Date(timeIntervalSince1970: second))
    }

    private func tool(_ id: String, _ second: Double) -> ToolActivity {
        ToolActivity(id: id, name: "read_file", detail: id, startedAt: Date(timeIntervalSince1970: second))
    }

    private func groups(_ timeline: [ConversationTimelineItem]) -> [ToolCallGroup] {
        timeline.compactMap { if case .tools(let group) = $0 { return group }; return nil }
    }

    private func messages(_ timeline: [ConversationTimelineItem]) -> [ChatMessage] {
        timeline.compactMap { if case .message(let message) = $0 { return message }; return nil }
    }

    func testCompletedTurnsPreserveEveryMessageAndCollapseTheirOwnTools() {
        var session = CompanionSession()
        session.id = "session"
        session.messages = [message("u1", "user", 10), message("a1", "assistant", 11),
                            message("u2", "user", 20), message("a2", "assistant", 21)]
        session.tools = [tool("t1", 12), tool("t2", 22), tool("t3", 23)]
        session.state = .finished
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["message:u1", "tools:session:turn:u1", "message:a1",
                                            "message:u2", "tools:session:turn:u2", "message:a2"])
        XCTAssertEqual(messages(timeline), session.messages)
        XCTAssertEqual(groups(timeline).map { $0.tools.map(\.id) }, [["t1"], ["t2", "t3"]])
        XCTAssertEqual(groups(timeline).flatMap(\.olderTools), session.tools)
        XCTAssertTrue(groups(timeline).allSatisfy { !$0.isLive && $0.liveTools.isEmpty })
    }

    func testStreamingAssistantAppearsAfterItsToolsDespiteEarlyCreationTime() {
        var session = CompanionSession()
        session.state = .working
        session.parentTurnComplete = false
        session.messages = [message("u", "user", 10), message("a", "assistant", 11, text: "The answer is coming…")]
        session.tools = [tool("t1", 12), tool("t2", 13)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.count, 3)
        XCTAssertEqual(timeline.first?.id, "message:u")
        XCTAssertEqual(timeline.last?.id, "message:a")
        XCTAssertEqual(groups(timeline).first?.liveTools.map(\.id), ["t1", "t2"])
        XCTAssertTrue(groups(timeline).first?.olderTools.isEmpty == true)
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
        session.messages.append(message("final", "assistant", 10.5))
        let finished = groups(ConversationTimeline.build(session: session))[0]
        XCTAssertEqual(live.id, finished.id)
        XCTAssertEqual(live.liveTools.count, 3)
        XCTAssertEqual(live.olderTools.count, 9)
        XCTAssertTrue(finished.liveTools.isEmpty)
        XCTAssertEqual(finished.olderTools, session.tools)
    }

    func testEqualTimestampsUseCanonicalMessageAndToolOrder() {
        var session = CompanionSession()
        session.messages = [message("u1", "user", 10), message("a1", "assistant", 10),
                            message("u2", "user", 10), message("a2", "assistant", 10)]
        session.tools = [tool("z-first", 10), tool("a-second", 10)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(messages(timeline), session.messages)
        XCTAssertEqual(groups(timeline).count, 1)
        XCTAssertTrue(groups(timeline)[0].id.hasSuffix(":u2"))
        XCTAssertEqual(groups(timeline)[0].tools.map(\.id), ["z-first", "a-second"])
        XCTAssertEqual(timeline.last?.id, "message:a2")
    }

    func testPartialHistoryRetainsUnassignedCallsAndExcludesNonConversationRoles() {
        var session = CompanionSession()
        session.messages = [message("private", "reasoning", 1), message("system", "system", 2),
                            message("raw", "tool", 3), message("u", "user", 20), message("a", "assistant", 21)]
        session.tools = [tool("orphan", 5), tool("current", 22)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(messages(timeline).map(\.id), ["u", "a"])
        XCTAssertEqual(groups(timeline).flatMap(\.tools).map(\.id), ["orphan", "current"])
        XCTAssertEqual(timeline.first?.id, "tools:\(session.id):unassigned")
        XCTAssertEqual(Set(timeline.map(\.id)).count, timeline.count)
    }

    func testAssistantCommentaryRemainsInOrderBeforeGroupedToolsAndFinalResponse() {
        var session = CompanionSession()
        session.messages = [message("u", "user", 10), message("commentary", "assistant", 11), message("answer", "assistant", 13)]
        session.tools = [tool("call", 12)]
        let timeline = ConversationTimeline.build(session: session)
        XCTAssertEqual(timeline.map(\.id), ["message:u", "message:commentary", "tools:\(session.id):turn:u", "message:answer"])
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
        var firstTool = tool("first-tool", 500)
        firstTool.turnID = "original-u1"
        var secondTool = tool("second-tool", 5)
        secondTool.turnID = "u2"
        session.messages = [firstUser, message("a1", "assistant", 101), message("u2", "user", 200), message("a2", "assistant", 201)]
        session.tools = [firstTool, secondTool]
        let actual = groups(ConversationTimeline.build(session: session))
        XCTAssertEqual(actual.map(\.id), ["tools:session:turn:original-u1", "tools:session:turn:u2"])
        XCTAssertEqual(actual.map { $0.tools.map(\.id) }, [["first-tool"], ["second-tool"]])
    }

    func testMissingExplicitOwnerDoesNotAttachToAnUnrelatedNewerTurn() {
        var session = CompanionSession()
        session.messages = [message("u", "user", 10)]
        var call = tool("retained", 20)
        call.turnID = "missing-prior-user"
        session.tools = [call]
        session.state = .working
        let group = groups(ConversationTimeline.build(session: session))[0]
        XCTAssertTrue(group.id.hasSuffix(":unassigned"))
        XCTAssertFalse(group.isLive)
        XCTAssertEqual(group.olderTools.map(\.id), ["retained"])
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
        XCTAssertFalse(groups(ConversationTimeline.build(session: session)).first!.id.hasSuffix(":unassigned"))
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
        XCTAssertEqual(groups(timeline).first?.id, "tools:session:turn:u1")
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
        XCTAssertEqual(timeline.map(\.id), ["message:u", "message:commentary", "tools:\(session.id):turn:u"])
        session.messages[2].text = "Here is the result"
        let streaming = ConversationTimeline.build(session: session)
        XCTAssertEqual(streaming.map(\.id), ["message:u", "message:commentary", "tools:\(session.id):turn:u", "message:placeholder"])
    }
}
