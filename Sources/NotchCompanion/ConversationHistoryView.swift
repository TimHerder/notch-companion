import SwiftUI
import AppKit

/// The same complete, scrollable transcript is used in the notch and full window.
struct ConversationHistoryView: View {
    /// Offscreen fixtures cannot hover, so they show the answers' hover controls this way.
    nonisolated(unsafe) static var revealsHoverControls = false
    @ObservedObject var model: AppModel
    var inNotch = true
    /// The full-session window's find field is open; closing it resumes following.
    var findOpen = false
    /// Its current match, revealed and highlighted.
    var find: TranscriptFindMatch? = nil
    @State private var derived = TranscriptDerivation()

    var body: some View {
        Transcript(model: model, derived: derived, shown: TranscriptDependencies(model, derived),
                   inNotch: inNotch, findOpen: findOpen, find: find)
            .equatable()
    }
}

/// The transcript itself. It does not observe the model, which publishes for every event of
/// every session and every frame the notch moves: what it draws comes from `shown`, and it is
/// evaluated again only when that changed. The model is here for the actions, and for
/// questions about `shown.session` alone.
private struct Transcript: View, Equatable {
    let model: AppModel
    let derived: TranscriptDerivation
    var shown: TranscriptDependencies
    var inNotch: Bool
    var findOpen: Bool
    var find: TranscriptFindMatch?
    @StateObject private var scrolling = HistoryScrollCoordinator()

    static func == (a: Self, b: Self) -> Bool {
        a.shown == b.shown && a.inNotch == b.inNotch && a.findOpen == b.findOpen && a.find == b.find
    }

