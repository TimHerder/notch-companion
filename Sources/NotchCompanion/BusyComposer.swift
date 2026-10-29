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

    var canSteer: Bool {
        supportsSteering && runtimeID != nil && state == .working && !parentTurnComplete
            && nativeActivityUnverified == nil && pendingSubmission == nil
            && !(runtime == .hermes && attachments.contains(where: \.isImage))
    }

    var busyInputHint: String {
        if pendingSubmission != nil { return "Wait for this turn, then check last send" }
        if canSteer { return "↩ to steer, ⌘↩ to queue for later" }
        if runtime == .hermes && attachments.contains(where: \.isImage) { return "⌘↩ to queue images for later" }
        if supportsSteering && parentTurnComplete { return "Waiting for agents · ⌘↩ to queue" }
        return "⌘↩ to queue for later · steering unavailable"
    }
}

struct BusyInputRejection: LocalizedError, RuntimeDefinitiveRejection {
    let message: String
    var errorDescription: String? { message }
}
