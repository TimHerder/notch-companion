import SwiftUI

/// What hovering the resting notch should reveal.
enum HoverPreview: String, CaseIterable, Identifiable {
    case glance, panel
    static let key = "notch.hoverPreview"
    var id: Self { self }
    var label: String { self == .glance ? "Glance" : "Full panel" }
}

/// One glanceable line about a companion session. Derived from real session
/// state only; a glance never acknowledges a result as read.
struct GlanceEntry: Identifiable, Equatable {
    enum Status: Equatable { case needsInput, working, failed, finished, stopped, idle }

    let id: String
    let title: String
    let status: Status
    let unread: Bool
    let detail: String
    let runtime: String
    /// Turn start while working (for a live timer), otherwise the last update.
    let since: Date
    /// The detail is the tail of a streaming answer and truncates at its head.
    var streaming = false
    /// Choices that answer the pending request straight from the glance.
    var quickReply: GlanceQuickReply? = nil
    /// A running turn the glance can stop.
    var canStop = false

    var accessibilityLabel: String {
        let state: String
        switch status {
        case .needsInput: state = "Needs you"
        case .working: state = "Working"
        case .failed: state = unread ? "Failed, unread" : "Failed"
        case .finished: state = unread ? "Finished, unread" : "Finished"
        case .stopped: state = "Stopped"
        case .idle: state = "Ready"
        }
        return "\(title). \(state). \(detail)"
    }
}

/// A pending request simple enough to answer from the glance, like an
/// interactive live activity: an approval's Deny / Allow once, or up to four
/// short single-choice options. Anything richer opens the session.
struct GlanceQuickReply: Equatable {
    struct Choice: Equatable, Identifiable {
        var id: String { value }
        let value: String
        let label: String
        let primary: Bool
    }

    let requestID: String
    let choices: [Choice]

    static let maxChoices = 4
    static let maxCharacters = 56

    /// The stage wraps its choices onto rows, so it lifts the character limit.
    static func make(for request: PendingRequest, maxCharacters: Int = maxCharacters) -> GlanceQuickReply? {
        switch request.kind {
        case .approval:
            // Broader grants (this session, cancel turn) stay in the full card.
            guard request.choices.contains(ApprovalAction.once.rawValue) else { return nil }
            var choices: [Choice] = []
            if request.choices.contains(ApprovalAction.deny.rawValue) {
                choices.append(Choice(value: ApprovalAction.deny.rawValue, label: ApprovalAction.deny.title, primary: false))
            }
            choices.append(Choice(value: ApprovalAction.once.rawValue, label: ApprovalAction.once.title, primary: true))
            return GlanceQuickReply(requestID: request.id, choices: choices)
        case .clarification:
            let options = request.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !request.multiSelect, (1...maxChoices).contains(options.count),
                  options.reduce(0, { $0 + $1.count }) <= maxCharacters,
                  !options.contains(where: { $0.contains("\n") }) else { return nil }
            return GlanceQuickReply(requestID: request.id,
                                    choices: options.map { Choice(value: $0, label: $0, primary: false) })
        }
    }
}

/// Counts for the glance's top band, across all owned sessions.
struct GlanceSummary: Equatable {
    var needsInput = 0
    var working = 0
    var unread = 0

    init(sessions: [CompanionSession]) {
        for session in sessions {
            switch CollapsedStatus.resolve(session: session) {
            case .waiting: needsInput += 1
            case .running: working += 1
            case .finished, .failed: unread += 1
            case .none: break
            }
        }
    }

    var isQuiet: Bool { needsInput == 0 && working == 0 && unread == 0 }
}

