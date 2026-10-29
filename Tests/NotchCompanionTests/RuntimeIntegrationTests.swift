import XCTest
@testable import NotchCompanion

@MainActor
private final class RoutedFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    var connectError = false
    var running = false
    var disconnectCount = 0
    var failPromptAfterAcceptance = false
    var rejectPrompt = false
    var missingResume = false
    var history: [[String: Any]] = []
    var completeOnAnswer = false
    var terminalStatus: String?
    var resumeFields: [String: Any] = [:]
    func connect() async throws {
        if connectError { throw AppError("Unavailable fixture") }
        onConnectionChange?(true, nil)
    }
    func disconnect() { disconnectCount += 1; onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        switch method {
        case "session.create", "session.resume":
            if method == "session.resume" && missingResume { throw HermesClientError.rpc(4007, "Session not found") }
            var result: [String: Any] = ["session_id": "same-native-id", "stored_session_id": "durable-id", "running": running, "messages": history]
            if let terminalStatus { result["terminal_status"] = terminalStatus }
            result.merge(resumeFields) { _, new in new }
            return result
        case "prompt.submit":
            if rejectPrompt { throw HermesClientError.rpc(4000, "Rejected fixture") }
            history.append(["role": "user", "text": params["text"] as? String ?? ""])
            if failPromptAfterAcceptance { throw HermesClientError.timedOut("prompt.submit") }
            return [:]
        case "approval.respond":
            if completeOnAnswer { event("message.complete", ["text": "Finished", "status": "complete"]) }
            return [:]
        case "file.attach": return ["ref_text": "attached fixture"]
        default: return [:]
        }
    }
    func event(_ name: String, _ extra: [String: Any] = [:]) {
        onEvent?(name, extra.merging(["session_id": "same-native-id"]) { old, _ in old })
    }
}

@MainActor
private final class StartupFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var starts = 0
    var first: CheckedContinuation<Void, Error>?
    func connect() async throws {
        starts += 1
        if starts == 1 { try await withCheckedThrowingContinuation { first = $0 } }
        onConnectionChange?(true, nil)
    }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func disconnect() {
        first?.resume(throwing: AppError("Cancelled startup")); first = nil
        onConnectionChange?(false, nil)
    }
}

