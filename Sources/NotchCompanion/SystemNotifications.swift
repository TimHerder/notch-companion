import AppKit
import SwiftUI
import UserNotifications

/// What one macOS notification says, keyed by the session it opens.
struct SystemNotice: Equatable {
    var sessionID: String
    var title: String
    var subtitle: String
    var body: String
}

/// Settings → macOS notifications (off by default): an announced moment also
/// goes to Notification Center, without a sound of its own (the app's cues
/// play). Each session keeps at most one notification, removed once read.
@MainActor
final class SystemNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifications()
    static let key = "notch.systemNotifications"
    /// System Settings → Notifications, on this app's page.
    static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + (Bundle.main.bundleIdentifier ?? ""))!
    }

    @Published var enabled = UserDefaults.standard.bool(forKey: key) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.key)
            if enabled { Task { await requestAuthorization() } }
        }
    }
    /// The user turned notifications off for this app in System Settings.
    @Published private(set) var denied = false
    /// Clicking a notification opens its session.
    var open: ((String) -> Void)?
    /// Sessions that may have a notification, so reads need not call macOS each time.
    private var delivered = Set<String>()
    /// Until the last run's notifications are listed, every removal goes to macOS.
    private var listedDelivered = false

    /// UserNotifications needs an app bundle with an identifier; the bare
    /// SwiftPM executable and the test runner have none and must not touch it.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    func install(open: @escaping (String) -> Void) {
        self.open = open
        guard let center else { return }
        center.delegate = self
        Task {
            // Notifications from the last run can still be removed once read.
            delivered.formUnion(await center.deliveredNotifications().map(\.request.identifier))
            listedDelivered = true
            await refreshAuthorization()
        }
    }

    func refreshAuthorization() async {
        guard let center else { return }
        denied = await center.notificationSettings().authorizationStatus == .denied
    }

    /// Offscreen fixtures show the denied switch without asking macOS.
    func setDeniedForPreview(_ value: Bool) { denied = value }

    private func requestAuthorization() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert])
        await refreshAuthorization()
    }

    func post(_ notice: SystemNotice) {
        // Not gated on `denied`: access granted later in System Settings applies at once.
        guard enabled, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.sessionID
        // The same identifier replaces the session's earlier notification.
        center.add(UNNotificationRequest(identifier: notice.sessionID, content: content, trigger: nil))
        delivered.insert(notice.sessionID)
    }

    func remove(_ sessionIDs: [String]) {
        let ids = sessionIDs.filter { delivered.remove($0) != nil || !listedDelivered }
        guard !ids.isEmpty, let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { open?(id) }
    }
}

extension AppModel {
    /// The notification for an announced moment, or nil: a snoozed session, a
    /// conversation on screen or a child's own result never notifies. A child's
    /// question surfaces under its parent's title and opens the child's card.
    func systemNotice(_ kind: NotchAnnouncement.Kind, sessionID: String, detail: String) -> SystemNotice? {
        guard kind != .hello, let session = sessions.first(where: { $0.id == sessionID }),
              session.snoozedUntil == nil, !isConversationOnScreen(sessionID) else { return nil }
        var title = session.title
        if let parentID = session.parentSessionID {
            guard kind == .needsInput, let parent = sessions.first(where: { $0.id == parentID }), parent.snoozedUntil == nil else { return nil }
            title = parent.title
        }
        return SystemNotice(sessionID: sessionID, title: title, subtitle: session.runtime.title + " · " + kind.verb,
                            body: String(detail.prefix(NotchAnnouncement.spokenLimit)))
    }
}

/// Off by default. Turning it on asks macOS; a denial says so and links to
/// System Settings → Notifications.
struct SystemNotificationsToggle: View {
    @ObservedObject var model: AppModel
    @ObservedObject var notifications = SystemNotifications.shared

    var body: some View {
        HStack(spacing: 10) {
            if notifications.enabled && notifications.denied {
                Button("Allow in System Settings") { model.openExternally(SystemNotifications.settingsURL) }
                    .buttonStyle(NotchPillButtonStyle(small: true))
                    .help("macOS notifications are off for Notch Companion. Allow them in System Settings → Notifications.")
            }
            Toggle("macOS notifications", isOn: $notifications.enabled).toggleStyle(NotchSwitchStyle())
        }
        .help("Post a notification when a session finishes, fails or needs you, unless you're reading it.")
        .task { await notifications.refreshAuthorization() }
    }
}
