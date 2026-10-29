import Foundation

enum AppVersion {
    /// Release metadata is stamped into the app before signing. A bare SwiftPM
    /// executable has no app metadata and must not claim to be a release.
    static var label: String {
        label(metadata: Bundle.main.infoDictionary ?? [:])
    }

    static func label(metadata: [String: Any]) -> String {
        if let preview = metadata["NotchCompanionPreview"] as? String {
            return "Notch Companion · Preview \(preview)"
        }
        guard let version = metadata["NotchCompanionReleaseVersion"] as? String,
              let build = metadata["CFBundleVersion"] as? String else {
            return "Notch Companion · Development build"
        }
        return "Notch Companion \(version) · Build \(build)"
    }
}
