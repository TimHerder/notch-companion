import AppKit

/// Edit from here: the harness's own rewind to before one of your messages, which then returns to the composer.
enum RewindChoice { case cancel, conversation, files }

/// Where a rewind cuts: the user row it removes with everything after it.
struct RewindPoint: Equatable {
    var messageID: String
    /// OpenCode: the native user message the revert removes.
    var nativeMessageID: String?
    /// Claude Code: the answer its truncating resume keeps the native chain through.
    var keepsNativeID: String?
    /// User turns removed, this one included.
    var turns: Int
}

extension CompanionSession {
    /// A native rewind this app drives: Claude Code's truncating resume (`--resume-session-at`), shared Hermes's
    /// `session.undo` (its latest turn only) and OpenCode 2's staged revert. Never for delegated children or side chats.
    var rewindsConversation: Bool {
        guard !isLegacyPrivate, parentSessionID == nil else { return false }
        switch runtime {
        case .claude, .hermes: return true
        case .opencode: return capabilities.rewind == true
        default: return false
        }
    }
    /// OpenCode's revert also restores its file snapshots; no other harness reverts files through this app.
    var rewindsFiles: Bool { rewindsConversation && runtime == .opencode }
}

extension AppModel {
    /// The native rewind point before this message of yours, or nil where the harness cannot rewind there.
    func rewindPoint(_ messageID: String, in session: CompanionSession) -> RewindPoint? {
        guard session.rewindsConversation, session.storedID != nil, session.pendingSubmission?.id != messageID,
              let index = session.messages.firstIndex(where: { $0.id == messageID }),
              session.messages[index].role == "user", session.messages[index].kind == nil,
              SessionHistory.isVisibleConversation(session.messages[index]),
              // A steer continues an earlier row's turn: cutting there would split that turn's tools, changes and outcome.
              (session.messages[index].turnID ?? messageID) == messageID else { return nil }
        // Only the current native session, and in a fork only what it added after the source's copied history.
        var start = session.segmentStart
        if let fork = session.forkedFrom {
            guard let answer = fork.answerID, let copied = session.messages.firstIndex(where: { $0.id == answer }) else { return nil }
            start = max(start, copied + 1)
        }
        guard index >= start else { return nil }
        let turns = session.messages[index...].filter { $0.role == "user" && SessionHistory.isVisibleConversation($0) }.count
        var point = RewindPoint(messageID: messageID, turns: turns)
        switch session.runtime {
        case .claude:
            // The resume keeps the native chain through the answer just before this message, so that answer's ID must be known.
            guard let previous = session.messages[start..<index].last(where: SessionHistory.isVisibleConversation),
                  previous.role == "assistant", let native = previous.nativeID else { return nil }
            point.keepsNativeID = native
        case .hermes:
            guard turns == 1 else { return nil }
        case .opencode:
            // The app sends its row ID as `msg_<id>`; rows restored from native history keep the native ID behind this prefix.
            let id = session.messages[index].id
            point.nativeMessageID = id.hasPrefix("hermes-") ? String(id.dropFirst(7)) : "msg_" + id
        default: return nil
        }
        return point
    }

    /// Why this session cannot rewind now, or nil. Restoring files also waits for every other session in the same folder.
    func rewindBlocker(_ session: CompanionSession, files: Bool = false) -> String? {
        if rewindingSessionIDs.contains(session.id) { return "Rewinding…" }
        if session.pendingSubmission != nil, !session.isBusy { return "Check the last send first." }
        let tree = [session.id] + delegatedDescendants(of: session.id)
        let asking = tree.contains { id in
            guard let runtimeID = sessions.first(where: { $0.id == id })?.runtimeID else { return false }
            return requests.contains { $0.sessionID == runtimeID }
        }
        if asking { return "Answer the open question or approval first." }
        if !session.queuedSends.isEmpty { return "Send or cancel the queued messages first." }
        if gitActionRunning(near: session.id) { return "Wait for the Git action to finish." }
        if !treeIsIdle(session.id) { return "Wait for this session and its delegated work to finish." }
        if files, !gitActionsIdle(session.id) { return "Another session is working in this folder, and restoring files could undo its edits." }
        return nil
    }