@MainActor
final class RuntimeIntegrationTests: XCTestCase {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("notch-runtime-\(UUID().uuidString)/sessions.json")
    }

    func testLegacyDecodePinsPrivateProfileAndPreservesAllContent() throws {
        let data = Data(#"{"id":"old","storedID":"private-id","title":"Earlier work","messages":[{"id":"u","role":"user","text":"Context","createdAt":0}],"draft":"Next step","attachments":[{"id":"00000000-0000-0000-0000-000000000001","url":"file:///tmp/input.txt"}]}"#.utf8)
        let session = try JSONDecoder().decode(CompanionSession.self, from: data)
        XCTAssertEqual(session.runtime, .hermes)
        XCTAssertTrue(session.isLegacyPrivate)
        XCTAssertEqual(session.storedID, "private-id")
        XCTAssertEqual(session.profileID, RuntimeRoute.defaultProfile(.hermes, legacy: true))
        XCTAssertEqual(session.draft, "Next step")
        XCTAssertEqual(session.attachments.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(CompanionSession.self, from: JSONEncoder().encode(session)), session)
    }

    func testUnsentOldDraftUsesSharedProfileWithoutLosingAttachments() throws {
        let data = Data(#"{"id":"draft","draft":"Keep this","attachments":[]}"#.utf8)
        let session = try JSONDecoder().decode(CompanionSession.self, from: data)
        XCTAssertFalse(session.isLegacyPrivate)
        XCTAssertEqual(session.profileID, RuntimeRoute.defaultProfile(.hermes))
        XCTAssertEqual(session.draft, "Keep this")
    }

    func testRouterNamespacesEventsApprovalsAndRefusesGlobalListing() async throws {
        let hermes = RoutedFixture(), codex = RoutedFixture()
        let router = RuntimeRouter { $0.runtime == .hermes ? hermes : codex }
        defer { router.disconnect() }
        var events: [(String, [String: Any])] = []
        router.onEvent = { events.append(($0, $1)) }
        let h = try await router.request("session.create", params: ["companion_id": "local-h", "runtime": "hermes"])
        let c = try await router.request("session.create", params: ["companion_id": "local-c", "runtime": "codex"])
        let hs = try XCTUnwrap(h["session_id"] as? String), cs = try XCTUnwrap(c["session_id"] as? String)
        XCTAssertNotEqual(hs, cs)
        XCTAssertEqual(h["stored_session_id"] as? String, "durable-id")
        hermes.event("approval.request", ["request_id": "1", "command": "fixture"])
        codex.event("approval.request", ["request_id": "1", "command": "fixture"])
        let approvals = events.filter { $0.0 == "approval.request" }
        XCTAssertEqual(approvals.count, 2)
        XCTAssertEqual(approvals[0].1["session_id"] as? String, hs)
        XCTAssertEqual(approvals[1].1["session_id"] as? String, cs)
        _ = try await router.request("approval.respond", params: ["session_id": cs, "request_id": cs + ":1", "choice": "deny"])
        XCTAssertEqual(codex.calls.last?.1["request_id"] as? String, "1")
        XCTAssertEqual(codex.calls.last?.1["session_id"] as? String, "same-native-id")
        XCTAssertEqual(hermes.calls.count, 1)
        let count = events.count
        codex.onEvent?("message.delta", ["session_id": "external-id", "text": "External session must be invisible"])
        XCTAssertEqual(events.count, count)
        do { _ = try await router.request("session.list", params: [:]); XCTFail("Global list must be unavailable") } catch {}
        do { _ = try await router.request("session.resume", params: ["runtime": "codex", "session_id": "external-id"]); XCTFail("Ownership identity required") } catch {}
    }

    func testOneRuntimeDisconnectDoesNotInterruptOtherRuntime() async throws {
        let hermes = RoutedFixture(), codex = RoutedFixture()
        let router = RuntimeRouter { $0.runtime == .hermes ? hermes : codex }
        let file = temporaryFile()
        let model = AppModel(storageURL: file, playsSounds: false, client: router)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await model.connect()
        model.draft = "Hermes task"
        await model.send()
        let hID = try XCTUnwrap(model.currentID)
        hermes.event("message.start")
        await model.newSession(showPanel: false, runtime: .codex)
        model.draft = "Codex task"
        await model.send()
        codex.event("message.start")
        let cID = try XCTUnwrap(model.currentID)
        hermes.onConnectionChange?(false, "Fixture disconnect")
        XCTAssertEqual(model.sessions.first { $0.id == hID }?.state, .interrupted)
        XCTAssertNil(model.sessions.first { $0.id == hID }?.runtimeID)
        XCTAssertEqual(model.sessions.first { $0.id == cID }?.state, .working)
        XCTAssertNotNil(model.sessions.first { $0.id == cID }?.runtimeID)
        XCTAssertTrue(model.connection)
        XCTAssertTrue(model.hasActiveWork)
        codex.event("message.complete", ["status": "complete", "text": "done"])
        XCTAssertFalse(model.hasActiveWork)
    }

    func testMissingRuntimeDoesNotDisableAvailableOne() async throws {
        let hermes = RoutedFixture(), codex = RoutedFixture()
        hermes.connectError = true
        let router = RuntimeRouter { $0.runtime == .hermes ? hermes : codex }
        defer { router.disconnect() }
        try await router.connect()
        XCTAssertFalse(router.status(RuntimeRoute(runtime: .codex)).connected, "Startup is lazy")
        do { try await router.connect(RuntimeRoute(runtime: .hermes)); XCTFail("Missing runtime must report setup failure") } catch {}
        try await router.connect(RuntimeRoute(runtime: .codex))
        XCTAssertFalse(router.status(RuntimeRoute(runtime: .hermes)).connected)
        XCTAssertTrue(router.status(RuntimeRoute(runtime: .codex)).connected)
    }

    func testContinuationStagesContextAndRetainsOriginalUnchanged() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var old = CompanionSession()
        old.title = "Prior task"; old.storedID = "private-old"; old.isLegacyPrivate = true
        old.profileID = RuntimeRoute.defaultProfile(.hermes, legacy: true)
        old.messages = [ChatMessage(role: "user", text: "Important context"), ChatMessage(role: "assistant", text: "Prior answer")]
        old.draft = "Continue this work"; old.attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/previous.txt"))]
        model.sessions = [old]; model.currentID = old.id
        await model.continueLegacySession(old.id)
        XCTAssertEqual(model.sessions.first { $0.id == old.id }, old)
        let next = try XCTUnwrap(model.current)
        XCTAssertNotEqual(next.id, old.id)
        XCTAssertFalse(next.isLegacyPrivate)
        XCTAssertNil(next.storedID)
        XCTAssertEqual(next.migratedFromSessionID, old.id)
        XCTAssertEqual(next.draft, old.draft)
        XCTAssertEqual(next.attachments.first, old.attachments.first)
        XCTAssertEqual(next.attachments.count, 2)
        let context = try String(contentsOf: XCTUnwrap(next.attachments.last).url, encoding: .utf8)
        XCTAssertTrue(context.contains("Important context"))
        XCTAssertTrue(context.contains("Prior answer"))
        XCTAssertTrue(transport.calls.isEmpty, "Continuation must not submit or create native state")
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, model.sessions)
    }

    func testSavedIdentityLocksRuntimeButDraftChoicePreservesInput() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = try XCTUnwrap(model.currentID)
        model.draft = "Do work"
        model.setRuntime(.codex, for: id)
        XCTAssertEqual(model.current?.runtime, .codex)
        XCTAssertEqual(model.draft, "Do work")
        await model.connect(); await model.send()
        model.setRuntime(.hermes, for: id)
        XCTAssertEqual(model.current?.runtime, .codex)
        XCTAssertEqual(model.current?.storedID, "durable-id")
        XCTAssertEqual(model.current?.profileID, RuntimeRoute.defaultProfile(.codex))
    }

    func testUnreadableRegistryIsNeverOverwritten() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("{bad history".utf8)
        try damaged.write(to: file)
        let model = AppModel(storageURL: file, playsSounds: false, client: RoutedFixture())
        model.shutdown()
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertNotNil(model.errorMessage)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testBusyNativeResumeDoesNotSubmitCompetingTurn() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        transport.running = true
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.sessions[0].storedID = "durable-id"
        model.draft = "Do not duplicate"
        await model.connect(); await model.send()
        XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertEqual(model.draft, "Do not duplicate")
        XCTAssertNotNil(model.errorMessage)
    }
    func testLostAcknowledgementChecksNativeHistoryInsteadOfResending() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await model.connect()
        model.draft = "Send exactly once"
        transport.failPromptAfterAcceptance = true
        transport.terminalStatus = "complete"
        await model.send()
        XCTAssertNotNil(model.current?.pendingSubmission)
        XCTAssertTrue(model.hasActiveWork, "Unknown native acceptance blocks silent reload")
        XCTAssertEqual(model.current?.displayState, .failed)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
        model.markAllAsRead()
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        XCTAssertNotNil(model.current?.pendingSubmission)
        XCTAssertTrue(model.hasActiveWork, "Reading cannot certify native delivery or allow a silent reload")
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: file))
        XCTAssertNotNil(saved.first?.pendingSubmission)
        await model.send()
        XCTAssertEqual(transport.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        XCTAssertNil(model.current?.pendingSubmission)
        XCTAssertEqual(model.current?.state, .finished)
        XCTAssertTrue(model.current?.hasUnreadCompletion == true)
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertEqual(model.current?.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertFalse(model.hasActiveWork)
    }

    func testDefiniteRejectionRetainsDraftAndPriorHistory() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await model.connect()
        let old = ChatMessage(role: "user", text: "Preserve this earlier turn")
        model.sessions[0].messages = [old]
        model.sessions[0].runtimeID = "same-native-id"
        model.draft = "Rejected request"
        transport.rejectPrompt = true
        await model.send()
        XCTAssertEqual(model.current?.messages, [old])
        XCTAssertEqual(model.draft, "Rejected request")
        XCTAssertNil(model.current?.pendingSubmission)
    }

    func testKnownUnusedMissingHermesIDCanRecoverWithoutDiscardingDraft() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await model.connect()
        model.sessions[0].storedID = "unused-not-persisted"
        model.draft = "First real turn"
        transport.missingResume = true
        await model.send()
        XCTAssertEqual(transport.calls.filter { $0.0 == "session.create" }.count, 1)
        XCTAssertEqual(transport.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        XCTAssertEqual(model.current?.storedID, "durable-id")
    }

    func testMissingSubmittedNativeHistoryNeverCreatesUnrelatedReplacement() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await model.connect()
        model.sessions[0].storedID = "missing-history"
        model.sessions[0].nativeSubmissionAttempted = true
        let old = ChatMessage(role: "user", text: "Original history")
        model.sessions[0].messages = [old]
        model.draft = "Preserve draft"
        transport.missingResume = true
        await model.send()
        XCTAssertEqual(model.current?.storedID, "missing-history")
        XCTAssertEqual(model.current?.messages, [old])
        XCTAssertEqual(model.draft, "Preserve draft")
        XCTAssertFalse(transport.calls.contains { $0.0 == "session.create" || $0.0 == "prompt.submit" })
    }

    func testUncertainSendCannotBeHiddenOrDiscarded() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = try XCTUnwrap(model.currentID)
        model.sessions[0].state = .interrupted
        model.sessions[0].isLegacyPrivate = true
        model.sessions[0].pendingSubmission = PendingSubmission(id: "turn", draft: "Unknown", userTurnCount: 1, attachmentIDs: [])
        XCTAssertFalse(model.canArchiveSession(id))
        model.archiveSession(id)
        model.deleteSession(id)
        await model.continueLegacySession(id)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.current?.id, id)
        XCTAssertFalse(model.current?.isArchived ?? true)
        XCTAssertNotNil(model.current?.pendingSubmission)
    }

    func testApprovalAcknowledgementCannotResurrectFinishedTurn() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.sessions[0].runtimeID = "same-native-id"
        transport.event("message.start")
        transport.event("approval.request", ["request_id": "approval", "command": "fixture", "choices": ["once", "deny"]])
        let request = try XCTUnwrap(model.currentRequest)
        transport.completeOnAnswer = true
        await model.answer(request, choice: "deny")
        XCTAssertEqual(model.current?.state, .finished)
        XCTAssertFalse(model.hasActiveWork)
    }

    func testReusedNativeChildRetainsPriorTurnAndPropagatesNewFailure() throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.sessions[0].runtimeID = "same-native-id"
        model.sessions[0].messages = [ChatMessage(id: "first", role: "user", text: "First", turnID: "first")]
        transport.event("message.start")
        transport.event("subagent.start", ["subagent_id": "native-child"])
        transport.event("subagent.complete", ["subagent_id": "native-child", "status": "complete", "text": "First child result"])
        transport.event("message.complete", ["status": "complete"])
        model.sessions[0].messages.append(ChatMessage(id: "next", role: "user", text: "Next", turnID: "next"))
        transport.event("message.start")
        transport.event("subagent.start", ["subagent_id": "native-child"])
        transport.event("subagent.complete", ["subagent_id": "native-child", "status": "error", "text": "Failed now"])
        transport.event("message.complete", ["status": "complete"])
        XCTAssertEqual(model.current?.agents.count, 2)
        XCTAssertEqual(model.current?.agents.first?.turnID, "first")
        XCTAssertEqual(model.current?.agents.first?.text, "First child result")
        XCTAssertEqual(model.current?.agents.last?.turnID, "next")
        XCTAssertEqual(model.current?.displayState, .failed)
        XCTAssertFalse(model.current?.hasUnreadCompletion ?? true)
    }

    func testInitialNativeTitleUsesPromptInsteadOfPlaceholder() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await model.connect()
        model.draft = "A recognizable native conversation title"
        await model.send()
        XCTAssertEqual(transport.calls.first { $0.0 == "session.create" }?.1["title"] as? String, "A recognizable native conversation title")
    }

    func testReconnectDuringStartupStartsFreshConnection() async throws {
        let file = temporaryFile(), transport = StartupFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let startup = Task { await model.connect() }
        while transport.first == nil { await Task.yield() }
        await model.reconnect()
        await startup.value
        XCTAssertEqual(transport.starts, 2)
        XCTAssertTrue(model.connection)
        XCTAssertFalse(model.connectionMessage.contains("Cancelled"))
    }

    func testTruncatedHistoryCannotMakeUncertainSendRetryable() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.sessions[0].storedID = "native"
        model.sessions[0].messages = [ChatMessage(id: "prior", role: "user", text: "Prior"), ChatMessage(id: "pending", role: "user", text: "Uncertain")]
        model.sessions[0].pendingSubmission = PendingSubmission(id: "pending", draft: "Uncertain", userTurnCount: 2, attachmentIDs: [])
        model.draft = "Uncertain"
        await model.connect(); await model.send()
        XCTAssertNotNil(model.current?.pendingSubmission)
        XCTAssertEqual(model.draft, "Uncertain")
        XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
    }

    func testIncompleteSendRecoveryRetainsNativeActivityBeforeReportingMissingReceipt() async throws {
        for (running, children) in [(true, [[String: Any]]()),
                                    (false, [["id": "native-child", "status": "waiting"]]),
                                    (false, [[String: Any]]())] {
            let file = temporaryFile(), transport = RoutedFixture()
            let model = AppModel(storageURL: file, playsSounds: false, client: transport)
            defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            model.sessions[0].storedID = "native"
            model.sessions[0].state = .interrupted
            model.sessions[0].parentTurnComplete = false
            let pending = PendingSubmission(id: "pending", draft: "Uncertain", userTurnCount: 1, attachmentIDs: [])
            model.sessions[0].pendingSubmission = pending
            model.draft = "Next draft"
            transport.resumeFields = ["history_complete": false, "running": running,
                                      "parent_complete": !running, "subagents": children]
            await model.connect(); await model.send()
            let active = running || !children.isEmpty
            XCTAssertEqual(model.hasActiveWork, active)
            XCTAssertEqual(model.current?.isBusy, active)
            XCTAssertEqual(model.current?.runtimeID != nil, active)
            XCTAssertEqual(model.current?.pendingSubmission, pending)
            XCTAssertEqual(model.draft, "Next draft")
            XCTAssertTrue(model.errorMessage?.contains("no exact delivery receipt") == true)
            XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
            var quitCount = 0, alertCount = 0
            model.terminateApplication = { quitCount += 1 }
            model.activeOperationDecision = { _ in alertCount += 1; return .cancel }
            await model.requestQuit()
            XCTAssertEqual(quitCount, active ? 0 : 1)
            XCTAssertEqual(alertCount, active ? 1 : 0)
        }
    }

    func testExactNativeClientIDRecoversSendAfterHistoryCompaction() async throws {
        let file = temporaryFile(), transport = RoutedFixture()
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.sessions[0].storedID = "native"
        model.sessions[0].messages = [ChatMessage(id: "pending", role: "user", text: "Confirmed by native identity")]
        model.sessions[0].pendingSubmission = PendingSubmission(id: "pending", draft: "Confirmed by native identity", userTurnCount: 8, attachmentIDs: [])
        model.draft = "Confirmed by native identity"
        transport.history = [["role": "user", "text": "Confirmed by native identity", "client_id": "pending"]]
        transport.terminalStatus = "complete"
        await model.connect(); await model.send()
        XCTAssertNil(model.current?.pendingSubmission)
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertEqual(model.current?.state, .finished)
        XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
    }

}
