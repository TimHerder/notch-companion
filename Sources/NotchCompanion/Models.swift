import Foundation
import AppKit

enum WorkState: String, Codable { case idle, working, waiting, finished, failed, interrupted }

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var role: String
    var text: String
    var createdAt: Date = Date()
    var turnID: String? = nil
    /// Questions an agent asked without blocking its turn (Codex's
    /// `request_user_input_async`). They are answered by the next message.
    var questions: [AsyncQuestion]? = nil
    /// A message the companion sent for an agent rather than the user.
    /// A string, so a kind from a newer build cannot discard the registry.
    var kind: String? = nil
    static let delegationResult = "delegationResult"
    /// A delegated child's question, relayed to its parent.
    static let delegationNotice = "delegationNotice"
    /// Sent by another session's agent through `notch_session_send`.
    static let agentMessage = "agentMessage"
    var isDelegationResult: Bool { kind == Self.delegationResult }
    /// A wake shows only T3 Code's one-line notice, `Delegated task "Title" finished`;
    /// the answer stays in the child and the parent's reply.
    var delegationSummary: String? {
        guard isDelegationResult, let line = text.split(separator: "\n", maxSplits: 1).first,
              let open = line.firstIndex(of: "\""), let close = line.range(of: "\" (", options: .backwards), open < close.lowerBound else { return nil }
        return "Delegated task \"\(line[line.index(after: open)..<close.lowerBound])\" \(line.hasSuffix(" failed.") ? "failed" : "finished")"
    }
    /// The child a wake came from, read from its first line's `sessionId`.
    var delegationChildID: String? {
        guard isDelegationResult, let line = text.split(separator: "\n", maxSplits: 1).first,
              let range = line.range(of: #"sessionId [^,)]+"#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst("sessionId ".count))
    }
    /// Shown in place of "You" for a message the companion sent for an agent.
    var agentLabel: String? {
        switch kind {
        case Self.delegationResult: return "Delegation result"
        case Self.delegationNotice: return "Delegated question"
        case Self.agentMessage: return "From another session"
        default: return nil
        }
    }
}

/// A non-blocking question: free text is always allowed beside the options.
struct AsyncQuestion: Codable, Equatable, Hashable {
    var title: String
    var options: [String] = []

    static func decode(_ value: Any?) -> [AsyncQuestion]? {
        let questions = (value as? [[String: Any]] ?? []).compactMap { row -> AsyncQuestion? in
            guard let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            return AsyncQuestion(title: title, options: (row["options"] as? [String] ?? []).filter { !$0.isEmpty })
        }
        return questions.isEmpty ? nil : questions
    }

    var payload: [String: Any] { ["title": title, "options": options] }