/// Pure text and ordering helpers shared by the glance and session browser.
enum SessionDigest {
    static func entries(sessions: [CompanionSession], requests: [PendingRequest],
                        limit: Int = NotchGeometry.glanceMaxRows) -> [GlanceEntry] {
        let ranked: [(rank: Int, session: CompanionSession)] = sessions.compactMap { session in
            let rank = rank(session)
            // Quiet archived sessions and untouched drafts are not activity.
            if rank >= 4 && (session.isArchived || session.messages.isEmpty) { return nil }
            return (rank, session)
        }
        return ranked
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.session.updatedAt > $1.session.updatedAt }
            .prefix(max(0, limit))
            .map { entry($0.session, requests: requests) }
    }

    /// Needs you, then working, then unread failures and results, then recent.
    static func rank(_ session: CompanionSession) -> Int {
        switch CollapsedStatus.resolve(session: session) {
        case .waiting: return 0
        case .running: return 1
        case .failed: return 2
        case .finished: return 3
        case .none: return 4
        }
    }

    static func entry(_ session: CompanionSession, requests: [PendingRequest]) -> GlanceEntry {
        let collapsed = CollapsedStatus.resolve(session: session)
        let status: GlanceEntry.Status
        switch collapsed {
        case .waiting: status = .needsInput
        case .running: status = .working
        case .failed: status = .failed
        case .finished: status = .finished
        case .none:
            switch session.displayState {
            case .finished: status = .finished
            case .failed: status = .failed
            case .interrupted: status = .stopped
            default: status = .idle
            }
        }
        var streaming = false
        var quickReply: GlanceQuickReply?
        let detail: String
        switch status {
        case .needsInput:
            if session.nativeActivityUnverified != nil {
                detail = "Check its native session before sending again"
            } else if let request = requests.first(where: { $0.sessionID == session.runtimeID && session.runtimeID != nil }) {
                let question = oneLine(request.detail)
                detail = question.isEmpty ? request.title : question
                quickReply = GlanceQuickReply.make(for: request)
            } else {
                detail = "Needs your answer"
            }
        case .working:
            let turn = session.latestUserTurnID
            let agents = session.agents.filter { $0.state == .working && ($0.turnID == nil || $0.turnID == turn) }
            if let tool = session.tools.last(where: { $0.state == .working }) {
                let context = oneLine(tool.detail)
                detail = context.isEmpty ? tool.displayName : "\(tool.displayName) · \(context)"
            } else if !agents.isEmpty {
                detail = agents.count == 1 ? "\(agents[0].title) is working" : "\(agents.count) delegated agents working"
            } else if session.messages.last?.role == "user" || session.messages.isEmpty {
                detail = "Thinking…"
            } else {
                let tail = plainText(String(session.latestResponse.suffix(320)))
                streaming = !tail.isEmpty
                detail = tail.isEmpty ? "Writing…" : tail
            }
        case .failed:
            if session.pendingSubmission != nil {
                detail = "Send unconfirmed · check its native history"
            } else if let child = session.failedCurrentAgents.first {
                detail = "\(child.title) failed"
            } else {
                let text = preview(session)
                detail = text.isEmpty ? "Something went wrong" : text
            }
        case .finished:
            let text = preview(session)
            detail = text.isEmpty ? "Finished" : text
        case .stopped:
            let text = preview(session)
            detail = text.isEmpty ? "Stopped" : "Stopped · \(text)"
        case .idle:
            detail = preview(session)
        }
        let turnStart = session.messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) })?.createdAt
        return GlanceEntry(id: session.id, title: session.title, status: status,
                           unread: collapsed != .none, detail: detail,
                           runtime: session.isLegacyPrivate ? "Legacy Hermes" : session.runtime.title,
                           since: status == .working ? (turnStart ?? session.updatedAt) : session.updatedAt,
                           streaming: streaming, quickReply: quickReply,
                           canStop: status == .working && session.state == .working && session.runtimeID != nil)
    }

    /// The latest message as one plain line, with Markdown syntax removed.
    static func preview(_ session: CompanionSession) -> String {
        guard let message = session.messages.last(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.questions != nil
        }) else { return "" }
        if message.role == "assistant", let question = message.questions?.first { return "Asks: " + oneLine(question.title) }
        if message.role == "user" { return oneLine(String(message.text.prefix(400))) }
        // Delivered files read as "Sent report.pdf", never as raw MEDIA: tags.
        return plainText(String(MessageContent.preview(message.text).prefix(400)))
    }

    /// This turn's answer as one plain line: never the prompt, never an earlier turn's answer.
    static func answer(_ session: CompanionSession) -> String {
        var turn = session
        let start = session.messages.lastIndex(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) }) ?? -1
        turn.messages = session.messages.suffix(from: start + 1).filter { $0.role == "assistant" }
        return preview(turn)
    }

    /// When the current turn began: its last visible prompt.
    static func turnStart(_ session: CompanionSession) -> Date? {
        session.messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) })?.createdAt
    }

    /// The message an announcement snapshots: the answer, the failure's
    /// reason (else its child or last answer), or the question.
    static func announcementDetail(_ kind: NotchAnnouncement.Kind, session: CompanionSession,
                                   requests: [PendingRequest], failure: String = "") -> String {
        switch kind {
        case .finished:
            return answer(session)
        case .failed:
            let reason = oneLine(String(failure.prefix(400)))
            if !reason.isEmpty { return reason }
            if session.pendingSubmission != nil { return "Send unconfirmed · check its native history" }
            if let child = session.failedCurrentAgents.first { return "\(child.title) failed" }
            let text = answer(session)
            return text.isEmpty ? "Something went wrong" : text
        case .needsInput:
            return String(entry(session, requests: requests).detail.prefix(400))
        case .hello:
            return ""
        }
    }

    static func plainText(_ markdown: String) -> String {
        let blocks = blockText(MarkdownDocument.parse(markdown))
        let formatted = (try? AttributedString(markdown: blocks, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? blocks
        return oneLine(formatted)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A heading followed by more text reads as "Heading — text".
    private static func blockText(_ blocks: [MarkdownBlock]) -> String {
        var parts: [String] = []
        for (index, block) in blocks.enumerated() {
            switch block.content {
            case .heading(_, let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let punctuated = trimmed.last.map { ".:!?…".contains($0) } ?? true
                parts.append(index < blocks.count - 1 && !punctuated ? trimmed + " —" : trimmed)
            case .paragraph(let text), .code(_, let text): parts.append(text)
            case .list(_, let items): parts.append(items.map { blockText($0.blocks) }.joined(separator: " "))
            case .quote(let nested): parts.append(blockText(nested))
            case .rule: break
            }
        }
        return parts.joined(separator: " ")
    }

    /// "now", "4m", "2h", "3d" — compact enough for the glance's trailing edge.
    static func compactAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 45 { return "now" }
        if seconds < 3_600 { return "\(max(1, Int((Double(seconds) / 60).rounded())))m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    /// A running turn's elapsed time: "0:42", "12:03", "1:02:10".
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

// MARK: - Views

/// The hover glance below the band: a few session lines, island-style.
/// Rows open their session; the rest of the surface opens the full panel.
struct NotchGlanceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let entries = model.glanceEntries
        let peek = model.notchPresentation.peek
        VStack(spacing: 0) {
            if entries.isEmpty {
                GlanceRow(entry: nil, reducedMotion: model.reducedMotion, newSessionDetail: newSessionDetail) {
                    model.startSessionFromNotch()
                }
                .glanceReveal(peek: peek, index: 0, reducedMotion: model.reducedMotion)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                GlanceRow(entry: entry, reducedMotion: model.reducedMotion,
                          answering: entry.quickReply.map { model.answeringRequestIDs.contains($0.requestID) } ?? false,
                          action: { model.openSessionFromNotch(entry.id) },
                          reply: { model.answerFromGlance(requestID: $0, choice: $1) },
                          stop: entry.canStop ? { model.stopFromGlance(entry.id) } : nil)
                    .glanceReveal(peek: peek, index: index, reducedMotion: model.reducedMotion)
            }
            if !entries.isEmpty {
                GlanceNewSessionRow(detail: model.newSessionRuntimeTitle) { model.startSessionFromNotch() }
                    .glanceReveal(peek: peek, index: entries.count, reducedMotion: model.reducedMotion)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, NotchGeometry.glanceTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.activatePanel?() }
        .foregroundStyle(IslandStyle.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent sessions")
    }

    private var newSessionDetail: String {
        model.newSessionRuntimeTitle.map { "Start a conversation with \($0)" } ?? "Start a conversation"
    }
}

/// The glance's own way to begin: a slim row below the session rows.
private struct GlanceNewSessionRow: View {
    var detail: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.07), in: Circle())
                Text("New session").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                if let detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(IslandStyle.faint).lineLimit(1)
                }
            }
            .foregroundStyle(IslandStyle.secondary)
            .padding(.horizontal, 10)
            .frame(height: NotchGeometry.glanceFooterHeight)
        }
        .buttonStyle(IslandRowButtonStyle(cornerRadius: 11))
        .accessibilityLabel(detail.map { "New session with \($0)" } ?? "New session")
        .help("Start a new session")
    }
}