    var body: some View {
        ScrollViewReader { proxy in
        let session = shown.session
        let items = shown.items
        let latestChanges = derived.latestChanges
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: PanelTheme.pick(16, 18, 19)) {
                    if let session, let fork = session.forkedFrom { forkedFromHeader(fork, sideChat: session.isSideChat) }
                    ForEach(items) { item in
                        switch item {
                        case .message(let message) where message.isSessionMarker:
                            SessionMarkerRow(message: message, expanded: shown.expandedWork.contains("marker:\(message.id)")) {
                                if model.expandedWork.remove("marker:\(message.id)") == nil {
                                    model.expandedWork.insert("marker:\(message.id)")
                                    scrolling.stopFollowing()
                                }
                            }
                            .transcriptFindRow("message:\(message.id)")
                        case .message(let message) where message.delegationSummary != nil:
                            let childID = message.delegationChildID.flatMap { id in shown.sessionIDs.contains(id) ? id : nil }
                            DelegationResultRow(summary: message.delegationSummary ?? "", failed: message.delegationSummary?.hasSuffix(" failed") == true,
                                                open: childID.map { id in { model.openDelegatedSession(id) } })
                                .transcriptFindRow("message:\(message.id)")
                        case .message(let message):
                            messageView(message, commentary: false)
                                .transition(message.id == session?.stagedSubmission?.message.id && !shown.reducedMotion
                                    ? .asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .identity)
                                    : .identity)
                        case .commentary(let message):
                            messageView(message, commentary: true)
                        case .tools(let group):
                            TranscriptToolGroup(group: group, reducedMotion: shown.reducedMotion,
                                                onInspect: scrolling.stopFollowing, reveal: find?.group == group.id).equatable()
                        case .work(let work):
                            TurnWorkView(work: work, expanded: !work.folds || shown.expandedWork.contains(work.id), toggle: {
                                if model.expandedWork.remove(work.id) == nil {
                                    model.expandedWork.insert(work.id)
                                    scrolling.stopFollowing()
                                }
                            }, resume: session.flatMap { session in shown.resumableTurns.contains(work.turnRowID)
                                ? { model.resumeAtReset(session.id, turn: work.turnRowID) } : nil }) {
                                ForEach(work.entries) { entry in
                                    switch entry {
                                    case .commentary(let message), .message(let message):
                                        messageView(message, commentary: true)
                                    case .tools(let group):
                                        TranscriptToolGroup(group: group, reducedMotion: shown.reducedMotion,
                                                            onInspect: scrolling.stopFollowing, inWork: true).equatable()
                                    default: EmptyView()
                                    }
                                }
                            }
                        case .changes(let summary):
                            let key = "\(session?.id ?? ""):\(summary.id)"
                            let shows = shown.changeDisclosure[key] ?? latestChanges.contains(summary.id)
                            ChangeSummaryView(summary: summary, editorName: shown.codeEditorName,
                                              open: { model.openInCodeEditor($0) },
                                              chooseEditor: { model.openInCodeEditor($0, choose: true) },
                                              onInspect: scrolling.stopFollowing,
                                              showsFiles: shows, toggle: { model.changeDisclosure[key] = !shows },
                                              fileLimit: inNotch ? 3 : 6,
                                              actions: session.flatMap { session in latestChanges.contains(summary.id) ? GitActionsView(
                                                controller: model.gitActions(for: session.id),
                                                blocked: shown.gitActionsIdle ? nil : "Git actions wait until this session, its delegated work, sessions in the same folder and any unconfirmed send are idle.",
                                                pullRequest: session.pullRequest, isWorktree: session.worktree != nil,
                                                watching: session.pullRequestWatch != nil, watchError: shown.watchError, harness: session.runtime.title,
                                                openURL: { model.openExternally($0) }) : nil })
                        }
                    }
                    .animation(shown.reducedMotion ? nil : .easeOut(duration: 0.18),
                               value: session?.stagedSubmission?.message.id)
                    if session?.stagedSubmission != nil && session?.pendingSubmission == nil {
                        Group {
                            switch PanelTheme.current {
                            case .refined:
                                Text("Sending…").font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            case .tahoe:
                                Text("Sending…").font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            case .instrument:
                                Text("Sending…").font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                            }
                        }
                        .accessibilityLabel("Sending message")
                        .transition(.identity)
                    }
                    if let session, session.isBusy {
                        LiveTurnFooter(since: SessionDigest.turnStart(session) ?? session.updatedAt,
                                       waiting: session.state == .waiting,
                                       hint: workingHint(session).map { hint in session.goalFooter.map { hint + " · " + $0 } ?? hint } ?? session.goalFooter,
                                       reducedMotion: shown.reducedMotion)
                    }
                    Color.clear.frame(height: 2).id("conversation-tail")
                }
                // Refined and Tahoe: text sits on the panel's margin, under the title and the field's edge.
                // As deep as the edge fades, so content at rest is never faded.
                .padding(.vertical, 14).padding(.horizontal, PanelTheme.pick(0, 0, 3))
                .background(alignment: .topLeading) {
                    HistoryScrollProbe(coordinator: scrolling)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
            // Content dissolves as it passes under the header and into the composer, never sliced.
            // A lazy transcript with rows taller than the view (an unfolded turn) can
            // lose its rows when scrolled to the end from the top or from another
            // session's offset. Each session gets its own scroll view, opened at the end.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .environment(\.transcriptFindTarget, find?.id)
            .id(session?.id)
            .scrollEdgeFade(top: 14, bottom: 14)
            .accessibilityLabel("Conversation history")
            // Links in answers open in their own app; local paths open as files.
            .environment(\.openURL, OpenURLAction { url in
                model.openExternally(MessageContent.linkDestination(url, workspace: model.currentWorkspacePath))
                return .handled
            })
            .overlay(alignment: .bottomTrailing) {
                if !scrolling.followsLatest { jumpToLatest }
            }
            // A new draft chooses its harness and folder in the middle of its empty conversation.
            .overlay {
                if shown.choosesRuntime, let session { emptyDraft(session) }
            }
        }
        .onChange(of: HistoryRevision(session)) { old, new in
            if old.sessionID != new.sessionID { scrolling.resetForSession() }
            scrolling.contentChanged()
        }
        .onAppear {
            scrolling.installScrollAction {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("conversation-tail", anchor: .bottom) }
            }
        }
        .onDisappear { scrolling.removeScrollAction() }
        // Closing find resumes following, as Jump to latest does, whether or not anything matched.
        .onChange(of: findOpen) { _, open in if !open { scrolling.jumpToLatest() } }
        .onChange(of: find, initial: true) { _, new in
            guard let new else { return }
            scrolling.stopFollowing()
            if let work = new.work { model.expandedWork.insert(work) }
            // The lazy item is realized first, then the row inside it is centred.
            DispatchQueue.main.async {
                proxy.scrollTo(new.item, anchor: .top)
                DispatchQueue.main.async { proxy.scrollTo(new.scrollID, anchor: .center) }
            }
        }
        .onChange(of: shown.revealed) { _, revealed in
            if revealed { scrolling.revealIfFollowing() }
        }
        }
    }

    /// Without a configured harness it says how to start; otherwise only the choosers.
    private func emptyDraft(_ session: CompanionSession) -> some View {
        VStack(spacing: 14) {
            if shown.noRuntimes {
                VStack(spacing: 6) {
                    Text("Connect a harness to get started.")
                        .font(CompanionStyle.title)
                    Text("Your draft and files stay here.")
                        .font(CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary)
                }
                .multilineTextAlignment(.center)
            }
            DraftDestinationView(model: model, session: session)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var jumpToLatest: some View {
        let title = scrolling.hasNewActivity ? "New activity" : "Jump to latest"
        switch PanelTheme.current {
        case .refined:
            Button { scrolling.jumpToLatest() } label: {
                Label(title, systemImage: "arrow.down")
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                    .notchControlBackground(Capsule(), fallback: CompanionStyle.surface)
            }.buttonStyle(.plain).foregroundStyle(CompanionStyle.text).pressableCursor()
            .padding(.bottom, 8).frame(maxWidth: .infinity)
        case .tahoe:
            Button { scrolling.jumpToLatest() } label: {
                Label(title, systemImage: "arrow.down")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                    .notchControlBackground(Capsule(), fallback: CompanionStyle.elevated)
                    .overlay(Capsule().strokeBorder(GlassEdge.gradient(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }.buttonStyle(.plain).foregroundStyle(CompanionStyle.text).pressableCursor()
            .padding(.trailing, 10).padding(.bottom, 6)
        case .instrument:
            Button { scrolling.jumpToLatest() } label: {
                Label(title, systemImage: "arrow.down")
            }
            .buttonStyle(NotchPillButtonStyle(small: true, selected: scrolling.hasNewActivity))
            .background(Color.black, in: RoundedRectangle(cornerRadius: CompanionStyle.radius))
            .padding(.trailing, 6).padding(.bottom, 6)
        }
    }
}

extension Transcript {
    fileprivate func messageView(_ message: ChatMessage, commentary: Bool) -> some View {
        let session = shown.session
        let sessionID = session?.id ?? ""
        let forks = !commentary && derived.forks(message.id) { session.flatMap { model.forkPoint(message.id, in: $0) } != nil }
        let edits = !commentary && derived.edits(message.id) { session.flatMap { model.rewindPoint(message.id, in: $0) } != nil }
        return TranscriptMessageView(message: message, runtimeTitle: session?.runtime.title ?? shown.defaultRuntimeTitle,
                                     questionStatus: questionStatus(message, in: session), commentary: commentary,
                                     open: { url, reveal in model.openExternally(url, reveal: reveal) },
                                     reply: { questions, answers in await model.replyToQuestions(questions, answers: answers) },
                                     quote: { [inNotch] text in model.quoteInReply(text, inNotch: inNotch) },
                                     fork: forks ? { Task { await model.forkFromHere(message.id, in: sessionID) } } : nil,
                                     forkBlocker: shown.forkBlocker,
                                     edit: edits ? { Task { await model.editFromHere(message.id, in: sessionID) } } : nil,
                                     editBlocker: shown.editBlocker)
            .equatable()
            .transcriptFindRow("message:\(message.id)")
    }

    /// A quiet line over a fork's copied history that opens the session it came from.
    fileprivate func forkedFromHeader(_ fork: ForkRecord, sideChat: Bool) -> some View {
        let source = shown.sessionIDs.firstIndex(of: fork.sourceSessionID).map { shown.sessionTitles[$0] }
        let text = (sideChat ? "Side chat of " : "Forked from ") + (source ?? fork.sourceTitle)
        return Button { if source != nil { model.selectSession(fork.sourceSessionID) } } label: {
            Label(text, systemImage: "arrow.triangle.branch").font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .buttonStyle(.plain).foregroundStyle(CompanionStyle.secondary)
        .disabled(source == nil).pressableCursor()
        .help(source.map { "Open \($0)" } ?? "The source session was deleted")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Delegated agents still at work; the transcript already shows tools and text.
    fileprivate func workingHint(_ session: CompanionSession) -> String? {
        let agents = session.agents.filter { $0.state == .working }
        if agents.count > 1 { return "\(agents.count) delegated agents working" }
        return agents.first.map { "\($0.title) is working" }
    }

    fileprivate func questionStatus(_ message: ChatMessage, in session: CompanionSession?) -> AsyncQuestionCard.Status? {
        guard message.questions != nil, let session else { return nil }
        guard ConversationTimeline.questionsOpen(message.id, in: session) else { return .answered }
        let runtime = session.runtime.title
        if session.isBusy { return .open(canReply: false, hint: "Reply when \(runtime) finishes this turn.") }
        if shown.submitting { return .open(canReply: false, hint: "Sending…") }
        if session.pendingSubmission != nil { return .open(canReply: false, hint: "Check the last send before replying.") }
        return .open(canReply: true, hint: "Sent as your next message.")
    }
}

/// Everything the transcript reads from the model, as values. Whatever a row newly reads from
/// the model belongs here, or the transcript will not notice it change.
private struct TranscriptDependencies: Equatable {
    /// Without its draft, which the composer alone shows: typing leaves the transcript as it is.
    var session: CompanionSession?
    var items: TimelineItems
    var expandedWork: Set<String>
    var changeDisclosure: [String: Bool]
    var reducedMotion: Bool
    var submitting: Bool
    /// The panel has opened far enough to show its content.
    var revealed: Bool
    var codeEditorName: String
    var defaultRuntimeTitle: String
    /// Why Fork from here and Edit from here must wait, the same for every row.
    var forkBlocker: String?
    var editBlocker: String?
    var gitActionsIdle = true
    var watchError: String?
    /// Limit-stopped turns that offer Resume at reset.
    var resumableTurns: Set<String> = []
    /// The day, while a limit-stopped turn words its reset by it ("resets 3:40 PM", or with its date).
    var day: Date?
    /// An empty draft chooses its harness and folder, and says so when none is set up.
    var choosesRuntime = false
    var noRuntimes = false
    /// The other sessions, as delegation rows and a fork's header name them.
    var sessionIDs: [String]
    var sessionTitles: [String]

    @MainActor init(_ model: AppModel, _ derived: TranscriptDerivation) {
        var session = model.current
        session?.draft = ""
        self.session = session
        items = derived.timeline(for: session)
        expandedWork = model.expandedWork
        changeDisclosure = model.changeDisclosure
        reducedMotion = model.reducedMotion
        submitting = model.submitting
        revealed = model.notchPresentation.contentIsInteractive
        codeEditorName = model.codeEditorName
        defaultRuntimeTitle = model.defaultRuntime.title
        forkBlocker = session.flatMap(model.forkBlocker)
        editBlocker = session.flatMap { model.rewindBlocker($0) }
        if let session {
            // Only the latest change card offers Git actions, and only an empty draft its choosers.
            if !derived.latestChanges.isEmpty { gitActionsIdle = model.gitActionsIdle(session.id) }
            watchError = model.pullRequestPolls[session.id]?.error
            resumableTurns = Set(session.limitResets.keys.filter { model.canResumeAtReset(session.id, turn: $0) })
            if !session.limitResets.isEmpty { day = Calendar.app.startOfDay(for: Date()) }
            choosesRuntime = items.isEmpty && model.canChangeRuntime(session.id)
            noRuntimes = choosesRuntime && model.readyRuntimes.isEmpty
        }
        sessionIDs = model.sessions.map(\.id)
        sessionTitles = model.sessions.map(\.title)
    }
}

/// What the transcript derives from its session, kept until the session changes. The model
/// publishes far more often than that, and each of these walks the whole history.
@MainActor private final class TranscriptDerivation {
    private var source: CompanionSession?
    private var items = TimelineItems()
    private(set) var latestChanges: Set<String> = []
    private var forkable: [String: Bool] = [:]
    private var editable: [String: Bool] = [:]

    func timeline(for session: CompanionSession?) -> TimelineItems {
        if session != source {
            source = session
            let built = session.map(ConversationTimeline.build) ?? []
            items = TimelineItems(items: built, build: items.build + 1)
            latestChanges = session.map { ChangeSummaryView.latestFinished(in: built, session: $0) } ?? []
            forkable = [:]
            editable = [:]
        }
        return items
    }

    /// Whether a row offers Fork from here, found once per row and session change.
    func forks(_ id: String, _ find: () -> Bool) -> Bool {
        if let known = forkable[id] { return known }
        let found = find()
        forkable[id] = found
        return found
    }

    func edits(_ id: String, _ find: () -> Bool) -> Bool {
        if let known = editable[id] { return known }
        let found = find()
        editable[id] = found
        return found
    }
}

/// One build of the timeline. SwiftUI compares the list it is given at every level of the
/// view above it, and comparing a long history item by item costs more than building it:
/// two lists are the same when they are the same build.
private struct TimelineItems: RandomAccessCollection, Equatable {
    var items: [ConversationTimelineItem] = []
    var build = 0
    var startIndex: Int { items.startIndex }
    var endIndex: Int { items.endIndex }
    subscript(position: Int) -> ConversationTimelineItem { items[position] }
    static func == (a: Self, b: Self) -> Bool { a.build == b.build }
}

private struct HistoryRevision: Equatable {
    var sessionID: String?
    var messageCount: Int
    var stagedMessageID: String?
    var lastMessage: String
    var toolCount: Int
    var finishedTools: Int
    var state: WorkState
    var changes: [TurnChanges]

    init(_ session: CompanionSession?) {
        sessionID = session?.id
        messageCount = session?.messages.count ?? 0
        stagedMessageID = session?.stagedSubmission?.message.id
        lastMessage = session?.messages.last?.text ?? ""
        toolCount = session?.tools.count ?? 0
        finishedTools = session?.tools.filter { $0.state != .working }.count ?? 0
        state = session?.state ?? .idle
        changes = session?.changes ?? []
    }
}

private struct TranscriptMessageView: View, Equatable {
    var message: ChatMessage
    var runtimeTitle: String
    var questionStatus: AsyncQuestionCard.Status?
    /// Text written between tool calls: a step smaller and quieter, with no header or copy.
    var commentary = false
    var open: (URL, Bool) -> Void
    var reply: ([AsyncQuestion], [String]) async -> Bool
    var quote: ((String) -> Void)? = nil
    /// Fork from here, where the harness can fork at this answer; disabled with the reason while it must wait.
    var fork: (() -> Void)? = nil
    var forkBlocker: String? = nil
    /// Edit from here, on your own messages where the harness can rewind to before them.
    var edit: (() -> Void)? = nil
    var editBlocker: String? = nil
    @State private var hovering = false
    @FocusState private var copyFocused: Bool
    @FocusState private var quoteFocused: Bool
    @FocusState private var forkFocused: Bool
    @FocusState private var editFocused: Bool

    /// Hover or keyboard focus shows Copy (and Quote in reply).
    private var revealed: Bool { hovering || copyFocused || quoteFocused || forkFocused || ConversationHistoryView.revealsHoverControls }
    private var forks: Bool { quotes && fork != nil }
    private var edits: Bool { edit != nil && isOwnMessage }
    private var editRevealed: Bool { hovering || editFocused || ConversationHistoryView.revealsHoverControls }
    /// An agent's own answer can be quoted into the reply; commentary and relayed messages cannot.
    private var quotes: Bool {
        quote != nil && !commentary && message.role == "assistant" && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Refined and Tahoe: your own words read as a sent bubble at the trailing edge.
    private var isOwnMessage: Bool { message.role == "user" && message.agentLabel == nil }

    /// The actions hold only the model, this row's IDs and `inNotch`, none of which change for a
    /// row, so they are left out: a row redraws only when what it shows changed.
    static func == (a: Self, b: Self) -> Bool {
        a.message == b.message && a.runtimeTitle == b.runtimeTitle && a.questionStatus == b.questionStatus
            && a.commentary == b.commentary && (a.quote == nil) == (b.quote == nil)
            && (a.fork == nil) == (b.fork == nil) && a.forkBlocker == b.forkBlocker
            && (a.edit == nil) == (b.edit == nil) && a.editBlocker == b.editBlocker
    }

    var body: some View {
        if quotes {
            entry
                .contextMenu {
                    Button("Quote in reply", systemImage: "text.quote") { quote?(message.text) }
                    if forks { Button("Fork from here", systemImage: "arrow.triangle.branch") { fork?() }.disabled(forkBlocker != nil) }
                    Button("Copy message", systemImage: "doc.on.doc", action: copy)
                }
                .accessibilityAction(named: "Quote in reply") { quote?(message.text) }
                .accessibilityActions {
                    if forks { Button("Fork from here") { if forkBlocker == nil { fork?() } } }
                }
        } else if edits {
            entry
                .contextMenu {
                    Button("Edit from here", systemImage: "pencil") { edit?() }.disabled(editBlocker != nil)
                    Button("Copy message", systemImage: "doc.on.doc", action: copy)
                }
                .accessibilityActions {
                    Button("Edit from here") { if editBlocker == nil { edit?() } }
                }
        } else {
            entry
        }
    }

    /// Which files a row delivers is read against the disk (a path with spaces, a local image),
    /// and nothing publishes when one appears: a row that may hold one is read again every
    /// second. Each file's card asks for its own file.
    @ViewBuilder private var entry: some View {
        if message.role != "user", message.text.holdsBytes("MEDIA:") || message.text.holdsBytes("![") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in drawn }
        } else {
            drawn
        }
    }

    @ViewBuilder private var drawn: some View {
        if commentary && message.role == "assistant" {
            commentaryBody
        } else {
            switch PanelTheme.current {
            case .refined:
                Group {
                    if isOwnMessage { refinedUserBubble } else { refinedAgentReply(label: message.agentLabel) }
                }
                .onHover { hovering = $0 }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Copy message", copy)
            case .tahoe:
                if isOwnMessage { tahoeOwnMessage } else { tahoeTranscriptMessage }
            case .instrument:
                instrumentEntry
            }
        }
    }

    private var commentaryBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            messageBody(content, interpretsMarkdown: true, questionGap: 4)
        }
        .environment(\.markdownBodySize, 12)
        .foregroundStyle(CompanionStyle.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The answer's copy control floats at its top edge while the pointer is over it.
    private var floatingCopyButton: some View {
        HStack(spacing: 4) {
            if quotes {
                quoteButton.notchControlBackground(Circle(), fallback: CompanionStyle.surface).focused($quoteFocused)
            }
            if forks {
                forkButton.notchControlBackground(Circle(), fallback: CompanionStyle.surface).focused($forkFocused)
            }
            copyButton.notchControlBackground(Circle(), fallback: CompanionStyle.surface).focused($copyFocused)
        }
        .opacity(revealed ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: revealed)
    }

    /// Delivered files leave the text and appear as previews or cards.
    private var content: MessageContent {
        message.role == "user" ? MessageContent(text: message.text, media: []) : MessageContent.parse(message.text)
    }

    @ViewBuilder private func messageBody(_ content: MessageContent, interpretsMarkdown: Bool, questionGap: CGFloat) -> some View {
        if !content.text.isEmpty || (content.media.isEmpty && message.questions == nil) {
            MarkdownContentView(text: content.text, interpretsMarkdown: interpretsMarkdown)
        }
        if !content.media.isEmpty { MessageMediaList(media: content.media, open: open) }
        if let questions = message.questions, let questionStatus {
            AsyncQuestionCard(questions: questions, asker: runtimeTitle, status: questionStatus) { answers in
                await reply(questions, answers)
            }
            .id(message.id)
            .padding(.top, content.text.isEmpty ? 0 : questionGap)
        }
    }

    private var copyButton: some View {
        Button(action: copy) { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
            .buttonStyle(NotchIconButtonStyle(size: 22))
            .help("Copy message").accessibilityLabel("Copy message")
    }

    private var quoteButton: some View {
        Button { quote?(message.text) } label: { Image(systemName: "text.quote").font(.system(size: 10)) }
            .buttonStyle(NotchIconButtonStyle(size: 22))
            .help("Quote in reply").accessibilityLabel("Quote in reply")
    }

    private var forkButton: some View {
        Button { fork?() } label: { Image(systemName: "arrow.triangle.branch").font(.system(size: 10)) }
            .buttonStyle(NotchIconButtonStyle(size: 22))
            .disabled(forkBlocker != nil)
            .help(forkBlocker.map { "Fork from here: \($0)" } ?? "Fork from here").accessibilityLabel("Fork from here")
    }

    private var editButton: some View {
        Button { edit?() } label: { Image(systemName: "pencil").font(.system(size: 10)) }
            .buttonStyle(NotchIconButtonStyle(size: 22))
            .disabled(editBlocker != nil)
            .help(editBlocker.map { "Edit from here: \($0)" } ?? "Edit from here").accessibilityLabel("Edit from here")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    // MARK: Refined

    /// Your own words: a quiet bubble on the right that hugs short messages.
    private var refinedUserBubble: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 48)
            refinedCopyButton.padding(.top, 5)
            if edits {
                editButton.focused($editFocused).padding(.top, 5)
                    .opacity(editRevealed ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: editRevealed)
            }
            Text(verbatim: message.text)
                .font(CompanionStyle.body).lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(CompanionStyle.raised, in: RoundedRectangle(cornerRadius: CompanionStyle.Radius.field, style: .continuous))
                .accessibilityLabel("You: \(message.text)")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The agent's answer reads as a page; messages sent for another agent
    /// sit in a card under their branch label.
    private func refinedAgentReply(label: String?) -> some View {
        let content = content
        return VStack(alignment: .leading, spacing: 6) {
            // The session names its harness; only relayed messages carry a label.
            if let label {
                HStack(spacing: 6) {
                    Label(label, systemImage: message.kind == ChatMessage.goal ? "scope" : "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CompanionStyle.secondary)
                    Spacer(minLength: 0)
                    refinedCopyButton.padding(.vertical, -4)
                }
            }
            messageBody(content, interpretsMarkdown: true, questionGap: 4)
        }
        .padding(label == nil ? 0 : 12)
        .background(label == nil ? .clear : CompanionStyle.well, in: RoundedRectangle(cornerRadius: CompanionStyle.Radius.row, style: .continuous))
        .overlay(alignment: .topTrailing) { if label == nil { floatingCopyButton.offset(y: -3) } }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Copy waits for the pointer, so a long transcript is not lined with icons.
    private var refinedCopyButton: some View {
        copyButton
            // Keyboard focus shows it too, so tabbing never lands on an invisible control.
            .focused($copyFocused)
            .opacity(hovering || copyFocused ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering || copyFocused)
    }

    // MARK: Tahoe

    /// Your own words read as a sent bubble at the trailing edge, as in Messages.
    private var tahoeOwnMessage: some View {
        HStack(alignment: .center, spacing: 6) {
            Spacer(minLength: 64)
            // Copy shows beside the bubble while the pointer is over it.
            copyButton.opacity(hovering ? 1 : 0)
            if edits { editButton.focused($editFocused).opacity(editRevealed ? 1 : 0) }
            Text(verbatim: message.text)
                .font(.system(size: 13)).lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(CompanionStyle.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var tahoeTranscriptMessage: some View {
        let content = content
        let relayed = message.agentLabel != nil
        return VStack(alignment: .leading, spacing: 6) {
            if let label = message.agentLabel {
                HStack(spacing: 6) {
                    Label(label, systemImage: message.kind == ChatMessage.goal ? "scope" : "arrow.triangle.branch").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CompanionStyle.secondary)
                    Spacer()
                    copyButton.padding(.vertical, -3)
                }
            }
            messageBody(content, interpretsMarkdown: message.role != "user" || message.agentLabel != nil, questionGap: 3)
        }
        .padding(.horizontal, relayed ? 14 : 0).padding(.vertical, relayed ? 11 : 3)
        .background { if relayed { Color.clear.notchGroup(cornerRadius: 14) } }
        .overlay(alignment: .topTrailing) { if !relayed { floatingCopyButton } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copy message", copy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Instrument

    private var instrumentEntry: some View {
        let content = content
        let user = message.role == "user"
        return VStack(alignment: .leading, spacing: 8) {
            // Each entry opens on a ruled log header: who, then when.
            HStack(spacing: 8) {
                if let label = message.agentLabel {
                    Label(label, systemImage: message.kind == ChatMessage.goal ? "scope" : "arrow.triangle.branch").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CompanionStyle.text)
                } else if user {
                    Text("You").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(CompanionStyle.secondary)
                } else {
                    // The answer's mark; the session already names its harness.
                    Rectangle().fill(CompanionStyle.text).frame(width: 5, height: 5)
                        .accessibilityLabel(runtimeTitle)
                }
                Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
                Text(message.createdAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(CompanionStyle.faint)
                if quotes { quoteButton.padding(.vertical, -4) }
                if forks { forkButton.padding(.vertical, -4) }
                if edits { editButton.padding(.vertical, -4) }
                copyButton.padding(.vertical, -4)
            }
            messageBody(content, interpretsMarkdown: message.role != "user" || message.agentLabel != nil, questionGap: 3)
        }
        .padding(.horizontal, user ? 12 : 0).padding(.vertical, user ? 10 : 0)
        .background {
            // Your words sit in an inset readout; the agent's answer stands on the panel.
            if user {
                let shape = RoundedRectangle(cornerRadius: CompanionStyle.cardRadius, style: .continuous)
                shape.fill(Color(white: 0.06)).overlay(shape.strokeBorder(CompanionStyle.rule, lineWidth: 0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A delegated child's wake, drawn as a compact activity row that opens the child.
private struct DelegationResultRow: View {
    var summary: String
    var failed: Bool
    var open: (() -> Void)?
    var body: some View {
        row
            .help(open == nil ? summary : "Open the delegated session")
            .accessibilityLabel(summary)
            .accessibilityHint(open == nil ? "" : "Opens the delegated session")
    }

    @ViewBuilder private var row: some View {
        switch PanelTheme.current {
        case .refined:
            Button { open?() } label: {
                HStack(spacing: 8) {
                    Image(systemName: failed ? "exclamationmark.circle" : "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CompanionStyle.color(failed ? .failed : .finished)).frame(width: 16)
                    Text(summary).font(CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if open != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CompanionStyle.tertiary) }
                }
                .frame(height: 34).padding(.horizontal, 10)
            }
            .buttonStyle(NotchRowButtonStyle()).disabled(open == nil)
            .background(CompanionStyle.well, in: RoundedRectangle(cornerRadius: CompanionStyle.Radius.row, style: .continuous))
        case .tahoe:
            Button { open?() } label: {
                HStack(spacing: 10) {
                    SettingsIcon(symbol: failed ? "exclamationmark" : "arrow.triangle.branch", tint: failed ? .red : .indigo)
                    Text(summary).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 5)
                    if open != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CompanionStyle.faint) }
                }.frame(height: 38).padding(.horizontal, 8).contentShape(Rectangle())
            }
            .buttonStyle(NotchRowButtonStyle(cornerRadius: 12)).disabled(open == nil)
            .background(CompanionStyle.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .instrument:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.radius, style: .continuous)
            Button { open?() } label: {
                HStack(spacing: 9) {
                    Image(systemName: failed ? "exclamationmark.triangle" : "arrow.triangle.branch").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(failed ? CompanionStyle.error : CompanionStyle.secondary).frame(width: 14)
                    Text(summary).font(CompanionStyle.mono(11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 5)
                    Text(failed ? "ERR" : "DONE").microLabel(9.5, weight: .semibold, tracking: 0.6)
                        .foregroundStyle(failed ? CompanionStyle.error : CompanionStyle.faint).accessibilityHidden(true)
                    if open != nil { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(CompanionStyle.faint) }
                }.frame(height: 30).padding(.horizontal, 10).contentShape(Rectangle())
            }
            .buttonStyle(NotchRowButtonStyle()).disabled(open == nil)
            .overlay(shape.strokeBorder(failed ? CompanionStyle.error.opacity(0.55) : CompanionStyle.rule, lineWidth: 0.5))
        }
    }
}

private struct TranscriptToolGroup: View, Equatable {
    var group: ToolCallGroup
    var reducedMotion: Bool
    var onInspect: () -> Void
    /// Inside an unfolded turn every call shows as its own row.
    var inWork = false
    /// Find selected a call behind the collapsed line, so it shows.
    var reveal = false
    @State private var showsOlder = false

    static func == (a: Self, b: Self) -> Bool {
        a.group == b.group && a.reducedMotion == b.reducedMotion && a.inWork == b.inWork && a.reveal == b.reveal
    }

    var body: some View {
        let theme = PanelTheme.current
        VStack(alignment: .leading, spacing: PanelTheme.pick(4, 6, 6)) {
            if inWork {
                calls(group.tools)
            } else if !group.olderTools.isEmpty {
                let count = group.isLive ? group.olderTools.count : group.tools.count
                let open = showsOlder || reveal
                Button { showsOlder = !open } label: {
                    DisclosureLine(title: "\(count) \(group.isLive ? "earlier " : "")tool \(count == 1 ? "call" : "calls")", expanded: open)
                }
                .buttonStyle(.plain).pressableCursor()
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                .onChange(of: showsOlder) { _, open in if open { onInspect() } }
                if open { calls(group.olderTools) }
            }
            if group.isLive {
                VStack(spacing: 0) {
                    ForEach(group.liveTools) { tool in
                        ToolRow(tool: tool).transcriptFindRow("tool:\(tool.id)")
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .clipped()
                .animation(reducedMotion ? nil : .spring(response: 0.30, dampingFraction: 0.90), value: group.liveTools.map(\.id))
            }
        }
        // Refined and Tahoe: plain rows on the page. Instrument: a log column, one
        // hairline down its leading edge (an unfolded turn already draws one).
        .padding(.leading, theme == .instrument && !inWork ? 12 : 0).padding(.vertical, theme == .instrument ? 4 : 0)
        .overlay(alignment: .leading) { if theme == .instrument && !inWork { Rectangle().fill(CompanionStyle.ruleStrong).frame(width: 1) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.isLive ? "Live tool activity, most recent three calls" : "Tool activity")
    }

    private func calls(_ tools: [ToolActivity]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tools) { tool in ToolHistoryDetail(tool: tool, onInspect: onInspect).transcriptFindRow("tool:\(tool.id)") }
        }
    }
}

/// A quiet disclosure line: a turning chevron (or a status symbol), a label, and
/// optionally a rule to the trailing edge.
private struct DisclosureLine: View {
    var title: String
    /// Nil draws a static line without a chevron.
    var expanded: Bool?
    var symbol: (name: String, color: Color)? = nil
    var rule = false
    @State private var hovering = false

    var body: some View {
        let theme = PanelTheme.current
        HStack(spacing: theme == .instrument ? 7 : 6) {
            if let expanded {
                Image(systemName: "chevron.right").font(.system(size: theme == .instrument ? 8 : 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
            } else if let symbol {
                Image(systemName: symbol.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(symbol.color)
            }
            switch theme {
            case .refined: Text(title).font(CompanionStyle.callout.monospacedDigit())
            case .tahoe: Text(title).font(.system(size: 12, weight: .medium).monospacedDigit())
            case .instrument: Text(title).font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
            if rule {
                Rectangle().fill(PanelTheme.pick(CompanionStyle.hairline, CompanionStyle.separator, CompanionStyle.rule))
                    .frame(height: 0.5).padding(.leading, 4)
            }
        }
        .foregroundStyle(hovering && expanded != nil ? CompanionStyle.text : PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
        .frame(minHeight: 20, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A finished turn's work above its answer: "Worked for 2:14", unfolding the
/// commentary and tool calls in the order they happened. A turn without an
/// answer keeps its work open under the header.
private struct TurnWorkView<Content: View>: View {
    var work: TurnWork
    var expanded: Bool
    var toggle: () -> Void
    /// Resume at reset, offered on a limit-stopped turn's line.
    var resume: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.pick(10, 10, 8)) {
            HStack(spacing: 8) {
                header
                if let resume {
                    Button("Resume at reset", action: resume)
                        .buttonStyle(NotchToolbarButtonStyle(height: PanelTheme.current == .instrument ? 20 : 22))
                        .fixedSize()
                        .help("Send “\(QueuedSend.resumeText)” when the limit resets")
                }
            }
            if expanded && !work.entries.isEmpty {
                VStack(alignment: .leading, spacing: PanelTheme.pick(10, 10, 9)) { content }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(PanelTheme.pick(CompanionStyle.hairline, CompanionStyle.separator, CompanionStyle.ruleStrong)).frame(width: 1)
                    }
                    .padding(.leading, 4.5)
            }
        }
    }

    @ViewBuilder private var header: some View {
        if work.folds {
            Button(action: toggle) { DisclosureLine(title: work.label, expanded: expanded, rule: true) }
                .buttonStyle(.plain).pressableCursor()
                .help(expanded ? "Hide the work" : "Show the commentary and tool calls")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        } else {
            let symbol: (name: String, color: Color)? = switch work.outcome {
            case .failed: ("exclamationmark.circle", CompanionStyle.color(.failed))
            case .interrupted: ("stop.circle", CompanionStyle.secondary)
            default: nil
            }
            DisclosureLine(title: work.label, expanded: nil, symbol: symbol, rule: true)
                .accessibilityElement(children: .combine)
        }
    }
}

/// “Context compacted”, unfolding the native summary when there is one, or the
/// “New session” rule where Start fresh opened a new native session.
private struct SessionMarkerRow: View {
    var message: ChatMessage
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        let summary = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.kind == ChatMessage.goalReached {
            VStack(alignment: .leading, spacing: PanelTheme.pick(6, 6, 5)) {
                DisclosureLine(title: "Goal reached", expanded: nil, symbol: ("checkmark.circle", CompanionStyle.color(.finished)), rule: true)
                if !summary.isEmpty {
                    Text(summary).font(PanelTheme.pick(CompanionStyle.caption, .system(size: 12), .system(size: 11.5)))
                        .foregroundStyle(CompanionStyle.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(PanelTheme.pick(CompanionStyle.hairline, CompanionStyle.separator, CompanionStyle.ruleStrong)).frame(width: 1)
                        }
                        .padding(.leading, 4.5)
                }
            }
            .accessibilityElement(children: .combine)
        } else if message.kind == ChatMessage.newSession {
            DisclosureLine(title: "New session", expanded: nil, symbol: ("plus.bubble", CompanionStyle.secondary), rule: true)
                .accessibilityElement(children: .combine)
                .help("A new native session started here, with an empty context")
        } else if summary.isEmpty {
            DisclosureLine(title: "Context compacted", expanded: nil, symbol: ("arrow.down.right.and.arrow.up.left", CompanionStyle.secondary), rule: true)
                .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: PanelTheme.pick(10, 10, 8)) {
                Button(action: toggle) { DisclosureLine(title: "Context compacted", expanded: expanded, rule: true) }
                    .buttonStyle(.plain).pressableCursor()
                    .help(expanded ? "Hide the summary" : "Show the summary the harness kept")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    Text(summary).font(PanelTheme.pick(CompanionStyle.caption, .system(size: 12), .system(size: 11.5)))
                        .foregroundStyle(CompanionStyle.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(PanelTheme.pick(CompanionStyle.hairline, CompanionStyle.separator, CompanionStyle.ruleStrong)).frame(width: 1)
                        }
                        .padding(.leading, 4.5)
                }
            }
        }
    }
}

/// Under the newest content while the turn runs: how long it has been working. While
/// the turn waits on you nothing is running, so a still question mark replaces the spinner.
private struct LiveTurnFooter: View {
    var since: Date
    var waiting: Bool
    var hint: String?
    var reducedMotion: Bool

    var body: some View {
        let theme = PanelTheme.current
        HStack(spacing: 8) {
            switch theme {
            case .refined, .tahoe:
                if waiting {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CompanionStyle.color(.waiting)).accessibilityHidden(true)
                } else if theme == .refined {
                    ProgressView().controlSize(.mini).tint(CompanionStyle.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            case .instrument: LED(color: waiting ? CompanionStyle.amber : CompanionStyle.signal, pulsing: !waiting, size: 5)
            }
            Group {
                if waiting {
                    Text("Waiting for your reply…")
                } else {
                    // Only the label ticks; the transcript around it stays put.
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("Working for " + TurnWork.format(context.date.timeIntervalSince(since)))
                            .contentTransition(reducedMotion ? .identity : .numericText(countsDown: false))
                    }
                }
            }
            .foregroundStyle(theme == .instrument && waiting ? CompanionStyle.amber : CompanionStyle.secondary)
            if let hint {
                Text(hint).foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.faint, CompanionStyle.faint))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .modifier(FooterType())
        .padding(.vertical, PanelTheme.pick(4, 5, 5))
        .accessibilityElement(children: .combine)
    }

    private struct FooterType: ViewModifier {
        func body(content: Content) -> some View {
            switch PanelTheme.current {
            case .refined: content.font(CompanionStyle.callout.monospacedDigit())
            case .tahoe: content.font(.system(size: 12.5).monospacedDigit())
            case .instrument: content.font(.system(size: 11.5).monospacedDigit())
            }
        }
    }
}

/// A finished call: the row opens its recorded output below it.
private struct ToolHistoryDetail: View {
    var tool: ToolActivity
    var onInspect: () -> Void
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: { ToolRow(tool: tool).contentShape(Rectangle()) }
                .buttonStyle(.plain).pressableCursor()
                .accessibilityHint(open ? "Hides the output" : "Shows the output")
            if open {
                let output = Text(tool.output.isEmpty ? (tool.detail.isEmpty ? "No output was recorded." : tool.detail) : tool.output)
                if PanelTheme.current == .instrument {
                    output
                        .font(CompanionStyle.mono(10.5)).foregroundStyle(CompanionStyle.secondary).lineSpacing(2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                        .background(CompanionStyle.inset, in: RoundedRectangle(cornerRadius: CompanionStyle.radius))
                        .overlay(RoundedRectangle(cornerRadius: CompanionStyle.radius).strokeBorder(CompanionStyle.rule, lineWidth: 0.5))
                        .padding(.vertical, 4)
                } else {
                    // Under the call's name, past its status column.
                    output
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(CompanionStyle.secondary).lineSpacing(2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, PanelTheme.pick(22, 24, 0)).padding(.top, 2).padding(.bottom, 8)
                }
            }
        }
        .onChange(of: open) { _, expanded in if expanded { onInspect() } }
    }
}


/// Tracks actual native scrolling, including trackpads and the scrollbar. Appends
/// follow the bottom only when the user was there; inspecting history suspends it.
@MainActor
final class HistoryScrollCoordinator: ObservableObject {
    @Published private(set) var followsLatest = true
    /// Published only when it changes: each publication re-evaluates the transcript, and it is
    /// written with every scroll at the end and every delta while reading back.
    private(set) var hasNewActivity: Bool {
        get { newActivity }
        set { if newActivity != newValue { newActivity = newValue } }
    }
    @Published private var newActivity = false
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var wheelMonitor: Any?
    private var isProgrammatic = false
    private var followIntent = true
    private var scheduled = false
    private var lastDocumentHeight: CGFloat = 0
    private var lastOriginY: CGFloat = 0
    private var scrollAction: (() -> Void)?
    private var pendingFollow = false
    private var programmaticGeneration = 0

    func attach(_ scroll: NSScrollView) {
        guard scroll !== scrollView else { return }
        detach()
        scrollView = scroll
        lastDocumentHeight = scroll.documentView?.bounds.height ?? 0
        lastOriginY = scroll.contentView.bounds.minY
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        }
        if let document = scroll.documentView {
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.followIntent == true { self?.scheduleBottom() } }
            }
        }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let scroll = self.scrollView, event.window === scroll.window,
                      abs(event.scrollingDeltaY) > 0,
                      scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return }
                self.userBeganScrolling()
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scroll = self.scrollView, let document = scroll.documentView else { return }
                    if self.distanceToBottom(scroll: scroll, document: document) <= 6 {
                        self.setFollowing(true)
                        self.hasNewActivity = false
                    }
                }
            }
            return event
        }
        scheduleBottom()
    }

    func detach() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        boundsObserver = nil; frameObserver = nil; scrollView = nil
        wheelMonitor = nil
    }

    func installScrollAction(_ action: @escaping () -> Void) {
        scrollAction = action
        if pendingFollow || followIntent { scheduleBottom() }
    }
    func removeScrollAction() { scrollAction = nil }
    func revealIfFollowing() { if followIntent { scheduleBottom() } }
    func userBeganScrolling() {
        programmaticGeneration += 1
        isProgrammatic = false
        pendingFollow = false
        setFollowing(false)
    }
    func stopFollowing() { userBeganScrolling() }
    func resetForSession() { setFollowing(true); hasNewActivity = false; scheduleBottom() }
    func jumpToLatest() { setFollowing(true); hasNewActivity = false; scheduleBottom() }
    func contentChanged() {
        if followIntent { scheduleBottom() }
        else { hasNewActivity = true }
    }

    private func boundsChanged() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let bounds = scrollView.contentView.bounds
        let layoutChanged = abs(document.bounds.height - lastDocumentHeight) > 0.5
        let positionChanged = abs(bounds.minY - lastOriginY) > 0.5
        lastDocumentHeight = document.bounds.height
        lastOriginY = bounds.minY
        // Lazy layout and collapsing tool groups can clamp the clip origin.
        // That is not the user's decision to follow a running conversation.
        guard !isProgrammatic, positionChanged else { return }
        let distance = distanceToBottom(scroll: scrollView, document: document)
        let atBottom = distance <= 6
        if !atBottom {
            // Stop synchronously before a previously queued follow operation
            // executes. LazyVStack can remeasure while the user scrolls upward.
            setFollowing(false)
        } else if !layoutChanged {
            setFollowing(true)
            DispatchQueue.main.async { [weak self] in
                if self?.followIntent == true { self?.hasNewActivity = false }
            }
        }
    }

    private func setFollowing(_ value: Bool) {
        followIntent = value
        // Only the SwiftUI-facing publication is deferred out of AppKit layout;
        // the intent above immediately cancels queued automatic scrolling.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.followsLatest != self.followIntent { self.followsLatest = self.followIntent }
        }
    }

    private func distanceToBottom(scroll: NSScrollView, document: NSView) -> CGFloat {
        let bounds = scroll.contentView.bounds
        return document.isFlipped ? document.bounds.maxY - bounds.maxY : bounds.minY - document.bounds.minY
    }

    private func scheduleBottom() {
        guard followIntent else { return }
        pendingFollow = true
        guard scrollAction != nil else { return }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.followIntent, let action = self.scrollAction else { return }
            self.pendingFollow = false
            self.programmaticGeneration += 1
            let generation = self.programmaticGeneration
            self.isProgrammatic = true
            // SwiftUI owns its lazy transcript's scroll position. Moving the
            // backing NSClipView directly leaves its visible-row cache stale.
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self, self.programmaticGeneration == generation else { return }
                self.isProgrammatic = false
                self.lastDocumentHeight = self.scrollView?.documentView?.bounds.height ?? 0
                self.lastOriginY = self.scrollView?.contentView.bounds.minY ?? 0
            }
        }
    }
}

private struct HistoryScrollProbe: NSViewRepresentable {
    var coordinator: HistoryScrollCoordinator
    func makeNSView(context: Context) -> ProbeView { let view = ProbeView(); view.coordinator = coordinator; return view }
    func updateNSView(_ view: ProbeView, context: Context) { view.coordinator = coordinator; view.findScrollView() }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.coordinator?.detach() }

    @MainActor final class ProbeView: NSView {
        weak var coordinator: HistoryScrollCoordinator?
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); findScrollView() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); findScrollView() }
        func findScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                self.coordinator?.attach(scroll)
            }
        }
    }
}