    /// One reply message: a single answer alone, several as labelled lines.
    static func reply(_ questions: [AsyncQuestion], answers: [String]) -> String {
        let pairs = zip(questions, answers).map { ($0.title, $1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
        if questions.count == 1 { return pairs.first?.1 ?? "" }
        return pairs.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n\n")
    }
}

struct ToolActivity: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var detail: String
    var state: WorkState = .working
    var output: String = ""
    var startedAt: Date = Date()
    var finishedAt: Date?
    var turnID: String? = nil
    /// T3 Code's wording for the companion's tools: action, running, done, object.
    static let delegationLabels: [String: [String]] = [
        "orchestrator_capabilities": ["Get", "Getting", "Got", "delegation options"],
        "delegate_task": ["Delegate", "Delegating", "Delegated", "a child task"],
        "task_status": ["Get", "Getting", "Got", "delegated task status"],
        "task_cancel": ["Cancel", "Canceling", "Requested cancellation of", "a delegated task"],
        "create_sessions": ["Create", "Creating", "Created", "sessions"],
        "notch_session_list": ["List", "Listing", "Listed", "sessions"],
        "notch_session_read": ["Read", "Reading", "Read", "a session"],
        "notch_session_send": ["Send", "Sending", "Sent", "a session message"],
        "notch_session_wait": ["Wait for", "Waiting for", "Waited for", "a session"],
        "notch_session_interrupt": ["Interrupt", "Interrupting", "Interrupted", "a session"],
        "notch_session_update": ["Update", "Updating", "Updated", "a session"],
        "pending_request_list": ["List", "Listing", "Listed", "pending questions"],
        "pending_request_read": ["Read", "Reading", "Read", "a pending question"],
        "pending_request_respond": ["Answer", "Answering", "Answered", "a pending question"]
    ]
    /// The companion's tool under any harness prefix; Codex reports it bare.
    static func delegationTool(_ name: String) -> String? {
        let server = DelegationServer.name
        for prefix in ["mcp__\(server)__", "\(server).", "\(server)__", "\(server)/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        // OpenCode 2 gives each session its own server, `notch-<16 hex>`.
        if let match = name.prefixMatch(of: #/notch-[0-9a-f]{16}_/#) { return String(name[match.range.upperBound...]) }
        // OpenClaw node tools are `notch_<tool>`; a bare `notch_session_*` is the tool itself.
        if name.hasPrefix(server + "_"), delegationLabels[String(name.dropFirst(server.count + 1))] != nil { return String(name.dropFirst(server.count + 1)) }
        return delegationLabels[name] == nil ? nil : name
    }
    var displayName: String {
        if let tool = Self.delegationTool(name), let labels = Self.delegationLabels[tool] {
            return (state == .working ? labels[1] : state == .finished ? labels[2] : labels[0]) + " " + labels[3]
        }
        let names = ["terminal": "Terminal", "web_search": "Searching the web", "web_extract": "Reading a page", "read_file": "Reading a file", "write_file": "Writing a file", "browser_navigate": "Opening a page", "python": "Running Python"]
        return names[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct ChildAgent: Identifiable, Codable, Equatable {
    var id: String
    var nativeID: String? = nil
    var title: String
    var state: WorkState = .working
    var tools: [ToolActivity] = []
    var text: String = ""
    var turnID: String? = nil
    /// An app-owned child: its companion session, harness and role.
    var sessionID: String? = nil
    var runtime: RuntimeKind? = nil
    var role: String? = nil
    /// "Codex · review" for an app-owned child.
    var delegationDetail: String? {
        guard sessionID != nil else { return nil }
        return [runtime?.title, role].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A task another agent delegated to this app-owned child session.
struct DelegationRecord: Codable, Equatable {
    var taskID: String
    var clientRequestID: String? = nil
    var role: String? = nil
    /// Whether this task's results wake the parent: async tasks, and waits that returned early.
    var completionWake: Bool = true
    /// The child result the parent already read through `task_status` or a wait.
    var readCompletionID: String? = nil
    /// The child result a wake was sent for, and that wake's parent message.
    var wokenCompletionID: String? = nil
    var wakeMessageID: String? = nil
    var cancelled: Bool = false
}

/// A message waiting for its session's turn to end, kept across restarts.
struct QueuedSend: Codable, Equatable {
    var id: String
    var text: String
    var kind: String? = nil
    /// A question notice is dropped once its question is answered.
    var requestID: String? = nil
    var questionSessionID: String? = nil
    var attachments: [Attachment]? = nil
    var paused: Bool? = nil

    var isUserMessage: Bool { kind == nil }
}

enum SessionFilter: String, CaseIterable, Identifiable {
    case all, needsYou, unread, archived
    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "All"
        case .needsYou: return "Needs you"
        case .unread: return "Unread"
        case .archived: return "Archived"
        }
    }
}

/// How long a read, idle session stays in Your sessions before it is listed
/// under Archived. Derived on display; nothing is flagged or swept.
enum SessionAutoArchive: String, CaseIterable, Identifiable {
    case hour, halfDay, threeDays, never
    static let key = "sessions.autoArchiveAfter"
    var id: Self { self }
    var label: String {
        switch self {
        case .hour: return "1 hour"
        case .halfDay: return "12 hours"
        case .threeDays: return "3 days"
        case .never: return "Never"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .hour: return 3_600
        case .halfDay: return 12 * 3_600
        case .threeDays: return 3 * 86_400
        case .never: return nil
        }
    }
}

enum DeferredOperation: Equatable {
    case reconnect, quit
    var title: String { self == .reconnect ? "Reconnect" : "Quit" }
    var waitingMessage: String { "\(title) when all work finishes" }
}

enum ActiveOperationChoice { case whenFinished, stopNow, cancel }

struct PendingRequest: Identifiable, Equatable {
    enum Kind: Equatable { case approval, clarification }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var choices: [String]
    var sessionID: String
    var questionID: String? = nil
    var requestID: String? = nil
    var multiSelect: Bool = false
    var allowsFreeText: Bool = true
    /// Native option descriptions, shown under their choice.
    var choiceDetails: [String: String] = [:]
}

struct Attachment: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var url: URL
    var name: String { url.lastPathComponent }
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(url.pathExtension.lowercased()) }
}

struct PendingSubmission: Codable, Equatable {
    var id: String
    var draft: String
    var userTurnCount: Int
    var attachmentIDs: [UUID]
    /// Events from the original turn cannot acknowledge additional input.
    var isSteering: Bool? = nil
}

/// Keeps input recoverable while the composer is free for the next message.
struct StagedSubmission: Codable, Equatable {
    var message: ChatMessage
    var draft: String?
    var attachments: [Attachment]
}

struct CompanionSession: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var runtimeID: String?
    var storedID: String?
    var runtime: RuntimeKind = .hermes
    var profileID: String? = nil
    var isLegacyPrivate: Bool = false
    var migratedFromSessionID: String? = nil
    var nativeSubmissionAttempted: Bool = false
    var pendingSubmission: PendingSubmission? = nil
    var stagedSubmission: StagedSubmission? = nil
    var modelOverride: RuntimeModelChoice? = nil
    /// Nil is Inherit: the native profile's approvals apply.
    var permissionMode: PermissionMode? = nil
    var fullAccessConfirmed: Bool = false
    var runtimeInfo: RuntimeSessionInfo? = nil
    var trustedProjectPath: String? = nil
    var nativeActivityUnverified: String? = nil
    var title: String = "New session"
    var state: WorkState = .idle
    var messages: [ChatMessage] = []
    var tools: [ToolActivity] = []
    var agents: [ChildAgent] = []
    var changes: [TurnChanges] = []
    /// Tokens each companion turn used, as the runtime reported them; absent is unknown.
    var turnTokens: [String: Int] = [:]
    /// When each turn ended (completed, failed or stopped), keyed by its visible user row:
    /// steering and wakes share a turn ID but each starts its own block.
    var turnEndedAt: [String: Date] = [:]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Last opened, read or restored; with `updatedAt` it starts the auto-archive clock.
    var lastSeenAt: Date? = nil
    var draft: String = ""
    var attachments: [Attachment] = []
    var workspacePath: String? = nil
    var parentTurnComplete: Bool = true
    var completionID: String? = nil
    var acknowledgedCompletionID: String? = nil
    var isArchived: Bool = false
    /// An app-owned child lives inside this parent session only.
    var parentSessionID: String? = nil
    var delegation: DelegationRecord? = nil
    var queuedSends: [QueuedSend] = []
    var latestResponse: String { messages.last(where: { $0.role == "assistant" })?.text ?? "" }
    var isBusy: Bool { nativeActivityUnverified != nil || state == .working || state == .waiting || agents.contains { $0.state == .working || $0.state == .waiting } }
    /// Its own turn or native children are working; app-owned children are not counted.
    /// A turn is only live while connected: a restart leaves `parentTurnComplete` as it was.
    var isBusyIgnoringDelegates: Bool {
        nativeActivityUnverified != nil || (runtimeID != nil && !parentTurnComplete)
            || agents.contains { $0.sessionID == nil && ($0.state == .working || $0.state == .waiting) }
    }
    var recentTools: [ToolActivity] { Array(tools.suffix(3)) }
    var latestUserTurnID: String? { messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) }).map { $0.turnID ?? $0.id } }
    // Legacy children did not have turn metadata. On a legacy session they
    // remain relevant until the next real turn gives the session a new ID.
    var failedCurrentAgents: [ChildAgent] { agents.filter { $0.state == .failed && $0.turnID == latestUserTurnID } }
    var displayState: WorkState {
        if nativeActivityUnverified != nil { return .waiting }
        // Delivery uncertainty is a readable warning, not a live question.
        // The saved intent still blocks another send and silent reload.
        if pendingSubmission != nil && !isBusy { return .failed }
        if state == .waiting || agents.contains(where: { $0.state == .waiting }) { return .waiting }
        if isBusy { return .working }
        if state == .failed || !failedCurrentAgents.isEmpty { return .failed }
        return state
    }
    // Successful and failed results share durable read receipts. Older saved
    // results get a stable fallback; a later result creates a fresh receipt.
    private var completionReceipt: String {
        if let pendingSubmission { return "unconfirmed:\(pendingSubmission.id)" }
        let receipt = completionID ?? "legacy:\(id)"
        // Older failed sends could retain a previously read success receipt.
        return displayState == .failed ? "failed:\(receipt)" : receipt
    }
    var hasUnreadCompletion: Bool { displayState == .finished && acknowledgedCompletionID != completionReceipt }
    var hasUnreadFailure: Bool { displayState == .failed && acknowledgedCompletionID != completionReceipt }
    var hasUnreadResult: Bool { hasUnreadCompletion || hasUnreadFailure }

