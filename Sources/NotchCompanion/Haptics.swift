import AppKit

/// Force Touch trackpad feedback for island moments the hand is part of:
/// a glance opening under the pointer, a swipe crossing its threshold, and a
/// file moving between drop destinations. Silent on other input devices.
@MainActor
enum Haptics {
    static let key = "notch.haptics"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
