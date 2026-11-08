import XCTest
@testable import NotchCompanion

final class SessionIndicatorTests: XCTestCase {
    func testIndicatorsRetainEverySessionAndStableIdentity() {
        let sessions = [
            CompanionSession(id: "first", title: "Research", state: .working),
            CompanionSession(id: "second", title: "Build", state: .working),
            CompanionSession(id: "third", title: "Answer", state: .finished),
            CompanionSession(id: "idle", state: .idle),
            CompanionSession(id: "stopped", state: .interrupted)
        ]
        let indicators = SessionIndicator.resolve(sessions: sessions)
        XCTAssertEqual(indicators.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(indicators.map(\.status), [.running, .running, .finished])
        XCTAssertEqual(indicators.first?.label, "Research: Working")
    }

    func testAcknowledgementHidesOnlyThatCompletion() {
        var read = CompanionSession(id: "read", state: .finished)
        let unread = CompanionSession(id: "unread", state: .finished)
        XCTAssertTrue(read.acknowledgeResult())
        XCTAssertFalse(read.acknowledgeResult())
        let indicators = SessionIndicator.resolve(sessions: [read, unread])
        XCTAssertEqual(indicators.map(\.id), ["unread"])
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [read]), .none)
    }

    func testReadingParentCannotHideActiveDelegatedWork() {
        var parent = CompanionSession(state: .finished, agents: [ChildAgent(id: "child", title: "Delegated")])
        XCTAssertFalse(parent.acknowledgeResult())
        XCTAssertEqual(CollapsedStatus.resolve(session: parent), .running)
        parent.agents[0].state = .waiting
        XCTAssertEqual(CollapsedStatus.resolve(session: parent), .waiting)
        XCTAssertFalse(parent.acknowledgeResult())
    }

    func testLegacyCompletionAcknowledgementSurvivesPersistence() throws {
        let oldData = Data(#"{"id":"legacy","title":"Older conversation","state":"finished"}"#.utf8)
        var session = try JSONDecoder().decode(CompanionSession.self, from: oldData)
        XCTAssertTrue(session.hasUnreadCompletion)
        XCTAssertTrue(session.acknowledgeResult())
        let restored = try JSONDecoder().decode(CompanionSession.self, from: JSONEncoder().encode(session))
        XCTAssertFalse(restored.hasUnreadCompletion)
        XCTAssertEqual(restored.state, .finished)
        XCTAssertEqual(CollapsedStatus.resolve(session: restored), .none)
    }

    @MainActor private func makeModel() -> (AppModel, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-status-\(UUID().uuidString)/sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: StatusTestTransport())
        model.sessions[0].runtimeID = "parent"
        return (model, file)
    }

    @MainActor private func cleanUp(_ model: AppModel, storage: URL) {
        model.shutdown()
        try? FileManager.default.removeItem(at: storage.deletingLastPathComponent())
    }

    @MainActor func testStoredSelectionDoesNotAcknowledgeAnUnseenCompletion() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Finished"])
        model.selectSession(model.currentID!)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        model.setSessionVisibility(notchVisible: true)
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        XCTAssertEqual(model.current?.latestResponse, "Finished")
    }

    @MainActor func testReadingFailureClearsOnlyItsDotAndPersistsWithoutErasingError() async throws {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        let first = model.currentID!
        model.page = .sessions
        model.setSessionVisibility(notchVisible: true)
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Authentication failed"])
        model.sessions.append(CompanionSession(id: "other", state: .failed))
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed, .failed])
        model.selectSession(first)
        XCTAssertEqual(model.sessionIndicators.map(\.id), ["other"])
        XCTAssertFalse(model.current!.hasUnreadFailure)
        XCTAssertEqual(model.current?.displayState, .failed, "Reading acknowledges the error; it does not change the outcome")
        XCTAssertEqual(model.current?.latestResponse, "Authentication failed")
        model.shutdown()
        let restored = AppModel(storageURL: file, playsSounds: false, client: StatusTestTransport())
        defer { restored.shutdown() }
        XCTAssertEqual(restored.sessionIndicators.map(\.id), ["other"])
        XCTAssertEqual(restored.sessions.first { $0.id == first }?.latestResponse, "Authentication failed")
    }

    @MainActor func testReadingUnconfirmedSendPreservesProtectionAcrossReload() throws {
        for reader in ["notch", "full", "bulk"] {
            let (model, file) = makeModel()
            defer { cleanUp(model, storage: file) }
            let pending = PendingSubmission(id: "unconfirmed-turn", draft: "Possibly delivered", userTurnCount: 1, attachmentIDs: [])
            model.sessions[0].runtime = .claude
            model.sessions[0].storedID = "native-claude-session"
            model.sessions[0].state = .interrupted
            model.sessions[0].parentTurnComplete = false
            model.sessions[0].pendingSubmission = pending
            model.sessions[0].completionID = "old-success"
            model.sessions[0].acknowledgedCompletionID = "old-success"
            model.sessions[0].messages = [ChatMessage(role: "assistant", text: "Earlier connection error")]
            model.draft = "Next draft"
            model.errorMessage = "No exact native delivery receipt"
            model.page = .settings
            model.setSessionVisibility(notchVisible: true)
            model.page = .sessions
            XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
            XCTAssertEqual(model.unreadResultCount, 1)
            model.sessionFilter = .needsYou
            XCTAssertEqual(model.visibleSessions.count, 1)
            XCTAssertEqual(NotchHeaderView.status(state: model.current!.displayState, session: model.current).text, "Send unconfirmed")

            switch reader {
            case "notch": model.selectSession(model.currentID!)
            case "full": model.setSessionVisibility(fullSessionVisible: true)
            default: model.markAllAsRead()
            }
            XCTAssertTrue(model.sessionIndicators.isEmpty)
            XCTAssertEqual(model.unreadResultCount, 0)
            XCTAssertTrue(model.visibleSessions.isEmpty)
            model.sessionFilter = .unread
            XCTAssertTrue(model.visibleSessions.isEmpty)
            XCTAssertEqual(model.current?.pendingSubmission, pending)
            XCTAssertEqual(model.draft, "Next draft")
            XCTAssertEqual(model.current?.latestResponse, "Earlier connection error")
            XCTAssertTrue(model.hasActiveWork, "Acknowledgement cannot certify delivery or permit silent reload")
            XCTAssertFalse(model.canArchiveSession(model.currentID!))
            model.shutdown()

            let restored = AppModel(storageURL: file, playsSounds: false, client: StatusTestTransport())
            defer { restored.shutdown() }
            XCTAssertTrue(restored.sessionIndicators.isEmpty)
            XCTAssertEqual(restored.current?.pendingSubmission, pending)
            XCTAssertEqual(restored.current?.storedID, "native-claude-session")
            XCTAssertEqual(restored.draft, "Next draft")
            XCTAssertEqual(restored.current?.latestResponse, "Earlier connection error")
            XCTAssertFalse(restored.hasActiveWork, "A detached saved intent is not live owned work")
            restored.sessions[0].pendingSubmission?.id = "later-unconfirmed-turn"
            XCTAssertEqual(restored.sessionIndicators.map(\.status), [.failed], "A different send needs its own receipt")
        }
    }

    func testReadingUnconfirmedSendCannotHideLiveParentOrChildActivity() {
        let pending = PendingSubmission(id: "pending", draft: "Possibly delivered", userTurnCount: 1, attachmentIDs: [])
        for state in [WorkState.working, .waiting] {
            for session in [CompanionSession(pendingSubmission: pending, state: state),
                            CompanionSession(pendingSubmission: pending, state: .interrupted,
                                             agents: [ChildAgent(id: "child", title: "Active child", state: state)])] {
                var session = session
                XCTAssertFalse(session.acknowledgeResult())
                XCTAssertEqual(CollapsedStatus.resolve(session: session), state == .waiting ? .waiting : .running)
            }
        }
        var unverified = CompanionSession(pendingSubmission: pending, nativeActivityUnverified: "Check native children", state: .interrupted)
        XCTAssertFalse(unverified.acknowledgeResult())
        XCTAssertEqual(CollapsedStatus.resolve(session: unverified), .waiting)
    }

    func testReadFailureHeaderDescribesOutcomeWithoutDemandingAttention() {
        var session = CompanionSession(state: .failed)
        XCTAssertEqual(NotchHeaderView.status(state: session.displayState, session: session).text, "Needs attention")
        session.acknowledgeResult()
        XCTAssertEqual(NotchHeaderView.status(state: session.displayState, session: session).text, "Failed")
    }

    @MainActor func testDuplicateFailureStaysReadAndNextFailedTurnIsUnread() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.setSessionVisibility(fullSessionVisible: true, fullConversationVisible: false)
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Failed"])
        XCTAssertTrue(model.current!.hasUnreadFailure)
        model.setSessionVisibility(fullConversationVisible: true)
        let receipt = model.current?.completionID
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        model.setSessionVisibility(fullSessionVisible: false)
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Failed"])
        model.receive("session.error", payload: ["session_id": "parent", "message": "Failed"])
        XCTAssertEqual(model.current?.completionID, receipt)
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "New failure"])
        XCTAssertNotEqual(model.current?.completionID, receipt)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
    }

    @MainActor func testDelegatedFailureWaitsForActiveWorkBeforeAcknowledgement() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.setSessionVisibility(notchVisible: true)
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "child"])
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Parent failed"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.running])
        XCTAssertNil(model.current?.acknowledgedCompletionID)
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "child", "status": "error"])
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        XCTAssertEqual(model.current?.displayState, .failed)
        model.setSessionVisibility(notchVisible: false)
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "late-child"])
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "late-child", "status": "error"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
    }

    func testLegacyFailureAcknowledgementKeepsTheStoredConversation() throws {
        for snapshot in [#"{"id":"old-failure","state":"failed"}"#,
                         #"{"id":"old-failure","state":"failed","completionID":"old-success","acknowledgedCompletionID":"old-success"}"#] {
            var session = try JSONDecoder().decode(CompanionSession.self, from: Data(snapshot.utf8))
            XCTAssertTrue(session.hasUnreadFailure, "An old successful receipt cannot acknowledge a later failure")
            XCTAssertTrue(session.acknowledgeResult())
            let restored = try JSONDecoder().decode(CompanionSession.self, from: JSONEncoder().encode(session))
            XCTAssertFalse(restored.hasUnreadFailure)
            XCTAssertEqual(restored.state, .failed)
        }
    }

    @MainActor func testSuccessfulLateChildCannotEraseParentFailure() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Parent failed"])
        model.markAllAsRead()
        let receipt = model.current?.completionID
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "late"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.running])
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "late"])
        XCTAssertEqual(model.current?.state, .failed)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
        XCTAssertNotEqual(model.current?.completionID, receipt)
    }

    @MainActor func testCheckingOneVisibleSessionLeavesOtherCompletionsUnread() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        let firstID = model.currentID!
        model.receive("message.complete", payload: ["session_id": "parent", "text": "First result"])
        model.sessions.append(CompanionSession(id: "second", state: .finished))
        model.page = .sessions
        model.setSessionVisibility(notchVisible: true)
        XCTAssertEqual(model.sessionIndicators.count, 2)
        model.selectSession("second")
        XCTAssertEqual(model.sessionIndicators.map(\.id), [firstID])
    }

    @MainActor func testSessionListAndSettingsDoNotReadCompletion() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.page = .settings
        model.setSessionVisibility(notchVisible: true)
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Unread"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        model.page = .sessions
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        model.page = .session
        XCTAssertTrue(model.sessionIndicators.isEmpty)
    }

    @MainActor func testCompletionWhileViewedClearsAndNextHiddenTurnReturnsGreen() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.setSessionVisibility(notchVisible: true)
        model.receive("message.start", payload: ["session_id": "parent"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.running])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Seen result"])
        let seenReceipt = model.current?.completionID
        XCTAssertNotNil(seenReceipt)
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        model.setSessionVisibility(notchVisible: false)
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "New result"])
        XCTAssertNotEqual(model.current?.completionID, seenReceipt)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
    }

    @MainActor func testDuplicateCompletionDoesNotReappearAfterCheckIn() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Result"])
        model.setSessionVisibility(notchVisible: true)
        let receipt = model.current?.completionID
        model.setSessionVisibility(notchVisible: false)
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Result"])
        XCTAssertEqual(model.current?.completionID, receipt)
        XCTAssertTrue(model.sessionIndicators.isEmpty)
    }

    @MainActor func testSendingNextTurnResetsReceiptBeforeStreamingBegins() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        await model.connect()
        model.receive("message.complete", payload: ["session_id": "parent", "text": "First result"])
        model.setSessionVisibility(notchVisible: true)
        let receipt = model.current?.completionID
        model.setSessionVisibility(notchVisible: false)
        model.draft = "Next question"
        await model.send()
        XCTAssertNil(model.current?.completionID)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.running])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Next answer"])
        XCTAssertNotEqual(model.current?.completionID, receipt)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
    }

    @MainActor func testFullWindowOnlyAcknowledgesVisibleConversation() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Unread"])
        model.setSessionVisibility(fullSessionVisible: true, fullConversationVisible: false)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        model.setSessionVisibility(fullConversationVisible: true)
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        model.setSessionVisibility(fullSessionVisible: false)
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Background result"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
    }

    @MainActor func testFinalChildCompletionCreatesReceiptAfterAllChildrenFinish() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "working"])
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "waiting", "status": "waiting"])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Delegated"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.waiting])
        XCTAssertNil(model.current?.completionID)
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "working"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.waiting])
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "waiting"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        XCTAssertNotNil(model.current?.completionID)
    }

    @MainActor func testLateDelegationFinishesWithNewUnreadReceipt() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Parent result"])
        model.setSessionVisibility(notchVisible: true)
        let receipt = model.current?.completionID
        model.setSessionVisibility(notchVisible: false)
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "late-child"])
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.running])
        XCTAssertNil(model.current?.completionID)
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "late-child", "text": "Child result"])
        XCTAssertNotEqual(model.current?.completionID, receipt)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
    }

    @MainActor func testInterruptedTurnCannotBeRevivedByLateChildEvents() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.start", payload: ["session_id": "parent"])
        model.receive("subagent.start", payload: ["session_id": "parent", "subagent_id": "child", "status": "waiting"])
        model.receive("message.complete", payload: ["session_id": "parent", "status": "interrupted"])
        XCTAssertFalse(model.current!.isBusy)
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        model.receive("subagent.thinking", payload: ["session_id": "parent", "subagent_id": "child"])
        model.receive("subagent.complete", payload: ["session_id": "parent", "subagent_id": "child", "status": "interrupted"])
        XCTAssertEqual(model.current?.state, .interrupted)
        XCTAssertEqual(model.current?.agents.first?.state, .interrupted)
        XCTAssertTrue(model.sessionIndicators.isEmpty)
    }

    @MainActor func testAcknowledgedCompletionSurvivesAppReload() async throws {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Durable result"])
        model.setSessionVisibility(notchVisible: true)
        model.shutdown()
        let restored = AppModel(storageURL: file, playsSounds: false, client: StatusTestTransport())
        defer { restored.shutdown() }
        XCTAssertEqual(restored.current?.latestResponse, "Durable result")
        XCTAssertTrue(restored.sessionIndicators.isEmpty)
    }

    @MainActor func testMarkAllAsReadAcknowledgesFinishedAndFailedNonbusySessions() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        var alreadyRead = CompanionSession(id: "already-read", state: .finished)
        alreadyRead.acknowledgeResult()
        model.sessions = [
            CompanionSession(id: "finished", state: .finished, messages: [ChatMessage(role: "assistant", text: "Preserve this answer")], draft: "Keep drafting", completionID: "done-1"),
            CompanionSession(id: "legacy", state: .finished),
            CompanionSession(id: "running", state: .working),
            CompanionSession(id: "waiting", state: .waiting),
            CompanionSession(id: "failed", state: .failed),
            CompanionSession(id: "idle"),
            CompanionSession(id: "stopped", state: .interrupted),
            CompanionSession(id: "delegating", state: .finished, agents: [ChildAgent(id: "child", title: "Working child")]),
            CompanionSession(id: "child-waiting", state: .finished, agents: [ChildAgent(id: "child", title: "Waiting child", state: .waiting)]),
            alreadyRead
        ]
        model.currentID = "running"
        model.page = .sessions
        var expected = model.sessions
        expected[0].acknowledgeResult()
        expected[1].acknowledgeResult()
        expected[4].acknowledgeResult()
        XCTAssertEqual(model.unreadResultCount, 3)
        model.markAllAsRead()
        XCTAssertEqual(model.unreadResultCount, 0)
        // Reading restarts each acknowledged session's auto-archive clock.
        XCTAssertEqual(model.sessions.map { $0.lastSeenAt != nil }, expected.map { $0.lastSeenAt != nil })
        for index in expected.indices { expected[index].lastSeenAt = model.sessions[index].lastSeenAt }
        XCTAssertEqual(model.sessions, expected)
        XCTAssertEqual(model.currentID, "running")
        XCTAssertEqual(model.page, .sessions)
        XCTAssertEqual(model.sessionIndicators.map(\.id), ["running", "waiting", "delegating", "child-waiting"])
    }

    @MainActor func testMarkAllAsReadWithoutUnreadCompletionsIsANoOp() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        var read = CompanionSession(id: "read", state: .finished)
        read.acknowledgeResult()
        var failed = CompanionSession(id: "failed", state: .failed)
        failed.acknowledgeResult()
        model.sessions = [read, CompanionSession(id: "running", state: .working), failed]
        let before = model.sessions
        XCTAssertEqual(model.unreadResultCount, 0)
        model.markAllAsRead()
        XCTAssertEqual(model.sessions, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testMarkAllAsReadPersistsImmediatelyAcrossReload() async throws {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Stored answer"])
        model.sessions.append(CompanionSession(id: "second", state: .finished, messages: [ChatMessage(role: "assistant", text: "Other answer")]))
        XCTAssertEqual(model.unreadResultCount, 2)
        model.markAllAsRead()
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, model.sessions)
        let restored = AppModel(storageURL: file, playsSounds: false, client: StatusTestTransport())
        defer { restored.shutdown() }
        XCTAssertEqual(restored.unreadResultCount, 0)
        XCTAssertTrue(restored.sessionIndicators.isEmpty)
        XCTAssertEqual(restored.sessions.map(\.latestResponse), ["Stored answer", "Other answer"])
    }

    @MainActor func testNewCompletionAfterMarkAllAsReadIsUnreadAgain() async {
        let (model, file) = makeModel()
        defer { cleanUp(model, storage: file) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "First result"])
        let firstReceipt = model.current?.completionID
        model.markAllAsRead()
        XCTAssertEqual(model.unreadResultCount, 0)
        model.receive("message.start", payload: ["session_id": "parent"])
        model.markAllAsRead()
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.running])
        model.receive("message.complete", payload: ["session_id": "parent", "text": "New result"])
        XCTAssertNotEqual(model.current?.completionID, firstReceipt)
        XCTAssertEqual(model.unreadResultCount, 1)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
    }
}

@MainActor
private final class StatusTestTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
