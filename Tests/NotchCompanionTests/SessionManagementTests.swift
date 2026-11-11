import XCTest
@testable import NotchCompanion

@MainActor
final class SessionManagementTests: XCTestCase {
    private func fixture() -> (AppModel, ManagementTransport, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-management-\(UUID().uuidString)/sessions.json")
        let transport = ManagementTransport()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        model.sessions[0].runtimeID = "parent"
        return (model, transport, file)
    }

    private func cleanUp(_ model: AppModel, _ file: URL) {
        model.shutdown()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Deferred operation did not finish")
    }

    private func event(_ model: AppModel, _ name: String, _ values: [String: Any] = [:]) {
        model.receive(name, payload: values.merging(["session_id": "parent"]) { old, _ in old })
    }

    func testChildFailureBeforeParentCompletionRemainsRed() {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.start")
        event(model, "subagent.start", ["subagent_id": "child"])
        event(model, "subagent.complete", ["subagent_id": "child", "status": "failed", "summary": "Permission denied"])
        event(model, "message.complete", ["text": "Delegated work settled"])
        XCTAssertEqual(model.current?.state, .failed)
        XCTAssertEqual(model.current?.displayState, .failed)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
        XCTAssertFalse(model.current!.hasUnreadCompletion)
        model.openFailedAgent()
        XCTAssertEqual(model.page, .agent("child"))
    }

    func testChildFailureAfterParentCompletionRemainsRed() {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.start")
        event(model, "subagent.start", ["subagent_id": "child"])
        event(model, "message.complete", ["text": "Waiting for delegated result"])
        event(model, "subagent.complete", ["subagent_id": "child", "status": "error"])
        XCTAssertEqual(model.current?.state, .failed)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
        XCTAssertNotNil(model.current?.completionID)
    }

    func testRuntimeTitleReplacesOnlyAnAutomaticTitle() async {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        model.sessions[0].runtimeID = nil
        await model.connect()
        model.draft = "Fix the flaky login test in CI"
        await model.send()
        XCTAssertEqual(transport.created.count, 1)
        XCTAssertNil(transport.created.first?["title"], "An automatic title is not sent, so the runtime names its own session")
        XCTAssertEqual(model.current?.title, "Fix the flaky login test in CI")
        event(model, "session.title", ["title": " Fix flaky login test\n"])
        XCTAssertEqual(model.current?.title, "Fix flaky login test")
        event(model, "session.title", ["title": " "])
        XCTAssertEqual(model.current?.title, "Fix flaky login test")
        model.renameSession(model.currentID ?? "", title: "My name")
        event(model, "session.title", ["title": "Runtime name"])
        XCTAssertEqual(model.current?.title, "My name")
    }

    func testANameReportedWhenTheRuntimeOpensReplacesAnAutomaticTitle() async {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        model.sessions[0].runtimeID = nil
        transport.openedTitle = "Named while away"
        await model.connect()
        model.draft = "Fix the flaky login test in CI"
        await model.send()
        XCTAssertEqual(model.current?.title, "Named while away")
    }

    func testAChosenTitleIsSentAtCreateAndKept() async {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        model.sessions[0].runtimeID = nil
        await model.connect()
        model.renameSession(model.currentID ?? "", title: "Release notes")
        transport.openedTitle = "Runtime name"
        model.draft = "Draft them"
        await model.send()
        XCTAssertEqual(transport.created.first?["title"] as? String, "Release notes")
        event(model, "session.title", ["title": "Runtime name"])
        XCTAssertEqual(model.current?.title, "Release notes")
    }

    func testNewTurnDoesNotInheritHistoricalChildFailure() async {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        await model.connect()
        model.draft = "First request"
        await model.send()
        event(model, "message.start")
        event(model, "subagent.start", ["subagent_id": "failed-child"])
        event(model, "subagent.complete", ["subagent_id": "failed-child", "status": "failed"])
        event(model, "message.complete")
        XCTAssertEqual(model.current?.displayState, .failed)
        let oldTurn = model.current?.latestUserTurnID
        model.draft = "Try a different task"
        await model.send()
        event(model, "message.start")
        event(model, "message.complete", ["text": "This task succeeded"])
        XCTAssertNotEqual(model.current?.latestUserTurnID, oldTurn)
        XCTAssertEqual(model.current?.agents.first?.state, .failed)
        XCTAssertEqual(model.current?.displayState, .finished)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        XCTAssertNil(model.currentFailedAgent)
    }

