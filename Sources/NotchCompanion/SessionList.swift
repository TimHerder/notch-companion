import Foundation

/// An archive, snooze or unpin the list's toast can take back.
struct SessionUndo: Equatable {
    enum Kind: String { case archived = "Archived", snoozed = "Snoozed", unpinned = "Unpinned" }
    /// The fields those actions change.
    struct Placement: Equatable {
        var isArchived: Bool
        var isPinned: Bool
        var snoozedUntil: Date?
        init(_ session: CompanionSession) {
            isArchived = session.isArchived; isPinned = session.isPinned; snoozedUntil = session.snoozedUntil
        }
    }
    let id = UUID()
    var kind: Kind
    var sessionID: String
    var title: String
    var before: Placement
    var after: Placement
    var message: String { "\(kind.rawValue) \(title)" }
    static let duration: Duration = .seconds(5)
}

extension AppModel {
    /// Top-level sessions that are not archived by hand or by age.
    func canPinSession(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return session.parentSessionID == nil && !session.isPinned && !session.isArchived && !isAutoArchived(session)
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard pinned ? canPinSession(id) : sessions.contains(where: { $0.id == id && $0.isPinned }) else { return }
        // An unpinned session's auto-archive clock starts now, not from its last activity.
        update(id) { $0.isPinned = pinned; if !pinned { $0.lastSeenAt = Date() } }
        save()
    }

    /// A read result of an idle top-level session can be marked unread again. Not while
    /// snoozed: its unread state is hidden and waking clears the receipt anyway, and an
    /// unread failure would look newly arrived and wake it.
    func canMarkUnread(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return session.parentSessionID == nil && session.snoozedUntil == nil && !session.isBusy && !session.hasUnreadResult
            && [.finished, .failed].contains(session.displayState) && session.acknowledgedCompletionID != nil
    }

    /// Clears the read receipt, so the row, dots, glance and counts show it unread
    /// and it stays out of Archived until it is read again.
    func markUnread(_ id: String) {
        guard canMarkUnread(id) else { return }
        update(id) { $0.acknowledgedCompletionID = nil }
        save()
    }

    /// Runs a list action and offers to undo it, replacing any earlier toast.
    func undoable(_ kind: SessionUndo.Kind, _ id: String, _ action: () -> Void) {
        guard let before = sessions.first(where: { $0.id == id }) else { return }
        action()
        guard let after = sessions.first(where: { $0.id == id }), SessionUndo.Placement(after) != SessionUndo.Placement(before) else { return }
        let undo = SessionUndo(kind: kind, sessionID: id, title: after.title, before: .init(before), after: .init(after))
        sessionUndo = undo
        sessionUndoTimer?.cancel()
        sessionUndoTimer = Task { [weak self] in
            try? await Task.sleep(for: SessionUndo.duration)
            guard !Task.isCancelled, self?.sessionUndo?.id == undo.id else { return }
            self?.sessionUndo = nil
        }
    }

    /// Puts back exactly what the action changed, unless something else has moved the session since.
    func undoSessionChange() {
        guard let undo = sessionUndo else { return }
        sessionUndo = nil
        sessionUndoTimer?.cancel()
        guard let session = sessions.first(where: { $0.id == undo.sessionID }), SessionUndo.Placement(session) == undo.after else { return }
        update(undo.sessionID) {
            $0.isArchived = undo.before.isArchived; $0.isPinned = undo.before.isPinned; $0.snoozedUntil = undo.before.snoozedUntil
        }
        save()
        wakeDueSessions()
        // Like Restore, undoing an archive brings back a worktree cleanup removed meanwhile.
        if undo.after.isArchived && !undo.before.isArchived { Task { await recreateWorktrees(restoring: undo.sessionID) } }
    }

    /// When the session's harness can work again: the latest reset among its reached
    /// limit windows, or nil while none is reached or one's reset time is unknown.
    func limitResetDate(for id: String, now: Date = Date()) -> Date? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        // A window whose reset already passed is out of date, not reached.
        let reached = (rateLimits[session.runtime.rawValue] ?? []).filter { $0.reached && !$0.isStale(now: now) }
        guard !reached.isEmpty, reached.allSatisfy({ $0.resetsAt != nil }) else { return nil }
        return reached.compactMap(\.resetsAt).max()
    }
}
