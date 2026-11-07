import SwiftUI
import AppKit

/// The same complete, scrollable transcript is used in the notch and full window.
struct ConversationHistoryView: View {
    @ObservedObject var model: AppModel
    var inNotch = true
    @StateObject private var scrolling = HistoryScrollCoordinator()

    private var session: CompanionSession? { model.current }
    private var timeline: [ConversationTimelineItem] { session.map(ConversationTimeline.build) ?? [] }
    private var revision: HistoryRevision {
        HistoryRevision(sessionID: session?.id, messageCount: session?.messages.count ?? 0,
                        stagedMessageID: session?.stagedSubmission?.message.id,
                        lastMessage: session?.messages.last?.text ?? "", toolCount: session?.tools.count ?? 0,
                        finishedTools: session?.tools.filter { $0.state != .working }.count ?? 0,
                        state: session?.state ?? .idle, changes: session?.changes ?? [])
    }

    var body: some View {
        ScrollViewReader { proxy in
        let items = timeline
        let latestChanges = session.map { ChangeSummaryView.latestFinished(in: items, session: $0) } ?? []
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: PanelTheme.pick(16, 18, 19)) {
                    if items.isEmpty {
                        let needsSetup = session.map { model.canChangeRuntime($0.id) } == true && model.readyRuntimes.isEmpty
                        emptyState(needsSetup: needsSetup)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .message(let message) where message.delegationSummary != nil:
                            let childID = message.delegationChildID.flatMap { id in model.sessions.contains { $0.id == id } ? id : nil }
                            DelegationResultRow(summary: message.delegationSummary ?? "", failed: message.delegationSummary?.hasSuffix(" failed") == true,
                                                open: childID.map { id in { model.openDelegatedSession(id) } })
                        case .message(let message):
                            messageView(message, commentary: false)
                                .transition(message.id == session?.stagedSubmission?.message.id && !model.reducedMotion
                                    ? .asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .identity)
                                    : .identity)
                        case .commentary(let message):
                            messageView(message, commentary: true)
                        case .tools(let group):
                            TranscriptToolGroup(group: group, reducedMotion: model.reducedMotion,
                                                onInspect: scrolling.stopFollowing)
                        case .work(let work):
                            TurnWorkView(work: work, expanded: !work.folds || model.expandedWork.contains(work.id), toggle: {
                                if model.expandedWork.remove(work.id) == nil {
                                    model.expandedWork.insert(work.id)
                                    scrolling.stopFollowing()
                                }
                            }) {
                                ForEach(work.entries) { entry in
                                    switch entry {
                                    case .commentary(let message), .message(let message):
                                        messageView(message, commentary: true)
                                    case .tools(let group):
                                        TranscriptToolGroup(group: group, reducedMotion: model.reducedMotion,
                                                            onInspect: scrolling.stopFollowing, inWork: true)
                                    default: EmptyView()
                                    }
                                }
                            }
                        case .changes(let summary):
                            let key = "\(session?.id ?? ""):\(summary.id)"
                            let shows = model.changeDisclosure[key] ?? latestChanges.contains(summary.id)
                            ChangeSummaryView(summary: summary, editorName: model.codeEditorName,
                                              open: { model.openInCodeEditor($0) },
                                              chooseEditor: { model.openInCodeEditor($0, choose: true) },
                                              onInspect: scrolling.stopFollowing,
                                              showsFiles: shows, toggle: { model.changeDisclosure[key] = !shows },
                                              fileLimit: inNotch ? 3 : 6)
                        }
                    }
                    .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18),
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
                                Text("Sending…").microLabel(9.5, tracking: 0.7).foregroundStyle(CompanionStyle.secondary)
                            }
                        }
                        .accessibilityLabel("Sending message")
                        .transition(.identity)
                    }
                    if let session, session.isBusy {
                        LiveTurnFooter(since: SessionDigest.turnStart(session) ?? session.updatedAt,
                                       waiting: session.state == .waiting, hint: workingHint(session), reducedMotion: model.reducedMotion)
                    }
                    Color.clear.frame(height: 2).id("conversation-tail")
                }
                // Refined and Tahoe: text sits on the panel's margin, under the title and the field's edge.
                .padding(.vertical, 12).padding(.horizontal, PanelTheme.pick(0, 0, 3))
                .background(alignment: .topLeading) {
                    HistoryScrollProbe(coordinator: scrolling)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
            // Content softens as it passes under the title and into the composer
            // (Tahoe: only under the title, like a system scroll edge).
            .scrollEdgeFade(top: PanelTheme.pick(12, 12, 14), bottom: PanelTheme.pick(12, 0, 10))
            .accessibilityLabel("Conversation history")
            // Links in answers open in their own app; local paths open as files.
            .environment(\.openURL, OpenURLAction { url in
                model.openExternally(MessageContent.linkDestination(url, workspace: model.currentWorkspacePath))
                return .handled
            })
            .overlay(alignment: .bottomTrailing) {
                if !scrolling.followsLatest { jumpToLatest }
            }
        }
        .onChange(of: revision) { old, new in
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
        .onChange(of: model.notchPresentation.contentIsInteractive) { _, revealed in
            if revealed { scrolling.revealIfFollowing() }
        }
        }
    }

    @ViewBuilder private func emptyState(needsSetup: Bool) -> some View {
        switch PanelTheme.current {
        case .refined:
            VStack(alignment: .leading, spacing: 8) {
                Text(needsSetup ? "Connect a harness to get started." : "Ready when you are.").font(CompanionStyle.display)
                Text(needsSetup ? "Set up your preferred harness in Settings. Your draft and files stay here." : "A question, a project, a little rabbit hole.")
                    .font(CompanionStyle.body).foregroundStyle(CompanionStyle.secondary)
                Label("Drop a file onto the notch to attach it.", systemImage: "doc.badge.plus")
                    .font(CompanionStyle.callout).foregroundStyle(CompanionStyle.tertiary).padding(.top, 16)
            }.padding(.vertical, 32).frame(maxWidth: .infinity, alignment: .leading)
        case .tahoe:
            // A native empty state: a quiet symbol, a title and one line, centred.
            VStack(spacing: 6) {
                Image(systemName: needsSetup ? "puzzlepiece.extension" : "bubble.left.and.text.bubble.right")
                    .font(.system(size: 34, weight: .light)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(CompanionStyle.secondary).frame(height: 44).padding(.bottom, 8)
                    .accessibilityHidden(true)
                Text(needsSetup ? "Connect a harness to get started." : "Ready when you are.").font(.system(size: 17, weight: .semibold))
                Text(needsSetup ? "Set up your preferred harness in Settings. Your draft and files stay here." : "A question, a project, a little rabbit hole.").font(.system(size: 13)).foregroundStyle(CompanionStyle.secondary)
                Label("Drop a file onto the notch to attach it.", systemImage: "doc.badge.plus")
                    .font(.system(size: 12)).foregroundStyle(CompanionStyle.secondary).padding(.top, 14)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 84).padding(.horizontal, 30).frame(maxWidth: .infinity)
        case .instrument:
            VStack(alignment: .leading, spacing: 10) {
                RuleLabel(needsSetup ? "No harness" : "Standby · \(session?.runtime.title ?? model.defaultRuntime.title)",
                          color: needsSetup ? CompanionStyle.signal : CompanionStyle.secondary)
                    .padding(.bottom, 8)
                Text(needsSetup ? "Connect a harness to get started." : "Ready when you are.")
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                Text(needsSetup ? "Set up your preferred harness in Settings. Your draft and files stay here." : "A question, a project, a little rabbit hole.").font(.system(size: 13)).foregroundStyle(CompanionStyle.secondary)
                Label("Drop a file onto the notch to attach it", systemImage: "arrow.down.to.line")
                    .microLabel(9.5, weight: .regular, tracking: 0.6).foregroundStyle(CompanionStyle.faint).padding(.top, 14)
            }.padding(.top, 26).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading)
        }
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

extension ConversationHistoryView {
    fileprivate func messageView(_ message: ChatMessage, commentary: Bool) -> some View {
        TranscriptMessageView(message: message, runtimeTitle: session?.runtime.title ?? model.defaultRuntime.title,
                              questionStatus: questionStatus(message), commentary: commentary,
                              open: { url, reveal in model.openExternally(url, reveal: reveal) },
                              reply: { questions, answers in await model.replyToQuestions(questions, answers: answers) })
    }

    /// Delegated agents still at work; the transcript already shows tools and text.
    fileprivate func workingHint(_ session: CompanionSession) -> String? {
        let agents = session.agents.filter { $0.state == .working }
        if agents.count > 1 { return "\(agents.count) delegated agents working" }
        return agents.first.map { "\($0.title) is working" }
    }

    fileprivate func questionStatus(_ message: ChatMessage) -> AsyncQuestionCard.Status? {
        guard message.questions != nil, let session else { return nil }
        guard ConversationTimeline.questionsOpen(message.id, in: session) else { return .answered }
        let runtime = session.runtime.title
        if session.isBusy { return .open(canReply: false, hint: "Reply when \(runtime) finishes this turn.") }
        if model.submitting { return .open(canReply: false, hint: "Sending…") }
        if session.pendingSubmission != nil { return .open(canReply: false, hint: "Check the last send before replying.") }
        return .open(canReply: true, hint: "Sent as your next message.")
    }
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
}

private struct TranscriptMessageView: View {
    var message: ChatMessage
    var runtimeTitle: String
    var questionStatus: AsyncQuestionCard.Status?
    /// Text written between tool calls: a step smaller and quieter, with no header or copy.
    var commentary = false
    var open: (URL, Bool) -> Void
    var reply: ([AsyncQuestion], [String]) async -> Bool
    @State private var hovering = false
    @FocusState private var copyFocused: Bool

    /// Refined and Tahoe: your own words read as a sent bubble at the trailing edge.
    private var isOwnMessage: Bool { message.role == "user" && message.agentLabel == nil }

    var body: some View {
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
        copyButton
            .notchControlBackground(Circle(), fallback: CompanionStyle.surface)
            .focused($copyFocused)
            .opacity(hovering || copyFocused ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering || copyFocused)
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
                    Label(label, systemImage: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
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
                    Label(label, systemImage: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold))
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
                    Label(label, systemImage: "arrow.triangle.branch").microLabel(10, weight: .semibold)
                        .foregroundStyle(CompanionStyle.text)
                } else if user {
                    Text("› You").microLabel(10, weight: .semibold).foregroundStyle(CompanionStyle.secondary)
                        .accessibilityLabel("You")
                } else {
                    // The answer's mark; the session already names its harness.
                    Rectangle().fill(CompanionStyle.text).frame(width: 5, height: 5)
                        .accessibilityLabel(runtimeTitle)
                }
                Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
                Text(message.createdAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(CompanionStyle.mono(10).monospacedDigit()).foregroundStyle(CompanionStyle.faint)
                copyButton.padding(.vertical, -4)
            }
            messageBody(content, interpretsMarkdown: message.role != "user" || message.agentLabel != nil, questionGap: 3)
        }
        .padding(.horizontal, user ? 12 : 0).padding(.vertical, user ? 10 : 0)
        .background {
            // Your words sit in an inset readout; the agent's answer stands on the grid.
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
                        .foregroundStyle(failed ? CompanionStyle.signal : CompanionStyle.secondary).frame(width: 14)
                    Text(summary).font(CompanionStyle.mono(11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 5)
                    Text(failed ? "ERR" : "DONE").microLabel(9.5, weight: .semibold, tracking: 0.6)
                        .foregroundStyle(failed ? CompanionStyle.signal : CompanionStyle.faint).accessibilityHidden(true)
                    if open != nil { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(CompanionStyle.faint) }
                }.frame(height: 30).padding(.horizontal, 10).contentShape(Rectangle())
            }
            .buttonStyle(NotchRowButtonStyle()).disabled(open == nil)
            .overlay(shape.strokeBorder(failed ? CompanionStyle.signal.opacity(0.55) : CompanionStyle.rule, lineWidth: 0.5))
        }
    }
}