    func testLegacyArchiveAndChildTurnMetadataDecodeSafely() throws {
        let old = Data(#"{"id":"legacy","state":"finished","messages":[{"id":"turn","role":"user","text":"Task","createdAt":0}],"agents":[{"id":"child","title":"Legacy child","state":"failed","tools":[],"text":"Failed"}]}"#.utf8)
        let session = try JSONDecoder().decode(CompanionSession.self, from: old)
        XCTAssertFalse(session.isArchived)
        XCTAssertEqual(session.agents.first?.turnID, "turn")
        XCTAssertEqual(session.displayState, .failed)
        var next = session
        next.messages.append(ChatMessage(id: "new-turn", role: "user", text: "New task"))
        XCTAssertEqual(next.displayState, .finished)
        XCTAssertEqual(try JSONDecoder().decode(CompanionSession.self, from: JSONEncoder().encode(next)).agents.first?.turnID, "turn")
    }

    func testDeferredReconnectWaitsForParentAndEveryChild() async throws {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.start")
        event(model, "subagent.start", ["subagent_id": "first"])
        event(model, "subagent.start", ["subagent_id": "second"])
        model.activeOperationDecision = { _ in .whenFinished }
        await model.reconnect()
        XCTAssertEqual(model.deferredOperation, .reconnect)
        XCTAssertEqual(transport.disconnectCount, 0)
        event(model, "message.complete")
        event(model, "subagent.complete", ["subagent_id": "first"])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(transport.disconnectCount, 0)
        event(model, "subagent.complete", ["subagent_id": "second"])
        try await waitUntil { transport.connectCount == 1 }
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertEqual(transport.connectCount, 1)
        XCTAssertNil(model.deferredOperation)
    }

    func testInterruptAcknowledgementDoesNotPrematurelyRunDeferredQuit() async throws {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.start")
        event(model, "subagent.start", ["subagent_id": "child"])
        var quitCount = 0
        let quit = expectation(description: "quit after the child has settled")
        quit.assertForOverFulfill = true
        model.terminateApplication = { quitCount += 1; quit.fulfill() }
        model.activeOperationDecision = { _ in .whenFinished }
        await model.requestQuit()
        await model.interrupt()
        XCTAssertFalse(model.current!.isBusy)
        XCTAssertTrue(model.hasActiveWork)
        event(model, "message.complete", ["status": "interrupted"])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(quitCount, 0)
        event(model, "subagent.complete", ["subagent_id": "child", "status": "interrupted"])
        await fulfillment(of: [quit], timeout: 5)
        XCTAssertEqual(quitCount, 1)
    }

    func testDeferredOperationCanBeCancelledAfterWorkSettles() async throws {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.start")
        model.activeOperationDecision = { _ in .whenFinished }
        await model.reconnect()
        event(model, "message.complete")
        model.cancelDeferredOperation()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(transport.disconnectCount, 0)
        XCTAssertNil(model.deferredOperation)
    }

    func testStopNowAndCancelHaveDistinctEffects() async {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.start")
        model.activeOperationDecision = { _ in .cancel }
        await model.reconnect()
        XCTAssertEqual(transport.disconnectCount, 0)
        XCTAssertNil(model.deferredOperation)
        model.activeOperationDecision = { _ in .stopNow }
        await model.reconnect()
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertEqual(transport.connectCount, 1)
    }

    func testRestoredUnconfirmedSendAllowsQuitAndReconnectWithoutLosingItsIntent() async throws {
        let (original, _, file) = fixture()
        defer { cleanUp(original, file) }
        let pending = PendingSubmission(id: "old-input", draft: "Possibly delivered", userTurnCount: 1, attachmentIDs: [])
        original.sessions[0].runtime = .claude
        original.sessions[0].storedID = "native-claude-session"
        original.sessions[0].state = .interrupted
        original.sessions[0].parentTurnComplete = false
        original.sessions[0].pendingSubmission = pending
        original.sessions[0].messages = [ChatMessage(role: "assistant", text: "Old connection error")]
        original.draft = "Next draft"
        original.markAllAsRead()
        original.shutdown()

        let transport = ManagementTransport()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown() }
        var alertCount = 0, quitCount = 0
        model.activeOperationDecision = { _ in alertCount += 1; return .whenFinished }
        model.terminateApplication = { quitCount += 1 }
        XCTAssertNil(model.current?.runtimeID)
        XCTAssertFalse(model.hasActiveWork)
        XCTAssertFalse(model.canArchiveSession(model.currentID!))
        await model.requestQuit()
        XCTAssertEqual(quitCount, 1)
        XCTAssertEqual(alertCount, 0)
        XCTAssertNil(model.deferredOperation)
        await model.reconnect()
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertEqual(transport.connectCount, 1)
        XCTAssertEqual(alertCount, 0)
        XCTAssertEqual(model.current?.pendingSubmission, pending)
        XCTAssertEqual(model.draft, "Next draft")
        model.shutdown()
        let restored = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file))
        XCTAssertEqual(restored.first?.pendingSubmission, pending)
        XCTAssertEqual(restored.first?.storedID, "native-claude-session")
        XCTAssertEqual(restored.first?.latestResponse, "Old connection error")
        XCTAssertEqual(restored.first?.draft, "Next draft")
        XCTAssertFalse(restored.first!.hasUnreadResult)
    }

    func testLiveUnconfirmedSendGuardsQuitUntilItsFrontendDisconnects() async throws {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        model.sessions[0].state = .interrupted
        let pending = PendingSubmission(id: "live-input", draft: "Unconfirmed", userTurnCount: 1, attachmentIDs: [])
        model.sessions[0].pendingSubmission = pending
        var quitCount = 0
        model.terminateApplication = { quitCount += 1 }
        model.activeOperationDecision = { _ in .cancel }
        await model.requestQuit()
        XCTAssertEqual(quitCount, 0)
        XCTAssertTrue(model.hasActiveWork)
        model.activeOperationDecision = { _ in .whenFinished }
        await model.requestQuit()
        XCTAssertEqual(model.deferredOperation, .quit)
        event(model, "session.disconnected")
        try await waitUntil { quitCount == 1 }
        XCTAssertEqual(quitCount, 1)
        XCTAssertFalse(model.hasActiveWork)
        XCTAssertEqual(model.current?.pendingSubmission, pending)
    }

    func testSubmittingIsProtectedEvenBeforeTurnStarts() async throws {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        await model.connect()
        transport.holdPrompt = true
        model.draft = "Starting work"
        let send = Task { await model.send() }
        let deadline = Date().addingTimeInterval(5)
        while transport.promptWaiter == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(transport.promptWaiter)
        XCTAssertTrue(model.submitting)
        model.activeOperationDecision = { _ in .whenFinished }
        await model.reconnect()
        XCTAssertEqual(transport.disconnectCount, 0)
        XCTAssertFalse(model.canArchiveSession(model.currentID!))
        transport.promptWaiter?.resume(returning: ["status": "streaming"])
        transport.promptWaiter = nil
        await send.value
        event(model, "message.complete")
        try await waitUntil { transport.disconnectCount == 1 }
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testArchivePreservesUnreadReceiptAndAttentionAcrossReload() throws {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.complete", ["text": "Unread answer"])
        let id = model.currentID!
        let receipt = model.current?.completionID
        model.archiveSession(id)
        XCTAssertTrue(model.sessions.first(where: { $0.id == id })!.isArchived)
        XCTAssertEqual(model.sessions.first(where: { $0.id == id })?.completionID, receipt)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        XCTAssertFalse(model.visibleSessions.contains(where: { $0.id == id }))
        model.sessionFilter = .unread
        XCTAssertEqual(model.visibleSessions.map(\.id), [id])
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file))
        XCTAssertTrue(saved.first(where: { $0.id == id })!.isArchived)
        XCTAssertTrue(saved.first(where: { $0.id == id })!.hasUnreadCompletion)
        model.restoreSession(id)
        XCTAssertFalse(model.sessions.first(where: { $0.id == id })!.isArchived)
        XCTAssertTrue(model.sessions.first(where: { $0.id == id })!.hasUnreadCompletion)
    }

    func testArchiveRejectsActiveWorkAndPreservesSelection() {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        let current = model.currentID!
        event(model, "message.start")
        model.archiveSession(current)
        XCTAssertFalse(model.current!.isArchived)
        event(model, "message.complete")
        model.sessions.append(CompanionSession(id: "unread-next", state: .finished))
        model.setSessionVisibility(notchVisible: true)
        model.archiveSession(current)
        XCTAssertEqual(model.currentID, current)
        XCTAssertTrue(model.current!.isArchived)
        XCTAssertEqual(model.page, .sessions)
        XCTAssertTrue(model.sessions.first(where: { $0.id == "unread-next" })!.hasUnreadCompletion)
    }

    func testArchivingSelectedSessionDoesNotReadAnotherFullWindowConversation() {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        event(model, "message.complete", ["text": "Selected response"])
        let selectedID = model.currentID!
        model.sessions.append(CompanionSession(id: "unread-other", state: .finished, completionID: "other-receipt"))
        model.setSessionVisibility(fullSessionVisible: true, fullConversationVisible: true)
        XCTAssertFalse(model.current!.hasUnreadCompletion)
        model.archiveSession(selectedID)
        XCTAssertEqual(model.currentID, selectedID)
        XCTAssertTrue(model.current!.isArchived)
        let other = model.sessions.first(where: { $0.id == "unread-other" })!
        XCTAssertTrue(other.hasUnreadCompletion)
        XCTAssertNil(other.acknowledgedCompletionID)
        XCTAssertEqual(model.sessionIndicators.map(\.id), ["unread-other"])
    }

    func testSearchFiltersAndRenamePreserveConversation() {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        model.sessions = [
            CompanionSession(id: "normal", title: "Untitled", messages: [ChatMessage(role: "user", text: "Discuss Zürich")]),
            CompanionSession(id: "archived-failure", title: "Archive", state: .failed, isArchived: true),
            CompanionSession(id: "archived-unread", title: "Answer", state: .finished, isArchived: true)
        ]
        model.renameSession("normal", title: "  Research notes  ")
        XCTAssertEqual(model.sessions[0].title, "Research notes")
        model.renameSession("normal", title: "  ")
        XCTAssertEqual(model.sessions[0].title, "Research notes")
        model.sessionSearch = "ZÜRICH"
        XCTAssertEqual(model.visibleSessions.map(\.id), ["normal"])
        model.sessionSearch = "research"
        XCTAssertEqual(model.visibleSessions.map(\.id), ["normal"])
        model.sessionSearch = ""
        model.sessionFilter = .needsYou
        XCTAssertEqual(model.visibleSessions.map(\.id), ["archived-failure"])
        model.sessionFilter = .unread
        XCTAssertEqual(model.visibleSessions.map(\.id), ["archived-failure", "archived-unread"])
        model.sessions[1].acknowledgeResult()
        XCTAssertEqual(model.visibleSessions.map(\.id), ["archived-unread"])
        model.sessionFilter = .needsYou
        XCTAssertTrue(model.visibleSessions.isEmpty)
        model.sessionFilter = .archived
        XCTAssertEqual(Set(model.visibleSessions.map(\.id)), ["archived-failure", "archived-unread"])
    }

    func testStartingArchivedSessionRestoresItAndNewSessionResetsFilter() async {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        await model.connect()
        model.sessions[0].isArchived = true
        model.draft = "Continue this task"
        await model.send()
        XCTAssertFalse(model.current!.isArchived)
        model.sessionFilter = .archived
        model.sessionSearch = "Old search"
        await model.newSession(showPanel: false)
        XCTAssertEqual(model.sessionFilter, .all)
        XCTAssertTrue(model.sessionSearch.isEmpty)
    }

    func testSearchAndFiltersRetainStableSessionInsertionOrder() {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        model.sessions = [
            CompanionSession(id: "first", title: "Match one", state: .failed, updatedAt: Date(timeIntervalSince1970: 1)),
            CompanionSession(id: "second", title: "Other", state: .idle, updatedAt: Date(timeIntervalSince1970: 3)),
            CompanionSession(id: "third", title: "Match three", state: .waiting, updatedAt: Date(timeIntervalSince1970: 2)),
            CompanionSession(id: "archived", title: "Match archive", state: .finished, updatedAt: Date(timeIntervalSince1970: 4), isArchived: true)
        ]
        // "second" is read, idle and old, so it rests under Archived; a search finds archived sessions too.
        XCTAssertEqual(model.visibleSessions.map(\.id), ["first", "third"])
        model.sessionFilter = .archived
        XCTAssertEqual(model.visibleSessions.map(\.id), ["second", "archived"])
        model.sessionFilter = .all
        model.sessionSearch = "Match"
        XCTAssertEqual(model.visibleSessions.map(\.id), ["first", "third", "archived"])
        model.sessionFilter = .needsYou
        XCTAssertEqual(model.visibleSessions.map(\.id), ["first", "third"])
        XCTAssertEqual(model.sessionIndicators.map(\.id), ["first", "third", "archived"])
    }

    func testProjectsGroupByFolderAndStartNewSessionsThere() async {
        let (model, _, file) = fixture()
        defer { cleanUp(model, file) }
        model.workspacePath = "/tmp/app"
        model.sessions = [
            CompanionSession(id: "app", title: "App", workspacePath: "/tmp/app"),
            CompanionSession(id: "site", title: "Site", workspacePath: "/tmp/site/"),
            CompanionSession(id: "default", title: "Draft in the default folder")
        ]
        XCTAssertEqual(model.visibleProjects.map(\.name), ["app", "site"])
        XCTAssertEqual(model.visibleProjects.map { $0.sessions.map(\.id) }, [["app", "default"], ["site"]])
        await model.newSession(showPanel: false, workspace: "/tmp/site")
        let created = model.currentID!
        XCTAssertEqual(model.current?.workspacePath, "/tmp/site")
        XCTAssertEqual(model.page, .session)
        XCTAssertEqual(model.visibleProjects.map { $0.sessions.map(\.id) }, [[created, "site"], ["app", "default"]])
    }

    // MARK: Auto-archive

    /// A private defaults suite, so the archive setting never leaks between tests.
    private func dormancyFixture(_ sessions: [CompanionSession]) -> (AppModel, ManagementTransport, URL, UserDefaults) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-dormancy-\(UUID().uuidString)/sessions.json")
        let suite = "notch-dormancy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let transport = ManagementTransport()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport, preferences: defaults)
        model.sessions = sessions + [CompanionSession(id: "selected", title: "Selected")]
        model.currentID = "selected"
        addTeardownBlock {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        return (model, transport, file, defaults)
    }

    private func readSession(_ id: String, hoursAgo: Double) -> CompanionSession {
        CompanionSession(id: id, title: "Old \(id)", state: .finished,
                         messages: [ChatMessage(role: "user", text: "Question"), ChatMessage(role: "assistant", text: "Answer")],
                         updatedAt: Date().addingTimeInterval(-hoursAgo * 3_600),
                         completionID: "\(id)-result", acknowledgedCompletionID: "\(id)-result")
    }

    func testReadIdleSessionMovesToArchivedAfterTheSetting() {
        let (model, _, _, defaults) = dormancyFixture([readSession("old", hoursAgo: 48), readSession("recent", hoursAgo: 2)])
        XCTAssertEqual(model.autoArchiveAfter, .halfDay)
        XCTAssertEqual(model.visibleSessions.map(\.id), ["recent", "selected"])
        XCTAssertEqual(model.archivedCount, 1)
        XCTAssertFalse(model.sessions.first { $0.id == "old" }!.isArchived, "Derived, never flagged")
        XCTAssertFalse(model.glanceEntries.contains { $0.id == "old" }, "The glance skips it as recent work")
        model.sessionFilter = .archived
        XCTAssertEqual(model.visibleSessions.map(\.id), ["old"])
        model.sessionFilter = .all
        model.sessionSearch = "Old old"
        XCTAssertEqual(model.visibleSessions.map(\.id), ["old"], "Search finds it from the default list")
        model.sessionSearch = ""

        model.autoArchiveAfter = .threeDays
        XCTAssertEqual(model.visibleSessions.map(\.id), ["old", "recent", "selected"])
        model.autoArchiveAfter = .hour
        XCTAssertEqual(model.visibleSessions.map(\.id), ["selected"])
        model.autoArchiveAfter = .never
        XCTAssertEqual(model.visibleSessions.map(\.id), ["old", "recent", "selected"])
        XCTAssertEqual(model.archivedCount, 0)

        let reloaded = AppModel(storageURL: model.storageURL, playsSounds: false, client: ManagementTransport(), preferences: defaults)
        defer { reloaded.shutdown() }
        XCTAssertEqual(reloaded.autoArchiveAfter, .never, "The setting persists")
    }

    func testActiveSessionsNeverAutoArchive() {
        var unread = readSession("unread", hoursAgo: 48)
        unread.acknowledgedCompletionID = nil
        var failed = readSession("failed", hoursAgo: 48)
        (failed.state, failed.acknowledgedCompletionID) = (.failed, nil)
        var waiting = readSession("waiting", hoursAgo: 48)
        waiting.state = .waiting
        var working = readSession("working", hoursAgo: 48)
        working.state = .working
        var pending = readSession("pending", hoursAgo: 48)
        pending.pendingSubmission = PendingSubmission(id: "turn", draft: "Sent?", userTurnCount: 1, attachmentIDs: [])
        pending.acknowledgeResult()
        var queued = readSession("queued", hoursAgo: 48)
        queued.queuedSends = [QueuedSend(id: "later", text: "Then this")]
        var drafted = readSession("drafted", hoursAgo: 48)
        drafted.draft = "Half-written follow-up"
        var attached = readSession("attached", hoursAgo: 48)
        attached.attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/notes.txt"))]
        let active = [unread, failed, waiting, working, pending, queued, drafted, attached]
        let (model, _, _, _) = dormancyFixture(active + [readSession("old", hoursAgo: 48)])
        XCTAssertEqual(model.visibleSessions.map(\.id), active.map(\.id) + ["selected"])
        model.sessionFilter = .archived
        XCTAssertEqual(model.visibleSessions.map(\.id), ["old"])
        model.currentID = "old"
        XCTAssertTrue(model.visibleSessions.isEmpty, "The selection stays in the default list")
        XCTAssertEqual(model.sessionIndicators.map(\.id), ["unread", "failed", "waiting", "working"], "Dots are unaffected; the read unconfirmed send has none")
    }

    func testSelectingAcknowledgingAndRestoringRestartTheClock() {
        var unread = readSession("unread", hoursAgo: 48)
        unread.acknowledgedCompletionID = nil
        let (model, _, _, _) = dormancyFixture([readSession("opened", hoursAgo: 48), readSession("restored", hoursAgo: 48), unread])
        model.selectSession("opened")
        model.selectSession("selected")
        XCTAssertNotNil(model.sessions.first { $0.id == "opened" }?.lastSeenAt)
        XCTAssertFalse(model.isAutoArchived(model.sessions.first { $0.id == "opened" }!), "Opening it restarted its clock")
        XCTAssertTrue(model.isAutoArchived(model.sessions.first { $0.id == "restored" }!))
        model.restoreSession("restored")
        XCTAssertFalse(model.isAutoArchived(model.sessions.first { $0.id == "restored" }!))
        model.markAllAsRead()
        XCTAssertFalse(model.isAutoArchived(model.sessions.first { $0.id == "unread" }!), "Reading a result restarts the clock")
        XCTAssertEqual(model.visibleSessions.map(\.id), ["opened", "restored", "unread", "selected"])
    }

    func testLeavingTheSelectionRestartsItsClock() {
        let (model, _, _, _) = dormancyFixture([readSession("reading", hoursAgo: 48)])
        // Selected without selectSession (as at launch), then read with nothing new to acknowledge.
        model.currentID = "reading"
        XCTAssertNil(model.sessions.first { $0.id == "reading" }?.lastSeenAt)
        model.selectSession("selected")
        XCTAssertNotNil(model.sessions.first { $0.id == "reading" }?.lastSeenAt)
        XCTAssertFalse(model.isAutoArchived(model.sessions.first { $0.id == "reading" }!),
                       "The session just being read stays in the list instead of vanishing on the switch")
        XCTAssertTrue(model.visibleSessions.contains { $0.id == "reading" })
    }

    func testSendingBringsAnAutoArchivedSessionBack() async {
        let (model, _, _, _) = dormancyFixture([readSession("old", hoursAgo: 48)])
        await model.connect()
        model.sessionFilter = .archived
        model.selectSession("old")
        model.draft = "One more thing"
        await model.send()
        model.selectSession("selected")
        model.sessions[0].lastSeenAt = nil
        XCTAssertFalse(model.isAutoArchived(model.sessions[0]), "Sending updates it, whatever it was last seen")
        model.sessionFilter = .all
        XCTAssertTrue(model.visibleSessions.contains { $0.id == "old" })
    }

    func testLastSeenAtRoundTripsAndOlderFilesDecodeWithoutIt() throws {
        var session = CompanionSession(id: "seen", title: "Seen")
        session.lastSeenAt = Date(timeIntervalSince1970: 1_800_000_000)
        let decoded = try JSONDecoder().decode(CompanionSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.lastSeenAt, session.lastSeenAt)
        let older = try JSONDecoder().decode(CompanionSession.self, from: Data(#"{"id":"older","title":"Older"}"#.utf8))
        XCTAssertNil(older.lastSeenAt)
        XCTAssertEqual(older.title, "Older")
    }

    func testDuplicateAnswersAcrossViewsSubmitOnlyOnce() async {
        let (model, transport, file) = fixture()
        defer { cleanUp(model, file) }
        transport.holdAnswer = true
        event(model, "clarify.request", ["request_id": "question", "question": "Choose"])
        let request = model.requests[0]
        let first = Task { await model.answer(request, choice: "First") }
        for _ in 0..<100 where transport.answerWaiter == nil { await Task.yield() }
        XCTAssertTrue(model.isAnswering(request))
        await model.answer(request, choice: "Duplicate")
        XCTAssertEqual(transport.answerCount, 1)
        transport.answerWaiter?.resume(returning: ["resolved": true])
        transport.answerWaiter = nil
        await first.value
        XCTAssertFalse(model.isAnswering(request))
        XCTAssertTrue(model.requests.isEmpty)
        await model.answer(request, choice: "Stale resolved replay")
        XCTAssertEqual(transport.answerCount, 1)
    }
}

@MainActor
private final class ManagementTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var disconnectCount = 0
    var connectCount = 0
    var answerCount = 0
    var holdPrompt = false
    var holdAnswer = false
    var created: [[String: Any]] = []
    var openedTitle: String?
    var promptWaiter: CheckedContinuation<[String: Any], Error>?
    var answerWaiter: CheckedContinuation<[String: Any], Error>?

    func connect() async throws { connectCount += 1; onConnectionChange?(true, nil) }
    func disconnect() {
        disconnectCount += 1
        promptWaiter?.resume(throwing: HermesClientError.disconnected)
        promptWaiter = nil
        answerWaiter?.resume(throwing: HermesClientError.disconnected)
        answerWaiter = nil
        onConnectionChange?(false, nil)
    }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.create" {
            created.append(params)
            return ["session_id": "parent", "stored_session_id": "stored", "title": openedTitle].compactMapValues { $0 }
        }
        if method == "prompt.submit", holdPrompt { return try await withCheckedThrowingContinuation { promptWaiter = $0 } }
        if method == "clarify.respond" || method == "approval.respond" {
            answerCount += 1
            if holdAnswer { return try await withCheckedThrowingContinuation { answerWaiter = $0 } }
        }
        return ["status": "streaming", "resolved": true]
    }
}
