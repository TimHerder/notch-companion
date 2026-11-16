import Foundation

/// Where a session forked from: the source, and the native point its fork goes through.
struct ForkRecord: Codable, Equatable {
    var sourceSessionID: String
    var sourceTitle: String
    var sourceStoredID: String
    /// The source's user row that began the answer's block: its local, turn and native IDs (Codex finds its turn by them).
    var userMessageIDs: [String]
    /// The answer's own native ID, where the harness forks at a message (Claude Code).
    var nativeMessageID: String?
    /// The answer was the source's last visible message.
    var latest: Bool
    /// The answer forked through, which a whole-session fork made again must still end the source.
    var answerID: String? = nil

    /// `session.create`'s `fork` parameter.
    var parameters: [String: Any] {
        var value: [String: Any] = ["session_id": sourceStoredID, "message_ids": userMessageIDs, "latest": latest]
        if let nativeMessageID { value["native_message_id"] = nativeMessageID }
        return value
    }
}

extension RuntimeKind {
    /// Harnesses whose native fork this app drives: Codex `thread/fork` through a turn, Claude Code
    /// `--fork-session` through a message. Others fork natively in ways not wired here, or not at all.
    var forksSessions: Bool { self == .codex || self == .claude }
}

extension CompanionSession {
    /// A side chat: a native fork that lives under the session it forked from.
    var isSideChat: Bool { forkedFrom != nil && parentSessionID != nil }
}

extension AppModel {
    /// The native fork point for a finished answer, or nil where this harness cannot fork there.
    func forkPoint(_ messageID: String, in session: CompanionSession) -> ForkRecord? {
        guard session.runtime.forksSessions, !session.isLegacyPrivate, let stored = session.storedID,
              let index = session.messages.firstIndex(where: { $0.id == messageID }),
              session.messages[index].role == "assistant", SessionHistory.isVisibleConversation(session.messages[index]) else { return nil }
        let message = session.messages[index]
        let later = session.messages[(index + 1)...].filter(SessionHistory.isVisibleConversation)
        // The running turn's text is not a finished answer yet.
        if session.isBusyIgnoringDelegates, !later.contains(where: { $0.role == "user" }) { return nil }
        let user = session.messages[..<index].last { $0.role == "user" && SessionHistory.isVisibleConversation($0) }
        var ids: [String] = []
        for id in [user?.id, user?.turnID].compactMap({ $0 }) {
            // Restored rows carry the native item ID behind this prefix.
            for candidate in [id, id.hasPrefix("hermes-") ? String(id.dropFirst(7)) : id] where !ids.contains(candidate) { ids.append(candidate) }
        }
        switch session.runtime {
        // `thread/fork` stops at a turn's end: an answer a later steer continued does not end one.
        case .codex: guard !ids.isEmpty, !later.contains(where: { $0.role == "user" && $0.turnID == (user?.turnID ?? user?.id) && $0.id != user?.id }) else { return nil }
        // Without the answer's message ID only the whole session can be copied, which is this answer only when it is the last.
        case .claude: guard message.nativeID != nil || later.isEmpty else { return nil }
        default: return nil
        }
        return ForkRecord(sourceSessionID: session.id, sourceTitle: session.title, sourceStoredID: stored,
                          userMessageIDs: ids, nativeMessageID: message.nativeID, latest: later.isEmpty, answerID: message.id)
    }

    /// A fork nothing was sent to is forked again on reopen. A whole-session fork (Claude Code without the
    /// answer's message ID) is the same fork only while that answer still ends an idle source.
    func reforkBlocker(_ fork: ForkRecord) -> String? {
        guard fork.nativeMessageID == nil, fork.latest, let answer = fork.answerID else { return nil }
        guard let source = sessions.first(where: { $0.id == fork.sourceSessionID }), !source.isBusyIgnoringDelegates,
              source.messages.last(where: SessionHistory.isVisibleConversation)?.id == answer else {
            return "“\(fork.sourceTitle)” has moved on since this fork was made, so its native fork cannot be made again. Fork it anew."
        }
        return nil
    }

    /// Why this session cannot be forked now, or nil. Its whole tree must be idle with no unconfirmed send.
    func forkBlocker(_ session: CompanionSession) -> String? {
        if forkingSessionIDs.contains(session.id) { return "Forking…" }
        if session.pendingSubmission != nil, !session.isBusy { return "Check the last send first." }
        let busy = ([session.id] + delegatedDescendants(of: session.id)).contains { id in
            guard let member = sessions.first(where: { $0.id == id }) else { return false }
            return member.isBusy || member.pendingSubmission != nil || member.stagedSubmission != nil || isSubmitting(id)
                || unfinishedParents.contains(id) || !(unfinishedChildren[id]?.isEmpty ?? true)
        }
        if busy { return "Wait for this session and its delegated work to finish." }
        return nil
    }

    /// A side chat forks the session's latest finished answer. Only top-level sessions have one.
    func sideChatPoint(_ session: CompanionSession) -> (messageID: String, point: ForkRecord)? {
        guard session.parentSessionID == nil,
              let answer = session.messages.last(where: { $0.role == "assistant" && SessionHistory.isVisibleConversation($0) }),
              let point = forkPoint(answer.id, in: session) else { return nil }
        return (answer.id, point)
    }

