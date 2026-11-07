import XCTest
import AppKit
import SwiftUI
@testable import NotchCompanion

@MainActor private final class ComposerFlowTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var pausedMethod = "none"
    var failing: [String: Error] = [:]
    var pending: CheckedContinuation<[String: Any], Error>?
    var calls: [(String, [String: Any])] = []

    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { finish(.failure(AppError("Disconnected fixture"))) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if let error = failing[method] { throw error }
        if method == pausedMethod { return try await withCheckedThrowingContinuation { pending = $0 } }
        switch method {
        case "session.create", "session.resume": return ["session_id": "live", "stored_session_id": "saved", "messages": []]
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

@MainActor final class ComposerFlowTests: XCTestCase {
    private var folder: URL!
    private var transport: ComposerFlowTransport!
    private var model: AppModel!
    private var preferences: UserDefaults!
    private var suite: String!
    private var storage: URL { folder.appendingPathComponent("sessions.json") }
    private var saved: CompanionSession { get throws { try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: storage))[0] } }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("composer-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transport = ComposerFlowTransport()
        suite = "composer-flow-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        model = AppModel(storageURL: storage, playsSounds: false, client: transport, preferences: preferences)
        await model.connect()
    }
    override func tearDown() async throws {
        model.shutdown()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func working(_ runtime: RuntimeKind = .codex) {
        model.sessions[0].runtime = runtime
        model.sessions[0].runtimeID = "live"
        model.sessions[0].storedID = "saved"
        model.sessions[0].state = .working
        model.sessions[0].parentTurnComplete = false
        model.sessions[0].workspacePath = folder.path
        model.sessions[0].messages = [ChatMessage(id: "original", role: "user", text: "Original", turnID: "original")]
    }
    private func file(_ name: String) throws -> Attachment {
        let url = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return Attachment(url: url)
    }
    private func queue(_ text: String, files: [Attachment] = []) async {
        model.draft = text
        model.sessions[0].attachments = files
        await model.send(queue: true)
    }
    private func waitForRequest() async throws {
        for _ in 0..<500 where transport.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(transport.pending)
    }
    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    // MARK: Queued messages

    func testEditMovesAQueuedMessageIntoAnEmptyComposerOnly() async throws {
        working()
        let attached = try file("notes.txt")
        await queue("First", files: [attached])
        await queue("Second")
        let ids = model.current!.queuedSends.map(\.id)
        model.draft = "Still typing"
        XCTAssertFalse(model.editQueuedSend(ids[1]), "A draft in the composer blocks Edit")
        XCTAssertEqual(model.current?.queuedSends.map(\.text), ["First", "Second"])
        XCTAssertEqual(model.draft, "Still typing")

        model.draft = ""
        XCTAssertTrue(model.editQueuedSend(ids[0]))
        XCTAssertEqual(model.draft, "First")
        XCTAssertEqual(model.current?.attachments, [attached])
        XCTAssertEqual(model.current?.queuedSends.map(\.text), ["Second"])
        XCTAssertEqual(try saved.draft, "First", "Saved before the queue drops it")
        XCTAssertEqual(try saved.queuedSends.map(\.text), ["Second"])
        XCTAssertFalse(model.editQueuedSend(ids[1]), "Files in the composer block Edit too")
        XCTAssertFalse(transport.calls.contains { ["prompt.submit", "prompt.steer"].contains($0.0) })
    }

    func testEditPutsTheCaretAfterTheRestoredMessage() async throws {
        _ = NSApplication.shared
        working()
        await queue("Then run the full test suite")
        let hosting = NSHostingView(rootView: SendComposerFixture(model: model, compact: true))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func findEditor(_ view: NSView) -> ComposerTextView? { view as? ComposerTextView ?? view.subviews.lazy.compactMap(findEditor).first }
        hosting.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(findEditor(hosting))
        XCTAssertTrue(model.editQueuedSend(try XCTUnwrap(model.current?.queuedSends.first?.id)))
        for _ in 0..<100 where editor.string != model.draft {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(editor.string, "Then run the full test suite")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (editor.string as NSString).length, length: 0), "Typing goes on after the message")
    }

    func testOptionUpAndCommandShiftReturnReachTheQueueOnlyFromAnEmptyComposer() throws {
        let editor = ComposerTextView()
        var edits = 0, steers = 0, queues = 0, handles = true
        editor.onEditQueued = { edits += 1; return handles }
        editor.onSteerQueued = { steers += 1; return handles }
        editor.onQueue = { queues += 1 }
        let optionUp = try key(126, [.option, .numericPad, .function], "\u{F700}")
        let steerKey = try key(36, [.command, .shift], "\r")
        editor.keyDown(with: optionUp)
        editor.keyDown(with: steerKey)
        XCTAssertEqual([edits, steers, queues], [1, 1, 0])
        handles = false
        editor.keyDown(with: steerKey)
        XCTAssertEqual([steers, queues], [2, 1], "Nothing to steer falls back to Command-Return")
        editor.string = "Typed"
        editor.keyDown(with: optionUp)
        editor.keyDown(with: steerKey)
        XCTAssertEqual([edits, steers, queues], [1, 2, 2], "Typed text keeps the usual key meanings")
    }

    func testSteerNowDeliversTheQueuedMessageIntoTheRunningTurnAndKeepsTheDraft() async throws {
        working()
        let attached = try file("notes.txt")
        await queue("Later", files: [attached])
        let queued = try XCTUnwrap(model.current?.queuedSends.first)
        model.draft = "Still typing"
        transport.pausedMethod = "prompt.steer"
        let steer = Task { await model.steerQueuedSend(queued.id) }
        try await waitForRequest()
        XCTAssertTrue(model.current!.queuedSends.isEmpty)
        XCTAssertEqual(model.draft, "Still typing")
        XCTAssertEqual(model.current?.pendingSubmission?.isSteering, true)
        XCTAssertEqual(model.current?.pendingSubmission?.id, queued.id)
        XCTAssertEqual(model.current?.messages.last?.turnID, "original", "A steer belongs to the running turn")
        XCTAssertEqual(try saved.stagedSubmission?.draft, "Later", "Saved before delivery")
        XCTAssertEqual(transport.calls.last?.1["text"] as? String, "Later\n\nfixture file")
        transport.finish(.success([:]))
        await steer.value
        XCTAssertNil(model.current?.pendingSubmission)
        XCTAssertNil(model.current?.stagedSubmission)
        XCTAssertEqual(model.draft, "Still typing")
        XCTAssertEqual(model.current?.attachments, [])
        XCTAssertFalse(transport.calls.contains { $0.0 == "prompt.submit" })
    }

    func testARefusedSteerNowReturnsTheMessageToItsPlaceAndALostReceiptStaysProtected() async throws {
        for uncertain in [false, true] {
            working()
            model.sessions[0].queuedSends = []
            await queue("First")
            await queue("Second")
            let second = model.current!.queuedSends[1]
            model.draft = "Typing"
            transport.pausedMethod = "prompt.steer"
            let steer = Task { await model.steerQueuedSend(second.id) }
            try await waitForRequest()
            transport.finish(.failure(uncertain ? AppError("lost acknowledgement") : BusyInputRejection(message: "turn ended")))
            await steer.value
            XCTAssertEqual(model.draft, "Typing", "The composer is never overwritten")
            if uncertain {
                XCTAssertEqual(model.current?.pendingSubmission?.id, second.id)
                XCTAssertEqual(model.current?.queuedSends.map(\.text), ["First"], "No duplicate copy goes back to the queue")
                model.sessions[0].pendingSubmission = nil
            } else {
                XCTAssertEqual(model.current?.queuedSends, [model.current!.queuedSends[0], second])
                XCTAssertEqual(model.current?.queuedSends.map(\.text), ["First", "Second"])
                XCTAssertNil(model.current?.stagedSubmission)
                XCTAssertFalse(model.current!.messages.contains { $0.id == second.id })
            }
        }
        working(.deepseek)
        model.sessions[0].queuedSends = []
        await queue("Queue only")
        let before = transport.calls.count
        await model.steerQueuedSend(model.current!.queuedSends[0].id)
        XCTAssertEqual(model.current?.queuedSends.map(\.text), ["Queue only"])
        XCTAssertEqual(transport.calls.count, before, "Steering is never substituted on a queue-only harness")
    }

    func testTheBusySendKeyNamesWhatReturnDoes() throws {
        working(.codex)
        XCTAssertEqual(model.current?.busySendLabel, "Steer message")
        model.sessions[0].parentTurnComplete = true
        XCTAssertEqual(model.current?.busySendLabel, "Queue message", "A parent waiting only on children queues")
        working(.deepseek)
        XCTAssertEqual(model.current?.busySendLabel, "Queue message")
        working(.hermes)
        model.sessions[0].attachments = [try file("photo.png")]
        XCTAssertEqual(model.current?.busySendLabel, "Queue message", "Hermes queues images")
        XCTAssertTrue(model.current!.canSteer([]), "A queued message without images can still steer")
    }

    // MARK: Plan ready

    private func planTurn(_ session: inout CompanionSession, id: String = "turn") {
        session.permissionMode = .plan
        session.messages.append(ChatMessage(id: id, role: "user", text: "Plan it", turnID: id))
        session.messages.append(ChatMessage(role: "assistant", text: "1. Do it", turnID: id))
        session.state = .finished
        session.completionID = "result-\(id)"
        session.turnOutcome[id] = .finished
    }

    func testPlanReadyFollowsOnlyAFinishedUnansweredPlanTurn() {
        var session = CompanionSession()
        session.runtime = .claude
        planTurn(&session)
        XCTAssertEqual(session.planReadyTurnID, "turn")
        XCTAssertTrue(SessionBrowserView.showsPlanReady(session), "An unread plan replaces the row's runtime label")
        var read = session
        read.acknowledgeResult()
        XCTAssertNotNil(read.planReadyTurnID)
        XCTAssertFalse(SessionBrowserView.showsPlanReady(read))
        var hidden: [String: CompanionSession] = [:]
        hidden["busy"] = session; hidden["busy"]!.state = .working
        hidden["failed"] = session; hidden["failed"]!.state = .failed; hidden["failed"]!.turnOutcome["turn"] = .failed
        hidden["stopped"] = session; hidden["stopped"]!.state = .interrupted; hidden["stopped"]!.turnOutcome["turn"] = .interrupted
        hidden["not plan"] = session; hidden["not plan"]!.permissionMode = .autoEdit
        hidden["unconfirmed"] = session
        hidden["unconfirmed"]!.pendingSubmission = PendingSubmission(id: "next", draft: "Go", userTurnCount: 1, attachmentIDs: [])
        hidden["answered"] = session
        hidden["answered"]!.tools = [ToolActivity(id: "exit", name: "ExitPlanMode", detail: "", state: .finished, turnID: "turn")]
        hidden["dismissed"] = session; hidden["dismissed"]!.planReadyDismissedTurnID = "turn"
        for (reason, session) in hidden { XCTAssertNil(session.planReadyTurnID, reason) }
        var next = hidden["dismissed"]!
        planTurn(&next, id: "turn-2")
        XCTAssertEqual(next.planReadyTurnID, "turn-2", "Keep planning hides one turn's banner only")
    }

    func testPlanReadyIsNamedByTheAnswersFirstHeading() {
        var session = CompanionSession()
        session.runtime = .claude
        planTurn(&session)
        XCTAssertNil(session.planReadyTitle, "An answer without a heading reads Plan ready")
        func named(_ answer: String, in base: CompanionSession? = nil) -> String? {
            var copy = base ?? session
            copy.messages[copy.messages.count - 1].text = answer
            return copy.planReadyTitle
        }
        XCTAssertEqual(named("Intro\n\n## Ready for **review**\n\nSteps\n\n# Later"), "Ready for review", "The first heading, as plain text")
        XCTAssertEqual(named("# Plan: Add `welcome()`"), "Add welcome()")
        XCTAssertEqual(named("Plan — migrate\n==="), "migrate", "Setext headings count")
        XCTAssertNil(named("## Plan"), "A heading that only says Plan adds nothing")
        XCTAssertEqual(named("# Planning notes"), "Planning notes")
        XCTAssertNil(named("```\n# not a heading\n```\nPlain"), "Code is not a heading")
        var dismissed = session
        dismissed.planReadyDismissedTurnID = "turn"
        XCTAssertNil(named("# Ship it", in: dismissed), "No ready plan, no name")
        var next = session
        next.messages[next.messages.count - 1].text = "# Earlier plan"
        planTurn(&next, id: "turn-2")
        XCTAssertNil(next.planReadyTitle, "An earlier turn's heading never names the latest plan")
        next.messages.append(ChatMessage(role: "assistant", text: "# Final plan", turnID: "turn-2"))
        XCTAssertEqual(next.planReadyTitle, "Final plan", "The turn's last answer names it")
    }

    func testImplementRestoresThePrePlanModeAndSendsThroughTheNormalPath() async throws {
        await model.newSession(showPanel: false, runtime: .codex)
        let id = try XCTUnwrap(model.currentID)
        model.setPermissionMode(.autoEdit, for: id)
        model.setPermissionMode(.plan, for: id)
        XCTAssertEqual(model.current?.prePlanPermissionMode, .autoEdit)
        model.setPermissionMode(.plan, for: id)
        XCTAssertEqual(try saved.prePlanPermissionMode, .autoEdit, "Choosing Plan again keeps the mode from before Plan")
        model.draft = "Plan the release"
        await model.send()
        model.receive("message.complete", payload: ["session_id": "live", "text": "1. Tag it"])
        XCTAssertNotNil(model.current?.planReadyTurnID)

        // Nothing starts: the session stays in Plan and the banner can be tried again.
        model.connection = false
        model.draft = "Unrelated draft"
        await model.implementPlan(id)
        XCTAssertEqual(model.current?.permissionMode, .plan)
        XCTAssertNotNil(model.current?.planReadyTurnID)
        XCTAssertEqual(model.draft, "Unrelated draft")
        XCTAssertFalse(transport.calls.contains { $0.1["text"] as? String == AppModel.implementPlanMessage })

        model.connection = true
        model.errorMessage = nil
        await model.implementPlan(id)
        XCTAssertEqual(model.current?.permissionMode, .autoEdit)
        XCTAssertEqual(transport.calls.last(where: { $0.0 == "session.permission.set" })?.1["mode"] as? String, "autoEdit")
        XCTAssertEqual(transport.calls.last(where: { $0.0 == "prompt.submit" })?.1["text"] as? String, AppModel.implementPlanMessage)
        XCTAssertEqual(model.current?.messages.filter { $0.text == AppModel.implementPlanMessage }.count, 1)
        XCTAssertEqual(model.draft, "Unrelated draft", "The composer's draft is left alone")
        XCTAssertNil(model.current?.planReadyTurnID)
        let sends = transport.calls.filter { $0.0 == "prompt.submit" }.count
        await model.implementPlan(id)
        XCTAssertEqual(transport.calls.filter { $0.0 == "prompt.submit" }.count, sends, "A working session never sends twice")

        model.receive("message.complete", payload: ["session_id": "live", "text": "Implemented"])
        model.setPermissionMode(.plan, for: id)
        XCTAssertNil(model.current?.planReadyTurnID, "A turn from before Plan was chosen made no plan")
        model.draft = "Plan the follow-up"
        await model.send()
        model.receive("message.complete", payload: ["session_id": "live", "text": "1. Follow up"])
        XCTAssertNotNil(model.current?.planReadyTurnID)
        transport.failing["prompt.submit"] = BusyInputRejection(message: "Rejected")
        await model.implementPlan(id)
        XCTAssertEqual(model.current?.permissionMode, .autoEdit, "A rejected send shows its failure and keeps the chosen mode")
        XCTAssertEqual(model.errorMessage, "Rejected")
        XCTAssertEqual(model.draft, "", "Implement never puts its text into the composer")
    }

    func testKeepPlanningPersistsAndOlderSavesDecodeWithoutPlanFields() throws {
        planTurn(&model.sessions[0])
        model.sessions[0].runtime = .codex
        let id = model.sessions[0].id
        model.keepPlanning(id)
        XCTAssertNil(model.current?.planReadyTurnID)
        XCTAssertEqual(try saved.planReadyDismissedTurnID, "turn")

        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as? [[String: Any]]).first!
        row["prePlanPermissionMode"] = "futureMode"
        XCTAssertNil(try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: row)).prePlanPermissionMode)
        row.removeValue(forKey: "prePlanPermissionMode")
        row.removeValue(forKey: "planReadyDismissedTurnID")
        let older = try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(older.prePlanPermissionMode)
        XCTAssertEqual(older.planReadyTurnID, "turn", "An older save shows its plan again")
    }
}