private struct TranscriptToolGroup: View {
    var group: ToolCallGroup
    var reducedMotion: Bool
    var onInspect: () -> Void
    /// Inside an unfolded turn every call shows as its own row.
    var inWork = false
    @State private var showsOlder = false

    var body: some View {
        let theme = PanelTheme.current
        VStack(alignment: .leading, spacing: PanelTheme.pick(4, 6, 6)) {
            if inWork {
                calls(group.tools)
            } else if !group.olderTools.isEmpty {
                let count = group.isLive ? group.olderTools.count : group.tools.count
                Button { showsOlder.toggle() } label: {
                    DisclosureLine(title: "\(count) \(group.isLive ? "earlier " : "")tool \(count == 1 ? "call" : "calls")", expanded: showsOlder)
                }
                .buttonStyle(.plain).pressableCursor()
                .accessibilityValue(showsOlder ? "Expanded" : "Collapsed")
                .onChange(of: showsOlder) { _, open in if open { onInspect() } }
                if showsOlder { calls(group.olderTools) }
            }
            if group.isLive {
                VStack(spacing: 0) {
                    ForEach(group.liveTools) { tool in
                        ToolRow(tool: tool)
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
        VStack(alignment: .leading, spacing: 0) { ForEach(tools) { tool in ToolHistoryDetail(tool: tool, onInspect: onInspect) } }
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
            case .instrument: Text(title).microLabel(9.5, tracking: 0.7)
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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.pick(10, 10, 8)) {
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
            case .instrument: LED(color: waiting ? CompanionStyle.signal : CompanionStyle.text, pulsing: !waiting, size: 5)
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
            .foregroundStyle(theme == .instrument && waiting ? CompanionStyle.signal : CompanionStyle.secondary)
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
            case .instrument: content.microLabel(9.5, tracking: 0.7)
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
    @Published private(set) var hasNewActivity = false
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