    @discardableResult
    mutating func acknowledgeResult() -> Bool {
        guard hasUnreadResult, !isBusy else { return false }
        acknowledgedCompletionID = completionReceipt
        lastSeenAt = Date()
        return true
    }

    /// Read, idle, with nothing pending or drafted, and untouched for `interval`:
    /// it leaves the default list for Archived without an archive flag.
    func isDormant(after interval: TimeInterval?, now: Date = Date()) -> Bool {
        guard let interval, !isArchived, CollapsedStatus.resolve(session: self) == .none, !isBusy,
              pendingSubmission == nil, queuedSends.isEmpty, attachments.isEmpty,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return max(updatedAt, lastSeenAt ?? .distantPast) < now.addingTimeInterval(-interval)
    }
}

/// Sessions that share a working folder.
struct SessionProject: Identifiable {
    let path: String
    var sessions: [CompanionSession]
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum PanelPage: Equatable {
    case session, sessions, team, agent(String), activity, settings, usage, runtimeSetup(RuntimeKind), runtimeChooser(defaultSelection: Bool)
    /// First-run choices, one step at a time; the step survives the panel closing for a preview.
    case welcome(step: Int)
    var isRuntimeSetup: Bool {
        switch self { case .runtimeSetup, .runtimeChooser: return true; default: return false }
    }
    var isWelcome: Bool { if case .welcome = self { return true }; return false }
}

enum CollapsedStatus: Equatable {
    case none, running, waiting, finished, failed

    var label: String {
        switch self {
        case .none: return "Ready"
        case .running: return "Working"
        case .waiting: return "Needs your input"
        case .finished: return "Finished"
        case .failed: return "Needs attention"
        }
    }

