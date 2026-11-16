import Foundation

/// A goal keeps a top-level session working across turns until its definition of done is met.
/// The companion drives it on every harness: one labelled message per turn through the queue,
/// and the turn's final answer says when it is done (`GOAL COMPLETE` on its own last line).
struct SessionGoal: Codable, Equatable {
    var objective: String
    /// The turn cap chosen (1–50) and the turns allowed now; Continue adds another cap.
    var cap: Int
    var limit: Int
    /// Goal turns sent, the first message included; a resumed limit-stopped goal turn counts too.
    var turns: Int = 0
    var pause: Pause? = nil
    /// The latest goal turn's visible user row, which Resume at reset may continue.
    var turnID: String? = nil

    enum Pause: String, Codable {
        case user, stopped, interrupted, failed, limit, cap, quit
    }

    static let caps = 1...50
    static let defaultCap = 10
    static let marker = "GOAL COMPLETE"

    var isActive: Bool { pause == nil }
    var progress: String { "\(turns)/\(limit)" }
    var pauseText: String? {
        switch pause {
        case nil: return nil
        case .user: return "Goal paused"
        case .stopped: return "Goal paused when you stopped the turn"
        case .interrupted: return "Goal paused when the turn ended early"
        case .failed: return "Goal paused after a failed turn"
        case .limit: return "Goal paused at the usage limit"
        case .cap: return "Goal paused after \(turns) turns"
        case .quit: return "Goal paused when the app quit"
        }
    }

    var startText: String {
        "Goal: \(objective)\n\nWork toward this goal across turns. When it is fully met, end your final answer with a short summary, then a last line containing exactly \(Self.marker)."
    }
    var continueText: String {
        "Continue working toward the goal: \(objective)\n\nReply with \(Self.marker) on its own last line when it is fully done."
    }

    /// The summary above the marker when the answer's last non-empty line, outside any code
    /// block or quote, is exactly `GOAL COMPLETE`; nil otherwise. A quoted, fenced, indented,
    /// decorated or partial marker never counts.
    static func completion(_ answer: String) -> String? {
        // The open fence's character and length: only the same character, at least as long, closes it.
        var fence: (Character, Int)?
        var last: (index: Int, counts: Bool)?
        let lines = answer.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A fence is indented at most three spaces; deeper, the line is content.
            if line.prefix(while: { $0 == " " }).count <= 3, !line.hasPrefix("\t"), let mark = trimmed.first, mark == "`" || mark == "~" {
                let run = trimmed.prefix { $0 == mark }.count
                if run >= 3 {
                    if let open = fence {
                        if mark == open.0, run >= open.1, trimmed.count == run { fence = nil }
                    } else { fence = (mark, run) }
                    last = (index, false)
                    continue
                }
            }
            guard !trimmed.isEmpty else { continue }
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            last = (index, fence == nil && !indented && trimmed == marker)
        }
        guard let last, last.counts, fence == nil else { return nil }
        // The last paragraph above the marker.
        let above = lines[..<last.index].reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let paragraph = above.prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
        return String(paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
    }
}

extension ChatMessage {
    /// A message the companion sent for a goal, labelled “Goal”.
    static let goal = "goal"
    /// The quiet row where a goal was reached, holding the agent's summary.
    static let goalReached = "goalReached"
}

extension QueuedSend {
    /// Waits for the session and its children to be idle, like the user's own queued messages.
    /// Scheduled runs and PR watch messages wait the same way.
    var waitsForIdle: Bool { isUserMessage || isAutomation || kind == ChatMessage.goal }
}

extension CompanionSession {
    /// A goal turn: a Goal message, or Resume at reset continuing the latest goal turn.
    func isGoalTurn(_ row: ChatMessage) -> Bool {
        if row.kind == ChatMessage.goal || row.id == goal?.turnID { return true }
        guard row.text == QueuedSend.resumeText, let turnID = goal?.turnID else { return false }
        let rows = messages.filter { $0.role == "user" && SessionHistory.isVisibleConversation($0) }
        guard let index = rows.lastIndex(where: { $0.id == row.id }), index > 0 else { return false }
        return rows[index - 1].id == turnID
    }

    /// A goal message waiting to be sent; one whose turn already began (the send not yet acknowledged) is not.
    var hasUnsentGoalTurn: Bool { queuedSends.contains { $0.kind == ChatMessage.goal && !wasDelivered($0.id) } }

