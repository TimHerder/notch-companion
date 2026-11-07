import XCTest
@testable import NotchCompanion

@MainActor final class SnoozeTests: XCTestCase {
    /// A private defaults suite and file; status effects on so announcements are observable.
    private func makeModel(_ sessions: [CompanionSession]) -> AppModel {
        let suite = "notch-snooze-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)/sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: SnoozeTransport(), preferences: defaults)
        let effects = model.statusEffects
        model.statusEffects = true
        model.sessions = sessions + [CompanionSession(id: "selected", title: "Selected")]
        model.currentID = "selected"
        addTeardownBlock {
            model.statusEffects = effects
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        return model
    }

    private func read(_ id: String, hoursAgo: Double = 0) -> CompanionSession {
        CompanionSession(id: id, title: "Notes \(id)", state: .finished,
                         messages: [ChatMessage(role: "user", text: "Question"), ChatMessage(role: "assistant", text: "Answer")],
                         updatedAt: Date().addingTimeInterval(-hoursAgo * 3_600),
                         completionID: "\(id)-result", acknowledgedCompletionID: "\(id)-result")
    }

    private func working(_ id: String) -> CompanionSession {
        CompanionSession(id: id, runtimeID: "live-\(id)", title: "Work \(id)", state: .working,
                         messages: [ChatMessage(role: "user", text: "Go")], parentTurnComplete: false)
    }

    private func session(_ model: AppModel, _ id: String) -> CompanionSession { model.sessions.first { $0.id == id }! }
    private let hour: TimeInterval = 3_600

    func testSnoozedSessionLeavesTheListAndWakesOnTimeAsUnread() {
        let model = makeModel([read("later")])
        model.snoozeSession("later", until: Date().addingTimeInterval(hour))
        XCTAssertEqual(model.visibleSessions.map(\.id), ["selected"])
        XCTAssertEqual(model.snoozedCount, 1)
        XCTAssertEqual(model.archivedCount, 0)
        XCTAssertNotNil(model.snoozeTimer, "A timer waits for the wake while running")
        model.sessionFilter = .snoozed
        XCTAssertEqual(model.visibleSessions.map(\.id), ["later"])
        model.sessionFilter = .all
        model.sessionSearch = "notes later"
        XCTAssertEqual(model.visibleSessions.map(\.id), ["later"], "Search still finds it")
        model.sessionSearch = ""

        model.wakeDueSessions(now: Date().addingTimeInterval(hour / 2))
        XCTAssertNotNil(session(model, "later").snoozedUntil, "Not yet due")
        model.wakeDueSessions(now: Date().addingTimeInterval(hour + 1))
        XCTAssertNil(session(model, "later").snoozedUntil)
        XCTAssertTrue(session(model, "later").hasUnreadCompletion, "It comes back unread")
        XCTAssertEqual(model.visibleSessions.map(\.id), ["later", "selected"])
        XCTAssertEqual(model.sessionIndicators.map(\.id), ["later"])
        XCTAssertNil(model.snoozeTimer, "Nothing left to wait for")
    }

    func testLaunchWakesWhatIsAlreadyDueAndOlderSavesDecodeWithoutSnooze() throws {
        var due = read("due")
        due.snoozedUntil = Date().addingTimeInterval(-60)
        var later = read("later")
        later.snoozedUntil = Date(timeIntervalSince1970: 4_000_000_000)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-snooze-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sessions.json")
        try JSONEncoder().encode([later, due]).write(to: file)
        let suite = "notch-snooze-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(storageURL: file, playsSounds: false, client: SnoozeTransport(), preferences: defaults)
        defer { model.shutdown() }
        XCTAssertNil(session(model, "due").snoozedUntil)
        XCTAssertTrue(session(model, "due").hasUnreadCompletion)
        XCTAssertEqual(session(model, "later").snoozedUntil, later.snoozedUntil, "Round-trips")
        XCTAssertEqual(model.currentID, "due", "Launch selects an active session, not a snoozed one")
        XCTAssertNotNil(model.snoozeTimer)

        let older = try JSONDecoder().decode(CompanionSession.self, from: Data(#"{"id":"older","title":"Older"}"#.utf8))
        XCTAssertNil(older.snoozedUntil)
        XCTAssertEqual(older.title, "Older")
    }

    func testQuestionsApprovalsAndFailuresWakeEarly() {
        let events: [(String, [String: Any])] = [
            ("approval.request", ["request_id": "r", "command": "ls"]),
            ("clarify.request", ["request_id": "q", "question": "Which folder?"]),
            ("message.complete", ["status": "error", "text": "Boom"])
        ]
        for (name, payload) in events {
            let model = makeModel([working("work")])
            model.snoozeSession("work", until: Date().addingTimeInterval(hour))
            XCTAssertNotNil(session(model, "work").snoozedUntil, "A working session can be snoozed")
            model.receive(name, payload: payload.merging(["session_id": "live-work"]) { old, _ in old })
            XCTAssertNil(session(model, "work").snoozedUntil, name)
            XCTAssertTrue(model.visibleSessions.contains { $0.id == "work" }, name)
            XCTAssertEqual(model.announcement?.sessionID, "work", "\(name) announces as usual")
        }
    }

    func testCompletionStaysQuietAndOutOfIndicatorsWhileWorkStillCounts() {
        let model = makeModel([working("work")])
        model.snoozeSession("work", until: Date().addingTimeInterval(hour))
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.running], "Busy tracking is unaffected")
        XCTAssertTrue(model.hasActiveWork, "Quit protection still counts it")
        XCTAssertEqual(model.glanceEntries.map(\.id), ["work"])

        model.receive("message.complete", payload: ["session_id": "live-work", "text": "Done"])
        let done = session(model, "work")
        XCTAssertEqual(done.state, .finished)
        XCTAssertNotNil(done.snoozedUntil, "A completion does not wake it")
        XCTAssertNil(model.announcement, "Nor does it announce")
        XCTAssertTrue(done.hasUnreadCompletion, "Its receipt waits for the wake")
        XCTAssertTrue(model.sessionIndicators.isEmpty)
        XCTAssertEqual(model.unreadResultCount, 0)
        XCTAssertEqual(model.glanceSummary.unread, 0)
        XCTAssertEqual(model.collapsedStatus, .none)
        XCTAssertFalse(model.glanceEntries.contains { $0.id == "work" })
    }

    func testSnoozedSessionsNeverAutoArchiveAndNeedAReadAfterWaking() {
        let model = makeModel([read("old", hoursAgo: 48)])
        XCTAssertFalse(model.canSnoozeSession("old"), "Auto-archived sessions offer Restore instead")
        model.sessions[0].snoozedUntil = Date().addingTimeInterval(hour)
        XCTAssertFalse(model.isAutoArchived(session(model, "old")))
        XCTAssertEqual(model.archivedCount, 0)
        model.wakeSession("old")
        let later = Date().addingTimeInterval(3 * 86_400)
        XCTAssertFalse(model.isAutoArchived(session(model, "old"), now: later), "Unread until read")
        model.markAllAsRead()
        XCTAssertTrue(model.isAutoArchived(session(model, "old"), now: later))
    }

    func testArchivingClearsSnoozeAndArchivedOrWaitingSessionsCannotSnooze() {
        var asks = read("asks")
        asks.state = .waiting
        let model = makeModel([read("done"), asks])
        XCTAssertFalse(model.canSnoozeSession("asks"), "A question needs an answer first")
        model.snoozeSession("asks", until: Date().addingTimeInterval(hour))
        XCTAssertNil(session(model, "asks").snoozedUntil)
        model.snoozeSession("done", until: Date().addingTimeInterval(hour))
        model.archiveSession("done")
        XCTAssertTrue(session(model, "done").isArchived)
        XCTAssertNil(session(model, "done").snoozedUntil)
        XCTAssertFalse(model.canSnoozeSession("done"))
    }

    func testSendingFromTheComposerWakesIt() async {
        let model = makeModel([read("later")])
        await model.connect()
        model.snoozeSession("later", until: Date().addingTimeInterval(hour))
        model.selectSession("later")
        model.draft = "One more thing"
        await model.send()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(session(model, "later").state, .working, "Sent, not woken by a failure")
        XCTAssertNil(session(model, "later").snoozedUntil)
        XCTAssertTrue(model.visibleSessions.contains { $0.id == "later" })
    }

    func testChoicesFollowTheLocalCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let saturday = date(7, 22, 30)
        XCTAssertEqual(SnoozeChoice.hour.until(from: saturday, calendar: calendar), date(7, 23, 30))
        XCTAssertEqual(SnoozeChoice.threeHours.until(from: saturday, calendar: calendar), date(8, 1, 30))
        XCTAssertEqual(SnoozeChoice.tomorrow.until(from: saturday, calendar: calendar), date(8, 9))
        XCTAssertEqual(SnoozeChoice.nextWeek.until(from: saturday, calendar: calendar), date(9, 9), "The coming Monday")
        let monday = date(9, 8)
        XCTAssertEqual(SnoozeChoice.tomorrow.until(from: monday, calendar: calendar), date(10, 9))
        XCTAssertEqual(SnoozeChoice.nextWeek.until(from: monday, calendar: calendar), date(16, 9), "Never later the same day")
        let sunday = date(8, 23)
        XCTAssertEqual(SnoozeChoice.nextWeek.until(from: sunday, calendar: calendar), date(9, 9))
    }

    func testWakeLabelUsesTheCompactAgeStyle() {
        XCTAssertEqual(SessionDigest.wakeLabel(10), "now")
        XCTAssertEqual(SessionDigest.wakeLabel(45 * 60), "45m")
        XCTAssertEqual(SessionDigest.wakeLabel(3 * hour - 5), "3h", "A fresh 3-hour snooze reads 3h")
        XCTAssertEqual(SessionDigest.wakeLabel(89 * 60), "1h")
        XCTAssertEqual(SessionDigest.wakeLabel(23 * hour + 50 * 60), "1d")
        XCTAssertEqual(SessionDigest.wakeLabel(2 * 86_400 - hour), "2d")
    }
}

@MainActor private final class SnoozeTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        method == "session.create" ? ["session_id": "live-later", "stored_session_id": "stored"] : ["status": "streaming"]
    }
}