extension View {
    /// Rows pour out of the band one after another as the glance opens:
    /// blurred and lifted, then sharp. Driven by the one presentation clock.
    func glanceReveal(peek: CGFloat, index: Int, reducedMotion: Bool) -> some View {
        let start = 0.45 + 0.08 * CGFloat(index)
        let amount = EyeMotion.smoothstep((peek - start) / 0.3)
        return opacity(Double(amount))
            .blur(radius: reducedMotion ? 0 : 5 * (1 - amount))
            .offset(y: reducedMotion ? 0 : -8 * (1 - amount))
    }

    /// A soft highlight sweeps through status text while an agent works.
    @ViewBuilder func workingShimmer(_ active: Bool, reducedMotion: Bool) -> some View {
        if active && !reducedMotion {
            overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let center = WorkingShimmer.center(at: context.date.timeIntervalSinceReferenceDate)
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)],
                                   startPoint: UnitPoint(x: center - 0.3, y: 0.5),
                                   endPoint: UnitPoint(x: center + 0.3, y: 0.5))
                }
                .mask(self)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            self
        }
    }
}

enum WorkingShimmer {
    static let period: TimeInterval = 1.8

    /// The highlight's centre in unit width: it crosses the text, then rests
    /// off the trailing edge for the last third of each period.
    static func center(at time: TimeInterval) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        return -0.35 + 2.1 * CGFloat(phase)
    }
}