    /// The working footer's quiet line while a goal turn runs.
    var goalFooter: String? {
        guard let goal, isBusy, let row = messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) }),
              isGoalTurn(row) else { return nil }
        return "Goal · turn \(goal.turns) of \(goal.limit)"
    }

    /// A goal never sends at launch by itself: an unsent follow-up is dropped and the goal pauses.
    mutating func pauseGoalForLaunch() {
        let unsent = queuedSends.filter { $0.kind == ChatMessage.goal }.count
        queuedSends.removeAll { $0.kind == ChatMessage.goal }
        guard var goal else { return }
        goal.turns = max(0, goal.turns - unsent)
        // A goal's Resume at reset may still run; the goal itself waits for Resume.
        if goal.pause == nil || goal.pause == .limit { goal.pause = .quit }
        self.goal = goal
    }

    /// Stop, a failure or a disconnect: the goal pauses and its follow-up leaves the queue.
    mutating func pauseGoal(_ reason: SessionGoal.Pause) {
        guard var goal else { return }
        let unsent = queuedSends.filter { $0.kind == ChatMessage.goal && !wasDelivered($0.id) }.count
        queuedSends.removeAll { $0.kind == ChatMessage.goal }
        goal.turns = max(0, goal.turns - unsent)
        // A specific reason replaces the generic one; Stop and the user's own Pause stay.
        if goal.pause == nil || goal.pause == .interrupted { goal.pause = reason }
        self.goal = goal
    }
}

/// A goal message Pause, Clear or Stop removed while its send was being set up.
struct GoalCancelled: LocalizedError {
    var errorDescription: String? { "The goal was paused before its message was sent." }
}

extension AppModel {
    /// Resume at reset never continues a goal turn past the goal's cap.
    func goalAllowsResume(_ session: CompanionSession, turn: String) -> Bool {
        guard let goal = session.goal, let row = session.messages.first(where: { $0.id == turn }), session.isGoalTurn(row) else { return true }
        return goal.turns < goal.limit
    }

    /// Top-level sessions of a supported harness; not delegated children.
    func offersGoal(_ session: CompanionSession) -> Bool {
        session.parentSessionID == nil && session.runtime.isSupported && !session.isLegacyPrivate
    }

    func startGoal(_ id: String, objective: String, cap: Int) {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = sessions.first(where: { $0.id == id }), offersGoal(session), !text.isEmpty else { return }
        let cap = min(max(cap, SessionGoal.caps.lowerBound), SessionGoal.caps.upperBound)
        update(id) { $0.goal = SessionGoal(objective: text, cap: cap, limit: cap); $0.snoozedUntil = nil }
        queueGoalTurn(id, start: true)
    }

    /// Edit keeps the goal's state; the next follow-up states the new definition.
    func editGoal(_ id: String, objective: String, cap: Int) {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = sessions.first(where: { $0.id == id }), session.goal != nil, !text.isEmpty else { return }
        let cap = min(max(cap, SessionGoal.caps.lowerBound), SessionGoal.caps.upperBound)
        update(id) { target in
            target.goal?.objective = text; target.goal?.cap = cap; target.goal?.limit = cap
            // An unsent goal message states the new definition too.
            for index in target.queuedSends.indices where target.queuedSends[index].kind == ChatMessage.goal && !target.wasDelivered(target.queuedSends[index].id) {
                let start = target.queuedSends[index].text.hasPrefix("Goal: ")
                if let goal = target.goal { target.queuedSends[index].text = start ? goal.startText : goal.continueText }
            }
        }
        guard save() else { update(id) { $0.goal = session.goal }; return }
    }