    static func resolve(sessions: [CompanionSession]) -> Self {
        if sessions.contains(where: { resolve(session: $0) == .waiting }) { return .waiting }
        if sessions.contains(where: { resolve(session: $0) == .running }) { return .running }
        guard let latest = sessions.filter({ resolve(session: $0) != .none }).max(by: { $0.updatedAt < $1.updatedAt }) else { return .none }
        return resolve(session: latest)
    }

    static func resolve(session: CompanionSession) -> Self {
        if session.nativeActivityUnverified != nil { return .waiting }
        if session.state == .waiting || session.agents.contains(where: { $0.state == .waiting }) { return .waiting }
        if session.isBusy { return .running }
        switch session.displayState {
        case .finished: return session.hasUnreadCompletion ? .finished : .none
        case .failed: return session.hasUnreadFailure ? .failed : .none
        default: return .none
        }
    }
}

struct SessionIndicator: Identifiable, Equatable {
    let id: String
    let title: String
    let status: CollapsedStatus
    var label: String { "\(title): \(status.label)" }

    static func resolve(sessions: [CompanionSession]) -> [Self] {
        sessions.compactMap { session in
            let status = CollapsedStatus.resolve(session: session)
            guard status != .none else { return nil }
            return Self(id: session.id, title: session.title, status: status)
        }
    }
}

// Additive persistence fields must not discard conversations from an older build.
extension CompanionSession {
    mutating func restoreStagedSubmission() {
        guard let staged = stagedSubmission else { return }
        if let original = staged.draft {
            draft = draft.isEmpty ? original : original + "\n\n" + draft
        }
        let existing = Set(attachments.map(\.id))
        attachments.insert(contentsOf: staged.attachments.filter { !existing.contains($0.id) }, at: 0)
        stagedSubmission = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, runtimeID, storedID, title, state, messages, tools, agents, changes, createdAt, updatedAt, draft, attachments, workspacePath, parentTurnComplete, completionID, acknowledgedCompletionID, isArchived, runtime, profileID, isLegacyPrivate, migratedFromSessionID, nativeSubmissionAttempted, pendingSubmission, stagedSubmission, modelOverride, permissionMode, fullAccessConfirmed, turnTokens, turnEndedAt, runtimeInfo, trustedProjectPath, nativeActivityUnverified, parentSessionID, delegation, queuedSends, lastSeenAt
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        runtimeID = try values.decodeIfPresent(String.self, forKey: .runtimeID)
        storedID = try values.decodeIfPresent(String.self, forKey: .storedID)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "New session"
        state = try values.decodeIfPresent(WorkState.self, forKey: .state) ?? .idle
        messages = try values.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        tools = try values.decodeIfPresent([ToolActivity].self, forKey: .tools) ?? []
        agents = try values.decodeIfPresent([ChildAgent].self, forKey: .agents) ?? []
        changes = try values.decodeIfPresent([TurnChanges].self, forKey: .changes) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        draft = try values.decodeIfPresent(String.self, forKey: .draft) ?? ""
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        workspacePath = try values.decodeIfPresent(String.self, forKey: .workspacePath)
        parentTurnComplete = try values.decodeIfPresent(Bool.self, forKey: .parentTurnComplete) ?? ![WorkState.working, .waiting].contains(state)
        completionID = try values.decodeIfPresent(String.self, forKey: .completionID)
        acknowledgedCompletionID = try values.decodeIfPresent(String.self, forKey: .acknowledgedCompletionID)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        runtime = try values.decodeIfPresent(RuntimeKind.self, forKey: .runtime) ?? .hermes
        // Old durable IDs refer only to the private bridge. Never send one to
        // the shared profile or silently begin a context-free replacement.
        isLegacyPrivate = try values.decodeIfPresent(Bool.self, forKey: .isLegacyPrivate)
            ?? (!values.contains(.runtime) && (storedID != nil || runtimeID != nil || !messages.isEmpty))
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
            ?? ((!values.contains(.runtime) || isLegacyPrivate) ? RuntimeRoute.defaultProfile(runtime, legacy: isLegacyPrivate) : nil)
        migratedFromSessionID = try values.decodeIfPresent(String.self, forKey: .migratedFromSessionID)
        nativeSubmissionAttempted = try values.decodeIfPresent(Bool.self, forKey: .nativeSubmissionAttempted) ?? !messages.isEmpty
        pendingSubmission = try values.decodeIfPresent(PendingSubmission.self, forKey: .pendingSubmission)
        stagedSubmission = try values.decodeIfPresent(StagedSubmission.self, forKey: .stagedSubmission)
        modelOverride = try values.decodeIfPresent(RuntimeModelChoice.self, forKey: .modelOverride)
        // A mode this build does not know falls back to Inherit instead of
        // discarding the conversation.
        permissionMode = try? values.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
        fullAccessConfirmed = try values.decodeIfPresent(Bool.self, forKey: .fullAccessConfirmed) ?? false
        turnTokens = try values.decodeIfPresent([String: Int].self, forKey: .turnTokens) ?? [:]
        turnEndedAt = try values.decodeIfPresent([String: Date].self, forKey: .turnEndedAt) ?? [:]
        runtimeInfo = try values.decodeIfPresent(RuntimeSessionInfo.self, forKey: .runtimeInfo)
        trustedProjectPath = try values.decodeIfPresent(String.self, forKey: .trustedProjectPath)
        nativeActivityUnverified = try values.decodeIfPresent(String.self, forKey: .nativeActivityUnverified)
        parentSessionID = try values.decodeIfPresent(String.self, forKey: .parentSessionID)
        delegation = try values.decodeIfPresent(DelegationRecord.self, forKey: .delegation)
        queuedSends = try values.decodeIfPresent([QueuedSend].self, forKey: .queuedSends) ?? []
        lastSeenAt = try values.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        // Assign legacy children to the current restored turn once, so future
        // prompts do not inherit an old child's failure.
        for index in agents.indices where agents[index].turnID == nil {
            agents[index].turnID = latestUserTurnID
        }
    }
}

struct NotchGeometry: Equatable {
    let screen: CGRect
    let hardware: CGRect
    let hasHardware: Bool
    var indicatorCount: Int = 0
    var mascotWidth: CGFloat = 58
    var panelWidth: CGFloat { min(560, max(1, screen.width - 24)) }
    /// The header's top row is the notch band (a physical camera or the simulated
    /// one) plus a little air for its controls: eyes and status left, icon
    /// controls right, nothing behind a camera. The title row follows below, so
    /// every display shares one layout.
    static let topRowExtra: CGFloat = 4
    static let titleRowHeight: CGFloat = 28
    var expandedTopRowHeight: CGFloat { bandHeight + Self.topRowExtra }
    var expandedBandHeight: CGFloat { min(screen.height, expandedTopRowHeight + Self.titleRowHeight) }
    /// Eye centerline below the top edge: the band's middle at rest, the top row's when expanded.
    func eyeCenterY(progress: CGFloat) -> CGFloat { (bandHeight + Self.topRowExtra * progress) / 2 }
    /// Expanded eyes keep their left edge on the 20-point content margin (half
    /// the eye pair is 9 points per unit scale).
    static let expandedEyeX: CGFloat = 20 + 9 * EyesDrawing.expandedScale
    /// A physical camera's left edge in expanded-panel coordinates; top-row text
    /// ends before it. The simulated notch hides nothing.
    var expandedCameraMinX: CGFloat? { hasHardware ? hardware.minX - expandedBandFrame.minX : nil }
    var bodyHeight: CGFloat { min(480, max(0, screen.height - expandedBandHeight - 24)) }