    /// A rewind restoring files in this session's checkout, which a send there must wait for.
    func restoringFiles(near id: String) -> Bool {
        restoringFilesSessionIDs.contains { $0 == id || sharesCheckout(id, $0) }
    }

    /// Asks first, then rewinds natively; the message's text and files return to the composer, never sent.
    func editFromHere(_ messageID: String, in id: String) async {
        guard let saved = sessions.first(where: { $0.id == id }), rewindPoint(messageID, in: saved) != nil else { return }
        if let blocker = rewindBlocker(saved) { errorMessage = blocker; return }
        // As Start fresh does: a conversation not attached in this run first restores newer native history.
        if saved.runtimeID == nil {
            backgroundSubmissions.insert(id)
            do { _ = try await ensureRuntime(id) } catch {
                backgroundSubmissions.remove(id)
                errorMessage = "Could not check the native session before rewinding. " + error.localizedDescription
                return
            }
            backgroundSubmissions.remove(id)
        }
        guard let session = sessions.first(where: { $0.id == id }), let point = rewindPoint(messageID, in: session) else {
            errorMessage = "This message can no longer be edited from here."; return
        }
        if let blocker = rewindBlocker(session) { errorMessage = blocker; return }
        let harness = session.runtime.title
        let later = point.turns - 1
        let removed = later == 0 ? "this message and its turn" : "this message and the \(later) later \(later == 1 ? "turn" : "turns") after it"
        let message = "Rewinding removes \(removed) from \(harness)'s history. Your message returns to the composer to edit and send."
            + (session.rewindsFiles ? " Rewind and Restore Files also puts back the files \(harness) changed since then." : " Files \(harness) changed stay as they are.")
        let choice: RewindChoice
        if let rewindDecision { choice = rewindDecision(message, session.rewindsFiles) }
        else {
            let alert = NSAlert()
            alert.messageText = "Edit from here?"
            alert.informativeText = message
            if session.rewindsFiles { alert.addButton(withTitle: "Rewind and Restore Files") }
            alert.addButton(withTitle: "Rewind")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            let response = alert.runAboveNotch()
            let first = response == .alertFirstButtonReturn, second = response == .alertSecondButtonReturn
            choice = session.rewindsFiles ? (first ? .files : second ? .conversation : .cancel) : (first ? .conversation : .cancel)
        }
        guard choice != .cancel else { return }
        let files = choice == .files
        // The modal ran while events kept arriving: the point and the session must be unchanged.
        guard let current = sessions.first(where: { $0.id == id }), rewindPoint(messageID, in: current) == point else {
            errorMessage = "The conversation changed, so nothing was rewound."; return
        }
        if let blocker = rewindBlocker(current, files: files) { errorMessage = blocker; return }
        await rewind(id, to: point, files: files)
    }

