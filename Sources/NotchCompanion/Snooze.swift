import Foundation

/// When a snoozed session comes back, on the user's calendar.
enum SnoozeChoice: String, CaseIterable, Identifiable {
    case hour, threeHours, tomorrow, nextWeek
    var id: Self { self }
    var title: String {
        switch self {
        case .hour: return "1 hour"
        case .threeHours: return "3 hours"
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    /// Tomorrow and next week mean 9:00, next week on Monday.
    func until(from now: Date = Date(), calendar: Calendar = .app) -> Date {
        switch self {
        case .hour: return now.addingTimeInterval(3_600)
        case .threeHours: return now.addingTimeInterval(3 * 3_600)
        case .tomorrow, .nextWeek:
            let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            let morning = DateComponents(hour: 9, minute: 0, weekday: self == .nextWeek ? 2 : nil)
            return calendar.nextDate(after: tomorrow.addingTimeInterval(-1), matching: morning, matchingPolicy: .nextTime)
                ?? tomorrow.addingTimeInterval(9 * 3_600)
        }
    }

    /// "Snooze until 4:12 PM" today, "Snooze until Mon, Nov 9, 9:00 AM" otherwise.
    func help(now: Date = Date(), calendar: Calendar = .app) -> String {
        "Snooze until " + SnoozeChoice.time(until(from: now, calendar: calendar), now: now, calendar: calendar)
    }

    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .app) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(calendar.isDate(date, inSameDayAs: now) ? style.hour().minute()
                              : style.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

extension SessionDigest {
    /// Time until a snoozed session wakes, in the list's age style ("45m", "3h", "2d"),
    /// rounded to the nearest unit so a fresh 3-hour snooze reads 3h.
    static func wakeLabel(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded())
        if minutes < 60 { return minutes < 1 ? "now" : "\(minutes)m" }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours < 24 ? "\(hours)h" : "\(Int((Double(hours) / 24).rounded()))d"
    }
}

extension AppModel {
    /// What the island counts: a snoozed session's work still shows, its unread result does not.
    var noticedSessions: [CompanionSession] {
        topLevelSessions.map { session in
            var quiet = session
            if quiet.snoozedUntil != nil { quiet.acknowledgeResult() }
            return quiet
        }
    }

    var snoozedCount: Int { topLevelSessions.filter { $0.snoozedUntil != nil }.count }

    /// Archived sessions offer Restore instead, and a session that needs an answer cannot be put off.
    func canSnoozeSession(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return session.parentSessionID == nil && !session.isArchived && !isAutoArchived(session)
            && CollapsedStatus.resolve(session: session) != .waiting
    }

    func snoozeSession(_ id: String, until: Date) {
        guard canSnoozeSession(id) else { return }
        update(id) { $0.snoozedUntil = until }
        save()
        wakeDueSessions()
    }

    /// Back in the active list, unread: a result needs a read again before it can auto-archive.
    /// Without a result to mark, its auto-archive clock restarts instead.
    func wakeSession(_ id: String) {
        guard sessions.contains(where: { $0.id == id && $0.snoozedUntil != nil }) else { return }
        update(id) { $0.snoozedUntil = nil; $0.acknowledgedCompletionID = nil; $0.lastSeenAt = Date() }
        scheduleSave()
    }

    /// Wakes every session whose time has come (at launch too), then sleeps until the next.
    func wakeDueSessions(now: Date = Date()) {
        for session in sessions where session.snoozedUntil.map({ $0 <= now }) == true { wakeSession(session.id) }
        snoozeTimer?.cancel()
        guard let next = sessions.compactMap(\.snoozedUntil).min() else { snoozeTimer = nil; return }
        snoozeTimer = Task { [weak self] in
            // A continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.wakeDueSessions()
        }
    }

    /// A new question, approval or failure wakes a snoozed session at once; a completion does not.
    func wakeSessionsThatNeedYou(since old: [CompanionSession]) {
        for session in sessions where session.snoozedUntil != nil {
            let status = CollapsedStatus.resolve(session: session)
            guard status == .waiting || status == .failed, let before = old.first(where: { $0.id == session.id }),
                  CollapsedStatus.resolve(session: before) != status else { continue }
            wakeSession(session.id)
        }
    }

    /// A finished turn's chime and announcement; a snoozed session finishes quietly.
    func announceCompletion(_ id: String) {
        guard sessions.first(where: { $0.id == id })?.snoozedUntil == nil else { return }
        play(.complete)
        announce(.finished, sessionID: id)
    }
}
