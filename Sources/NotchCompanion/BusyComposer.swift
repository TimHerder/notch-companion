import Foundation

extension CompanionSession {
    var supportsSteering: Bool {
        guard !isLegacyPrivate else { return false }
        switch runtime {
        case .codex, .pi, .hermes: return true
        case .claude: return capabilities.steering == true
        case .opencode: return runtimeInfo?.nativeInterface == "opencode-http-v2"
        default: return false
        }
    }

    var canSteer: Bool { canSteer(attachments) }

    /// Whether these files (the draft's, or a queued message's) can go into the running turn.
    func canSteer(_ files: [Attachment]) -> Bool {
        supportsSteering && runtimeID != nil && state == .working && !parentTurnComplete
            && nativeActivityUnverified == nil && pendingSubmission == nil
            && !(runtime == .hermes && files.contains(where: \.isImage))
    }

    /// The send key while working says what Return does with the draft.
    var busySendLabel: String { canSteer ? "Steer message" : "Queue message" }

    /// The latest turn finished in Plan, its plan was neither answered natively
    /// (answering a plan approval saves the dismissal; the `ExitPlanMode` scan
    /// covers turns answered before that) nor set aside with Keep planning.
    var planReadyTurnID: String? {
        guard permissionMode == .plan, displayState == .finished,
              let boundary = messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) }),
              turnOutcome[boundary.id] == .finished, planReadyDismissedTurnID != boundary.id,
              !tools.contains(where: { $0.name == "ExitPlanMode" && $0.turnID == (boundary.turnID ?? boundary.id) }) else { return nil }
        return boundary.id
    }

    var busyInputHint: String {
        if pendingSubmission != nil { return "Wait for this turn, then check last send" }
        if canSteer { return "↩ to steer, ⌘↩ to queue for later" }
        if runtime == .hermes && attachments.contains(where: \.isImage) { return "⌘↩ to queue images for later" }
        if supportsSteering && parentTurnComplete { return "Waiting for agents · ⌘↩ to queue" }
        return "⌘↩ to queue for later · steering unavailable"
    }
}

extension AppModel {
    static let implementPlanMessage = "Implement the plan."

    /// Plan ready → Implement: back to the mode used before Plan, then an
    /// ordinary send (receipts, duplicate protection); the draft stays.
    func implementPlan(_ id: String) async {
        guard currentID == id, !submitting, let session = sessions.first(where: { $0.id == id }),
              session.planReadyTurnID != nil, canChangePermissionMode(id) else { return }
        update(id) { $0.permissionMode = session.prePlanPermissionMode }
        if await submit(reply: Self.implementPlanMessage) { return }
        // Nothing started (not connected, not saved): back to Plan, so the banner
        // offers it again. A rejected send shows its failure and keeps the mode.
        guard var retry = sessions.first(where: { $0.id == id }) else { return }
        retry.permissionMode = .plan
        if retry.planReadyTurnID != nil {
            update(id) { $0.permissionMode = .plan }
            save()
        }
    }

    /// Plan ready → Keep planning: hidden for this turn, across restarts.
    func keepPlanning(_ id: String) {
        guard let turn = sessions.first(where: { $0.id == id })?.planReadyTurnID else { return }
        update(id) { $0.planReadyDismissedTurnID = turn }
        save()
    }
}

struct BusyInputRejection: LocalizedError, RuntimeDefinitiveRejection {
    let message: String
    var errorDescription: String? { message }
}