    init(screen: CGRect, topInset: CGFloat, leftArea: CGRect?, rightArea: CGRect?, indicatorCount: Int = 0) {
        self.screen = screen
        self.indicatorCount = max(0, indicatorCount)
        if topInset > 0, let leftArea, let rightArea, rightArea.minX > leftArea.maxX {
            // Cover the thin bottom seam at the reported camera safe-area edge.
            let height = topInset + 1
            hardware = CGRect(x: leftArea.maxX, y: screen.maxY - height,
                              width: rightArea.minX - leftArea.maxX, height: height)
            hasHardware = true
        } else {
            // Emulate a 200-point camera notch plus the left mascot extension.
            // Center the entire software silhouette on displays without a notch.
            hardware = CGRect(x: screen.midX - (200 - 58) / 2, y: screen.maxY - 32, width: 200, height: 32)
            hasHardware = false
        }
    }

    var bandHeight: CGFloat { hardware.height }
    var indicatorLayout: SessionIndicatorLayout {
        let available = screen.maxX - hardware.maxX - 12 + (hasHardware ? 0 : hardware.width)
        return SessionIndicatorLayout(count: indicatorCount, availableWidth: available)
    }
    // Grow the visible right shoulder for each session; no dot can be painted
    // underneath the physical camera. The simulated camera has drawable room.
    var dotShoulderWidth: CGFloat { hasHardware ? indicatorLayout.width : max(0, indicatorLayout.width - hardware.width) }
    /// A status announcement adds a label between the camera and the dots.
    var statusShoulderWidth: CGFloat {
        guard announcing else { return restShoulderWidth }
        if hasHardware { return dotShoulderWidth + announcementWidth + 10 }
        // A simulated camera is drawable, so the label can use its space;
        // the band still visibly widens to mark the moment.
        let available = hardware.width + dotShoulderWidth - 6 - max(12, indicatorLayout.width - 4)
        return dotShoulderWidth + max(Self.externalAnnouncementGrowth, announcementWidth + 4 - available)
    }
    /// The resting shoulder without an announcement: the dots, or the live
    /// activity (mirroring the eyes' extension) followed by the other dots.
    var restShoulderWidth: CGFloat {
        guard showsLiveActivity else { return dotShoulderWidth }
        if hasHardware {
            return Self.liveCameraGap + liveContentWidth + (indicatorCount > 0 ? indicatorLayout.width - Self.liveDotGap : 12)
        }
        // A simulated camera is drawable; the band still widens to mark it.
        return dotShoulderWidth + Self.externalLiveGrowth
    }
    var collapsedFrame: CGRect { restingFrame(shoulder: statusShoulderWidth) }
    private func restingFrame(shoulder: CGFloat) -> CGRect {
        let width = hardware.width + mascotWidth + shoulder
        return CGRect(x: hasHardware ? hardware.minX - mascotWidth : screen.midX - width / 2,
                      y: hardware.minY, width: width, height: hardware.height)
    }

