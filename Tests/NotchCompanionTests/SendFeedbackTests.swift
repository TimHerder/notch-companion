import XCTest
import SwiftUI
@testable import NotchCompanion

struct SendComposerFixture: View {
    @ObservedObject var model: AppModel
    var compact: Bool
    @FocusState private var focused: Bool
    var body: some View { ComposerView(model: model, focused: $focused, isCompact: compact).padding() }
}

@MainActor private final class SendFeedbackTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var pausedMethod = "session.create"
    var pending: CheckedContinuation<[String: Any], Error>?
    var calls: [String] = []
    var parameters: [(String, [String: Any])] = []
    var resumeFields: [String: Any] = [:]

    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { finish(.failure(AppError("Disconnected fixture"))) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(method)
        parameters.append((method, params))
        if method == pausedMethod { return try await withCheckedThrowingContinuation { pending = $0 } }
        switch method {
        case "session.create", "session.resume":
            return ["session_id": "live", "stored_session_id": "saved", "messages": []].merging(resumeFields) { _, new in new }
        case "file.attach": return ["ref_text": "fixture file"]
        default: return [:]
        }
    }
    func finish(_ result: Result<[String: Any], Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@MainActor final class SendFeedbackTests: XCTestCase {
    private var folder: URL!
    private var transport: SendFeedbackTransport!
    private var model: AppModel!
    private var preferences: UserDefaults!
    private var preferenceSuite: String!
    private var storage: URL { folder.appendingPathComponent("sessions.json") }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("send-feedback-\(UUID().uuidString)")
        transport = SendFeedbackTransport()
        preferenceSuite = "send-feedback-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferenceSuite)!
        preferences.set([RuntimeKind.hermes.rawValue: RuntimeRoute.defaultProfile(.hermes, defaults: preferences)],
                        forKey: "runtime.configuredProfiles")
        model = AppModel(storageURL: storage, playsSounds: false, client: transport, preferences: preferences)
        model.sessions[0].runtime = .hermes
        await model.connect()
    }
    override func tearDown() async throws {
        model.shutdown()
        preferences.removePersistentDomain(forName: preferenceSuite)
        try? FileManager.default.removeItem(at: folder)
    }
    private func waitForRequest() async throws {
        let deadline = Date().addingTimeInterval(5)
        while transport.pending == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(transport.pending)
    }
    private func stagedFile(_ name: String) throws -> Attachment {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        model.addAttachments([url], showPanel: false)
        return try XCTUnwrap(model.current?.attachments.last)
    }
    private func visibleMessages(_ session: CompanionSession) -> [ChatMessage] {
        ConversationTimeline.build(session: session).flatMap { item -> [ConversationTimelineItem] in
            if case .work(let work) = item { return work.entries }
            return [item]
        }.compactMap {
            switch $0 {
            case .message(let message), .commentary(let message): return message
            default: return nil
            }
        }
    }

    private func working(_ runtime: RuntimeKind = .codex) {
        transport.pausedMethod = "none"
        model.sessions[0].runtime = runtime
        model.sessions[0].runtimeID = "live"
        model.sessions[0].storedID = "saved"
        model.sessions[0].state = .working
        model.sessions[0].parentTurnComplete = false
        model.sessions[0].workspacePath = folder.path
        model.sessions[0].messages = [ChatMessage(id: "original", role: "user", text: "Original", turnID: "original")]
    }

    private func waitForSendCount(_ count: Int) async throws {
        for _ in 0..<500 where transport.calls.filter({ $0 == "prompt.submit" }).count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transport.calls.filter({ $0 == "prompt.submit" }).count, count)
        for _ in 0..<500 where model.isSubmitting(model.currentID!) { await Task.yield() }
    }

    func testQueuePersistsTextAndAttachmentsForEveryHarnessWithoutSending() async throws {
        for runtime in RuntimeKind.allCases {
            working(runtime)
            model.sessions[0].queuedSends = []
            model.draft = "After the current task"
            let file = try stagedFile("queued.txt")
            await model.send(queue: true)
            XCTAssertEqual(model.draft, "")
            XCTAssertEqual(model.current?.attachments, [])
            let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: storage))[0]
            XCTAssertEqual(saved.queuedSends.map(\.text), ["After the current task"], runtime.title)
            XCTAssertEqual(saved.queuedSends.first?.attachments, [file])
            XCTAssertTrue(transport.calls.isEmpty)
        }
    }

    func testQueueDrainsInOrderPreservesNextDraftAndFiles() async throws {
        working()
        model.draft = "First queued"
        let file = try stagedFile("queued.txt")
        await model.send(queue: true)
        model.draft = "Second queued"
        await model.send(queue: true)
        model.draft = "Still editing"
        model.receive("message.complete", payload: ["session_id": "live", "text": "Original done"])
        try await waitForSendCount(1)
        XCTAssertEqual(model.current?.queuedSends.map(\.text), ["Second queued"])
        XCTAssertEqual(model.draft, "Still editing")
        XCTAssertTrue(transport.parameters.contains { $0.0 == "file.attach" && $0.1["path"] as? String == file.url.path })
        XCTAssertEqual(transport.parameters.first { $0.0 == "prompt.submit" }?.1["text"] as? String, "First queued\n\nfixture file")
        model.receive("message.complete", payload: ["session_id": "live", "text": "First done"])
        try await waitForSendCount(2)
        XCTAssertTrue(model.current!.queuedSends.isEmpty)
        XCTAssertEqual(model.draft, "Still editing")
    }

    func testStopPausesQueueAndResumeRequiresExplicitAction() async throws {
        working()
        model.draft = "Later"
        await model.send(queue: true)
        await model.interrupt()
        model.receive("message.complete", payload: ["session_id": "live", "status": "interrupted"])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.current?.queuedSends.first?.paused, true)
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        model.resumeQueuedSends()
        try await waitForSendCount(1)
    }

    func testQueueFailureKeepsOneRecoverableCopyAndPausesFollowingMessages() async throws {
        working()
        model.draft = "Queued with a file"
        let file = try stagedFile("queued.txt")
        await model.send(queue: true)
        model.draft = "Second queued"
        await model.send(queue: true)
        model.draft = "Unsent draft"
        transport.pausedMethod = "prompt.submit"
        model.receive("message.complete", payload: ["session_id": "live", "text": "Original done"])
        try await waitForRequest()
        transport.finish(.failure(BusyInputRejection(message: "Rejected")))
        for _ in 0..<500 where model.current?.queuedSends.first?.paused != true { await Task.yield() }
        XCTAssertEqual(model.current?.queuedSends.count, 2)
        XCTAssertEqual(model.current?.queuedSends.first?.attachments, [file])
        XCTAssertTrue(model.current!.queuedSends.allSatisfy { $0.paused == true })
        XCTAssertNil(model.current?.stagedSubmission)
        XCTAssertEqual(model.current?.attachments, [])
        XCTAssertEqual(model.draft, "Unsent draft")
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
    }

    func testQueueWaitsForDelegatedChildAndCanBeCancelled() async throws {
        working()
        model.sessions[0].parentTurnComplete = true
        model.sessions[0].agents = [ChildAgent(id: "native-child", title: "Child", state: .working, turnID: "original")]
        model.draft = "Wait for child"
        await model.send(queue: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        let id = try XCTUnwrap(model.current?.queuedSends.first?.id)
        model.cancelQueuedSend(id)
        XCTAssertTrue(model.current!.queuedSends.isEmpty)
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: storage))[0]
        XCTAssertTrue(saved.queuedSends.isEmpty)
    }

    func testRestartKeepsUserQueuePausedAndDoesNotDuplicatePreparingInput() async throws {
        working()
        model.draft = "Keep for later"
        await model.send(queue: true)
        let queued = try XCTUnwrap(model.current?.queuedSends.first)
        model.sessions[0].stagedSubmission = StagedSubmission(message: ChatMessage(id: queued.id, role: "user", text: queued.text), draft: queued.text, attachments: [])
        model.save()
        let restored = AppModel(storageURL: storage, playsSounds: false, client: SendFeedbackTransport(), preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.current?.queuedSends.first?.paused, true)
        XCTAssertEqual(restored.current?.queuedSends.first?.text, queued.text)
        XCTAssertNil(restored.current?.stagedSubmission)
        XCTAssertEqual(restored.draft, "")
        XCTAssertFalse(restored.hasActiveWork)
    }

    func testPausedUserQueueDoesNotBlockMessagesFromOtherSessions() async throws {
        working()
        model.draft = "User follow-up"
        await model.send(queue: true)
        model.pauseQueuedSends(model.currentID!)
        model.sessions[0].parentTurnComplete = true
        model.sessions[0].state = .finished
        model.sessions[0].queuedSends.append(QueuedSend(id: "other-session", text: "A delegate needs guidance", kind: ChatMessage.agentMessage))
        model.processDelegationWakes()
        try await waitForSendCount(1)
        XCTAssertEqual(model.current?.queuedSends.map(\.text), ["User follow-up"])
        XCTAssertEqual(transport.parameters.first { $0.0 == "prompt.submit" }?.1["text"] as? String, "A delegate needs guidance")
    }

    func testSteeringStaysInOriginalTurnAndDoesNotEraseNewDraft() async throws {
        working()
        transport.pausedMethod = "prompt.steer"
        model.draft = "Change direction"
        let send = Task { await model.send() }
        try await waitForRequest()
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.current?.messages.last?.turnID, "original")
        model.draft = "Next draft"
        model.receive("message.start", payload: ["session_id": "live"])
        model.receive("message.complete", payload: ["session_id": "live", "text": "Old turn completed"])
        XCTAssertEqual(model.current?.pendingSubmission?.isSteering, true, "Original activity is not a steer receipt")
        transport.finish(.success(["steered": true]))
        await send.value
        XCTAssertNil(model.current?.pendingSubmission)
        XCTAssertNil(model.current?.stagedSubmission)
        XCTAssertEqual(model.draft, "Next draft")
        XCTAssertEqual(model.current?.messages.filter { $0.text == "Change direction" }.count, 1)
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
    }

    func testSteeringRejectionRestoresDraftButLostReceiptStaysProtected() async throws {
        for uncertain in [false, true] {
            working()
            transport.pausedMethod = "prompt.steer"
            model.draft = "Steer this"
            let send = Task { await model.send() }
            try await waitForRequest()
            model.draft = "New typing"
            transport.finish(.failure(uncertain ? AppError("lost acknowledgement") : BusyInputRejection(message: "turn ended")))
            await send.value
            XCTAssertEqual(model.current?.state, .working, "A failed steer must not end the original turn")
            if uncertain {
                XCTAssertEqual(model.current?.pendingSubmission?.isSteering, true)
                XCTAssertEqual(model.draft, "New typing")
                model.receive("message.complete", payload: ["session_id": "live", "text": "Done"])
                XCTAssertNotNil(model.current?.pendingSubmission)
                transport.pausedMethod = "none"
                transport.resumeFields = ["accepted_turn_ids": [model.current!.pendingSubmission!.id], "history_complete": false]
                await model.send()
                XCTAssertNil(model.current?.pendingSubmission, "An exact native receipt resolves the protected steer")
            } else {
                XCTAssertNil(model.current?.pendingSubmission)
                XCTAssertEqual(model.draft, "Steer this\n\nNew typing")
                XCTAssertFalse(model.current!.messages.contains { $0.text == "Steer this" })
            }
        }
    }

    func testSteeringHintsMatchNativeCapabilitiesAndChildOnlyWork() {
        for runtime in RuntimeKind.allCases {
            working(runtime)
            XCTAssertEqual(model.current!.canSteer, [.codex, .pi, .hermes].contains(runtime), runtime.title)
        }
        working(.opencode)
        model.sessions[0].runtimeInfo = RuntimeSessionInfo(nativeInterface: "opencode-http-v2")
        XCTAssertTrue(model.current!.canSteer)
        model.sessions[0].parentTurnComplete = true
        XCTAssertFalse(model.current!.canSteer)
        XCTAssertTrue(model.current!.busyInputHint.contains("Waiting for agents"))
        model.sessions[0].isLegacyPrivate = true
        XCTAssertFalse(model.current!.supportsSteering)
        working(.claude)
        model.sessions[0].isLegacyPrivate = false
        var capabilities = RuntimeKind.claude.capabilities
        capabilities.steering = true
        model.sessions[0].runtimeInfo = RuntimeSessionInfo(capabilities: capabilities)
        XCTAssertTrue(model.current!.canSteer)
    }

    func testNativeReturnAndCommandReturnHaveSeparateCallbacks() throws {
        let editor = ComposerTextView()
        var steer = 0, queue = 0
        editor.onSubmit = { steer += 1 }
        editor.onQueue = { queue += 1 }
        for code: UInt16 in [36, 76] {
            for modifiers: NSEvent.ModifierFlags in [[], [.command], [.shift]] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
                editor.keyDown(with: event)
            }
        }
        XCTAssertEqual(steer, 2)
        XCTAssertEqual(queue, 2)
        XCTAssertEqual(editor.string, "\n\n")
    }

    func testComposerClearsBeforeSetupAndKeepsOneMessageThroughAcknowledgement() async throws {
        model.draft = "Send now"
        let file = try stagedFile("first.txt")
        let send = Task { await model.send() }
        try await waitForRequest()
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.current?.attachments, [])
        XCTAssertTrue(model.submitting)
        XCTAssertTrue(model.hasActiveWork)
        XCTAssertNil(model.current?.pendingSubmission, "Preparing is not native delivery uncertainty")
        let message = try XCTUnwrap(model.current?.stagedSubmission?.message)
        XCTAssertEqual(visibleMessages(model.current!), [message])
        XCTAssertTrue(model.current!.messages.isEmpty, "Native history remains separate until submission")
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: storage))[0]
        XCTAssertEqual(saved.stagedSubmission?.draft, "Send now")
        XCTAssertEqual(saved.stagedSubmission?.attachments, [file])
        await model.send()
        XCTAssertEqual(transport.calls.filter { $0 == "session.create" }.count, 1)

        // Repeating the same text is still a new draft and must survive acceptance.
        model.draft = "Send now"
        let next = try stagedFile("next.txt")
        transport.pausedMethod = "prompt.submit"
        transport.finish(.success(["session_id": "live", "stored_session_id": "saved"]))
        try await waitForRequest()
        XCTAssertEqual(visibleMessages(model.current!), [message])
        XCTAssertEqual(model.current?.pendingSubmission?.id, message.id)
        transport.finish(.success([:]))
        await send.value
        XCTAssertEqual(visibleMessages(model.current!), [message])
        XCTAssertNil(model.current?.stagedSubmission)
        XCTAssertNil(model.current?.pendingSubmission)
        XCTAssertEqual(model.draft, "Send now")
        XCTAssertEqual(model.current?.attachments, [next])
    }

    func testFailureAtEachAwaitRestoresInputWithoutLosingNextDraft() async throws {
        for method in ["session.create", "file.attach", "prompt.submit"] {
            model.sessions = [CompanionSession()]
            model.currentID = model.sessions[0].id
            model.draft = "Original \(method)"
            let first = try stagedFile("first.txt")
            transport.pausedMethod = method
            let send = Task { await model.send() }
            try await waitForRequest()
            XCTAssertEqual(model.draft, "")
            model.draft = "Next draft"
            let next = try stagedFile("next.txt")
            transport.finish(.failure(HermesClientError.rpc(4000, "Rejected fixture")))
            await send.value
            XCTAssertEqual(model.draft, "Original \(method)\n\nNext draft")
            XCTAssertEqual(model.current?.attachments, [first, next])
            XCTAssertEqual(visibleMessages(model.current!), [])
            XCTAssertNil(model.current?.stagedSubmission)
            XCTAssertNil(model.current?.pendingSubmission)
        }
    }

    func testRestartDuringPreparationRestoresInputWithoutRetrying() async throws {
        model.draft = "Recover after interruption"
        let file = try stagedFile("first.txt")
        let send = Task { await model.send() }
        try await waitForRequest()
        let restoredTransport = SendFeedbackTransport()
        let restored = AppModel(storageURL: storage, playsSounds: false, client: restoredTransport, preferences: preferences)
        XCTAssertEqual(restored.draft, "Recover after interruption")
        XCTAssertEqual(restored.current?.attachments, [file])
        XCTAssertNil(restored.current?.stagedSubmission)
        XCTAssertNil(restored.current?.pendingSubmission)
        XCTAssertTrue(restoredTransport.calls.isEmpty)
        transport.finish(.failure(AppError("Setup interrupted")))
        await send.value
        restored.shutdown()
    }

    func testUncertainSendStaysProtectedAcrossRestartAndRestoresOnlyAfterProvenAbsent() async throws {
        transport.pausedMethod = "prompt.submit"
        model.draft = "Check delivery first"
        let file = try stagedFile("first.txt")
        let send = Task { await model.send() }
        try await waitForRequest()
        model.draft = "Next draft"
        transport.finish(.failure(HermesClientError.timedOut("prompt.submit")))
        await send.value
        XCTAssertEqual(model.draft, "Next draft")
        XCTAssertNotNil(model.current?.pendingSubmission)
        let restoredTransport = SendFeedbackTransport()
        let restored = AppModel(storageURL: storage, playsSounds: false, client: restoredTransport, preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.draft, "Next draft")
        XCTAssertNotNil(restored.current?.pendingSubmission)
        XCTAssertNotNil(restored.current?.stagedSubmission)
        await restored.connect()
        await restored.send()
        XCTAssertFalse(restoredTransport.calls.contains("prompt.submit"))
        XCTAssertEqual(restored.draft, "Check delivery first\n\nNext draft")
        XCTAssertEqual(restored.current?.attachments, [file])
        XCTAssertNil(restored.current?.pendingSubmission)
        XCTAssertNil(restored.current?.stagedSubmission)
        XCTAssertTrue(restored.current!.messages.isEmpty)
    }

    func testEarlyReceiptAndLostAcknowledgementDoNotRestoreAcceptedInput() async throws {
        transport.pausedMethod = "prompt.submit"
        model.draft = "Accepted"
        let send = Task { await model.send() }
        try await waitForRequest()
        model.receive("message.start", payload: ["session_id": "live"])
        model.draft = "Accepted"
        transport.finish(.failure(HermesClientError.timedOut("prompt.submit")))
        await send.value
        XCTAssertNil(model.current?.stagedSubmission)
        XCTAssertNil(model.current?.pendingSubmission)
        XCTAssertEqual(model.draft, "Accepted")
        XCTAssertEqual(visibleMessages(model.current!).map(\.text), ["Accepted"])
    }

    func testFailedSendRestoresItsOriginalSessionAfterSelectionChanges() async throws {
        let originalID = model.currentID
        model.draft = "Original session"
        let send = Task { await model.send() }
        try await waitForRequest()
        var other = CompanionSession()
        other.draft = "Other session"
        model.sessions.append(other)
        model.currentID = other.id
        transport.finish(.failure(AppError("Setup failed")))
        await send.value
        XCTAssertEqual(model.draft, "Other session")
        XCTAssertEqual(model.sessions.first { $0.id == originalID }?.draft, "Original session")
    }

    func testFailedPersistenceNeverContactsRuntimeOrDiscardsInput() async throws {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        model.draft = "Keep locally"
        await model.send()
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(model.draft, "Keep locally")
        XCTAssertNil(model.current?.stagedSubmission)
        XCTAssertFalse(model.submitting)
    }

    func testFailedIntentSaveRestoresInputAndRemovesUnsentHistoryRow() async throws {
        transport.pausedMethod = "file.attach"
        model.draft = "Keep after disk failure"
        let file = try stagedFile("first.txt")
        let send = Task { await model.send() }
        try await waitForRequest()
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        transport.finish(.success(["ref_text": "fixture file"]))
        await send.value
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        XCTAssertEqual(model.draft, "Keep after disk failure")
        XCTAssertEqual(model.current?.attachments, [file])
        XCTAssertTrue(model.current!.messages.isEmpty)
        XCTAssertNil(model.current?.stagedSubmission)
        XCTAssertNil(model.current?.pendingSubmission)
    }

    func testBusyNativeResumeRestoresDraftWithoutProjectingACompetingTurn() async throws {
        transport.pausedMethod = "session.resume"
        model.sessions[0].storedID = "saved"
        model.draft = "Wait for existing work"
        let send = Task { await model.send() }
        try await waitForRequest()
        transport.finish(.success(["session_id": "live", "running": true]))
        await send.value
        XCTAssertTrue(model.current!.isBusy)
        XCTAssertEqual(model.draft, "Wait for existing work")
        XCTAssertEqual(visibleMessages(model.current!), [])
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
    }

    func testNativeCompactAndFullEditorsClearWhileRuntimeSetupIsPaused() async throws {
        _ = NSApplication.shared
        func findEditor(_ view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        func settle(_ windows: [NSWindow]) {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
        func expectText(_ text: String, windows: [NSWindow]) async throws {
            func strings() -> [String?] { windows.map { findEditor($0.contentView!)?.string } }
            let deadline = Date(timeIntervalSinceNow: 2)
            while strings().contains(where: { $0 != text }), Date() < deadline {
                windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(strings(), Array(repeating: text, count: windows.count))
        }
        for reducedMotion in [false, true] {
            model.reducedMotion = reducedMotion
            model.draft = "First line\nSecond line\nThird line"
            let windows = [true, false].map { compact in
                let hosting = NSHostingView(rootView: SendComposerFixture(model: model, compact: compact))
                hosting.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: compact ? -10000 : -10600, y: -10000, width: 560, height: 160),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                window.orderFront(nil)
                hosting.layoutSubtreeIfNeeded()
                return window
            }
            defer { windows.forEach { $0.close() } }
            settle(windows)
            let editors = try windows.map { try XCTUnwrap(findEditor($0.contentView!)) }
            try await expectText(model.draft, windows: windows)
            editors[0].onSubmit?()
            try await waitForRequest()
            try await expectText("", windows: windows)
            XCTAssertNotNil(transport.pending, "The UI clears before native setup completes")
            let nextEditor = try XCTUnwrap(findEditor(windows[1].contentView!))
            nextEditor.string = "Next native draft"
            nextEditor.didChangeText()
            XCTAssertEqual(model.draft, "Next native draft")
            let preparingState = model.sessions[0].state
            model.sessions[0].state = .working
            settle(windows)
            nextEditor.onSubmit?()
            settle(windows)
            XCTAssertEqual(nextEditor.accessibilityHelp(), model.current?.busyInputHint, "Busy fields expose their shortcuts accessibly")
            XCTAssertEqual(model.draft, "Next native draft")
            XCTAssertFalse(transport.calls.contains("prompt.submit"), "A second send cannot overtake pending setup")
            model.sessions[0].state = preparingState
            transport.finish(.failure(AppError("Setup failed")))
            for _ in 0..<1000 where model.submitting { await Task.yield() }
            try await expectText("First line\nSecond line\nThird line\n\nNext native draft", windows: windows)
        }
    }
}
