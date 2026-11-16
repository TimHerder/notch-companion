import AppKit

/// Native session operations from the context bubble and a limit-stopped turn:
/// Compact, Start fresh and Resume at reset.
extension ChatMessage {
    /// Quiet transcript rows the companion adds between turns, never sent and never native history.
    static let contextCompacted = "contextCompacted"
    /// Where Start fresh opened a new native session for this conversation.
    static let newSession = "newSession"
    var isSessionMarker: Bool { role == "system" && [Self.contextCompacted, Self.newSession].contains(kind ?? "") }
}

extension QueuedSend {
    static let resumeText = "Continue where you left off."
    func isDue(_ now: Date = Date()) -> Bool { notBefore.map { $0 <= now } ?? true }
}

extension RuntimeKind {
    /// A native compaction this app drives: Codex `thread/compact/start`, Claude Code's
    /// `/compact` user input, Pi RPC `compact` and shared Hermes's `session.compress`.
    var compactsContext: Bool { [.codex, .claude, .pi, .hermes].contains(self) }
}

extension CompanionSession {
    /// Where the current native session's messages begin: after the latest New session divider.
    var segmentStart: Int { messages.lastIndex { $0.role == "system" && $0.kind == ChatMessage.newSession }.map { $0 + 1 } ?? 0 }
    /// Visible user rows of the current native session, the ones its native history holds.
    var segmentUserTurnCount: Int { messages[segmentStart...].filter { $0.role == "user" && SessionHistory.isVisibleConversation($0) }.count }
    /// The latest visible user row, which keys a turn's outcome and limit reset.
    var latestUserRowID: String? { messages.last { $0.role == "user" && SessionHistory.isVisibleConversation($0) }?.id }
}

extension SessionHistory {
    /// Native history covers only the current native session: earlier segments stay as saved,
    /// and the current one's markers keep their place after the message they followed.
    static func restoringSegment(_ rows: [[String: Any]], into saved: [ChatMessage]) -> [ChatMessage]? {
        let start = saved.lastIndex { $0.role == "system" && $0.kind == ChatMessage.newSession }.map { $0 + 1 } ?? 0
        let tail = Array(saved[start...])
        var restored = messages(rows, preserving: tail)
        guard !restored.isEmpty else { return nil }
        var anchor: String?
        for message in tail {
            if message.isSessionMarker {
                let index = anchor.flatMap { id in restored.firstIndex { $0.id == id }.map { $0 + 1 } }
                    ?? (anchor == nil ? 0 : restored.firstIndex { $0.createdAt > message.createdAt } ?? restored.count)
                restored.insert(message, at: index)
                anchor = message.id
            } else if isVisibleConversation(message) { anchor = message.id }
        }
        return Array(saved[..<start]) + restored
    }
}

extension AppModel {
    static let resumeAutomaticallyKey = "sessions.resumeAfterLimit"

    /// Like a model change: no turn, child, send, compaction or open question in flight.
    private func readyForSessionOp(_ session: CompanionSession) -> Bool {
        isSettled(session) && session.stagedSubmission == nil && !compactingSessionIDs.contains(session.id)
            && !(session.runtimeID.map { id in requests.contains { $0.sessionID == id } } ?? false)
    }

    /// Shown only for harnesses whose native compaction this app drives.
    func offersCompact(_ session: CompanionSession) -> Bool { session.runtime.compactsContext && !session.isLegacyPrivate }
    func canCompact(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return offersCompact(session) && session.storedID != nil && readyForSessionOp(session)
    }