    private func rewind(_ id: String, to point: RewindPoint, files: Bool) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Counts as a send in flight: other sends, archive, cleanup and Quit/Reconnect wait for it.
        rewindingSessionIDs.insert(id)
        backgroundSubmissions.insert(id)
        if files { restoringFilesSessionIDs.insert(id) }
        defer {
            rewindingSessionIDs.remove(id); backgroundSubmissions.remove(id); restoringFilesSessionIDs.remove(id)
            scheduleDeferredOperationIfIdle()
        }
        var requested = false
        do {
            let sid = try await ensureRuntime(id)
            var params: [String: Any] = ["session_id": sid, "turns": point.turns, "files": files]
            if let native = point.nativeMessageID { params["message_id"] = native }
            if let keep = point.keepsNativeID { params["native_message_id"] = keep }
            // The cut must be saved once the harness has rewound; an unwritable registry refuses before that.
            guard save() else { throw AppError("The session registry could not be saved, so nothing was rewound.") }
            requested = true
            let result = try await client.request("session.rewind", params: params)
            applyRewind(id, at: point, result: result)
        } catch {
            // The native outcome may be unknown (Claude Code also closed its process): the next use resumes and restores native history.
            if requested { update(id) { $0.runtimeID = nil } }
            errorMessage = "\(session.runtime.title) could not rewind this conversation. " + error.localizedDescription
        }
    }

    /// Everything from the point on leaves the conversation as it left native history; the message returns to the composer.
    func applyRewind(_ id: String, at point: RewindPoint, result: [String: Any]) {
        guard let session = sessions.first(where: { $0.id == id }),
              let cut = session.messages.firstIndex(where: { $0.id == point.messageID }) else { return }
        let removed = session.messages[cut...]
        // Turn ends, outcomes and limit resets are keyed by user rows; tools, changes and children by turns.
        let keys = Set(removed.map(\.id)).union(removed.map { $0.turnID ?? $0.id })
        let message = session.messages[cut]
        let files = message.attachments ?? []
        let available = files.filter { FileManager.default.isReadableFile(atPath: $0.url.path) }
        var text = message.text
        if !files.isEmpty, let range = text.range(of: "\n\nAttached: ", options: .backwards) { text = String(text[..<range.lowerBound]) }
        let children = session.agents.filter { $0.sessionID != nil && $0.turnID.map(keys.contains) == true }.compactMap(\.sessionID)
        update(id) { target in
            target.messages.removeSubrange(cut...)
            if result["history_complete"] as? Bool != false, let rows = result["messages"] as? [[String: Any]],
               let restored = SessionHistory.restoringSegment(rows, into: target.messages) { target.messages = restored }
            target.tools.removeAll { $0.turnID.map(keys.contains) ?? false }
            target.changes.removeAll { keys.contains($0.id) }
            // Native agents of removed turns went with them; app-owned children stay in the team, archived.
            target.agents.removeAll { $0.sessionID == nil && $0.turnID.map(keys.contains) == true }
            target.turnEndedAt = target.turnEndedAt.filter { !keys.contains($0.key) }
            target.turnOutcome = target.turnOutcome.filter { !keys.contains($0.key) }
            target.turnTokens = target.turnTokens.filter { !keys.contains($0.key) }
            target.turnUsage = target.turnUsage.filter { !keys.contains($0.key) }
            target.limitResets = target.limitResets.filter { !keys.contains($0.key) }
            if target.planTurnID.map(keys.contains) == true { target.planTurnID = nil }
            if target.planReadyDismissedTurnID.map(keys.contains) == true { target.planReadyDismissedTurnID = nil }
            // Goals (a separate change) should re-check their state here against the removed turns.
            // Forks of removed answers stay valid: they are separate native sessions, or refork only while their answer ends the source.
            target.resumeAt = result["resume_at"] as? String
            target.state = .idle
            target.completionID = nil
            target.parentTurnComplete = true
            target.runtimeInfo?.context = nil
            // As a failed send returns: ahead of any newer draft, separated by a blank line.
            target.draft = target.draft.isEmpty ? text : text + "\n\n" + target.draft
            let staged = Set(target.attachments.map(\.id))
            target.attachments.insert(contentsOf: available.filter { !staged.contains($0.id) }, at: 0)
            target.updatedAt = Date()
        }
        for child in children { update(child) { $0.isArchived = true; $0.snoozedUntil = nil; $0.isPinned = false } }
        // A result whose wake left the conversation, or from a child of a removed turn, never wakes the parent again.
        let wakes = Set(removed.map(\.id))
        for child in sessions where child.parentSessionID == id && child.delegation != nil
            && (children.contains(child.id) || child.delegation?.wakeMessageID.map(wakes.contains) == true) {
            update(child.id) { $0.delegation?.completionWake = false }
        }
        guard save() else {
            errorMessage = "The rewind happened, but it could not be saved here. Copy your message from the composer before quitting."
            return
        }
        if available.count < files.count {
            errorMessage = "\(files.count - available.count) of the message's attached files no longer exist, so they were not added back."
        }
        if currentID == id { composerFocusRequest += 1 }
    }
}