    // MARK: Announcement and glance tiers

    /// While a session result is announced, the resting band widens on its
    /// right (like a compact island) to name it. Height never changes.
    var announcing = false
    /// The announcement label's natural width (see `NotchAnnouncement.labelWidth`).
    var announcementWidth: CGFloat = 156
    static let externalAnnouncementGrowth: CGFloat = 48
    /// The label's horizontal span in local resting-band coordinates: after the
    /// camera (or the eyes, on a simulated notch) and before the status dots.
    var announcementLabelSpan: ClosedRange<CGFloat> {
        let frame = collapsedFrame
        let start = hasHardware ? hardware.maxX - frame.minX + 10 : mascotWidth + 6
        let end = frame.width - max(Self.minimumDotGap, indicatorLayout.width - (indicatorCount == 0 ? 12 : 4))
        return start...max(start, end)
    }
    private static let minimumDotGap: CGFloat = 12

    // MARK: Live activity

    /// The live activity's natural width (its row of glyphs); 0 hides it.
    /// The host leaves it at 0 while an announcement names a session.
    var liveContentWidth: CGFloat = 0
    /// The sessions shown as glyphs; their dots fold into the live activity.
    var liveSessionIDs: [String] = []
    var showsLiveActivity: Bool { liveContentWidth > 0 && !announcing }
    static let liveCameraGap: CGFloat = 8
    /// Space kept between the live content and the first remaining dot's region.
    static let liveDotGap: CGFloat = 2
    static let externalLiveGrowth: CGFloat = 24
    /// The live content's span in local resting-band coordinates, right-aligned
    /// before any remaining dots.
    var liveSpan: ClosedRange<CGFloat> {
        let width = collapsedFrame.width
        let end = width - (indicatorCount > 0 ? indicatorLayout.width - Self.liveDotGap : 12)
        return max(0, end - liveContentWidth)...max(0, end)
    }

    /// Number of session rows the hover glance shows (0 renders a quiet row).
    var glanceRows = 0
    static let glanceRowHeight: CGFloat = 44
    static let glanceMaxRows = 3
    static let glanceTargetWidth: CGFloat = 420
    static let glanceTopPadding: CGFloat = 4
    static let glanceBottomPadding: CGFloat = 10
    /// Below session rows, a slim New session row. With no rows, the single
    /// quiet row is itself the New session action.
    static let glanceFooterHeight: CGFloat = 34
    /// Rows whose pending request can be answered in place carry a line of choices.
    var glanceActionRows = 0
    static let glanceActionHeight: CGFloat = 30
    var glanceContentHeight: CGFloat {
        let rows = max(1, min(Self.glanceMaxRows, glanceRows))
        return Self.glanceTopPadding + CGFloat(rows) * Self.glanceRowHeight
            + CGFloat(min(rows, max(0, glanceActionRows))) * Self.glanceActionHeight
            + (glanceRows > 0 ? Self.glanceFooterHeight : 0) + Self.glanceBottomPadding
    }
    /// A slightly larger island: centred like the expanded panel, always
    /// covering the resting band, never larger than the screen allows.
    var glanceFrame: CGRect { islandFrame(width: Self.glanceTargetWidth, height: bandHeight + glanceContentHeight) }
    private func islandFrame(width: CGFloat, height: CGFloat) -> CGRect {
        let resting = restingFrame(shoulder: restShoulderWidth)
        let centerX = hasHardware ? hardware.midX + (24 - mascotWidth) / 2 : screen.midX
        let target = min(width, max(1, screen.width - 24))
        let margin = min(12, max(0, (screen.width - target) / 2))
        let minX = max(screen.minX + margin, min(resting.minX, centerX - target / 2))
        let maxX = min(screen.maxX - margin, max(resting.maxX, centerX + target / 2))
        let height = min(screen.height, height)
        return CGRect(x: minX, y: screen.maxY - height, width: max(1, maxX - minX), height: height)
    }