    /// Runs the harness's own compaction; a quiet row records it, with the native summary when there is one.
    func compactContext(_ id: String) async {
        guard canCompact(id) else { return }
        compactingSessionIDs.insert(id)
        // Counts as a send in flight: other sends wait and Quit asks first.
        backgroundSubmissions.insert(id)
        defer {
            compactingSessionIDs.remove(id); backgroundSubmissions.remove(id)
            processDelegationWakes(); scheduleDeferredOperationIfIdle()
        }
        do {
            let sid = try await ensureRuntime(id)
            let result = try await client.request("session.compact", params: ["session_id": sid])
            let summary = (result["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            update(id) {
                $0.messages.append(ChatMessage(role: "system", text: summary, kind: ChatMessage.contextCompacted))
                $0.updatedAt = Date()
            }
            save()
        } catch {
            errorMessage = "Could not compact the context. " + error.localizedDescription
        }
    }

    /// Every harness opens a new native session through `session.create`; Legacy Hermes cannot.
    func offersStartFresh(_ session: CompanionSession) -> Bool {
        session.parentSessionID == nil && !session.isLegacyPrivate && session.runtime.isSupported
    }
    func canStartFresh(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return offersStartFresh(session) && session.storedID != nil && readyForSessionOp(session)
    }

    /// After confirmation the next send opens a new native session with the same harness,
    /// profile, folder and choices; the transcript keeps everything above a New session row.
    func startFresh(_ id: String) {
        guard canStartFresh(id), let session = sessions.first(where: { $0.id == id }) else { return }
        let message = "Your next message opens a new \(session.runtime.title) session in this conversation, with an empty context. Everything above stays here."
        let confirmed: Bool
        if let startFreshDecision { confirmed = startFreshDecision(message) }
        else {
            let alert = NSAlert()
            alert.messageText = "Start fresh?"
            alert.informativeText = message
            alert.addButton(withTitle: "Start Fresh")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            confirmed = alert.runAboveNotch() == .alertFirstButtonReturn
        }
        // The modal ran while events kept arriving.
        guard confirmed, canStartFresh(id) else { return }
        update(id) { target in
            target.earlierStoredIDs = (target.earlierStoredIDs ?? []) + [target.storedID].compactMap { $0 }
            target.storedID = nil
            target.runtimeID = nil
            target.nativeSubmissionAttempted = false
            target.runtimeInfo?.context = nil
            // A resume continues the old context, which the new session does not have.
            target.queuedSends.removeAll { $0.resumesTurnID != nil }
            target.messages.append(ChatMessage(role: "system", text: "", kind: ChatMessage.newSession))
            target.updatedAt = Date()
        }
        guard save() else { update(id) { $0 = session }; return }
        // The new native session gets its own permission state and delegation tools.
        permissionOverrides.remove(id)
        delegationServer.revoke(sessionID: id)
        resumeTimerNeedsUpdate()
    }

    // MARK: Resume at reset

    /// The latest reset of a window the account reached, from the harness's own limit reports.
    func limitReset(_ runtime: RuntimeKind, now: Date = Date()) -> Date? {
        (rateLimits[runtime.rawValue] ?? []).filter { $0.reached || ($0.usedPercent ?? 0) >= 100 }
            .compactMap(\.resetsAt).filter { $0 > now }.max()
    }

    /// A turn the account limit stopped. Its reset comes from the harness's limit report,
    /// read again once when the turn's own report has none yet (Codex may report after the turn).
    func recordLimitStop(_ id: String, turn: String, refreshed: Bool = false) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard let reset = limitReset(session.runtime) else {
            if !refreshed, session.runtime.capabilities.rateLimits == true {
                Task { [weak self] in
                    await self?.refreshRateLimits(session.runtime)
                    self?.recordLimitStop(id, turn: turn, refreshed: true)
                }
            }
            return
        }
        update(id) { $0.limitResets[turn] = reset }
        scheduleSave()
        if resumeAutomatically { resumeAtReset(id, turn: turn) }
    }

    /// Only the latest turn, stopped by a limit with a known reset, with nothing sent since.
    func canResumeAtReset(_ id: String, turn: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return session.limitResets[turn] != nil && session.latestUserRowID == turn && session.turnOutcome[turn] == .failed
            && session.runtime.isSupported && !session.isLegacyPrivate && session.pendingSubmission == nil
            && !session.queuedSends.contains { $0.resumesTurnID != nil }
    }

    /// One follow-up through the queue, not before the reset.
    func resumeAtReset(_ id: String, turn: String) {
        guard canResumeAtReset(id, turn: turn), let session = sessions.first(where: { $0.id == id }),
              let reset = session.limitResets[turn] else { return }
        update(id) { $0.queuedSends.append(QueuedSend(id: UUID().uuidString, text: QueuedSend.resumeText, notBefore: reset, resumesTurnID: turn)) }
        guard save() else { update(id) { $0.queuedSends = session.queuedSends }; return }
        resumeTimerNeedsUpdate()
    }

    func sendResumeNow(_ entryID: String) {
        guard let session = current, !isSubmitting(session.id) else { return }
        update(session.id) { target in
            for index in target.queuedSends.indices where target.queuedSends[index].id == entryID { target.queuedSends[index].notBefore = Date() }
        }
        save()
        processDelegationWakes()
    }

    /// Sleeps until the next resume is due; a due one goes through the queue, at launch too.
    func resumeTimerNeedsUpdate(now: Date = Date()) {
        resumeTimer?.cancel()
        let times = sessions.flatMap { $0.queuedSends.compactMap(\.notBefore) }
        if times.contains(where: { $0 <= now }) { Task { @MainActor [weak self] in self?.processDelegationWakes() } }
        guard let next = times.filter({ $0 > now }).min() else { resumeTimer = nil; return }
        resumeTimer = Task { [weak self] in
            // A continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.resumeTimerNeedsUpdate()
        }
    }
}
