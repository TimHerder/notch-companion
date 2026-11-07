import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [CompanionSession] = [] { didSet { glanceCache = nil; liveCache = nil; wakeSessionsThatNeedYou(since: oldValue) } }
    @Published var currentID: String? {
        didSet {
            // Leaving a session counts as seeing it, so it never archives the moment it stops being the selection.
            if let oldValue, oldValue != currentID { update(oldValue) { $0.lastSeenAt = Date() } }
            acknowledgeVisibleSession(); refreshConnection()
        }
    }
    @Published var expanded = false
    @Published var notchPresentation = NotchPresentation.restingPlaceholder
    @Published var composerFocusRequest = 0
    @Published var hovering = false
    @Published var openOnHover = UserDefaults.standard.object(forKey: "notch.openOnHover") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openOnHover, forKey: "notch.openOnHover") }
    }
    /// The hover glance is the presented tier (the full panel is `expanded`).
    @Published var glancing = false
    @Published var hoverPreview = HoverPreview(rawValue: UserDefaults.standard.string(forKey: HoverPreview.key) ?? "") ?? .glance {
        didSet { UserDefaults.standard.set(hoverPreview.rawValue, forKey: HoverPreview.key) }
    }
    /// Announcements and the edge aura for finished, failed, and waiting sessions.
    @Published var statusEffects = UserDefaults.standard.object(forKey: "notch.statusEffects") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(statusEffects, forKey: "notch.statusEffects")
            if !statusEffects { announcement = nil; panelToast = nil }
        }
    }
    /// Trackpad: swipe down on the notch to open, up to close.
    @Published var swipeGestures = UserDefaults.standard.object(forKey: "notch.swipeGestures") as? Bool ?? true {
        didSet { UserDefaults.standard.set(swipeGestures, forKey: "notch.swipeGestures") }
    }
    /// The resting notch's contour leans toward a nearby pointer.
    @Published var pointerPull = UserDefaults.standard.object(forKey: "notch.pointerPull") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pointerPull, forKey: "notch.pointerPull") }
    }
    @Published var notchPull = NotchPull()
    /// A working or waiting session shown in the resting band's right shoulder.
    @Published var liveActivityEnabled = UserDefaults.standard.object(forKey: LiveActivity.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveActivityEnabled, forKey: LiveActivity.enabledKey) }
    }
    /// A compact right-side announcement or a larger popup.
    @Published var updateStyle = NotchUpdateStyle.popup {
        didSet { preferences.set(updateStyle.rawValue, forKey: NotchUpdateStyle.key) }
    }
    @Published var companionAppearance = CompanionAppearance.mascot {
        didSet { preferences.set(companionAppearance.rawValue, forKey: CompanionAppearance.key) }
    }
    /// The host is presenting the current announcement on the popup stage.
    @Published var staging = false
    /// Which mascot Mascot brings; Pip's former users get Mote.
    @Published var mascotCharacter = MascotCharacter.mote {
        didSet { preferences.set(mascotCharacter.rawValue, forKey: MascotCharacter.key) }
    }
    var mascotLibrary: MascotLibrary { MascotLibrary.library(mascotCharacter) }
    /// A character whose sprites are not bundled falls back to the eyes.
    var mascotEnabled: Bool { companionAppearance == .mascot && mascotLibrary.isAvailable }
    @Published private(set) var announcement: NotchAnnouncement?
    /// Another session's result, named inside the open panel.
    @Published var panelToast: NotchAnnouncement?
    @Published var pointerOffset = CGSize.zero
    /// Set by the host after a quiet spell with nobody near; the eyes doze.
    @Published var drowsy = false
    @Published var eating = false
    @Published private(set) var attachmentFeedEvent = 0
    /// Counts the pointer touching the visible eyes or mascot; each one boops them.
    @Published var pokeEvent = 0
    @Published private(set) var fileDropChoice: FileDropChoice?
    @Published var geometry: NotchGeometry?
    @Published var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var connection = false
    @Published var connectionMessage = "Connects when you send a message."
    @Published var projectTrustSessionID: String?
    /// Finished turns whose work the user unfolded, shared by the notch and full window.
    @Published var expandedWork: Set<String> = []
    @Published var defaultRuntime: RuntimeKind = .hermes {
        didSet { preferences.set(defaultRuntime.rawValue, forKey: "runtime.default") }
    }
    @Published var showModelPicker = false {
        didSet { preferences.set(showModelPicker, forKey: "notch.showModelPicker") }
    }
    @Published var showContextUsage = false {
        didSet { preferences.set(showContextUsage, forKey: "notch.showContextUsage") }
    }
    @Published var showPermissionModes = false {
        didSet { preferences.set(showPermissionModes, forKey: "notch.showPermissionModes") }
    }
    @Published var showUsage = false {
        didSet { preferences.set(showUsage, forKey: "notch.showUsage") }
    }
    @Published var showSnapShot = false {
        didSet { preferences.set(showSnapShot, forKey: "notch.showSnapShot") }
    }
    /// The window that was in front when the notch last opened.
    @Published var snapShotSource: SnapShotSource?
    @Published var snapShotNeedsPermission = false
    /// Last reported account limits per runtime, kept across launches with their report times.
    @Published private(set) var rateLimits: [String: [RuntimeRateLimit]] = [:] {
        didSet { preferences.set(try? JSONEncoder().encode(rateLimits), forKey: "usage.rateLimits") }
    }
    @Published private(set) var rateLimitErrors: [String: String] = [:]
    @Published private(set) var refreshingRateLimits = false
    @Published var modelCatalogs: [ModelCatalogKey: RuntimeModelCatalog] = [:]
    @Published private(set) var loadingModelCatalogs: Set<ModelCatalogKey> = []
    @Published private(set) var modelCatalogErrors: [ModelCatalogKey: String] = [:]
    @Published var errorMessage: String?
    @Published var page: PanelPage = .session { didSet { acknowledgeVisibleSession() } }
    @Published var requests: [PendingRequest] = [] { didSet { glanceCache = nil; liveCache = nil } }
    @Published var submitting = false
    @Published var sessionSearch = ""
    @Published var sessionFilter: SessionFilter = .all
    @Published var autoArchiveAfter = SessionAutoArchive.halfDay {
        didSet { preferences.set(autoArchiveAfter.rawValue, forKey: SessionAutoArchive.key); glanceCache = nil }
    }
    /// The one session row whose inline actions are open.
    @Published var sessionActionsID: String? { didSet { snoozeChoicesShown = false } }
    /// That row shows its snooze choices in place of its actions.
    @Published var snoozeChoicesShown = false
    /// Sleeps until the earliest snoozed session's wake.
    var snoozeTimer: Task<Void, Never>?
    @Published private(set) var deferredOperation: DeferredOperation?
    @Published private(set) var answeringRequestIDs: Set<String> = []
    @Published private(set) var runtimeSettingsRevision = 0
    @Published private(set) var runtimeSettingsPending: Set<RuntimeKind> = []
    @Published private(set) var configuredRuntimeProfiles: [String: String] = [:]
    @Published var workspacePath: String = UserDefaults.standard.string(forKey: "workspacePath") ?? AppPaths.workspace.path
    var togglePanel: (() -> Void)?
    var dismissPanel: (() -> Void)?
    var activatePanel: (() -> Void)?
    var openFullSession: (() -> Void)?
    var dismissStage: (() -> Void)?
    var requestOpenPanel: (() -> Void)?
    var terminateApplication: (() -> Void)?
    /// Tests inject a choice without presenting native UI.
    var activeOperationDecision: ((DeferredOperation) -> ActiveOperationChoice)?
    var modelChangeDecision: ((String) -> Bool)?
    var fullAccessDecision: ((String) -> Bool)?
    var snapShotCapture: ((SnapShotSource, URL) async throws -> URL)?

    let client: any RuntimeTransport
    private var persistTask: Task<Void, Never>?
    private var changeRevisions: [String: UUID] = [:]
    private var changeTasks: [String: Task<Void, Never>] = [:]
    /// Each session's assistant message that opened its current native turn.
    private var nativeTurnStarts: [String: String] = [:]
    private var connecting = false
    private var connectGeneration = UUID()
    var lastCompletion: [String: Date] = [:]
    /// This turn's latest runtime notice per session: a failed turn's reason
    /// when its terminal event carries none (Codex, ACP).
    private var turnNotices: [String: String] = [:]
    private var notchSessionVisible = false
    private var fullSessionVisible = false
    private var fullConversationVisible = true
    let storageURL: URL
    private let playsSounds: Bool
    let preferences: UserDefaults
    private var persistenceBlocked = false
    private var deferredOperationTask: Task<Void, Never>?
    private var executingOperation = false
    private var showingOperationAlert = false
    private var submittingSessionID: String?
    /// Delegation sends to sessions other than the composer's.
    var backgroundSubmissions: Set<String> = []
    var backgroundSendErrors: [String: String] = [:]
    func isSubmitting(_ id: String) -> Bool { submittingSessionID == id || backgroundSubmissions.contains(id) }
    @Published var delegationEnabled = true {
        didSet { preferences.set(delegationEnabled, forKey: "delegation.enabled") }
    }
    let delegationServer = DelegationServer()
    /// Sessions blocked on a delegation wait, counted per open wait.
    @Published var delegationWaits: [String: Int] = [:]
    /// Sessions being waited on; their questions reach the waiter, not a notice.
    var delegationWaitTargets: [String: Int] = [:]
    /// Wakes (by child) and queued messages (by ID) whose send failed this run; retried after a restart.
    var failedDeliveries: Set<String> = []
    /// Parents whose running turn refused a steered wake; theirs wait for the turn to end.
    var steerRefused: Set<String> = []
    /// Child creations in flight by task ID, so a retry joins the first call.
    var delegationCreations: [String: (parentID: String, task: Task<String, Error>)] = [:]
    /// What a connected installation reported about hosting delegation (OpenCode 1.x cannot).
    var delegationHosting: [RuntimeRoute: Bool] = [:]
    var unfinishedParents: Set<String> = []
    /// Sessions whose adapter was sent a mode; Inherit then asks it to restore once.
    private var permissionOverrides: Set<String> = []
    var unfinishedChildren: [String: Set<String>] = [:]
    /// Views re-evaluate on every published pointer sample; derive glance
    /// text only when sessions or requests actually change.
    private var glanceCache: [GlanceEntry]?
    private var liveCache: LiveActivity??

    var current: CompanionSession? { sessions.first { $0.id == currentID } }
    var fileDropCurrentSession: CompanionSession? {
        guard let id = fileDropChoice?.currentSessionID else { return nil }
        return sessions.first { $0.id == id && !$0.isArchived }
    }
    var currentRequest: PendingRequest? { requests.first { $0.sessionID == current?.runtimeID } }
    var currentWorkspacePath: String { current?.workspacePath ?? workspacePath }
    var currentFailedAgent: ChildAgent? { current?.failedCurrentAgents.first }
    var hasActiveWork: Bool {
        // A detached historical input remains protected from retry, but there
        // is no owned frontend to interrupt. Live uncertain sends still count.
        submitting || !backgroundSubmissions.isEmpty || !delegationCreations.isEmpty
            || sessions.contains { $0.isBusy || ($0.pendingSubmission != nil && $0.runtimeID != nil) } || !unfinishedParents.isEmpty
            || unfinishedChildren.values.contains(where: { !$0.isEmpty })
            || sessions.contains { $0.runtime.isSupported && $0.pendingSubmission == nil && $0.queuedSends.contains { $0.isUserMessage && $0.paused != true } }
    }
    var visibleSessions: [CompanionSession] {
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        return topLevelSessions.filter { session in
            let matchesFilter: Bool
            switch sessionFilter {
            // A search covers every session, archived ones included.
            case .all: matchesFilter = !query.isEmpty || !(session.isArchived || session.snoozedUntil != nil || isAutoArchived(session, now: now))
            case .needsYou: matchesFilter = session.displayState == .waiting || session.hasUnreadFailure
            case .unread: matchesFilter = session.hasUnreadResult && !session.isBusy
            case .archived: matchesFilter = session.isArchived || isAutoArchived(session, now: now)
            case .snoozed: matchesFilter = session.snoozedUntil != nil
            }
            return matchesFilter && (query.isEmpty || session.title.localizedCaseInsensitiveContains(query)
                || session.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }))
        }
    }
    /// Archived by hand or by the auto-archive setting: what the Archived chip lists.
    var archivedCount: Int {
        let now = Date()
        return topLevelSessions.filter { $0.isArchived || isAutoArchived($0, now: now) }.count
    }
    /// Dormant sessions leave the default list; the selection and live work stay.
    func isAutoArchived(_ session: CompanionSession, now: Date = Date()) -> Bool {
        session.id != currentID && !isSubmitting(session.id) && !unfinishedParents.contains(session.id)
            && (unfinishedChildren[session.id]?.isEmpty ?? true) && session.isDormant(after: autoArchiveAfter.interval, now: now)
    }
    /// A session's project is its working folder; drafts without one use the default.
    func projectPath(of session: CompanionSession) -> String {
        URL(fileURLWithPath: session.workspacePath ?? workspacePath).standardizedFileURL.path
    }
    /// Visible sessions grouped by project, both in the stable session order.
    var visibleProjects: [SessionProject] {
        var projects: [SessionProject] = []
        for session in visibleSessions {
            let path = projectPath(of: session)
            if let index = projects.firstIndex(where: { $0.path == path }) { projects[index].sessions.append(session) }
            else { projects.append(SessionProject(path: path, sessions: [session])) }
        }
        return projects
    }
    var draft: String {
        get { current?.draft ?? "" }
        set { mutateCurrent { $0.draft = newValue }; scheduleSave() }
    }
    /// App-owned children appear only inside their parent, never as rows or indicators of their own.
    var topLevelSessions: [CompanionSession] { sessions.filter { $0.parentSessionID == nil } }
    var activeCount: Int { topLevelSessions.filter(\.isBusy).count }
    var collapsedStatus: CollapsedStatus { CollapsedStatus.resolve(sessions: noticedSessions) }
    var sessionIndicators: [SessionIndicator] { SessionIndicator.resolve(sessions: noticedSessions) }
    var unreadResultCount: Int { noticedSessions.filter { $0.hasUnreadResult && !$0.isBusy }.count }
    var glanceEntries: [GlanceEntry] {
        if let glanceCache { return glanceCache }
        // shortcut: cached until sessions change, so a session turning dormant meanwhile stays until then.
        let entries = SessionDigest.entries(sessions: noticedSessions.filter { !isAutoArchived($0) }, requests: requests)
        glanceCache = entries
        return entries
    }
    var glanceSummary: GlanceSummary { GlanceSummary(sessions: noticedSessions) }
    /// The working and waiting sessions' glyphs, when the setting allows it.
    var liveActivity: LiveActivity? {
        guard liveActivityEnabled else { return nil }
        if let liveCache { return liveCache }
        let activity = LiveActivity.resolve(sessions: topLevelSessions)
        liveCache = .some(activity)
        return activity
    }
    /// Resting dots: sessions shown in the live activity have none of their own.
    var restingIndicators: [SessionIndicator] {
        guard let geometry, geometry.showsLiveActivity else { return sessionIndicators }
        return sessionIndicators.filter { !geometry.liveSessionIDs.contains($0.id) }
    }
    var overallState: WorkState {
        if !requests.isEmpty { return .waiting }
        if activeCount > 0 { return .working }
        return current?.displayState ?? .idle
    }

    init(storageURL: URL = AppPaths.sessions, playsSounds: Bool = true, client: (any RuntimeTransport)? = nil,
         preferences: UserDefaults = .standard) {
        self.client = client ?? RuntimeRouter()
        self.storageURL = storageURL
        self.playsSounds = playsSounds
        self.preferences = preferences
        let savedUpdateStyle = preferences.string(forKey: NotchUpdateStyle.key)
        updateStyle = NotchUpdateStyle(rawValue: savedUpdateStyle ?? "") ?? (savedUpdateStyle == "shoulder" ? .compact : .popup)
        autoArchiveAfter = SessionAutoArchive(rawValue: preferences.string(forKey: SessionAutoArchive.key) ?? "") ?? .halfDay
        companionAppearance = CompanionAppearance(rawValue: preferences.string(forKey: CompanionAppearance.key) ?? "")
            ?? (updateStyle == .compact ? .eyes : .mascot)
        mascotCharacter = MascotCharacter(rawValue: preferences.string(forKey: MascotCharacter.key) ?? "") ?? .mote
        // Freeze the former combined choice before either independent setting changes.
        preferences.set(companionAppearance.rawValue, forKey: CompanionAppearance.key)
        preferences.set(updateStyle.rawValue, forKey: NotchUpdateStyle.key)
        configuredRuntimeProfiles = preferences.dictionary(forKey: "runtime.configuredProfiles") as? [String: String] ?? [:]
        defaultRuntime = RuntimeKind(rawValue: preferences.string(forKey: "runtime.default") ?? "hermes") ?? .hermes
        showModelPicker = preferences.object(forKey: "notch.showModelPicker") as? Bool ?? true
        showContextUsage = preferences.object(forKey: "notch.showContextUsage") as? Bool ?? true
        showPermissionModes = preferences.bool(forKey: "notch.showPermissionModes")
        showUsage = preferences.bool(forKey: "notch.showUsage")
        showSnapShot = preferences.bool(forKey: "notch.showSnapShot")
        rateLimits = preferences.data(forKey: "usage.rateLimits").flatMap { try? JSONDecoder().decode([String: [RuntimeRateLimit]].self, from: $0) } ?? [:]
        try? AppPaths.prepare()
        if let data = try? Data(contentsOf: storageURL), let saved = try? JSONDecoder().decode([CompanionSession].self, from: data) {
            let backup = storageURL.appendingPathExtension("before-runtimes")
            if !FileManager.default.fileExists(atPath: backup.path) {
                do { try data.write(to: backup, options: .withoutOverwriting); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path) }
                catch { persistenceBlocked = true; errorMessage = "Could not back up existing history: \(error.localizedDescription)" }
            }
            sessions = saved.map { session in
                var copy = session
                copy.runtimeID = nil
                for index in copy.queuedSends.indices where copy.queuedSends[index].isUserMessage { copy.queuedSends[index].paused = true }
                if copy.pendingSubmission == nil {
                    if copy.queuedSends.contains(where: { $0.id == copy.stagedSubmission?.message.id }) { copy.stagedSubmission = nil }
                    else { copy.restoreStagedSubmission() }
                }
                if copy.runtime == .opencode, !["opencode-http-v1", "opencode-http-v2"].contains(copy.runtimeInfo?.nativeInterface ?? ""),
                   copy.isBusy, copy.nativeActivityUnverified == nil {
                    copy.nativeActivityUnverified = "OpenCode was active when this frontend ended. Its ACP interface cannot verify background child completion. Continue the exact session in native OpenCode."
                }
                copy.messages.removeAll { $0.role == "assistant" && $0.questions == nil && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if copy.isBusy { copy.state = .interrupted }
                for index in copy.tools.indices where [.working, .waiting].contains(copy.tools[index].state) { copy.tools[index].state = .interrupted }
                for index in copy.agents.indices where [.working, .waiting].contains(copy.agents[index].state) { copy.agents[index].state = .interrupted }
                // A turn the quit cut short, or an older save's last one, keeps how it ended.
                copy.recordUnreportedOutcome()
                return copy
            }
        }
        if FileManager.default.fileExists(atPath: storageURL.path), sessions.isEmpty,
           (try? JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: storageURL))) == nil {
            persistenceBlocked = true
            errorMessage = "Existing session history could not be read. It has been left untouched; restore it before starting new work."
        }
        // Upgrade existing successful companion sessions without launching any
        // native runtime or treating an installation alone as configured.
        if preferences.object(forKey: "runtime.configuredProfiles") == nil {
            for session in sessions where !session.isLegacyPrivate && session.runtime.isSupported
                && session.storedID != nil && session.pendingSubmission == nil
                && session.messages.contains(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
                let profile = RuntimeRoute.defaultProfile(session.runtime, defaults: preferences)
                if session.route.profileID == profile { configuredRuntimeProfiles[session.runtime.rawValue] = profile }
            }
            preferences.set(configuredRuntimeProfiles, forKey: "runtime.configuredProfiles")
        }
        wakeDueSessions()
        currentID = sessions.first(where: { !$0.isArchived && $0.snoozedUntil == nil && $0.parentSessionID == nil })?.id ?? topLevelSessions.first?.id ?? sessions.first?.id
        if sessions.isEmpty { var session = CompanionSession(); session.runtime = newDraftRuntime; session.profileID = RuntimeRoute.defaultProfile(session.runtime, defaults: preferences); applyNativeWorkspace(to: &session); sessions = [session]; currentID = session.id }
        delegationEnabled = preferences.object(forKey: "delegation.enabled") as? Bool ?? true
        configureDelegation()
        self.client.onEvent = { [weak self] name, payload in self?.receive(name, payload: payload) }
        self.client.onConnectionChange = { [weak self] connected, message in
            guard let self else { return }
            if self.client is RuntimeRouter {
                self.refreshConnection()
            } else {
                self.connection = connected
                self.connectionMessage = connected ? "Runtime connected" : (message ?? "Runtime disconnected")
            }
            if !connected {
                self.unfinishedParents.removeAll()
                self.unfinishedChildren.removeAll()
                for session in self.sessions { self.delegationServer.revoke(sessionID: session.id) }
                for index in self.sessions.indices {
                    self.sessions[index].runtimeID = nil
                    if self.sessions[index].isBusy { self.sessions[index].state = .interrupted; self.sessions[index].recordUnreportedOutcome() }
                    for child in self.sessions[index].agents.indices where [.working, .waiting].contains(self.sessions[index].agents[child].state) { self.sessions[index].agents[child].state = .interrupted }
                    for tool in self.sessions[index].tools.indices where [.working, .waiting].contains(self.sessions[index].tools[tool].state) { self.sessions[index].tools[tool].state = .interrupted }
                }
                self.requests.removeAll()
                self.syncDelegatedChildren()
                self.scheduleSave()
                self.scheduleDeferredOperationIfIdle()
            }
        }
    }

    func connectionStatus(for runtime: RuntimeKind) -> (connected: Bool, message: String) {
        if let router = client as? RuntimeRouter { return router.status(RuntimeRoute(runtime: runtime, profileID: RuntimeRoute.defaultProfile(runtime, defaults: preferences))) }
        return (connection, connectionMessage)
    }

    var readyRuntimes: [RuntimeKind] {
        RuntimeKind.allCases.filter {
            !runtimeSettingsPending.contains($0)
                && configuredRuntimeProfiles[$0.rawValue] == RuntimeRoute.defaultProfile($0, defaults: preferences)
        }
    }

    var currentDraftNeedsSetup: Bool {
        current.map { canChangeRuntime($0.id) && !readyRuntimes.contains($0.runtime) } ?? true
    }

    private var newDraftRuntime: RuntimeKind {
        readyRuntimes.contains(defaultRuntime) ? defaultRuntime : readyRuntimes.first ?? defaultRuntime
    }

    /// The harness a new draft would use, or nil when none is set up yet.
    var newSessionRuntimeTitle: String? { readyRuntimes.isEmpty ? nil : newDraftRuntime.title }

    private func setRuntimeReady(_ runtime: RuntimeKind, ready: Bool) {
        let profile = RuntimeRoute.defaultProfile(runtime, defaults: preferences)
        guard ready ? configuredRuntimeProfiles[runtime.rawValue] != profile : configuredRuntimeProfiles[runtime.rawValue] != nil else { return }
        if ready { configuredRuntimeProfiles[runtime.rawValue] = profile }
        else { configuredRuntimeProfiles.removeValue(forKey: runtime.rawValue) }
        preferences.set(configuredRuntimeProfiles, forKey: "runtime.configuredProfiles")
    }

    func chooseReadyRuntime(_ runtime: RuntimeKind, for id: String) {
        guard readyRuntimes.contains(runtime) else { return }
        setRuntime(runtime, for: id)
    }

    var canAttemptSend: Bool { current?.runtime.isSupported == true && (client is RuntimeRouter || connection) }

    func isProjectTrusted(_ session: CompanionSession) -> Bool {
        !session.runtime.requiresProjectTrust || session.trustedProjectPath == URL(fileURLWithPath: session.workspacePath ?? workspacePath)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    func trustProjectAndSend() async {
        guard let id = projectTrustSessionID, id == currentID, let session = current else { return }
        update(id) { $0.trustedProjectPath = URL(fileURLWithPath: session.workspacePath ?? workspacePath).standardizedFileURL.resolvingSymlinksInPath().path }
        projectTrustSessionID = nil
        guard save() else { return }
        await send()
    }

    func connectRuntime(_ runtime: RuntimeKind) async {
        guard runtime.isSupported else { return }
        let generation = connectGeneration
        let revision = runtimeSettingsRevision
        do {
            if let router = client as? RuntimeRouter {
                try await router.connect(RuntimeRoute(runtime: runtime, profileID: RuntimeRoute.defaultProfile(runtime, defaults: preferences)))
            } else { await connect() }
            guard generation == connectGeneration, revision == runtimeSettingsRevision else { return }
            setRuntimeReady(runtime, ready: connectionStatus(for: runtime).connected)
            if let current, canChangeRuntime(current.id), !readyRuntimes.contains(current.runtime) {
                chooseReadyRuntime(runtime, for: current.id)
            }
            errorMessage = nil
        } catch {
            guard generation == connectGeneration, revision == runtimeSettingsRevision else { return }
            setRuntimeReady(runtime, ready: false)
            errorMessage = error.localizedDescription
        }
        refreshConnection()
    }

    func modelCatalogKey(for session: CompanionSession) -> ModelCatalogKey {
        ModelCatalogKey(route: session.route, cwd: session.workspacePath ?? workspacePath)
    }

    func loadModels(for key: ModelCatalogKey, refresh: Bool = false) async {
        guard !key.route.legacy, !loadingModelCatalogs.contains(key), refresh || modelCatalogs[key] == nil else { return }
        guard key.route.runtime.capabilities.modelSelection else {
            modelCatalogErrors[key] = "\(key.route.title) does not expose a native model chooser here. Its configured default is used."
            return
        }
        let trusted = sessions.contains { $0.route == key.route && modelCatalogKey(for: $0) == key && isProjectTrusted($0) }
        // Claude reads its catalog without loading an untrusted project's resources.
        guard !key.route.runtime.requiresProjectTrust || trusted || key.route.runtime == .claude else {
            modelCatalogErrors[key] = "Send a message and review project trust before loading this project's native hooks and models."
            return
        }
        loadingModelCatalogs.insert(key)
        modelCatalogErrors[key] = nil
        let generation = connectGeneration
        defer { if connectGeneration == generation { loadingModelCatalogs.remove(key) } }
        do {
            let result = try await client.request("runtime.models", params: ["runtime": key.route.runtime.rawValue,
                "profile_id": key.route.profileID, "cwd": key.cwd, "project_trusted": trusted])
            guard connectGeneration == generation else { return }
            guard let catalog = result["catalog"] as? RuntimeModelCatalog else { throw AppError("This runtime did not report its models.") }
            modelCatalogs[key] = catalog
            if let hosts = result["hosts_delegation"] as? Bool { delegationHosting[key.route] = hosts }
        } catch {
            if connectGeneration == generation { modelCatalogErrors[key] = "Models unavailable. \(error.localizedDescription)" }
        }
    }

    func canChangeModel(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return session.capabilities.modelSelection && isSettled(session)
    }

    /// Per-session choices wait for the parent, its children and any unresolved send.
    private func isSettled(_ session: CompanionSession) -> Bool {
        !session.isLegacyPrivate && !session.isBusy && session.pendingSubmission == nil && !isSubmitting(session.id)
            && !unfinishedParents.contains(session.id) && (unfinishedChildren[session.id]?.isEmpty ?? true)
    }

    func canChangePermissionMode(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return !session.capabilities.supportedPermissionModes.isEmpty && isSettled(session)
    }

    /// Nil returns to Inherit. Full access asks once per session.
    func setPermissionMode(_ mode: PermissionMode?, for id: String) {
        guard canChangePermissionMode(id), let session = sessions.first(where: { $0.id == id }),
              mode.map(session.capabilities.supportedPermissionModes.contains) ?? true else { return }
        if mode == .fullAccess, !session.fullAccessConfirmed {
            let message = "\(session.runtime.title) will edit files and run commands in this session without asking you first. It applies to the next message you send here."
            let confirmed: Bool
            if let fullAccessDecision { confirmed = fullAccessDecision(message) }
            else {
                let alert = NSAlert()
                alert.messageText = "Give this session full access?"
                alert.informativeText = message
                alert.addButton(withTitle: "Allow Full Access")
                alert.addButton(withTitle: "Cancel")
                alert.buttons.last?.keyEquivalent = "\u{1b}"
                confirmed = alert.runAboveNotch() == .alertFirstButtonReturn
            }
            guard confirmed else { return }
        }
        update(id) {
            $0.permissionMode = mode
            if mode == .fullAccess { $0.fullAccessConfirmed = true }
        }
        save()
    }

    func setModel(_ choice: RuntimeModelChoice?, for id: String) {
        guard canChangeModel(id), let session = sessions.first(where: { $0.id == id }) else { return }
        if let choice {
            let catalog = modelCatalogs[modelCatalogKey(for: session)]
            guard catalog?.contains(choice) == true else { return }
        } else if session.storedID != nil { return }
        update(id) { $0.modelOverride = choice }
        save()
    }

    private func applyModel(_ choice: RuntimeModelChoice, sessionID: String) async throws {
        var params: [String: Any] = ["session_id": sessionID, "model": choice.model]
        if let provider = choice.provider { params["provider"] = provider }
        if let effort = choice.reasoningEffort { params["reasoning_effort"] = effort }
        let result = try await client.request("session.model.set", params: params)
        if result["confirm_required"] as? Bool == true {
            let message = result["confirm_message"] as? String ?? result["warning"] as? String ?? "Hermes requires confirmation to use this model."
            let confirmed: Bool
            if let modelChangeDecision { confirmed = modelChangeDecision(message) }
            else {
                let alert = NSAlert()
                alert.messageText = "Use \(choice.model)?"
                alert.informativeText = message
                alert.addButton(withTitle: "Use Model and Send")
                alert.addButton(withTitle: "Cancel")
                alert.buttons.last?.keyEquivalent = "\u{1b}"
                confirmed = alert.runAboveNotch() == .alertFirstButtonReturn
            }
            guard confirmed else { throw ModelChangeCancelled() }
            params["confirmed"] = true
            let confirmedResult = try await client.request("session.model.set", params: params)
            guard confirmedResult["confirm_required"] as? Bool != true else { throw AppError("Hermes did not confirm the model change. Your message was not sent.") }
        }
    }

    /// Usage for ready runtimes that report limits. An explicit request: it may
    /// start Codex's app-server, but never a session or prompt.
    func refreshRateLimits(_ only: RuntimeKind? = nil) async {
        guard !refreshingRateLimits else { return }
        refreshingRateLimits = true
        defer { refreshingRateLimits = false }
        for runtime in readyRuntimes where runtime.capabilities.rateLimits == true && (only == nil || runtime == only) {
            do {
                let result = try await client.request("runtime.rateLimits", params: ["runtime": runtime.rawValue,
                    "profile_id": RuntimeRoute.defaultProfile(runtime, defaults: preferences)])
                rateLimitErrors[runtime.rawValue] = nil
                if let limits = result["limits"] as? [RuntimeRateLimit] { storeRateLimits(limits, runtime: runtime.rawValue) }
            } catch { rateLimitErrors[runtime.rawValue] = error.localizedDescription }
        }
    }

    /// Updates can carry one bucket; replace matching windows and keep the rest.
    private func storeRateLimits(_ limits: [RuntimeRateLimit], runtime: String) {
        guard !limits.isEmpty else { return }
        var merged = rateLimits[runtime] ?? []
        for limit in limits {
            if let index = merged.firstIndex(where: { $0.id == limit.id }) { merged[index] = limit } else { merged.append(limit) }
        }
        rateLimits[runtime] = merged
    }

    private func refreshConnection() {
        guard let router = client as? RuntimeRouter else { return }
        let status = router.status(current?.route ?? RuntimeRoute(runtime: defaultRuntime))
        connection = status.connected
        connectionMessage = status.message
    }

    func connect() async {
        guard !connecting else { return }
        connecting = true
        let generation = connectGeneration
        connectionMessage = "Connects when you send a message."
        defer { if connectGeneration == generation { connecting = false; refreshConnection() } }
        do {
            try await client.connect()
            guard connectGeneration == generation else { return }
            if !(client is RuntimeRouter) { connection = true; connectionMessage = "Runtime connected" }
        } catch { if connectGeneration == generation { connectionMessage = error.localizedDescription } }
    }

    func reconnect() async {
        await requestOperation(.reconnect)
    }

    func requestQuit() async { await requestOperation(.quit) }

    func cancelDeferredOperation() {
        deferredOperationTask?.cancel()
        deferredOperationTask = nil
        deferredOperation = nil
    }

    private func requestOperation(_ operation: DeferredOperation) async {
        guard !executingOperation, !showingOperationAlert else { return }
        guard hasActiveWork else { await performOperation(operation); return }
        showingOperationAlert = true
        let choice = activeOperationDecision?(operation) ?? presentActiveWorkAlert(operation)
        showingOperationAlert = false
        switch choice {
        case .whenFinished:
            cancelDeferredOperation()
            deferredOperation = operation
            scheduleDeferredOperationIfIdle()
        case .stopNow: await performOperation(operation)
        case .cancel: break
        }
    }

    private func presentActiveWorkAlert(_ operation: DeferredOperation) -> ActiveOperationChoice {
        let alert = NSAlert()
        alert.messageText = "Your agents are still working"
        alert.informativeText = "\(operation.title) stops this app's active sessions and delegated agents. You can wait for all work to finish or stop it now."
        alert.addButton(withTitle: "When Work Finishes")
        alert.addButton(withTitle: "Stop and \(operation.title)")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        switch alert.runAboveNotch() {
        case .alertFirstButtonReturn: return .whenFinished
        case .alertSecondButtonReturn: return .stopNow
        default: return .cancel
        }
    }

    private func performOperation(_ operation: DeferredOperation) async {
        guard !executingOperation else { return }
        executingOperation = true
        cancelDeferredOperation()
        defer { executingOperation = false }
        switch operation {
        case .reconnect:
            cancelDelegationPreparations()
            connectGeneration = UUID()
            connecting = false
            modelCatalogs.removeAll()
            modelCatalogErrors.removeAll()
            loadingModelCatalogs.removeAll()
            client.disconnect()
            connection = false
            runtimeSettingsPending.removeAll()
            await connect()
            if showModelPicker, let current { await loadModels(for: modelCatalogKey(for: current)) }
        case .quit:
            terminateApplication?()
        }
    }

    func scheduleDeferredOperationIfIdle() {
        deferredOperationTask?.cancel()
        deferredOperationTask = nil
        guard let operation = deferredOperation, !hasActiveWork, !executingOperation else { return }
        // Coalesce the parent's terminal event with immediately following child
        // lifecycle events. Recheck all tracked work before touching the runtime.
        deferredOperationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled, self.deferredOperation == operation, !self.hasActiveWork else { return }
            await self.performOperation(operation)
        }
    }

    func shutdown() {
        cancelDelegationPreparations()
        connectGeneration = UUID(); connecting = false; cancelDeferredOperation()
        changeTasks.values.forEach { $0.cancel() }; changeTasks.removeAll()
        persistTask?.cancel(); snoozeTimer?.cancel(); save(); client.disconnect(); delegationServer.stop()
    }

    /// `workspace` starts the draft in a project's folder instead of the default.
    func newSession(showPanel: Bool = true, runtime: RuntimeKind? = nil, workspace: String? = nil) async {
        createDraftSession(showPanel: showPanel, runtime: runtime, workspace: workspace)
    }

    private func createDraftSession(showPanel: Bool, runtime: RuntimeKind? = nil, workspace: String? = nil) {
        var session = CompanionSession()
        session.workspacePath = workspace
        session.runtime = runtime ?? newDraftRuntime
        session.profileID = RuntimeRoute.defaultProfile(session.runtime, defaults: preferences)
        applyNativeWorkspace(to: &session)
        sessions.insert(session, at: 0)
        currentID = session.id
        page = .session
        sessionFilter = .all
        sessionSearch = ""
        errorMessage = nil
        projectTrustSessionID = nil
        refreshConnection()
        if showPanel { requestOpenPanel?() }
        save()
    }

    func selectSession(_ id: String) {
        // Opening a session restarts its auto-archive clock; the selection itself never auto-archives.
        update(id) { $0.lastSeenAt = Date() }
        scheduleSave()
        currentID = id; page = .session; errorMessage = nil
        projectTrustSessionID = nil
        refreshConnection()
    }

    /// A glance row or an announced band opens that conversation for input.
    func openSessionFromNotch(_ id: String) {
        guard sessions.contains(where: { $0.id == id }) else { activatePanel?(); return }
        selectSession(id)
        sessionActionsID = nil
        activatePanel?()
    }

    /// The glance's New session opens a ready draft for typing. An untouched
    /// draft is reused, so repeated hovers cannot pile up empty sessions.
    func startSessionFromNotch() {
        if let draft = sessions.first(where: { $0.messages.isEmpty && $0.storedID == nil && $0.runtimeID == nil && !$0.isArchived
            && $0.draft.isEmpty && $0.attachments.isEmpty && $0.pendingSubmission == nil && canChangeRuntime($0.id) }) {
            selectSession(draft.id)
            sessionActionsID = nil
        } else {
            createDraftSession(showPanel: false)
        }
        activatePanel?()
    }

    /// The open panel is showing this session's conversation.
    func isReading(_ id: String) -> Bool { expanded && page == .session && currentID == id }

    func openPanelToast() {
        guard let toast = panelToast else { return }
        panelToast = nil
        openSessionFromNotch(toast.sessionID)
    }

    /// Clicking the band while it names a session opens that session.
    func openAnnouncedSession() {
        if let announcement, notchPresentation.announce > 0.5 || notchPresentation.stage > 0.5 {
            clearAnnouncement(announcement.id)
            openSessionFromNotch(announcement.sessionID)
        } else {
            activatePanel?()
        }
    }

    func clearAnnouncement(_ id: UUID) {
        guard announcement?.id == id else { return }
        let welcomePreview = announcement?.sessionID == Self.previewAnnouncementID && page.isWelcome
        announcement = nil
        // The welcome's update preview hands back to the step it came from.
        if welcomePreview { activatePanel?() }
    }

    /// Settings demonstrates the effect on the resting notch: the panel closes
    /// first so the band and its edge light are visible. No session changes.
    func previewStatusEffect(_ kind: NotchAnnouncement.Kind = .finished, title: String = "Status effects preview") {
        guard statusEffects else { return }
        dismissPanel?()
        announcement = NotchAnnouncement(kind: kind, sessionID: Self.previewAnnouncementID, title: title,
                                         detail: "Finished sessions, questions and failures appear here.")
    }
    static let previewAnnouncementID = "notch.preview"
    static let helloAnnouncementID = "notch.hello"
    /// Set once the first launch has welcomed someone (formerly its hello).
    static let welcomeKey = "notch.welcomed"

    /// A new user's first launch opens the welcome in the notch. Anyone with
    /// conversations already knows the way; Settings can replay it.
    func welcomeIfFirstLaunch() {
        guard !preferences.bool(forKey: Self.welcomeKey), announcement == nil, !expanded, !glancing else { return }
        preferences.set(true, forKey: Self.welcomeKey)
        guard sessions.allSatisfy({ $0.messages.isEmpty && $0.storedID == nil }) else { return }
        page = .welcome(step: 0)
        activatePanel?()
    }

    /// The welcome's agent becomes the default and the untouched draft's harness.
    func chooseWelcomeRuntime(_ runtime: RuntimeKind) {
        defaultRuntime = runtime
        if let currentID { setRuntime(runtime, for: currentID) }
    }

    /// Leaving the welcome closes the panel and waves from the band, in the
    /// chosen updates and look, to show where to hover.
    func finishWelcome() {
        page = .session
        dismissPanel?()
        guard statusEffects else { return }
        announcement = Self.helloAnnouncement
    }
    static var helloAnnouncement: NotchAnnouncement {
        NotchAnnouncement(kind: .hello, sessionID: helloAnnouncementID, title: "Hi!", detail: "Hover here to begin")
    }

    /// Offscreen fixtures show a specific announcement without runtime events.
    func setAnnouncementForPreview(_ value: NotchAnnouncement?) { announcement = value }

    /// Snapshots the message with the moment, so the band and stage keep
    /// saying what happened even if the session moves on during the hold.
    func announce(_ kind: NotchAnnouncement.Kind, sessionID: String, failure: String = "") {
        guard statusEffects, let session = sessions.first(where: { $0.id == sessionID }) else { return }
        // The same request the detail snapshots: an approval's detail is its command.
        let request = requests.first { $0.sessionID == session.runtimeID }
        announcement = NotchAnnouncement(kind: kind, sessionID: sessionID, title: session.title,
                                         detail: SessionDigest.announcementDetail(kind, session: session, requests: requests, failure: failure),
                                         worked: SessionDigest.turnStart(session).map { Date().timeIntervalSince($0) },
                                         isApproval: kind == .needsInput && session.nativeActivityUnverified == nil
                                            && request?.kind == .approval && !SessionDigest.oneLine(request?.detail ?? "").isEmpty)
    }

    func canChangeRuntime(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return session.storedID == nil && session.runtimeID == nil && session.messages.isEmpty && session.pendingSubmission == nil
            && !session.nativeSubmissionAttempted && !session.isBusy && !session.isLegacyPrivate && !isSubmitting(id)
    }

    func setRuntime(_ runtime: RuntimeKind, for id: String) {
        guard runtime.isSupported, canChangeRuntime(id), sessions.first(where: { $0.id == id })?.runtime != runtime else { return }
        update(id) { $0.runtime = runtime; $0.profileID = RuntimeRoute.defaultProfile(runtime, defaults: preferences); $0.modelOverride = nil; $0.permissionMode = nil; $0.fullAccessConfirmed = false; $0.runtimeInfo = nil; $0.trustedProjectPath = nil; applyNativeWorkspace(to: &$0) }
        projectTrustSessionID = nil
        refreshConnection()
        save()
    }

    /// Explicit copy-forward, never an ID rewrite or database import. The old
    /// conversation remains resumable; context is visibly staged, not sent.
    func continueLegacySession(_ id: String) async {
        guard let original = sessions.first(where: { $0.id == id }), original.isLegacyPrivate,
              !original.isBusy, original.pendingSubmission == nil, !isSubmitting(id),
              !unfinishedParents.contains(id), unfinishedChildren[id]?.isEmpty ?? true else { return }
        do {
            let contextDirectory = storageURL.deletingLastPathComponent().appendingPathComponent("Migration Context", isDirectory: true)
            try FileManager.default.createDirectory(at: contextDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let contextURL = contextDirectory.appendingPathComponent("Hermes conversation \(UUID().uuidString).txt")
            var sections = ["Prior private Hermes conversation: \(original.title)", "Reference context from a separate conversation. Continue only when instructed by the user's new message."]
            sections += original.messages.filter(SessionHistory.isVisibleConversation).map { "\($0.role.uppercased())\n\($0.text)" }
            sections += original.tools.map { "TOOL \($0.name) [\($0.state.rawValue)]\n\($0.detail)\n\($0.output)" }
            sections += original.agents.map { "DELEGATED: \($0.title) [\($0.state.rawValue)]\n\($0.text)" }
            try Data(sections.joined(separator: "\n\n").utf8).write(to: contextURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contextURL.path)
            var next = CompanionSession()
            next.title = original.title + " · Continued"
            next.runtime = .hermes
            next.profileID = RuntimeRoute.defaultProfile(.hermes)
            next.workspacePath = original.workspacePath
            next.draft = original.draft
            next.attachments = original.attachments + [Attachment(url: contextURL)]
            next.migratedFromSessionID = original.id
            sessions.insert(next, at: 0)
            selectSession(next.id)
            composerFocusRequest += 1
            save()
        } catch { errorMessage = "Could not prepare the conversation context: \(error.localizedDescription)" }
    }

    func renameSession(_ id: String, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(id) { $0.title = String(title.prefix(160)) }
        save()
    }

    func canArchiveSession(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return !session.isBusy && session.pendingSubmission == nil && !session.isArchived && !isSubmitting(id)
            && !unfinishedParents.contains(id) && (unfinishedChildren[id]?.isEmpty ?? true)
    }

    func archiveSession(_ id: String) {
        guard canArchiveSession(id) else { return }
        update(id) { $0.isArchived = true; $0.snoozedUntil = nil }
        if currentID == id {
            page = .sessions
        }
        save()
    }

    /// Also brings back an auto-archived session by restarting its clock.
    func restoreSession(_ id: String) {
        update(id) { $0.isArchived = false; $0.lastSeenAt = Date() }
        save()
    }

    func openFailedAgent() {
        guard let child = currentFailedAgent else { return }
        page = .agent(child.id)
    }

    func markAllAsRead() {
        var acknowledged = sessions
        var changed = false
        for index in acknowledged.indices {
            if acknowledged[index].acknowledgeResult() { changed = true }
        }
        guard changed else { return }
        sessions = acknowledged
        persistTask?.cancel()
        persistTask = nil
        save()
    }

    // NativeHost reports a settled preview or an active full-session window.
    // A stored selection alone does not mean its response or failure was viewed.
    func setSessionVisibility(notchVisible: Bool? = nil, fullSessionVisible: Bool? = nil, fullConversationVisible: Bool? = nil) {
        if let notchVisible { notchSessionVisible = notchVisible }
        if let fullSessionVisible { self.fullSessionVisible = fullSessionVisible }
        if let fullConversationVisible { self.fullConversationVisible = fullConversationVisible }
        acknowledgeVisibleSession()
    }

    private func acknowledgeVisibleSession() {
        guard (notchSessionVisible && page == .session && fileDropChoice == nil)
                || (fullSessionVisible && fullConversationVisible && !page.isRuntimeSetup),
              let currentID, let index = sessions.firstIndex(where: { $0.id == currentID }),
              sessions[index].acknowledgeResult() else { return }
        scheduleSave()
    }

    func deleteSession(_ id: String) {
        // App-owned children go with their parent; their native histories stay.
        let removed = Set([id] + delegatedDescendants(of: id))
        guard sessions.contains(where: { $0.id == id }),
              sessions.filter({ removed.contains($0.id) }).allSatisfy({ session in
                  !session.isBusy && session.pendingSubmission == nil && !isSubmitting(session.id)
                      && !unfinishedParents.contains(session.id) && (unfinishedChildren[session.id]?.isEmpty ?? true)
              }) else { return }
        sessions.removeAll { removed.contains($0.id) }
        removed.forEach(delegationServer.revoke)
        if currentID.map(removed.contains) == true { currentID = topLevelSessions.first?.id ?? sessions.first?.id }
        if topLevelSessions.isEmpty { var fresh = CompanionSession(); fresh.runtime = defaultRuntime; fresh.profileID = RuntimeRoute.defaultProfile(fresh.runtime, defaults: preferences); applyNativeWorkspace(to: &fresh); sessions.append(fresh); currentID = fresh.id }
        save()
    }

    /// Store only a location. Applying it never interrupts work; Reconnect
    /// retains the existing wait/stop/cancel policy.
    func setRuntimeLocation(_ setting: RuntimeLocation, path: String?, defaults: UserDefaults = .standard) throws {
        let selected = try path.map { try setting.validate($0) }
        guard selected != setting.saved(in: defaults) else { return }
        if let selected { defaults.set(selected, forKey: setting.rawValue) }
        else { defaults.removeObject(forKey: setting.rawValue) }
        // Limits belong to the account behind the old profile.
        if setting.isProfile { rateLimits.removeValue(forKey: setting.runtime.rawValue) }
        if setting.isProfile, let session = current, session.runtime == setting.runtime, canChangeRuntime(session.id) {
            let profile = RuntimeRoute.defaultProfile(setting.runtime, defaults: defaults)
            update(session.id) {
                if $0.profileID != profile { $0.modelOverride = nil; $0.runtimeInfo = nil; $0.trustedProjectPath = nil }
                $0.profileID = profile
                applyNativeWorkspace(to: &$0)
            }
            save()
        }
        runtimeSettingsPending.insert(setting.runtime)
        setRuntimeReady(setting.runtime, ready: false)
        runtimeSettingsRevision += 1
        refreshConnection()
    }

    func applyNativeWorkspace(to session: inout CompanionSession) {
        guard session.runtime == .openclaw else { return }
        let identity = RuntimeProfileIdentity.decodeOpenClaw(session.route.profileID)
        if let workspace = try? OpenClawConfiguration.workspace(profileID: identity.directory, agent: identity.agent) {
            session.workspacePath = workspace
        }
    }

    func setOpenClawAgent(_ agent: String) {
        let identity = RuntimeProfileIdentity.decodeOpenClaw(RuntimeRoute.defaultProfile(.openclaw, defaults: preferences))
        guard (try? OpenClawConfiguration.configuredAgents(profileID: identity.directory))?.contains(agent) == true else { return }
        preferences.set(agent, forKey: "runtime.openclaw.agent")
        if let session = current, session.runtime == .openclaw, canChangeRuntime(session.id) {
            update(session.id) {
                $0.profileID = RuntimeProfileIdentity.openClaw(directory: identity.directory, agent: agent)
                $0.modelOverride = nil; $0.runtimeInfo = nil
                applyNativeWorkspace(to: &$0)
            }
            save()
        }
        runtimeSettingsRevision += 1
        refreshConnection()
    }

    /// The notch sits at status-bar level, above ordinary panels. Run pickers
    /// above it; while one is modal the notch ignores outside clicks.
    private func runPicker(_ picker: NSOpenPanel) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let raising = picker.keepAboveNotch()
        defer { raising.invalidate() }
        return picker.runModal()
    }

    func chooseRuntimeLocation(_ setting: RuntimeLocation) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = setting.isDirectory
        picker.canChooseFiles = !setting.isDirectory
        picker.treatsFilePackagesAsDirectories = !setting.isDirectory
        picker.canCreateDirectories = false
        picker.showsHiddenFiles = true
        picker.allowsMultipleSelection = false
        picker.prompt = "Use location"
        picker.message = setting.explanation
        if let path = setting.saved() {
            let url = URL(fileURLWithPath: path)
            picker.directoryURL = setting.isDirectory ? url : url.deletingLastPathComponent()
        }
        guard runPicker(picker) == .OK, let url = picker.url else { return }
        do { try setRuntimeLocation(setting, path: url.path); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func resetRuntimeLocation(_ setting: RuntimeLocation) {
        do { try setRuntimeLocation(setting, path: nil); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func folderPicker(_ message: String, from path: String) -> NSOpenPanel {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Use folder"; picker.message = message
        picker.directoryURL = URL(fileURLWithPath: path)
        return picker
    }

    func chooseWorkspace() {
        let picker = folderPicker("Working folder for new sessions", from: workspacePath)
        if runPicker(picker) == .OK, let url = picker.url {
            workspacePath = url.path
            UserDefaults.standard.set(workspacePath, forKey: "workspacePath")
        }
    }

    /// A project is a folder: it appears with its first session, which starts there.
    func addProject(showPanel: Bool = true) {
        let picker = folderPicker("Project folder. Its new sessions start here.", from: workspacePath)
        guard runPicker(picker) == .OK, let url = picker.url else { return }
        createDraftSession(showPanel: showPanel, workspace: url.standardizedFileURL.path)
    }

    /// A draft's folder can change until its native session exists. OpenClaw
    /// uses the workspace configured for its native agent.
    var canChooseCurrentWorkspace: Bool {
        current.map { canChangeRuntime($0.id) && $0.runtime != .openclaw } ?? false
    }

    func chooseSessionWorkspace() {
        guard let session = current, canChooseCurrentWorkspace else { return }
        let picker = folderPicker("Working folder for this session", from: session.workspacePath ?? workspacePath)
        guard runPicker(picker) == .OK, let url = picker.url, canChangeRuntime(session.id) else { return }
        // Project trust and model catalogs are per folder, so both follow it.
        update(session.id) { $0.workspacePath = url.standardizedFileURL.path }
        if projectTrustSessionID == session.id { projectTrustSessionID = nil }
        save()
    }

    /// Open a file, folder or link in its own app. The notch collapses so the
    /// opened window is not hidden beneath it.
    func openExternally(_ url: URL, reveal: Bool = false) {
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url) }
        if expanded { dismissPanel?() }
    }

    private(set) lazy var codeEditor: URL? = {
        if let path = preferences.string(forKey: "changes.editor"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode"]
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }()

    var codeEditorName: String {
        guard let codeEditor else { return "Editor…" }
        return codeEditor.deletingPathExtension().lastPathComponent == "Visual Studio Code" ? "VS Code" : codeEditor.deletingPathExtension().lastPathComponent
    }

    func openInCodeEditor(_ url: URL, choose: Bool = false) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "This file or folder no longer exists. Open the project to review its current state."
            return
        }
        var application = codeEditor
        if choose || application == nil {
            let picker = NSOpenPanel()
            picker.title = "Choose your code editor"
            picker.prompt = "Open"
            picker.allowedContentTypes = [.application]
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
            guard runPicker(picker) == .OK, let selected = picker.url else { return }
            application = selected
            codeEditor = selected
            preferences.set(selected.path, forKey: "changes.editor")
            objectWillChange.send()
        }
        guard let application else { return }
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.errorMessage = "Could not open the editor: \(error.localizedDescription)" }
                else if self?.expanded == true { self?.dismissPanel?() }
            }
        }
    }

    func pickFiles(showPanel: Bool = true) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false; picker.canChooseFiles = true
        picker.allowsMultipleSelection = true; picker.prompt = "Attach"
        if runPicker(picker) == .OK { addAttachments(picker.urls, showPanel: showPanel) }
    }

    func updateFileDrop(at point: CGPoint, fileCount: Int) {
        var choice = fileDropChoice ?? FileDropChoice(currentSessionID: current?.isArchived == false ? currentID : nil,
                                                      fileCount: fileCount)
        choice.fileCount = fileCount
        if fileDropChoice == nil { fileDropChoice = choice }
        choice.destination = fileDropDestination(at: point)
        if choice != fileDropChoice { fileDropChoice = choice }
    }

    func endFileDrop() { fileDropChoice = nil }

    func fileDropDestination(at point: CGPoint) -> FileDropDestination? {
        guard fileDropChoice != nil, expanded, notchPresentation.progress == 1,
              notchPresentation.contains(point) else { return nil }
        return FileDropLayout(size: notchPresentation.size, headerHeight: notchPresentation.bandHeight)
            .destination(at: point, hasCurrentSession: fileDropCurrentSession != nil)
    }

    /// Resolve and attach synchronously so another window cannot redirect the
    /// drop between the user's choice and session creation. No runtime request.
    func acceptFileDrop(_ urls: [URL]) -> Bool {
        guard let choice = fileDropChoice, let destination = choice.destination,
              !FileAttachmentValidation.readableFiles(urls).isEmpty else { return false }
        switch destination {
        case .currentSession:
            guard let session = fileDropCurrentSession else { return false }
            selectSession(session.id)
        case .newSession:
            createDraftSession(showPanel: false)
        }
        let accepted = addAttachments(urls, showPanel: false)
        if accepted { endFileDrop() }
        return accepted
    }

    @discardableResult
    func addAttachments(_ urls: [URL], showPanel: Bool = true) -> Bool {
        let readable = FileAttachmentValidation.readableFiles(urls)
        guard !readable.isEmpty, current != nil else {
            errorMessage = "Choose a readable file. Folders cannot be attached."
            return false
        }
        let accepted = readable.filter { url in
            !(current?.attachments.contains { $0.url.standardizedFileURL == url.standardizedFileURL } ?? false)
        }
        mutateCurrent { session in session.attachments.append(contentsOf: accepted.map { Attachment(url: $0) }) }
        attachmentFeedEvent += 1
        eating = true
        play(.attach)
        if showPanel { requestOpenPanel?() }
        page = .session
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.eating = false
        }
        save()
        return true
    }

    func removeAttachment(_ id: UUID) {
        let removed = current?.attachments.first { $0.id == id }
        mutateCurrent { $0.attachments.removeAll { $0.id == id } }; save()
        // A SnapShot exists only for its unsent draft.
        if let url = removed?.url, url.deletingLastPathComponent().standardizedFileURL == snapShotDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Kept beside the registry so pictures survive until they are sent.
    var snapShotDirectory: URL { storageURL.deletingLastPathComponent().appendingPathComponent("SnapShots", isDirectory: true) }

    /// Called as the panel opens, before it can take focus.
    func recordSnapShotSource() { snapShotSource = showSnapShot ? SnapShot.frontmost() : nil }

    /// Stages a picture of the recorded window in the current draft. Never sends.
    func attachSnapShot() async {
        guard showSnapShot, let target = currentID, current?.capabilities.images == true else { return }
        guard let source = snapShotSource else { errorMessage = "Open the notch from the window you want to attach."; return }
        if snapShotCapture == nil, !CGPreflightScreenCaptureAccess() {
            // macOS asks only the first time; afterwards the hint links to System Settings.
            snapShotNeedsPermission = !CGRequestScreenCaptureAccess()
            guard !snapShotNeedsPermission else { return }
        }
        do {
            let url = try await (snapShotCapture ?? SnapShot.capture)(source, snapShotDirectory)
            snapShotNeedsPermission = false
            guard currentID == target else { try? FileManager.default.removeItem(at: url); return }
            addAttachments([url], showPanel: false)
        } catch { errorMessage = "Could not capture \(source.name). \(error.localizedDescription)" }
    }

    func send(queue: Bool = false) async {
        guard let session = current else { return }
        if session.pendingSubmission != nil {
            if !session.isBusy { await submit(reply: nil); processDelegationWakes() }
            else { errorMessage = "Wait for this turn to finish, then check the last send before sending more input." }
        } else if session.isBusy || session.queuedSends.contains(where: { $0.paused != true }) {
            if queue { enqueueDraft() }
            else { await steerDraft() }
        } else { await submit(reply: nil) }
    }

    private func enqueueDraft() {
        guard let session = current, !isSubmitting(session.id), !submitting,
              !persistenceBlocked, session.runtime.isSupported, session.pendingSubmission == nil,
              session.nativeActivityUnverified == nil else { return }
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let queued = QueuedSend(id: UUID().uuidString, text: text, attachments: session.attachments)
        update(session.id) { $0.queuedSends.append(queued); $0.draft = ""; $0.attachments = [] }
        guard save() else {
            update(session.id) { $0.queuedSends.removeAll { $0.id == queued.id }; $0.draft = session.draft; $0.attachments = session.attachments }
            return
        }
        play(.send)
        processDelegationWakes()
    }

    func cancelQueuedSend(_ id: String) {
        guard let session = current, !isSubmitting(session.id) else { return }
        update(session.id) { $0.queuedSends.removeAll { $0.id == id && $0.isUserMessage } }
        guard save() else { update(session.id) { $0.queuedSends = session.queuedSends }; return }
        processDelegationWakes()
        scheduleDeferredOperationIfIdle()
    }

    func resumeQueuedSends() {
        guard let session = current, !isSubmitting(session.id) else { return }
        for send in session.queuedSends where send.isUserMessage { failedDeliveries.remove(send.id) }
        update(session.id) { target in
            for i in target.queuedSends.indices where target.queuedSends[i].isUserMessage { target.queuedSends[i].paused = false }
        }
        guard save() else { pauseQueuedSends(session.id); return }
        processDelegationWakes()
    }

    func pauseQueuedSends(_ id: String) {
        update(id) { target in
            for i in target.queuedSends.indices where target.queuedSends[i].isUserMessage { target.queuedSends[i].paused = true }
        }
    }

    private func steerDraft() async {
        guard let session = current, !isSubmitting(session.id), !submitting else { return }
        guard session.canSteer, let sid = session.runtimeID else {
            errorMessage = "This session cannot accept steering now. Use Command–Return to queue your message."
            return
        }
        guard !persistenceBlocked else { return }
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = UUID().uuidString
        let message = ChatMessage(id: id, role: "user", text: text + (session.attachments.isEmpty ? "" : "\n\nAttached: " + session.attachments.map(\.name).joined(separator: ", ")),
                                  turnID: session.latestUserTurnID ?? id)
        submitting = true
        submittingSessionID = session.id
        defer { submitting = false; submittingSessionID = nil; processDelegationWakes(); scheduleDeferredOperationIfIdle() }
        update(session.id) {
            $0.stagedSubmission = StagedSubmission(message: message, draft: session.draft, attachments: session.attachments)
            $0.draft = ""; $0.attachments = []
        }
        guard save() else { update(session.id) { $0.restoreStagedSubmission() }; return }
        var requested = false
        do {
            var references: [String] = []
            for file in session.attachments where !file.isImage {
                let result = try await client.request("file.attach", params: ["session_id": sid, "path": file.url.path])
                guard let reference = result["ref_text"] as? String else { throw BusyInputRejection(message: "The attachment could not be prepared.") }
                references.append(reference)
            }
            guard sessions.first(where: { $0.id == session.id })?.canSteer == true else {
                throw BusyInputRejection(message: "The turn finished before steering. Your message is back in the composer.")
            }
            update(session.id) {
                $0.messages.append(message)
                $0.pendingSubmission = PendingSubmission(id: id, draft: session.draft,
                    userTurnCount: $0.messages.filter { $0.role == "user" && SessionHistory.isVisibleConversation($0) }.count,
                    attachmentIDs: session.attachments.map(\.id), isSteering: true)
            }
            guard save() else { throw BusyInputRejection(message: "The send could not be saved. No steering was sent.") }
            requested = true
            _ = try await client.request("prompt.steer", params: ["session_id": sid, "turn_id": id,
                "text": ([text] + references).joined(separator: "\n\n"), "images": session.attachments.filter(\.isImage).map { $0.url.path }])
            confirmSubmission(session.id, includingSteering: true)
            errorMessage = nil
            play(.send)
        } catch {
            if !requested || Self.definitiveRejection(error) {
                update(session.id) {
                    $0.messages.removeAll { $0.id == id }; $0.pendingSubmission = nil; $0.restoreStagedSubmission()
                }
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Steering delivery is unconfirmed. Wait for this turn to finish, then use Check last send before retrying."
            }
        }
        save()
    }

    /// Answer a non-blocking question with an ordinary next message. The
    /// composer's draft and staged files stay for a later message.
    @discardableResult
    func replyToQuestions(_ questions: [AsyncQuestion], answers: [String]) async -> Bool {
        let text = AsyncQuestion.reply(questions, answers: answers)
        guard !text.isEmpty else { return false }
        return await submit(reply: text)
    }

    /// True once the runtime accepted the message. With `target`, a background
    /// send for delegation: it leaves the composer, page and banner alone,
    /// reports failures in `backgroundSendErrors`, and live app-owned
    /// children do not block it.
    @discardableResult
    func submit(reply: String?, target: String? = nil, kind: String? = nil, turnID fixedTurnID: String? = nil, queuedAttachments: [Attachment]? = nil) async -> Bool {
        let background = target != nil
        guard let localID = target ?? currentID, let session = sessions.first(where: { $0.id == localID }) else { return false }
        guard !(background ? session.isBusyIgnoringDelegates : session.isBusy), !(background ? isSubmitting(localID) : submitting || isSubmitting(localID)),
              !unfinishedParents.contains(localID), unfinishedChildren[localID]?.isEmpty ?? true else {
            if background { backgroundSendErrors[localID] = "The session is still working." }
            return false
        }
        var errorMessage: String? {
            get { background ? backgroundSendErrors[localID] : self.errorMessage }
            set { if background { backgroundSendErrors[localID] = newValue } else { self.errorMessage = newValue } }
        }
        backgroundSendErrors.removeValue(forKey: localID)
        guard !persistenceBlocked else { errorMessage = "Restore the saved session registry before sending."; return false }
        guard session.runtime.isSupported else { errorMessage = session.runtime.capabilityNote; return false }
        guard isProjectTrusted(session) else {
            if background { errorMessage = "Trust this project for \(session.runtime.title) in Notch Companion first."; return false }
            projectTrustSessionID = localID; page = .session; return false
        }
        if session.pendingSubmission != nil {
            guard !background else { errorMessage = "The session's last send is unconfirmed. Check it in Notch Companion first."; return false }
            submitting = true
            submittingSessionID = localID
            defer { submitting = false; submittingSessionID = nil; scheduleDeferredOperationIfIdle() }
            update(localID) { $0.runtimeID = nil }
            do {
                _ = try await ensureRuntime(localID)
                errorMessage = "The last send was checked against native history. Review the conversation before sending another message."
            } catch { errorMessage = error.localizedDescription }
            return false
        }
        let text = (reply ?? session.draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = queuedAttachments ?? (reply == nil ? session.attachments : [])
        guard !text.isEmpty else { errorMessage = "Add a message before sending."; return false }
        guard connection || client is RuntimeRouter else { errorMessage = "The runtime is not connected. Reconnect in Settings."; return false }
        if background { backgroundSubmissions.insert(localID) } else {
            submitting = true
            submittingSessionID = localID
        }
        errorMessage = nil
        defer {
            if background { backgroundSubmissions.remove(localID) } else {
                submitting = false
                submittingSessionID = nil
            }
            scheduleDeferredOperationIfIdle()
        }
        var imagePaths: [String] = []
        let turnID = fixedTurnID ?? UUID().uuidString
        var message = ChatMessage(id: turnID, role: "user",
            text: text + (attachments.isEmpty ? "" : "\n\nAttached: " + attachments.map(\.name).joined(separator: ", ")),
            turnID: turnID)
        message.kind = kind
        update(localID) { target in
            target.stagedSubmission = StagedSubmission(message: message, draft: queuedAttachments != nil ? reply : reply == nil ? session.draft : nil,
                                                        attachments: attachments)
            if reply == nil { target.draft = ""; target.attachments = [] }
            if target.title == "New session" { target.title = String(text.prefix(64)) }
        }
        guard save() else {
            update(localID) {
                if queuedAttachments != nil { $0.stagedSubmission = nil }
                else { $0.restoreStagedSubmission() }
            }
            return false
        }
        var runtimeID: String?
        var appendedTurnID: String?
        var requestedSubmission = false
        do {
            let sid = try await ensureRuntime(localID)
            runtimeID = sid
            let capabilities = sessions.first(where: { $0.id == localID })?.capabilities ?? session.capabilities
            guard attachments.isEmpty || capabilities.attachments else { throw AppError("\(session.runtime.title) cannot receive attachments through this interface. Remove the staged files before sending.") }
            guard !attachments.contains(where: \.isImage) || capabilities.images else { throw AppError("\(session.runtime.title) cannot receive images through this interface. Remove the staged images before sending.") }
            // Before the model: Claude may reopen its idle process to allow Full access.
            let modes = capabilities.supportedPermissionModes
            if let mode = session.permissionMode, !modes.contains(mode) {
                throw AppError("\(session.runtime.title) no longer offers \(mode.title) for this session. Choose another permission mode or Default permissions.")
            }
            if !modes.isEmpty, session.permissionMode != nil || permissionOverrides.contains(localID) {
                var params: [String: Any] = ["session_id": sid]
                if let mode = session.permissionMode { params["mode"] = mode.rawValue }
                _ = try await client.request("session.permission.set", params: params)
                if session.permissionMode == nil { permissionOverrides.remove(localID) } else { permissionOverrides.insert(localID) }
            }
            if let choice = session.modelOverride {
                let reported = sessions.first { $0.id == localID }?.runtimeInfo
                if session.runtime == .codex || session.runtime == .claude || choice.reasoningEffort != nil || reported?.model != choice.model ||
                    (choice.provider != nil && reported?.provider != choice.provider) {
                    try await applyModel(choice, sessionID: sid)
                }
            }
            guard save() else { throw AppError("The session registry could not be saved. No message was sent.") }
            var references: [String] = []
            for attachment in attachments {
                let method = attachment.isImage ? "image.attach" : "file.attach"
                let result = try await client.request(method, params: ["session_id": sid, "path": attachment.url.path])
                if attachment.isImage {
                    imagePaths.append(result["path"] as? String ?? attachment.url.path)
                } else if let reference = result["ref_text"] as? String { references.append(reference) }
                else { throw AppError("The runtime did not return a reference for \(attachment.name).") }
            }
            let prompt = ([text] + references).joined(separator: "\n\n")
            // Finish the previous snapshot before a new turn can change its files.
            for (key, task) in changeTasks where key.hasPrefix(localID + ":") { await task.value }
            let workspace = sessions.first(where: { $0.id == localID })?.workspacePath ?? workspacePath
            // A delegated child's parent shows only the child's own edits.
            let delegated = sessions.first(where: { $0.id == localID })?.parentSessionID != nil
            let changes = await Task.detached(priority: .utility) {
                WorkspaceChanges.baseline(workspace: workspace, turnID: turnID, recordingDirtyFiles: delegated)
            }.value
            // A delegate stopped while it was starting never sends its task.
            if background, sessions.first(where: { $0.id == localID })?.delegation?.cancelled == true { throw DelegationCancelled() }
            // Mark working before the RPC response: streaming events may arrive first.
            update(localID) { target in
                target.isArchived = false
                if !background { target.snoozedUntil = nil }
                target.state = .working
                target.parentTurnComplete = false
                target.completionID = nil
                appendedTurnID = turnID
                target.messages.append(message)
                target.changes.append(changes)
                if target.title == "New session" { target.title = String(text.prefix(64)) }
                target.updatedAt = Date()
                target.nativeSubmissionAttempted = true
                target.pendingSubmission = PendingSubmission(id: turnID, draft: reply ?? session.draft,
                    userTurnCount: target.messages.filter { $0.role == "user" && SessionHistory.isVisibleConversation($0) }.count,
                    attachmentIDs: attachments.map(\.id))
            }
            guard save() else {
                update(localID) { $0.pendingSubmission = nil; $0.nativeSubmissionAttempted = session.nativeSubmissionAttempted }
                throw AppError("The send could not be saved safely. No message was sent.")
            }
            requestedSubmission = true
            _ = try await client.request("prompt.submit", params: ["session_id": sid, "text": prompt, "surface": "hud", "turn_id": turnID])
            confirmSubmission(localID)
            if !background { page = .session; play(.send) }
            save()
            return true
        } catch {
            if error is ModelChangeCancelled {
                update(localID) {
                    if queuedAttachments != nil { $0.stagedSubmission = nil }
                    else { $0.restoreStagedSubmission() }
                }
                errorMessage = reply == nil ? "Model change cancelled. Your message is still in the composer." : "Model change cancelled. Your answer was not sent."
                save()
                return false
            }
            if let sid = runtimeID {
                for path in imagePaths { _ = try? await client.request("image.detach", params: ["session_id": sid, "path": path]) }
            }
            if !(error is NativeSessionBusy || error is DelegationCancelled) {
                let uncertain = appendedTurnID != nil && sessions.first(where: { $0.id == localID })?.pendingSubmission != nil
                let rejected = Self.definitiveRejection(error)
                // An observed start/completion is authoritative even if the RPC
                // acknowledgement was lost. Never restore its draft for retry.
                let accepted = requestedSubmission && appendedTurnID != nil && !uncertain
                    && sessions.first(where: { $0.id == localID })?.messages.contains(where: { $0.id == appendedTurnID }) == true
                if !accepted {
                    update(localID) { target in
                        target.state = uncertain && !rejected ? .interrupted : .failed
                        if target.state == .failed { target.completionID = UUID().uuidString }
                        if !uncertain || rejected {
                            if let appendedTurnID {
                                target.messages.removeAll { $0.id == appendedTurnID }
                                target.changes.removeAll { $0.id == appendedTurnID }
                            }
                            target.pendingSubmission = nil
                            target.nativeSubmissionAttempted = session.nativeSubmissionAttempted
                            if queuedAttachments != nil { target.stagedSubmission = nil }
                            else { target.restoreStagedSubmission() }
                        }
                    }
                    if !background { play(.failure) }
                }
                errorMessage = uncertain && !rejected
                    ? "The runtime may have received this message. Use Check last send to read its native history before trying again."
                    : error.localizedDescription
            } else {
                update(localID) {
                    if queuedAttachments != nil { $0.stagedSubmission = nil }
                    else { $0.restoreStagedSubmission() }
                }
                errorMessage = error.localizedDescription
            }
            acknowledgeVisibleSession()
            save()
        }
        return false
    }

    /// Stops the current session's turn, or another session's from the glance.
    /// Stop also stops its app-owned children depth-first and drops their
    /// wakes; a plain interrupt (`cascade: false`) leaves them running.
    func interrupt(sessionID: String? = nil, cascade: Bool = true) async {
        guard let localID = sessionID ?? currentID, let session = sessions.first(where: { $0.id == localID }) else { return }
        pauseQueuedSends(localID)
        save()
        if let sid = session.runtimeID { await interruptOwnWork(localID, session: session, sid: sid) }
        if cascade { await stopDelegatedChildren(of: localID) }
        // Children left running keep their rows, and the parent, working.
        syncDelegatedChildren()
    }

    private func interruptOwnWork(_ localID: String, session: CompanionSession, sid: String) async {
        if session.parentTurnComplete == false { unfinishedParents.insert(localID) }
        for child in session.agents where child.sessionID == nil && [.working, .waiting].contains(child.state) {
            unfinishedChildren[localID, default: []].insert(child.id)
        }
        do {
            _ = try await client.request("session.interrupt", params: ["session_id": sid])
            update(localID) {
                $0.state = .interrupted
                $0.parentTurnComplete = true
                // The runtime may never confirm a Stop; a later message.complete still overrides this.
                if session.isBusy { $0.recordUnreportedOutcome() }
                for child in $0.agents.indices where [.working, .waiting].contains($0.agents[child].state) { $0.agents[child].state = .interrupted }
                for tool in $0.tools.indices where [.working, .waiting].contains($0.tools[tool].state) { $0.tools[tool].state = .interrupted }
            }
            requests.removeAll { $0.sessionID == sid }
            save()
        } catch { errorMessage = error.localizedDescription }
    }

    func answer(_ request: PendingRequest, choice: String, answers: [String]? = nil) async {
        guard !answeringRequestIDs.contains(request.id),
              requests.contains(where: { $0.id == request.id && $0.sessionID == request.sessionID }) else { return }
        answeringRequestIDs.insert(request.id)
        defer { answeringRequestIDs.remove(request.id) }
        do {
            let method = request.kind == .approval ? "approval.respond" : "clarify.respond"
            var params: [String: Any] = ["session_id": request.sessionID, "request_id": request.requestID ?? request.id]
            if let questionID = request.questionID { params["question_id"] = questionID }
            params[request.kind == .approval ? "choice" : "answer"] = choice
            if request.kind == .clarification, request.multiSelect, let answers { params["answers"] = answers }
            _ = try await client.request(method, params: params)
            play(.send)
            requests.removeAll { $0.id == request.id }
            if !requests.contains(where: { $0.sessionID == request.sessionID }),
               let index = sessions.firstIndex(where: { $0.runtimeID == request.sessionID }), sessions[index].state == .waiting {
                sessions[index].state = .working
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func isAnswering(_ request: PendingRequest) -> Bool { answeringRequestIDs.contains(request.id) }

    /// A glance quick reply answers the same native request as the full card.
    func answerFromGlance(requestID: String, choice: String) {
        guard let request = requests.first(where: { $0.id == requestID }) else { return }
        Task { await answer(request, choice: choice) }
    }

    /// The glance's Stop interrupts that session's turn without opening it.
    func stopFromGlance(_ id: String) {
        Task { await interrupt(sessionID: id) }
    }

    private func confirmSubmission(_ localID: String, includingSteering: Bool = false) {
        update(localID) { target in
            guard let pending = target.pendingSubmission else { return }
            guard pending.isSteering != true || includingSteering else { return }
            if target.stagedSubmission != nil { target.stagedSubmission = nil }
            else {
                // Older saved sends still hold their input in the composer.
                if target.draft == pending.draft { target.draft = "" }
                let attachments = Set(pending.attachmentIDs)
                target.attachments.removeAll { attachments.contains($0.id) }
            }
            target.pendingSubmission = nil
        }
    }

    private static func definitiveRejection(_ error: Error) -> Bool {
        if error is RuntimeDefinitiveRejection { return true }
        if case HermesClientError.rpc = error { return true }
        if case CodexClientError.rpc = error { return true }
        if case ACPClientError.rpc = error { return true }
        return false
    }

    private func ensureRuntime(_ localID: String) async throws -> String {
        guard let session = sessions.first(where: { $0.id == localID }) else { throw AppError("Session is no longer available.") }
        if let runtime = session.runtimeID { return runtime }
        let requestedCwd = session.workspacePath ?? workspacePath
        var params: [String: Any] = ["companion_id": localID, "runtime": session.runtime.rawValue,
                                     "profile_id": session.route.profileID, "legacy_private": session.isLegacyPrivate,
                                     "cwd": requestedCwd, "project_trusted": isProjectTrusted(session),
                                     "activity_unverified": session.nativeActivityUnverified != nil,
                                     "native_submission_attempted": session.nativeSubmissionAttempted]
        if let pending = session.pendingSubmission { params["pending_turn_id"] = pending.id }
        if let mode = session.permissionMode { params["permission_mode"] = mode.rawValue }
        let delegation = await delegationLaunch(for: session)
        if let delegation { params["delegation"] = delegation }
        let result: [String: Any]
        // A launch that failed holds no token, so the next one gets the tools.
        do {
            if let stored = session.storedID {
                params["session_id"] = stored
                do { result = try await client.request("session.resume", params: params) }
                catch {
                    if case HermesClientError.rpc(4007, _) = error, session.runtime == .hermes,
                       !session.isLegacyPrivate, !session.nativeSubmissionAttempted, session.pendingSubmission == nil,
                       session.messages.isEmpty {
                        update(localID) { $0.storedID = nil; $0.runtimeID = nil }
                        // The replacement session gets the tools again with a fresh token.
                        if delegation != nil { delegationServer.revoke(sessionID: localID) }
                        return try await ensureRuntime(localID)
                    }
                    throw error
                }
            } else {
                guard !session.isLegacyPrivate || session.messages.isEmpty else {
                    throw AppError("This legacy conversation has no native session ID. Use Continue in Hermes to carry its preserved context into a new session.")
                }
                params["title"] = session.title
                result = try await client.request("session.create", params: params)
            }
        } catch {
            if delegation != nil { delegationServer.revoke(sessionID: localID) }
            throw error
        }
        guard let sid = result["session_id"] as? String else { throw AppError("The runtime returned an invalid session response.") }
        if let hosts = result["hosts_delegation"] as? Bool {
            delegationHosting[session.route] = hosts
            // An installation that cannot host never uses the token.
            if !hosts, delegation != nil { delegationServer.revoke(sessionID: localID) }
        }
        let nativeCwd = result["cwd"] as? String ?? requestedCwd
        guard URL(fileURLWithPath: nativeCwd).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: requestedCwd).standardizedFileURL.resolvingSymlinksInPath() else {
            throw AppError("The native session belongs to a different working folder. Restore its original folder before continuing; no message was sent.")
        }
        if let snapshots = result["subagents"] as? [[String: Any]] {
            update(localID) { Self.mergeNativeSubagents(snapshots, into: &$0) }
        }
        // App-owned children are separate native sessions, not this session's work.
        let childrenActive = sessions.first(where: { $0.id == localID })?.agents.contains { $0.sessionID == nil && [.working, .waiting].contains($0.state) } == true
        let nativeBusy = result["running"] as? Bool == true || result["busy"] as? Bool == true || childrenActive
        if nativeBusy {
            // Preserve live work even if delivery reconciliation fails below.
            update(localID) {
                $0.runtimeID = sid
                $0.state = $0.agents.contains(where: { $0.state == .waiting }) ? .waiting : .working
                $0.parentTurnComplete = result["parent_complete"] as? Bool ?? false
            }
            if result["parent_complete"] as? Bool != true { unfinishedParents.insert(localID) }
            else { unfinishedParents.remove(localID) }
            save()
        }
        if let pending = session.pendingSubmission {
            let rows = result["messages"] as? [[String: Any]]
            let users = (rows ?? []).filter { $0["role"] as? String == "user" && SessionHistory.isVisibleConversation($0) }
            let exactReceipt = (result["accepted_turn_ids"] as? [String] ?? []).contains(pending.id)
                || users.contains { $0["client_id"] as? String == pending.id }
            if exactReceipt {
                // A native receipt proves this exact input was accepted even
                // when history is paginated. It says nothing about completion.
                confirmSubmission(localID, includingSteering: true)
            } else {
                guard rows != nil, result["history_complete"] as? Bool != false else {
                    throw AppError("\(session.runtime.title) has no exact delivery receipt or complete native history for this send check. The saved send remains protected from retry; inspect the exact session in the native runtime.")
                }
                guard pending.userTurnCount > 0 else { throw AppError("The saved send intent is invalid. Native history was left untouched.") }
                if users.count >= pending.userTurnCount {
                    let raw = users[pending.userTurnCount - 1]["text"] as? String ?? ""
                    guard SessionHistory.projectedUserText(raw).hasPrefix(pending.draft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw AppError("The last send could not be matched safely to native history. It remains protected from automatic retry.")
                    }
                    confirmSubmission(localID, includingSteering: true)
                } else if result["running"] as? Bool != true && result["busy"] as? Bool != true {
                    // Absence is proof only in the complete unchanged prefix.
                    let previous = session.messages.filter { $0.role == "user" && $0.id != pending.id && SessionHistory.isVisibleConversation($0) }
                    guard users.count == pending.userTurnCount - 1, previous.count == users.count,
                          zip(users, previous).allSatisfy({ row, old in
                              SessionHistory.projectedUserText(row["text"] as? String ?? "").hasPrefix(old.text.components(separatedBy: "\n\nAttached:").first ?? old.text)
                          }) else {
                        throw AppError("Native history is incomplete for this send check. The saved send remains protected from retry.")
                    }
                    update(localID) {
                        $0.messages.removeAll { $0.id == pending.id }
                        $0.pendingSubmission = nil
                        $0.state = .interrupted
                        $0.parentTurnComplete = true
                        $0.nativeSubmissionAttempted = !users.isEmpty
                        $0.restoreStagedSubmission()
                    }
                }
            }
        }
        update(localID) { target in
            target.runtimeID = sid
            if let info = result["info"] as? [String: Any] {
                var snapshot = target.runtimeInfo ?? RuntimeSessionInfo()
                snapshot.merge(info, runtime: target.runtime)
                target.runtimeInfo = snapshot
            }
            target.profileID = result["profile_id"] as? String ?? session.route.profileID
            target.storedID = result["stored_session_id"] as? String ?? result["session_key"] as? String ?? target.storedID
            if target.workspacePath == nil { target.workspacePath = nativeCwd }
            if let complete = result["parent_complete"] as? Bool { target.parentTurnComplete = complete }
            if session.storedID != nil, result["history_complete"] as? Bool != false, let rows = result["messages"] as? [[String: Any]] {
                // Older saves treated backend wake-up envelopes as user turns.
                // Retain tools' identity while repairing ownership before those
                // synthetic messages are removed by the display projection.
                let aliases = SessionHistory.syntheticTurnAliases(in: target.messages)
                for index in target.tools.indices {
                    if let turnID = target.tools[index].turnID, let realTurn = aliases[turnID] { target.tools[index].turnID = realTurn }
                }
                for index in target.changes.indices {
                    if let realTurn = aliases[target.changes[index].id] { target.changes[index].id = realTurn }
                }
                for index in target.messages.indices where target.messages[index].role == "assistant" {
                    if let turnID = target.messages[index].turnID, let realTurn = aliases[turnID] { target.messages[index].turnID = realTurn }
                }
                let restored = SessionHistory.messages(rows, preserving: target.messages)
                if !restored.isEmpty { target.messages = restored }
            }
        }
        if !nativeBusy, session.pendingSubmission != nil, sessions.first(where: { $0.id == localID })?.pendingSubmission == nil,
           let terminal = result["terminal_status"] as? String {
            update(localID) { target in
                target.parentTurnComplete = true
                target.state = terminal == "complete" ? (target.failedCurrentAgents.isEmpty ? .finished : .failed)
                    : (terminal == "interrupted" ? .interrupted : .failed)
                if [.finished, .failed].contains(target.state) { target.completionID = UUID().uuidString }
                target.recordReportedOutcome()
            }
        }
        if nativeBusy {
            save()
            throw NativeSessionBusy()
        }
        guard save() else { throw AppError("The native session identity could not be saved. No message was sent.") }
        if let current = sessions.first(where: { $0.id == localID }) {
            let key = modelCatalogKey(for: current)
            if let catalog = result["catalog"] as? RuntimeModelCatalog { modelCatalogs[key] = catalog }
            else if showModelPicker && current.capabilities.modelSelection && (modelCatalogs[key]?.models.isEmpty ?? true) {
                Task { [weak self] in await self?.loadModels(for: key, refresh: true) }
            }
        }
        return sid
    }

    /// Native resume snapshots describe current children; they are not newly
    /// streamed text or new completion receipts. Preserve older turn history.
    static func mergeNativeSubagents(_ snapshots: [[String: Any]], into session: inout CompanionSession) {
        var seen = Set<String>()
        for snapshot in snapshots {
            guard let nativeID = snapshot["id"] as? String, !nativeID.isEmpty, seen.insert(nativeID).inserted else { continue }
            let state: WorkState
            switch snapshot["status"] as? String {
            case "working", "running": state = .working
            case "waiting": state = .waiting
            case "complete", "finished": state = .finished
            case "failed", "error": state = .failed
            case "interrupted", "cancelled": state = .interrupted
            default: continue // Unknown native state is not proof of completion.
            }
            if let index = session.agents.lastIndex(where: { ($0.nativeID ?? $0.id) == nativeID }) {
                session.agents[index].state = state
                if let name = snapshot["name"] as? String, !name.isEmpty { session.agents[index].title = String(name.prefix(100)) }
                if let text = snapshot["text"] as? String { session.agents[index].text = text }
                if ![WorkState.working, .waiting].contains(state) {
                    for tool in session.agents[index].tools.indices where [.working, .waiting].contains(session.agents[index].tools[tool].state) {
                        session.agents[index].tools[tool].state = state
                        session.agents[index].tools[tool].finishedAt = Date()
                    }
                }
            } else {
                let active = state == .working || state == .waiting
                session.agents.append(ChildAgent(id: nativeID, nativeID: nativeID,
                    title: String((snapshot["name"] as? String ?? "Delegated agent").prefix(100)), state: state,
                    text: snapshot["text"] as? String ?? "", turnID: active ? session.latestUserTurnID : nil))
            }
        }
    }

    func receive(_ name: String, payload original: [String: Any]) {
        if name == "runtime.rateLimits" {
            if let runtime = original["runtime"] as? String, let limits = original["limits"] as? [RuntimeRateLimit] { storeRateLimits(limits, runtime: runtime) }
            return
        }
        if name == "runtime.connection" {
            if let route = original["route"] as? String, original["connected"] as? Bool == false,
               let runtime = RuntimeKind.allCases.first(where: {
                   RuntimeRoute(runtime: $0, profileID: RuntimeRoute.defaultProfile($0, defaults: preferences)).eventKey == route
               }) {
                setRuntimeReady(runtime, ready: false)
            }
            if original["connected"] as? Bool == false, let route = original["route"] as? String {
                for index in sessions.indices where sessions[index].route.eventKey == route {
                    let id = sessions[index].id
                    pauseQueuedSends(id)
                    let sid = sessions[index].runtimeID
                    sessions[index].runtimeID = nil
                    if sessions[index].isBusy { sessions[index].state = .interrupted; endTurn(index) }
                    for child in sessions[index].agents.indices where [.working, .waiting].contains(sessions[index].agents[child].state) { sessions[index].agents[child].state = .interrupted }
                    for tool in sessions[index].tools.indices where [.working, .waiting].contains(sessions[index].tools[tool].state) { sessions[index].tools[tool].state = .interrupted }
                    unfinishedParents.remove(id)
                    unfinishedChildren.removeValue(forKey: id)
                    delegationServer.revoke(sessionID: id)
                    if let sid { requests.removeAll { $0.sessionID == sid } }
                }
                syncDelegatedChildren()
                scheduleSave()
                scheduleDeferredOperationIfIdle()
            }
            refreshConnection()
            return
        }
        var payload = original
        if let data = original["data"] as? [String: Any] { payload.merge(data) { _, new in new } }
        let sid = payload["session_id"] as? String ?? ""
        guard let index = sessions.firstIndex(where: { $0.runtimeID == sid }) else { return }
        let localID = sessions[index].id
        let turnID = sessions[index].latestUserTurnID
        let wasFailed = sessions[index].state == .failed
        let wasDisplayedFailed = sessions[index].displayState == .failed
        var failure = ""
        sessions[index].updatedAt = Date()
        switch name {
        case "turn.changes":
            if let turnID, let diff = payload["diff"] as? String {
                receiveChanges(diff, sessionID: localID, turnID: turnID)
            }
        case "runtime.activity_unverified":
            let reason = payload["message"] as? String ?? "The native runtime cannot confirm that delegated work has finished. Continue this exact session in its native interface."
            sessions[index].nativeActivityUnverified = reason
            sessions[index].state = .waiting
            sessions[index].completionID = nil
            errorMessage = reason
            if !save() { persistenceBlocked = true }
        case "session.disconnected":
            pauseQueuedSends(localID)
            sessions[index].runtimeID = nil
            if sessions[index].isBusy { sessions[index].state = .interrupted; endTurn(index) }
            for child in sessions[index].agents.indices where [.working, .waiting].contains(sessions[index].agents[child].state) { sessions[index].agents[child].state = .interrupted }
            for tool in sessions[index].tools.indices where [.working, .waiting].contains(sessions[index].tools[tool].state) { sessions[index].tools[tool].state = .interrupted }
            unfinishedParents.remove(localID); unfinishedChildren.removeValue(forKey: localID)
            delegationServer.revoke(sessionID: localID)
            requests.removeAll { $0.sessionID == sid }
            errorMessage = payload["message"] as? String ?? "\(sessions[index].runtime.title) disconnected. Resume its native session before sending again."
        case "session.info", "session.usage":
            var info = sessions[index].runtimeInfo ?? RuntimeSessionInfo()
            info.merge(payload, runtime: sessions[index].runtime)
            sessions[index].runtimeInfo = info
            // The runtime's running total for the current turn replaces any earlier report.
            if let tokens = payload["turn_tokens"] as? Int, tokens >= 0, let turnID { sessions[index].turnTokens[turnID] = tokens }
        case "runtime.notice":
            errorMessage = EventValue.string(payload["message"])
            turnNotices[localID] = errorMessage
        case "message.start":
            turnNotices[localID] = nil
            confirmSubmission(localID)
            unfinishedParents.insert(localID)
            sessions[index].parentTurnComplete = false
            sessions[index].state = .working
            sessions[index].completionID = nil
            let role = payload["role"] as? String ?? "assistant"
            if role == "assistant", !(sessions[index].messages.last?.role == "assistant" && sessions[index].messages.last?.text.isEmpty == true) {
                sessions[index].messages.append(ChatMessage(role: "assistant", text: "", turnID: turnID))
            }
            if role == "assistant" { nativeTurnStarts[localID] = sessions[index].messages.last?.id }
        case "message.delta":
            let segment = assistantSegment(index, turnID: turnID)
            var text = EventValue.string(payload["text"] ?? payload["delta"])
            // A new segment drops the blank line that separated it from the previous one.
            if sessions[index].messages[segment].text.isEmpty { text = String(text.drop(while: \.isNewline)) }
            guard !text.isEmpty else { break }
            if sessions[index].messages[segment].text.isEmpty, sessions[index].messages[segment].questions == nil {
                sessions[index].messages[segment].createdAt = Date()
            }
            sessions[index].messages[segment].text += text
        case "message.interim":
            // An assistant message can end before retries, queued input or
            // compaction settle. Preserve its authoritative text, stay busy.
            reconcileAssistantText(EventValue.string(payload["text"]), index: index, turnID: turnID)
        case "message.complete":
            var info = sessions[index].runtimeInfo ?? RuntimeSessionInfo()
            info.merge(["usage": payload["usage"] ?? [:]], runtime: sessions[index].runtime)
            sessions[index].runtimeInfo = info
            confirmSubmission(localID)
            unfinishedParents.remove(localID)
            let wasFinished = sessions[index].state == .finished && sessions[index].parentTurnComplete && !sessions[index].isBusy
            reconcileAssistantText(EventValue.string(payload["text"]), index: index, turnID: turnID)
            sessions[index].messages.removeAll { $0.role == "assistant" && $0.questions == nil && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let status = payload["status"] as? String ?? "complete"
            if status == "error" || status == "interrupted" { pauseQueuedSends(localID) }
            sessions[index].parentTurnComplete = true
            if status == "error" {
                sessions[index].state = .failed
                failure = EventValue.string(payload["error"])
                if failure.isEmpty { failure = turnNotices[localID] ?? "" }
            } else if status == "interrupted" {
                sessions[index].state = .interrupted
                for child in sessions[index].agents.indices where [.working, .waiting].contains(sessions[index].agents[child].state) { sessions[index].agents[child].state = .interrupted }
            } else if sessions[index].nativeActivityUnverified != nil || sessions[index].agents.contains(where: { $0.state == .waiting }) {
                sessions[index].state = .waiting
            } else if sessions[index].agents.contains(where: { $0.state == .working }) {
                sessions[index].state = .working
            } else if !sessions[index].failedCurrentAgents.isEmpty {
                sessions[index].state = .failed
            } else {
                sessions[index].state = .finished
                if !wasFinished { sessions[index].completionID = UUID().uuidString }
            }
            endTurn(index)
            for tool in sessions[index].tools.indices where sessions[index].tools[tool].state == .working {
                sessions[index].tools[tool].state = status == "interrupted" ? .interrupted : (status == "error" ? .failed : .finished)
                sessions[index].tools[tool].finishedAt = Date()
            }
            if sessions[index].nativeActivityUnverified == nil { requests.removeAll { $0.sessionID == sid } }
            // A child's result reaches its parent as a wake, not as its own announcement.
            if status == "complete", sessions[index].state == .finished, sessions[index].parentSessionID == nil,
               Date().timeIntervalSince(lastCompletion[localID] ?? .distantPast) > 1 {
                lastCompletion[localID] = Date(); announceCompletion(localID)
            }
        case "message.questions":
            // Non-blocking questions belong to this turn's answer; the turn goes on.
            guard let questions = AsyncQuestion.decode(payload["questions"]) else { break }
            let segment = assistantSegment(index, turnID: turnID)
            if sessions[index].messages[segment].text.isEmpty, sessions[index].messages[segment].questions == nil {
                sessions[index].messages[segment].createdAt = Date()
            }
            sessions[index].messages[segment].questions = (sessions[index].messages[segment].questions ?? []) + questions
        case "tool.start", "tool.complete":
            let id = EventValue.string(payload["tool_id"] ?? payload["tool_call_id"] ?? payload["id"])
            let key = id.isEmpty ? UUID().uuidString : id
            let toolName = payload["name"] as? String ?? payload["tool_name"] as? String ?? "Tool"
            if name == "tool.start" {
                let context = payload["context"] as? String ?? EventValue.summary(payload)
                sessions[index].tools.append(ToolActivity(id: key, name: toolName, detail: context, turnID: turnID))
            } else if let tool = sessions[index].tools.lastIndex(where: { $0.id == key }) {
                sessions[index].tools[tool].state = payload["is_error"] as? Bool == true || payload["status"] as? String == "error" ? .failed : .finished
                sessions[index].tools[tool].output = EventValue.string(payload["result"] ?? payload["summary"])
                sessions[index].tools[tool].finishedAt = Date()
            }
        case "approval.request", "clarify.request":
            let id = payload["request_id"] as? String ?? UUID().uuidString
            let isApproval = name == "approval.request"
            requests.removeAll { ($0.requestID ?? $0.id) == id }
            if !isApproval, let questions = payload["questions"] as? [[String: Any]], !questions.isEmpty {
                for (offset, question) in questions.enumerated() {
                    let qid = EventValue.string(question["qid"])
                    let header = EventValue.string(question["header"])
                    requests.append(PendingRequest(id: "\(id):\(qid.isEmpty ? String(offset) : qid)", kind: .clarification,
                        title: header.isEmpty ? "\(sessions[index].runtime.title) has a question" : "\(sessions[index].runtime.title) · \(header)",
                        detail: EventValue.string(question["question"]), choices: question["choices"] as? [String] ?? [], sessionID: sid,
                        questionID: qid.isEmpty ? nil : qid, requestID: id, multiSelect: question["multi_select"] as? Bool ?? false,
                        allowsFreeText: question["allows_free_text"] as? Bool ?? true, choiceDetails: question["choice_details"] as? [String: String] ?? [:]))
                }
            } else {
                let detail = EventValue.string(payload[isApproval ? "command" : "question"])
                let choices = payload["choices"] as? [String] ?? (isApproval ? ["once", "deny"] : [])
                requests.append(PendingRequest(id: id, kind: isApproval ? .approval : .clarification, title: isApproval ? "\(sessions[index].runtime.title) needs permission" : "\(sessions[index].runtime.title) has a question", detail: detail, choices: choices, sessionID: sid, multiSelect: payload["multi_select"] as? Bool ?? false, allowsFreeText: payload["allows_free_text"] as? Bool ?? true))
            }
            sessions[index].state = .waiting
            play(.attention)
            announce(.needsInput, sessionID: localID)
            if !isApproval, sessions[index].parentSessionID != nil { queueQuestionNotice(childID: localID, requestID: id) }
        case "clarify.expire":
            let id = EventValue.string(payload["request_id"])
            requests.removeAll { ($0.requestID ?? $0.id) == id }
            if !requests.contains(where: { $0.sessionID == sid }), sessions[index].state == .waiting { sessions[index].state = .working }
        case "subagent.start", "subagent.thinking", "subagent.tool", "subagent.text", "subagent.complete":
            receiveSubagent(name, payload: payload, index: index)
        case "error", "session.error":
            pauseQueuedSends(localID)
            sessions[index].state = .failed
            endTurn(index)
            errorMessage = EventValue.string(payload["message"] ?? payload["error"])
            failure = errorMessage ?? ""
        default: break
        }
        // One cue per transition, whichever event (error, failed turn, failed child) caused it.
        if !wasFailed, sessions[index].state == .failed, sessions[index].parentSessionID == nil {
            play(.failure)
            announce(.failed, sessionID: sessions[index].id, failure: failure)
        }
        if !wasDisplayedFailed, sessions[index].displayState == .failed {
            sessions[index].completionID = UUID().uuidString
        }
        acknowledgeVisibleSession()
        scheduleSave()
        if ["message.complete", "subagent.complete"].contains(name), !sessions[index].isBusy,
           let turnID { captureWorkspaceChanges(sessionID: localID, turnID: turnID) }
        syncDelegatedChildren()
        scheduleDeferredOperationIfIdle()
    }

    /// The assistant message new content belongs in. A tool that started after the
    /// current one had text or questions closes it, so text keeps its place between tool calls.
    private func assistantSegment(_ index: Int, turnID: String?) -> Int {
        if let last = sessions[index].messages.last, last.role == "assistant",
           last.text.allSatisfy(\.isWhitespace) && last.questions == nil
            || !(sessions[index].tools.last.map { $0.startedAt >= last.createdAt } ?? false) {
            return sessions[index].messages.count - 1
        }
        sessions[index].messages.append(ChatMessage(role: "assistant", text: "", turnID: turnID))
        return sessions[index].messages.count - 1
    }

    /// A runtime's authoritative text for its native turn. Text that turn's segments
    /// already hold (all of them joined, or the last ones, as Claude reports only its
    /// final message) keeps them; other text replaces the current segment's.
    private func reconcileAssistantText(_ text: String, index: Int, turnID: String?) {
        let squash = { (text: String) in text.filter { !$0.isWhitespace } }
        let wanted = squash(text)
        guard !wanted.isEmpty else { return }
        // A steer stays in its native turn; a wake starts another, so an earlier answer never stands in for its own.
        let messages = sessions[index].messages
        let start = nativeTurnStarts[sessions[index].id].flatMap { id in messages.firstIndex { $0.id == id } }
        let streamed = (start.map { Array(messages[$0...]) } ?? messages.filter { $0.turnID == turnID })
            .filter { $0.role == "assistant" }.map(\.text).joined()
        guard !squash(streamed).hasSuffix(wanted) else { return }
        let segment = assistantSegment(index, turnID: turnID)
        if sessions[index].messages[segment].text.isEmpty, sessions[index].messages[segment].questions == nil {
            sessions[index].messages[segment].createdAt = Date()
        }
        sessions[index].messages[segment].text = text
    }

    /// Ends the latest block's work clock and keeps the turn's own outcome from the
    /// state just set; its visible user row keys both.
    private func endTurn(_ index: Int) {
        guard let boundary = sessions[index].messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) }) else { return }
        sessions[index].turnEndedAt[boundary.id] = Date()
        sessions[index].recordReportedOutcome()
    }

    private func receiveChanges(_ diff: String, sessionID: String, turnID: String) {
        let key = sessionID + ":" + turnID
        let revision = UUID()
        changeRevisions[key] = revision
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        update(sessionID) { target in
            if !target.changes.contains(where: { $0.id == turnID }) {
                target.changes.append(TurnChanges(id: turnID, workspace: session.workspacePath ?? workspacePath))
            }
            if let index = target.changes.firstIndex(where: { $0.id == turnID }) {
                target.changes[index].source = .agent
                // Codex paths are relative to its cwd, Git paths to the repo root.
                target.changes[index].workspace = session.workspacePath ?? workspacePath
            }
        }
        changeTasks[key]?.cancel()
        changeTasks[key] = Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                diff.utf8.count <= UnifiedDiff.maximumBytes ? UnifiedDiff.files(diff) : nil
            }.value
            guard !Task.isCancelled, let self, changeRevisions[key] == revision else { return }
            update(sessionID) { target in
                guard let index = target.changes.firstIndex(where: { $0.id == turnID }) else { return }
                let supported = files.map { $0.count <= UnifiedDiff.maximumFiles } == true
                target.changes[index].files = supported ? files! : []
                target.changes[index].notice = supported ? nil : "The diff is too large to preview. Open the project in your editor."
                target.changes[index].capturedAt = Date()
            }
            changeTasks.removeValue(forKey: key)
            changeRevisions.removeValue(forKey: key)
            foldDelegatedChanges(sessionID)
            scheduleSave()
        }
    }

    private func captureWorkspaceChanges(sessionID: String, turnID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let baseline = session.changes.first(where: { $0.id == turnID }), baseline.source != .agent else { return }
        let key = sessionID + ":" + turnID
        let revision = UUID()
        changeRevisions[key] = revision
        changeTasks[key]?.cancel()
        changeTasks[key] = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { WorkspaceChanges.capture(baseline) }.value
            guard !Task.isCancelled, let self, changeRevisions[key] == revision else { return }
            defer {
                changeTasks.removeValue(forKey: key)
                changeRevisions.removeValue(forKey: key)
            }
            guard let target = sessions.first(where: { $0.id == sessionID }), !target.isBusy,
                  target.latestUserTurnID == turnID else { return }
            update(sessionID) { session in
                guard let index = session.changes.firstIndex(where: { $0.id == turnID }), session.changes[index].source != .agent else { return }
                let delegated = session.changes[index].delegated // children fold in on their own schedule
                session.changes[index] = snapshot
                session.changes[index].delegated = delegated
            }
            foldDelegatedChanges(sessionID)
            scheduleSave()
        }
    }

    private func receiveSubagent(_ name: String, payload: [String: Any], index: Int) {
        // Late child progress after an interruption must not resurrect a dot.
        if sessions[index].state == .interrupted, sessions[index].parentTurnComplete, name != "subagent.complete" { return }
        let fallback = EventValue.string(payload["delegation_id"]) + ":" + EventValue.string(payload["task_index"])
        let nativeID = EventValue.string(payload["subagent_id"] ?? payload["child_session_id"] ?? payload["agent_id"] ?? (fallback == ":" ? nil : fallback))
        guard !nativeID.isEmpty else { return }
        var id = nativeID
        if let previous = sessions[index].agents.last(where: { ($0.nativeID ?? $0.id) == nativeID }) {
            if previous.turnID == sessions[index].latestUserTurnID || name == "subagent.complete" {
                id = previous.id
            } else {
                id = nativeID + ":" + UUID().uuidString
            }
        }
        let localID = sessions[index].id
        if name == "subagent.complete" { unfinishedChildren[localID]?.remove(id) }
        else { unfinishedChildren[localID, default: []].insert(id) }
        if !sessions[index].agents.contains(where: { $0.id == id }) {
            let title = EventValue.string(payload["role"] ?? payload["name"] ?? payload["goal"] ?? payload["task"])
            sessions[index].agents.append(ChildAgent(id: id, nativeID: nativeID, title: title.isEmpty ? "Agent \(sessions[index].agents.count + 1)" : String(title.prefix(100)), turnID: sessions[index].latestUserTurnID))
        }
        guard let child = sessions[index].agents.firstIndex(where: { $0.id == id }) else { return }
        if name == "subagent.complete" {
            let status = payload["status"] as? String ?? "complete"
            sessions[index].agents[child].state = status == "error" || status == "failed" ? .failed : (status == "interrupted" ? .interrupted : .finished)
            for tool in sessions[index].agents[child].tools.indices where sessions[index].agents[child].tools[tool].state == .working {
                sessions[index].agents[child].tools[tool].state = sessions[index].agents[child].state
                sessions[index].agents[child].tools[tool].finishedAt = Date()
            }
            let result = EventValue.string(payload["summary"] ?? payload["result"] ?? payload["text"])
            if !result.isEmpty { sessions[index].agents[child].text = result }
            if sessions[index].parentTurnComplete, [.working, .waiting].contains(sessions[index].state) {
                if sessions[index].agents.contains(where: { $0.state == .waiting }) {
                    sessions[index].state = .waiting
                } else if sessions[index].agents.contains(where: { $0.state == .working }) {
                    sessions[index].state = .working
                } else {
                    sessions[index].state = sessions[index].failedCurrentAgents.isEmpty ? .finished : .failed
                    if sessions[index].state == .finished {
                        sessions[index].completionID = UUID().uuidString
                        lastCompletion[sessions[index].id] = Date()
                        announceCompletion(sessions[index].id)
                    }
                }
            }
        } else if name == "subagent.text" {
            sessions[index].agents[child].state = .working
            sessions[index].agents[child].text += EventValue.string(payload["text"] ?? payload["delta"])
        } else if name == "subagent.tool" {
            sessions[index].agents[child].state = .working
            let toolName = EventValue.string(payload["name"] ?? payload["tool_name"] ?? payload["tool"])
            // Hermes's own child mirror closes the prior call on the next tool
            // event, and closes the final one on subagent.complete.
            for tool in sessions[index].agents[child].tools.indices where sessions[index].agents[child].tools[tool].state == .working {
                sessions[index].agents[child].tools[tool].state = .finished
                sessions[index].agents[child].tools[tool].finishedAt = Date()
            }
            sessions[index].agents[child].tools.append(ToolActivity(id: UUID().uuidString, name: toolName, detail: EventValue.string(payload["tool_preview"]), state: .working))
        } else {
            sessions[index].agents[child].state = payload["status"] as? String == "waiting" ? .waiting : .working
        }
        if name != "subagent.complete", [.finished, .failed].contains(sessions[index].state) {
            // Async child startup can be delivered after the parent's result.
            // Its eventual finish is a new completion even if that result was read.
            // Keep a parent's failure: a successful late child cannot undo it.
            if sessions[index].state == .finished {
                sessions[index].state = sessions[index].agents.contains(where: { $0.state == .waiting }) ? .waiting : .working
            }
            sessions[index].completionID = nil
        }
    }

    private func mutateCurrent(_ mutate: (inout CompanionSession) -> Void) { if let currentID { update(currentID, mutate) } }
    func update(_ id: String, _ mutate: (inout CompanionSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
    }
    func scheduleSave() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)); self?.save() } catch { }
        }
    }
    @discardableResult
    func save() -> Bool {
        guard !persistenceBlocked else { return false }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(sessions).write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            return true
        } catch { errorMessage = "Could not save local session history: \(error.localizedDescription)"; return false }
    }

    func play(_ cue: SoundPlayer.Cue) { if playsSounds { SoundPlayer.shared.play(cue) } }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DelegationCancelled: LocalizedError {
    var errorDescription: String? { "The delegated task was cancelled before it started." }
}

struct NativeSessionBusy: LocalizedError {
    var errorDescription: String? { "This conversation is already working in its runtime. Wait for it to finish before sending another message." }
}

private struct ModelChangeCancelled: Error {}