    /// The mascot stage: a larger island where the mascot presents a moment, shaped
    /// and centred like the glance.
    static let stageWidth: CGFloat = 440
    /// The mascot's 150-point figure needs this much body below the band.
    static let mascotStageBodyHeight: CGFloat = 132
    /// The body's height for the presented moment, measured from its content
    /// (`StageContent.bodyHeight`); the host sets it before staging.
    var stageBodyHeight: CGFloat = mascotStageBodyHeight
    var stageFrame: CGRect { islandFrame(width: Self.stageWidth, height: bandHeight + stageBodyHeight) }
    /// A physical camera's right edge in glance coordinates; band text starts after it.
    var glanceCameraMaxX: CGFloat? { hasHardware ? hardware.maxX - glanceFrame.minX : nil }
    var glanceCameraMinX: CGFloat? { hasHardware ? hardware.minX - glanceFrame.minX : nil }
    var collapsedStatusCenter: CGPoint { CGPoint(x: collapsedFrame.maxX - 12, y: collapsedFrame.midY) }
    var expandedBandFrame: CGRect {
        // Reading bounds stay still as a completion is acknowledged or another
        // session starts. Only the resting status shoulder changes its width.
        let centerX = hasHardware ? hardware.midX + (24 - mascotWidth) / 2 : screen.midX
        let desiredX = centerX - panelWidth / 2
        let margin = min(12, max(0, (screen.width - panelWidth) / 2))
        let x = min(screen.maxX - margin - panelWidth, max(screen.minX + margin, desiredX))
        return CGRect(x: x, y: screen.maxY - expandedBandHeight,
                      width: panelWidth, height: expandedBandHeight)
    }
    var bodyFrame: CGRect {
        CGRect(x: expandedBandFrame.minX, y: expandedBandFrame.minY - bodyHeight,
               width: panelWidth, height: bodyHeight)
    }
    var expandedFrame: CGRect { expandedBandFrame.union(bodyFrame) }
    var mascotCenter: CGPoint { CGPoint(x: hardware.minX - mascotWidth / 2, y: hardware.midY) }
    var expandedMascotCenter: CGPoint {
        CGPoint(x: expandedBandFrame.minX + min(Self.expandedEyeX, panelWidth / 2), y: screen.maxY - eyeCenterY(progress: 1))
    }
}

enum MascotMotion {
    /// Continuous close-and-open curve rather than a one-frame binary blink.
    static func blinkAmount(at time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: 6.8)
        guard phase >= 0, phase < 0.24 else { return 0 }
        return pow(sin(.pi * phase / 0.24), 2)
    }
}

enum AppPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchCompanion", isDirectory: true)
    }
    static var workspace: URL { support.appendingPathComponent("Workspace", isDirectory: true) }
    static var sessions: URL { support.appendingPathComponent("sessions.json") }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

enum EventValue {
    static func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = value, JSONSerialization.isValidJSONObject(data), let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), let text = String(data: encoded, encoding: .utf8) { return text }
        return ""
    }
    static func summary(_ payload: [String: Any]) -> String {
        let args = payload["arguments"] as? [String: Any] ?? payload["args"] as? [String: Any] ?? payload["input"] as? [String: Any] ?? [:]
        for key in ["command", "query", "path", "url", "task", "prompt", "file_path"] {
            if let value = args[key] as? String, !value.isEmpty { return String(value.prefix(300)) }
        }
        return String(string(payload["description"] ?? payload["preview"]).prefix(300))
    }
}

enum SessionHistory {
    /// Hermes persists operational prompts as role=user. Prefer its explicit
    /// display typing; only recognize exact legacy envelopes when typing was
    /// absent (including old companion JSON that did not retain that metadata).
    static func isVisibleConversation(_ row: [String: Any]) -> Bool {
        guard let role = row["role"] as? String, let text = row["text"] as? String else { return false }
        if role == "assistant", AsyncQuestion.decode(row["questions"]) != nil { return true }
        return isVisibleConversation(role: role, text: text, displayKind: row["display_kind"] as? String)
    }

    static func isVisibleConversation(_ message: ChatMessage) -> Bool {
        if message.role == "assistant", message.questions != nil { return true }
        return isVisibleConversation(role: message.role, text: message.text, displayKind: nil)
    }

