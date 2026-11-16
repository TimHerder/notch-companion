import XCTest
@testable import NotchCompanion

private final class NoticeTestTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}

@MainActor final class SystemNotificationsTests: XCTestCase {
    func testAnnouncedMomentsPostNoticesUnlessSnoozedOnScreenOrAChildsOwn() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-notice-\(UUID().uuidString)/sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: NoticeTestTransport())
        let original = model.statusEffects
        defer { model.statusEffects = original; model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var posted: [SystemNotice] = [], removed: [String] = []
        model.postSystemNotice = { posted.append($0) }
        model.removeSystemNotices = { removed += $0 }
        model.statusEffects = false
        model.sessions[0].runtimeID = "parent"
        model.sessions[0].title = "Release notes"
        model.sessions[0].runtime = .codex
        let parentID = model.sessions[0].id
        var child = CompanionSession(); child.runtimeID = "child"; child.runtime = .claude; child.title = "Review"; child.parentSessionID = parentID
        model.sessions.append(child)

        model.receive("message.complete", payload: ["session_id": "parent", "text": "Shipped the **glance**."])
        XCTAssertEqual(posted, [SystemNotice(sessionID: parentID, title: "Release notes", subtitle: "Codex · Done", body: "Shipped the glance.")],
                       "Notices follow their own setting, not Status effects")
        model.receive("approval.request", payload: ["session_id": "parent", "request_id": "r", "command": "rm -rf build"])
        XCTAssertEqual(posted.last?.subtitle, "Codex · Needs you")
        XCTAssertEqual(posted.last?.body, "rm -rf build")

        posted = []
        model.receive("message.complete", payload: ["session_id": "child", "text": "Looks fine"])
        XCTAssertEqual(posted, [], "A child's own result reaches its parent, not Notification Center")
        model.receive("clarify.request", payload: ["session_id": "child", "request_id": "q", "question": "Which branch?"])
        XCTAssertEqual(posted, [SystemNotice(sessionID: child.id, title: "Release notes", subtitle: "Claude Code · Needs you", body: "Which branch?")],
                       "A child's question surfaces under its parent's title and opens the child")

        posted = []
        model.sessions[0].snoozedUntil = Date().addingTimeInterval(3_600)
        XCTAssertNil(model.systemNotice(.finished, sessionID: parentID, detail: "x"), "A snoozed session never notifies")
        XCTAssertNil(model.systemNotice(.needsInput, sessionID: child.id, detail: "x"), "Nor does its child")
        model.sessions[0].snoozedUntil = nil

        model.expanded = true
        model.page = .session
        model.setSessionVisibility(notchVisible: true)
        XCTAssertTrue(model.isConversationOnScreen(parentID))
        XCTAssertTrue(removed.contains(parentID), "Reading a session removes its notification")
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Boom"])
        XCTAssertEqual(posted, [], "No notice while its conversation is on screen")
        model.setSessionVisibility(notchVisible: false)

        removed = []
        model.sessions[0].state = .failed
        model.sessions[0].completionID = "later"
        model.markAllAsRead()
        XCTAssertEqual(removed, [parentID], "Mark all as read removes what it acknowledged")
    }

    func testControllerIsInertOutsideAnAppBundle() {
        // The test runner has no app bundle: posting and removing must not reach UserNotifications.
        let notifications = SystemNotifications.shared
        notifications.post(SystemNotice(sessionID: "s", title: "t", subtitle: "", body: ""))
        notifications.remove(["s"])
        XCTAssertTrue(SystemNotifications.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
    }
}