private struct GlanceRow: View {
    /// Nil renders the quiet empty-state row, which starts a new session.
    var entry: GlanceEntry?
    var reducedMotion: Bool
    var newSessionDetail = "Start a conversation"
    var answering = false
    var action: () -> Void
    var reply: ((String, String) -> Void)? = nil
    var stop: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            row
            if let quick = entry?.quickReply, let reply {
                quickReplies(quick, reply: reply)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Choices sit under the question, aligned with its text column.
    private func quickReplies(_ quick: GlanceQuickReply, reply: @escaping (String, String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(quick.choices) { choice in
                Button(choice.label) { reply(quick.requestID, choice.value) }
                    .buttonStyle(IslandPillButtonStyle(prominent: choice.primary, small: true))
                    .accessibilityLabel("\(choice.label), answer \(entry?.title ?? "")")
            }
            if answering {
                ProgressView().controlSize(.mini).padding(.leading, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + 24 + 11)
        .padding(.trailing, 10)
        .frame(height: NotchGeometry.glanceActionHeight, alignment: .top)
        .disabled(answering)
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                GlanceStatusGlyph(status: entry?.status, unread: entry?.unread ?? false, reducedMotion: reducedMotion)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry?.title ?? "New session").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let entry { trailing(entry) }
                    }
                    Text(entry?.detail ?? newSessionDetail)
                        .font(.system(size: 11)).foregroundStyle(IslandStyle.secondary)
                        .lineLimit(1).truncationMode(entry?.streaming == true ? .head : .tail)
                        // A streaming answer is read, not decorated.
                        .workingShimmer(entry?.status == .working && entry?.streaming == false, reducedMotion: reducedMotion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: NotchGeometry.glanceRowHeight)
        }
        .buttonStyle(IslandRowButtonStyle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if showsStop, let stop {
                Button(action: stop) {
                    Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(IslandIconButtonStyle(size: 20, filled: true))
                .help("Stop this turn")
                .accessibilityLabel("Stop \(entry?.title ?? "")")
                .padding(.top, 4).padding(.trailing, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(reducedMotion ? nil : .snappy(duration: 0.2), value: showsStop)
        .accessibilityLabel(entry?.accessibilityLabel ?? "New session. \(newSessionDetail)")
        .help(entry.map { "\($0.title)\n\($0.detail)" } ?? "Start a new session")
    }

    private var showsStop: Bool { hovering && stop != nil && entry?.canStop == true }

    @ViewBuilder private func trailing(_ entry: GlanceEntry) -> some View {
        HStack(spacing: 5) {
            // On hover a running row trades its runtime name for Stop.
            if !showsStop { Text(entry.runtime).foregroundStyle(IslandStyle.faint) }
            if entry.status == .working {
                // Only a running row needs a ticking clock; its digits roll.
                TimelineView(.periodic(from: entry.since, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(entry.since))
                    Text(SessionDigest.elapsed(TimeInterval(seconds)))
                        .foregroundStyle(IslandStyle.indicatorColor(.running))
                        .contentTransition(reducedMotion ? .identity : .numericText(countsDown: false))
                        .animation(reducedMotion ? nil : .snappy(duration: 0.3), value: seconds)
                }
                if showsStop { Color.clear.frame(width: 20, height: 1) }
            } else {
                Text(SessionDigest.compactAge(Date().timeIntervalSince(entry.since)))
                    .foregroundStyle(IslandStyle.secondary)
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

/// Status at a glance: a spinning arc while working, a pulsing question when
/// waiting, a lit check or warning while unread, and quiet marks once read.
struct GlanceStatusGlyph: View {
    var status: GlanceEntry.Status?
    var unread: Bool
    var reducedMotion: Bool
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            switch status {
            case .working:
                let orange = IslandStyle.indicatorColor(.running)
                Circle().stroke(orange.opacity(0.2), lineWidth: 2)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducedMotion)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    Circle().trim(from: 0, to: 0.32)
                        .stroke(orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(reducedMotion ? -90 : turn * 360))
                }
                Circle().fill(orange).frame(width: 4, height: 4)
            case .needsInput:
                let amber = IslandStyle.amber
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducedMotion)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    Circle().stroke(amber.opacity(reducedMotion ? 0 : 0.5 * (1 - phase)), lineWidth: 1.5)
                        .scaleEffect(reducedMotion ? 1 : 1 + 0.35 * phase)
                }
                Circle().fill(amber.opacity(0.2))
                Image(systemName: "questionmark").font(.system(size: 10, weight: .bold)).foregroundStyle(amber)
            case .finished:
                let green = IslandStyle.indicatorColor(.finished)
                Circle().fill(unread ? green : Color.white.opacity(0.07))
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(unread ? IslandStyle.onAccent : IslandStyle.secondary)
            case .failed:
                Circle().fill(unread ? IslandStyle.error.opacity(0.22) : Color.white.opacity(0.07))
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(unread ? IslandStyle.error : IslandStyle.secondary)
            case .stopped:
                Circle().fill(Color.white.opacity(0.07))
                Image(systemName: "stop.fill").font(.system(size: 7)).foregroundStyle(IslandStyle.secondary)
            case .idle:
                Circle().fill(Color.white.opacity(0.07))
                Image(systemName: "text.bubble").font(.system(size: 9.5)).foregroundStyle(IslandStyle.secondary)
            case nil:
                Circle().fill(Color.white.opacity(0.07))
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(IslandStyle.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The glance band's trailing summary, kept clear of a physical camera.
struct GlanceBandSummary: View {
    var summary: GlanceSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            words
            counts
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var tokens: [(count: Int, word: String, color: Color)] {
        [(summary.needsInput, "need you", IslandStyle.amber),
         (summary.working, "working", IslandStyle.indicatorColor(.running)),
         (summary.unread, "new", IslandStyle.indicatorColor(.finished))].filter { $0.count > 0 }
    }

    private var words: some View {
        HStack(spacing: 7) {
            if summary.isQuiet {
                Text("All caught up").foregroundStyle(IslandStyle.secondary)
            }
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                if index > 0 { Text("·").foregroundStyle(IslandStyle.faint) }
                Text(token.count == 1 && token.word == "need you" ? "1 needs you" : "\(token.count) \(token.word)")
                    .foregroundStyle(token.color)
            }
        }
        .fixedSize()
    }

    /// Beside a physical camera the words do not fit; symbols keep each
    /// count distinguishable without relying on color alone.
    private var counts: some View {
        HStack(spacing: 9) {
            if summary.isQuiet {
                Image(systemName: "checkmark").foregroundStyle(IslandStyle.secondary)
            }
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                HStack(spacing: 3) {
                    Image(systemName: Self.symbol(token.word)).font(.system(size: 9.5, weight: .bold))
                    Text("\(token.count)")
                }
                .foregroundStyle(token.color)
            }
        }
        .fixedSize()
    }

    private static func symbol(_ word: String) -> String {
        switch word {
        case "need you": return "questionmark"
        case "working": return "circle.dotted"
        default: return "checkmark"
        }
    }

    private var spoken: String {
        summary.isQuiet ? "All caught up"
            : tokens.map { "\($0.count) \($0.word)" }.joined(separator: ", ")
    }
}

/// The compact announcement inside the widened resting band: the acting
/// status icon, the session title, then the message. The icon and its color
/// carry the verb; VoiceOver still hears it.
struct AnnouncementLabel: View {
    var announcement: NotchAnnouncement
    var reducedMotion = false

    var body: some View {
        HStack(spacing: 6) {
            AnnouncementIcon(announcement: announcement, reducedMotion: reducedMotion, size: 13)
                .frame(width: NotchAnnouncement.iconWidth)
            Text(announcement.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(IslandStyle.text)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: announcement.detail.isEmpty ? nil : announcement.titleWidth, alignment: .leading)
            if !announcement.detail.isEmpty {
                Text(announcement.detail).font(.system(size: 11.5)).foregroundStyle(IslandStyle.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(announcement.spoken)
    }
}

/// The announcement's colored status icon, acting out its verb once it has
/// materialized: Done draws its check on, Hi waves, Failed shakes its head,
/// and a question hops like the eyes.
struct AnnouncementIcon: View {
    var announcement: NotchAnnouncement
    var reducedMotion = false
    var size: CGFloat = 13
    @State private var cue = 0

    var body: some View {
        icon
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(announcement.kind.color)
            .task(id: announcement.id) {
                try? await Task.sleep(for: .milliseconds(260))
                if !reducedMotion { cue += 1 }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        let image = Image(systemName: announcement.kind.symbol)
        switch announcement.kind {
        case .finished: image.symbolEffect(.drawOff, isActive: cue == 0 && !reducedMotion)
        case .hello: image.symbolEffect(.wiggle, options: .repeat(3), value: cue)
        case .failed: image.symbolEffect(.wiggle.left, options: .repeat(2), value: cue)
        case .needsInput: image.symbolEffect(.bounce.up, options: .repeat(2), value: cue)
        }
    }
}

/// A small island inside the open panel naming another session's result:
/// status glyph, title, one line of the message, Open.
struct PanelToastView: View {
    var announcement: NotchAnnouncement
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GlanceStatusGlyph(status: announcement.kind.glanceStatus, unread: true, reducedMotion: true, size: 18)
                Text(announcement.title).font(.system(size: 12, weight: .medium)).foregroundStyle(IslandStyle.text)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: announcement.detail.isEmpty ? nil : Self.titleWidth(announcement.title), alignment: .leading)
                if !announcement.detail.isEmpty {
                    Text(announcement.detail).font(.system(size: 12)).foregroundStyle(IslandStyle.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text("Open").font(.system(size: 11, weight: .medium)).foregroundStyle(IslandStyle.secondary)
                    .fixedSize().padding(.leading, 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondary)
            }
            .padding(.leading, 7).padding(.trailing, 12)
            .frame(height: 32)
            .background(Color(white: 0.11), in: Capsule())
            .overlay(Capsule().strokeBorder(announcement.kind.color.opacity(0.35), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pressableCursor()
        // Hugs its content; a long message truncates within the cap.
        .frame(maxWidth: 380)
        .accessibilityLabel("\(announcement.spoken). Open")
    }

    private static func titleWidth(_ title: String) -> CGFloat {
        NotchAnnouncement.width(title, font: .systemFont(ofSize: 12, weight: .medium), cap: 150)
    }
}

extension NotchAnnouncement.Kind {
    var glanceStatus: GlanceEntry.Status {
        switch self {
        case .finished, .hello: return .finished
        case .failed: return .failed
        case .needsInput: return .needsInput
        }
    }
}