    private static func isVisibleConversation(role: String, text: String, displayKind: String?) -> Bool {
        guard ["user", "assistant"].contains(role), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if displayKind == "hidden" { return false }
        guard role == "user" else { return true }
        let operationalKinds: Set<String> = ["async_delegation_complete", "auto_continue", "model_switch", "personality_switch"]
        if let displayKind, operationalKinds.contains(displayKind) { return false }
        // A slash-skill invocation and future unfamiliar display kinds remain
        // real conversation text. Do not interpret their contents heuristically.
        if let displayKind, !displayKind.isEmpty { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = String(lines.first ?? "")
        let body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // Source: tools/process_registry_notifications.py. Requiring both the
        // exact envelope shape and its boilerplate preserves ordinary questions
        // that merely mention or quote "ASYNC DELEGATION".
        let legacyDelegations = [
            ("[ASYNC DELEGATION BATCH COMPLETE — ", "A background fan-out unit you dispatched earlier"),
            ("[ASYNC DELEGATION COMPLETE — ", "A background subagent you dispatched earlier"),
            ("[ASYNC DELEGATION TASK FAILED — ", "One subagent in a background fan-out you dispatched has failed")
        ]
        if legacyDelegations.contains(where: { header.hasPrefix($0.0) && header.hasSuffix("]") && body.hasPrefix($0.1) }) { return false }
        if trimmed.hasPrefix("[System note: Your previous turn was interrupted mid-run"),
           trimmed.contains("The interrupted request was:]") { return false }
        if header.hasPrefix("[System: The active model for this chat has changed to "), header.hasSuffix("]") { return false }
        return true
    }

    static func projectedMessage(_ message: ChatMessage) -> ChatMessage {
        guard message.role == "user" else { return message }
        var result = message
        result.text = projectedUserText(message.text)
        return result
    }

    static func syntheticTurnAliases(in messages: [ChatMessage]) -> [String: String] {
        var aliases: [String: String] = [:]
        var precedingUser: String?
        for message in messages where message.role == "user" {
            if isVisibleConversation(message) {
                precedingUser = message.turnID ?? message.id
            } else if let precedingUser {
                aliases[message.id] = precedingUser
                if let turnID = message.turnID { aliases[turnID] = precedingUser }
            }
        }
        return aliases
    }

    /// Recover an older saved app attachment bubble whose display text was
    /// overwritten by the backend's expanded model prompt. Match the app's
    /// standalone trailing @file blocks and Hermes's actual expansion header;
    /// leave ordinary prose, inline refs, and quoted section headings intact.
    static func projectedUserText(_ text: String) -> String {
        let markers = ["\n\n--- Context Warnings ---\n", "\n\n--- Attached Context ---\n\n"]
        let ranges = markers.compactMap { marker -> (String, Range<String.Index>)? in
            text.range(of: marker).map { (marker, $0) }
        }
        guard let first = ranges.min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return text }
        let generated = text[first.1.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let knownGeneratedBody = first.0.contains("Warnings")
            ? generated.hasPrefix("- @file:") || generated.hasPrefix("- @ context injection")
            : generated.hasPrefix("📄 @file:") || generated.hasPrefix("📎 @file:")
        guard knownGeneratedBody else { return text }
        var blocks = String(text[..<first.1.lowerBound]).components(separatedBy: "\n\n")
        var names: [String] = []
        while let last = blocks.last, last.hasPrefix("@file:"), !last.contains("\n") {
            var path = String(last.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { break }
            if let quote = path.first, ["`", "\"", "'"].contains(String(quote)), path.last == quote {
                path = String(path.dropFirst().dropLast())
            } else if path.contains(where: { $0.isWhitespace }) { break }
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { break }
            names.insert(name, at: 0)
            blocks.removeLast()
        }
        guard !names.isEmpty, !blocks.isEmpty else { return text }
        return blocks.joined(separator: "\n\n") + "\n\nAttached: " + names.joined(separator: ", ")
    }

    static func messages(_ rows: [[String: Any]], preserving previous: [ChatMessage] = []) -> [ChatMessage] {
        let visibleRows = rows.filter(isVisibleConversation)
        let visiblePrevious = previous.filter(isVisibleConversation).map(projectedMessage)
        // App display text for a file contains "Attached: name", while Hermes
        // stores expanded @file context. Matching per-role counts establish an
        // ordinal correspondence even when these representations differ. A
        // global cursor also requires that each correspondence remain ordered.
        // Extra restored commentary must not invalidate the user-row mapping.
        let previousByRole = Dictionary(grouping: visiblePrevious.indices, by: { visiblePrevious[$0].role })
        let restoredByRole = Dictionary(grouping: visibleRows, by: { $0["role"] as? String ?? "" })
        var roleOrdinals: [String: Int] = [:]
        var priorCursor = 0
        var currentTurnID: String?
        var previousDate: Date?
        return visibleRows.map { row in
            let role = row["role"] as? String ?? ""
            let rawText = row["text"] as? String ?? ""
            let text = role == "user" ? projectedUserText(rawText) : rawText
            let rowID = EventValue.string(row["row_id"])
            let backendID = rowID.isEmpty ? nil : "hermes-\(rowID)"
            let remaining = visiblePrevious.indices.dropFirst(priorCursor)
            let exactID = backendID.flatMap { id in remaining.first { visiblePrevious[$0].id == id && visiblePrevious[$0].role == role } }
            let ordinal = roleOrdinals[role, default: 0]
            roleOrdinals[role] = ordinal + 1
            let priorRoleIndices = previousByRole[role] ?? []
            let ordinalMatch = priorRoleIndices.count == restoredByRole[role]?.count && ordinal < priorRoleIndices.count
                ? priorRoleIndices[ordinal] : nil
            let matchingIndex: Int?
            if let exactID {
                matchingIndex = exactID
            } else if let ordinalMatch, ordinalMatch >= priorCursor {
                matchingIndex = ordinalMatch
            } else {
                matchingIndex = remaining.first { visiblePrevious[$0].role == role && visiblePrevious[$0].text == text }
            }
            let prior = matchingIndex.map { visiblePrevious[$0] }
            if let matchingIndex { priorCursor = matchingIndex + 1 }
            let id = prior?.id ?? backendID ?? UUID().uuidString
            if role == "user" { currentTurnID = prior?.turnID ?? prior?.id ?? id }
            // An unmatched reply without a native time stays at its turn's start, not
            // after that turn's tools: it inherits the previous row's time.
            let createdAt = prior?.createdAt ?? (row["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? (role == "assistant" ? previousDate : nil) ?? Date()
            previousDate = createdAt
            return ChatMessage(id: id, role: role, text: role == "user" ? prior?.text ?? text : text,
                               createdAt: createdAt,
                               turnID: prior?.turnID ?? currentTurnID,
                               questions: role == "assistant" ? AsyncQuestion.decode(row["questions"]) ?? prior?.questions : nil,
                               kind: prior?.kind)
        }
    }
}
