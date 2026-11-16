import XCTest
@testable import NotchCompanion

/// Pin, Undo, Mark as unread and the extra snooze choices.
@MainActor final class SessionListTests: XCTestCase {
    private func makeModel(_ sessions: [CompanionSession], rateLimits: [String: [RuntimeRateLimit]] = [:]) -> AppModel {
        let suite = "notch-session-list-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(try? JSONEncoder().encode(rateLimits), forKey: "usage.rateLimits")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)/sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: ListTransport(), preferences: defaults)
        model.sessions = sessions + [CompanionSession(id: "selected", title: "Selected", workspacePath: "/tmp/app")]
        model.currentID = "selected"
        addTeardownBlock {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        return model
    }

    private func read(_ id: String, hoursAgo: Double = 0, folder: String = "/tmp/app") -> CompanionSession {
        CompanionSession(id: id, title: "Notes \(id)", state: .finished,
                         messages: [ChatMessage(role: "user", text: "Question"), ChatMessage(role: "assistant", text: "Answer")],
                         updatedAt: Date().addingTimeInterval(-hoursAgo * 3_600), workspacePath: folder,
                         completionID: "\(id)-result", acknowledgedCompletionID: "\(id)-result")
    }

    private func session(_ model: AppModel, _ id: String) -> CompanionSession { model.sessions.first { $0.id == id }! }
    private let hour: TimeInterval = 3_600

    func testPinnedSessionsGroupFirstInStableOrderAndNeverAutoArchive() throws {
        let model = makeModel([read("a", folder: "/tmp/site"), read("old", hoursAgo: 48), read("b", folder: "/tmp/site")])
        XCTAssertTrue(model.isAutoArchived(session(model, "old")))
        model.setPinned("b", true)
        XCTAssertFalse(model.canPinSession("old"), "Auto-archived sessions offer Restore instead")
        model.restoreSession("old")
        model.setPinned("old", true)
        model.update("old") { $0.lastSeenAt = Date().addingTimeInterval(-48 * self.hour) }
        XCTAssertFalse(model.isAutoArchived(session(model, "old")), "A pinned session never auto-archives")
        let groups = model.visibleProjects
        XCTAssertEqual(groups.map(\.pinned), [true, false, false])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["old", "b"], "The stable order, not the pin order")
        XCTAssertEqual(groups.dropFirst().map { $0.sessions.map(\.id) }, [["a"], ["selected"]])

        model.sessionSearch = "notes"
        XCTAssertFalse(model.visibleProjects.contains(where: \.pinned), "Search groups by project only")
        model.sessionSearch = ""

        // Persisted, and older saves decode unpinned.
        model.save()
        let saved = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: model.storageURL))
        XCTAssertEqual(saved.filter(\.isPinned).map(\.id), ["old", "b"])
        var older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(read("x"))) as! [String: Any]
        older.removeValue(forKey: "isPinned")
        XCTAssertFalse(try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: older)).isPinned)
    }

    func testArchivingUnpinsAndSnoozingHidesAPinnedSessionUntilItWakes() {
        let model = makeModel([read("p"), read("q")])
        model.setPinned("p", true)
        model.setPinned("q", true)
        model.snoozeSession("p", until: Date().addingTimeInterval(hour))
        XCTAssertFalse(model.visibleSessions.contains { $0.id == "p" })
        model.wakeDueSessions(now: Date().addingTimeInterval(hour + 1))
        XCTAssertTrue(session(model, "p").isPinned)
        XCTAssertEqual(model.visibleProjects.first?.sessions.map(\.id), ["p", "q"])
        model.archiveSession("q")
        XCTAssertFalse(session(model, "q").isPinned)
    }

    func testUndoRevertsArchiveSnoozeAndUnpinExactly() async throws {
        let model = makeModel([read("p"), read("s")])
        model.setPinned("p", true)
        model.update("p") { $0.snoozedUntil = nil }
        model.undoable(.archived, "p") { model.archiveSession("p") }
        XCTAssertEqual(model.sessionUndo?.message, "Archived Notes p")
        model.undoSessionChange()
        XCTAssertFalse(session(model, "p").isArchived)
        XCTAssertTrue(session(model, "p").isPinned, "Archiving unpinned it; Undo pins it again")
        XCTAssertNil(model.sessionUndo)

        model.undoable(.snoozed, "s") { model.snoozeSession("s", until: Date().addingTimeInterval(self.hour)) }
        model.undoable(.unpinned, "p") { model.setPinned("p", false) }
        XCTAssertEqual(model.sessionUndo?.kind, .unpinned, "A newer toast replaces the older one")
        model.undoSessionChange()
        XCTAssertTrue(session(model, "p").isPinned)
        XCTAssertNotNil(session(model, "s").snoozedUntil, "Only the shown change is undone")

        // Something else moved the session since: Undo leaves it alone.
        model.undoable(.snoozed, "p") { model.snoozeSession("p", until: Date().addingTimeInterval(self.hour)) }
        model.wakeSession("p")
        model.undoSessionChange()
        XCTAssertNil(session(model, "p").snoozedUntil)

        // Nothing changed, nothing to undo; and a toast leaves on its own.
        model.undoable(.archived, "selected") {}
        XCTAssertNil(model.sessionUndo)
        model.undoable(.unpinned, "p") { model.setPinned("p", false) }
        XCTAssertNotNil(model.sessionUndo)
        try await Task.sleep(for: SessionUndo.duration + .milliseconds(300))
        XCTAssertNil(model.sessionUndo)
    }

    func testMarkAsUnreadClearsTheReceiptUntilOpened() {
        let working = CompanionSession(id: "busy", runtimeID: "live", title: "Busy", state: .working,
                                       messages: [ChatMessage(role: "user", text: "Go")], parentTurnComplete: false)
        let model = makeModel([read("done", hoursAgo: 48), working, CompanionSession(id: "empty", title: "Draft")])
        XCTAssertTrue(model.isAutoArchived(session(model, "done")))
        XCTAssertFalse(model.canMarkUnread("busy"))
        XCTAssertFalse(model.canMarkUnread("empty"), "No result to mark")
        XCTAssertTrue(model.canMarkUnread("done"))
        model.markUnread("done")
        XCTAssertTrue(session(model, "done").hasUnreadCompletion)
        XCTAssertFalse(model.canMarkUnread("done"), "Already unread")
        XCTAssertFalse(model.isAutoArchived(session(model, "done")), "Unread sessions do not auto-archive")
        XCTAssertEqual(model.sessionIndicators.map(\.id), ["done", "busy"], "Its dot is back beside the working one")
        XCTAssertEqual(model.unreadResultCount, 1)
        // Not while snoozed: an unread failure would look new and wake it.
        model.update("busy") { $0.state = .failed; $0.parentTurnComplete = true; $0.runtimeID = nil; $0.completionID = "f"; $0.acknowledgeResult() }
        model.snoozeSession("busy", until: Date().addingTimeInterval(hour))
        XCTAssertFalse(model.canMarkUnread("busy"))
        model.markUnread("busy")
        XCTAssertNotNil(session(model, "busy").snoozedUntil)
        model.setSessionVisibility(notchVisible: true)
        model.selectSession("done")
        XCTAssertFalse(session(model, "done").hasUnreadCompletion, "Opening it reads it again")
    }

    func testUntilLimitResetsNeedsAReachedWindowWithAKnownFutureReset() {
        let now = Date()
        let soon = now.addingTimeInterval(2 * hour), later = now.addingTimeInterval(30 * hour)
        let model = makeModel([read("c"), read("x")], rateLimits: [
            RuntimeKind.claude.rawValue: [RuntimeRateLimit(name: "5-hour", resetsAt: soon, reached: true),
                                          RuntimeRateLimit(name: "Weekly", usedPercent: 40, resetsAt: later)],
            RuntimeKind.codex.rawValue: [RuntimeRateLimit(name: "5-hour", reached: true)],
        ])
        model.update("c") { $0.runtime = .claude }
        model.update("x") { $0.runtime = .codex }
        XCTAssertEqual(model.limitResetDate(for: "c", now: now), soon)
        XCTAssertNil(model.limitResetDate(for: "x", now: now), "An unknown reset time is not offered")
        XCTAssertNil(model.limitResetDate(for: "c", now: soon.addingTimeInterval(1)), "A past reset is out of date")
    }

    func testCustomSnoozeStartsAtARoundFutureHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14, minute: 20))!
        XCTAssertEqual(SessionBrowserView.defaultCustomDate(now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 16)))
    }
}

@MainActor private final class ListTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { ["status": "streaming"] }
}