    func pauseGoal(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }), session.goal?.isActive == true else { return }
        update(id) { $0.pauseGoal(.user) }
        guard save() else { update(id) { $0 = session }; return }
        scheduleDeferredOperationIfIdle()
    }

    /// Resume, or Continue for another cap of turns once the cap is reached. An idle session
    /// continues at once; a busy one when its turn ends.
    func resumeGoal(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }), var goal = session.goal, !goal.isActive else { return }
        if goal.turns >= goal.limit { goal.limit = goal.turns + goal.cap }
        goal.pause = nil
        update(id) { $0.goal = goal }
        if session.isBusy || isSubmitting(id) || session.hasUnsentGoalTurn {
            guard save() else { update(id) { $0.goal = session.goal }; return }
        } else { queueGoalTurn(id, start: false) }
    }

    func clearGoal(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }), session.goal != nil else { return }
        update(id) { $0.goal = nil; $0.queuedSends.removeAll { $0.kind == ChatMessage.goal } }
        guard save() else { update(id) { $0 = session }; return }
        scheduleDeferredOperationIfIdle()
    }

    /// One goal message through the queue, counted; never a second while one waits.
    private func queueGoalTurn(_ id: String, start: Bool) {
        guard let session = sessions.first(where: { $0.id == id }), let goal = session.goal, !session.hasUnsentGoalTurn else { return }
        let entry = QueuedSend(id: UUID().uuidString, text: start ? goal.startText : goal.continueText, kind: ChatMessage.goal)
        update(id) {
            $0.queuedSends.append(entry)
            $0.goal?.turns += 1
            $0.goal?.turnID = entry.id
        }
        guard save() else { update(id) { $0.queuedSends = session.queuedSends; $0.goal = session.goal }; return }
        processDelegationWakes()
    }

    /// A goal message the runtime refused or never received pauses the goal; it is not retried.
    func goalSendFailed(_ id: String, entry: String) {
        // Pause, Clear or Stop already took it out of the queue: nothing more to do, even for a newer goal.
        guard sessions.first(where: { $0.id == id })?.queuedSends.contains(where: { $0.id == entry }) == true else { return }
        // The unsent entry leaves the queue uncounted.
        update(id) { $0.pauseGoal(.failed) }
        save()
        if let error = backgroundSendErrors[id], currentID == id { errorMessage = "The goal's next message was not sent. " + error }
    }

    /// After a turn's end: reached, continue, or pause. True when a follow-up was queued, so the
    /// turn's completion is not announced on its own.
    @discardableResult
    func goalTurnEnded(_ id: String, status: String, limitReached: Bool) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }), let goal = session.goal, offersGoal(session),
              let row = session.messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) }) else { return false }
        let goalTurn = session.isGoalTurn(row)
        // A resumed limit-stopped goal turn counts however it ends, so repeated limits keep to the cap.
        if goalTurn, row.kind != ChatMessage.goal, goal.turnID != row.id {
            update(id) { $0.goal?.turns += 1; $0.goal?.turnID = row.id }
        }
        switch status {
        case "error":
            update(id) { $0.pauseGoal(limitReached ? .limit : .failed) }
            save(); return false
        case "interrupted":
            update(id) { $0.pauseGoal(.stopped) }
            save(); return false
        default: break
        }
        // A child still working or waiting ends this turn later; a failed child fails it.
        guard session.state == .finished else {
            if session.state == .failed { update(id) { $0.pauseGoal(.failed) }; save() }
            return false
        }
        // The turn's final answer: its last text after its own user row.
        let turn = session.messages[((session.messages.lastIndex { $0.id == row.id } ?? 0) + 1)...]
        let answer = turn.last { $0.role == "assistant" && $0.questions == nil && !$0.text.isEmpty }
        if let summary = answer.flatMap({ SessionGoal.completion($0.text) }) {
            update(id) {
                $0.goal = nil
                $0.queuedSends.removeAll { $0.kind == ChatMessage.goal }
                $0.messages.append(ChatMessage(role: "system", text: summary, kind: ChatMessage.goalReached))
            }
            save(); return false
        }
        // A resumed limit-stopped goal turn that finished lifts the limit pause.
        if goal.pause == .limit, goalTurn, row.kind != ChatMessage.goal { update(id) { $0.goal?.pause = nil } }
        guard let current = sessions.first(where: { $0.id == id })?.goal, current.isActive else { save(); return false }
        // An open question or approval waits for the user's reply; that turn's end continues.
        let asking = turn.contains { $0.questions != nil }
            || session.runtimeID.map { sid in requests.contains { $0.sessionID == sid } } == true
        if asking { save(); return false }
        if deferredOperation != nil { update(id) { $0.pauseGoal(.quit) }; save(); return false }
        // The first message of a goal started during this turn is already counted and waiting.
        if session.hasUnsentGoalTurn { save(); return true }
        if current.turns >= current.limit { update(id) { $0.pauseGoal(.cap) }; save(); return false }
        queueGoalTurn(id, start: false)
        return sessions.first(where: { $0.id == id })?.hasUnsentGoalTurn == true
    }
}