    /// Fork from here: a new top-level session whose native session is a fork through this answer.
    func forkFromHere(_ messageID: String, in sessionID: String) async {
        guard let source = sessions.first(where: { $0.id == sessionID }), let point = forkPoint(messageID, in: source) else { return }
        await openFork(of: source, through: messageID, point: point, sideChat: false)
    }

    /// A side chat under this session, forked from its current state.
    func openSideChat(_ sessionID: String) async {
        guard let source = sessions.first(where: { $0.id == sessionID }), let (messageID, point) = sideChatPoint(source) else { return }
        await openFork(of: source, through: messageID, point: point, sideChat: true)
    }

    private func openFork(of source: CompanionSession, through messageID: String, point: ForkRecord, sideChat: Bool) async {
        if let blocker = forkBlocker(source) { errorMessage = blocker; return }
        guard let end = source.messages.firstIndex(where: { $0.id == messageID }) else { return }
        var fork = CompanionSession()
        // Both count as sending while the fork opens: no send, archive, delete or Quit/Reconnect races it.
        forkingSessionIDs.insert(source.id)
        backgroundSubmissions.formUnion([source.id, fork.id])
        defer {
            forkingSessionIDs.remove(source.id)
            backgroundSubmissions.subtract([source.id, fork.id])
            syncDelegatedChildren()
            scheduleDeferredOperationIfIdle()
        }
        fork.runtime = source.runtime
        fork.profileID = source.profileID
        fork.workspacePath = source.workspacePath ?? workspacePath
        fork.trustedProjectPath = source.trustedProjectPath
        // The source's own choices; a side chat keeps the parent's mode, as a delegated child may.
        fork.permissionMode = source.permissionMode
        fork.fullAccessConfirmed = source.permissionMode == .fullAccess && source.fullAccessConfirmed
        fork.modelOverride = source.modelOverride
        fork.title = sideChat ? "Side chat" : source.title
        // The saved transcript up to the answer stands for the forked native history.
        let history = Array(source.messages[...end])
        let rows = Set(history.map(\.id))
        let turns = Set(history.map { $0.turnID ?? $0.id })
        fork.messages = history
        fork.tools = source.tools.filter { $0.turnID.map(turns.contains) ?? false }
        fork.turnEndedAt = source.turnEndedAt.filter { rows.contains($0.key) }
        fork.turnOutcome = source.turnOutcome.filter { rows.contains($0.key) }
        fork.forkedFrom = point
        if sideChat {
            fork.parentSessionID = source.id
            sessions.append(fork)
            // Its own turn ID keeps the side chat's result out of the parent's turn and changes.
            update(source.id) { $0.agents.append(ChildAgent(id: "side-chat:" + fork.id, title: fork.title, state: .idle, turnID: "side-chat:" + fork.id,
                                                            sessionID: fork.id, runtime: fork.runtime, role: "side chat")) }
        } else {
            sessions.insert(fork, at: 0)
        }
        func discard() {
            sessions.removeAll { $0.id == fork.id }
            update(source.id) { $0.agents.removeAll { $0.sessionID == fork.id } }
        }
        guard save() else { discard(); errorMessage = "The session registry could not be saved. Nothing was forked."; return }
        do { _ = try await ensureRuntime(fork.id) } catch {
            discard()
            save()
            errorMessage = "\(source.runtime.title) could not fork this session. \(error.localizedDescription)"
            return
        }
        selectSession(fork.id)
        composerFocusRequest += 1
        save()
    }

    /// The side chat's own latest answer, and the ID its Bring back message is sent with.
    func bringBackAnswer(_ chat: CompanionSession) -> (answer: ChatMessage, id: String)? {
        guard chat.isSideChat, let parent = sessions.first(where: { $0.id == chat.parentSessionID }),
              let answer = chat.messages.last(where: { $0.role == "assistant" && SessionHistory.isVisibleConversation($0) }),
              // Answers copied from the parent are already there.
              !parent.messages.contains(where: { $0.id == answer.id }) else { return nil }
        return (answer, Delegation.derivedID(caller: chat.id, operation: "bring_back", clientRequestID: answer.id))
    }

    /// This answer is already in the parent's transcript, its queue or its unconfirmed send.
    func broughtBack(_ chat: CompanionSession) -> Bool {
        guard let id = bringBackAnswer(chat)?.id, let parent = sessions.first(where: { $0.id == chat.parentSessionID }) else { return false }
        return parent.wasDelivered(id) || parent.queuedSends.contains { $0.id == id }
    }

    /// Bring back: the side chat's latest answer goes to the parent as one relayed message, through its queue.
    func bringBack(_ chatID: String) {
        guard let chat = sessions.first(where: { $0.id == chatID }), let parentID = chat.parentSessionID, !chat.isBusy,
              chat.pendingSubmission == nil, !isSubmitting(chatID), let (answer, id) = bringBackAnswer(chat), !broughtBack(chat) else { return }
        update(parentID) { $0.queuedSends.append(QueuedSend(id: id, text: "From side chat:\n\n" + answer.text, kind: ChatMessage.sideChatMessage)) }
        save()
        selectSession(parentID)
        processDelegationWakes()
    }

    /// Close: the side chat is archived with its history, and the parent opens.
    func closeSideChat(_ id: String) {
        guard let parentID = sessions.first(where: { $0.id == id && $0.isSideChat })?.parentSessionID, canArchiveSession(id) else { return }
        archiveSession(id)
        selectSession(parentID)
    }
}
