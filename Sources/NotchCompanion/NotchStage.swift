import AppKit
import SwiftUI

/// What the popup stage says about an announcement. Results and failures
/// show the message snapshotted when announced; a question shows the live
/// request, so one answered meanwhile shows that it landed.
struct StageContent: Equatable {
    var title: String
    var detail: String
    /// Faint trailing facts: the runtime and how long the turn worked.
    var meta: String?
    /// The pending question or approval the stage answers in place.
    var request: PendingRequest?
    var quickReply: GlanceQuickReply?
    var answered = false
    /// What an approval wants to run, in its own monospaced field.
    var command: String?
    /// A finished turn's changes, summarised on one quiet line.
    var changes: TurnChanges?
    /// The column beside the mascot (or the eyes' inset); text hangs after the icon.
    var textWidth: CGFloat = column

    @MainActor static func make(_ announcement: NotchAnnouncement, sessions: [CompanionSession],
                     requests: [PendingRequest], textWidth: CGFloat = column, mascot: String? = nil) -> StageContent {
        switch announcement.sessionID {
        case AppModel.helloAnnouncementID:
            return StageContent(title: mascot.map { "Hi, I’m \($0)" } ?? "Hi there", detail: "I live in your notch. Hover here to glance at your sessions, or click to start one.", textWidth: textWidth)
        case AppModel.previewAnnouncementID:
            return StageContent(title: announcement.title, detail: "Finished sessions, questions and failures appear here.", textWidth: textWidth)
        default:
            break
        }
        guard let session = sessions.first(where: { $0.id == announcement.sessionID }) else {
            return StageContent(title: announcement.title, detail: announcement.detail, textWidth: textWidth)
        }
        let runtime = session.isLegacyPrivate ? "Legacy Hermes" : session.runtime.title
        var content = StageContent(title: session.title, detail: announcement.detail,
                                   meta: announcement.worked.map { "\(runtime) · \(SessionDigest.elapsed($0))" } ?? runtime,
                                   textWidth: textWidth)
        switch announcement.kind {
        case .finished:
            content.changes = session.changes.first { $0.id == session.latestUserTurnID && !$0.allFiles.isEmpty }
        case .needsInput:
            content.answered = CollapsedStatus.resolve(session: session) != .waiting
            guard !content.answered, session.nativeActivityUnverified == nil, session.runtimeID != nil,
                  let request = requests.first(where: { $0.sessionID == session.runtimeID }) else {
                if content.answered, announcement.isApproval {
                    content.detail = "Wants to run"
                    content.command = announcement.detail
                }
                if content.detail.isEmpty { content.detail = SessionDigest.entry(session, requests: requests).detail }
                break
            }
            content.request = request
            content.quickReply = GlanceQuickReply.make(for: request, maxCharacters: .max)
            let detail = SessionDigest.oneLine(request.detail)
            if request.kind == .approval, !detail.isEmpty {
                content.detail = "Wants to run"
                content.command = detail
            } else {
                content.detail = detail.isEmpty ? request.title : detail
            }
        case .failed, .hello:
            break
        }
        return content
    }

    /// One typed line answers an open or single-choice question.
    var acceptsText: Bool {
        guard let request, !answered else { return false }
        return request.kind == .clarification && request.allowsFreeText && !request.multiSelect
    }

    /// Choices wrap across the text column the way the stage lays them out.
    var choiceRows: [[GlanceQuickReply.Choice]] { quickReply.map { Self.pack($0.choices, width: bodyWidth) } ?? [] }

    /// Rows under the question: choices, then a reply field; or the sent confirmation.
    var answerRows: Int { answered ? 1 : choiceRows.count + (acceptsText ? 1 : 0) }

    static let column = NotchGeometry.stageWidth - MascotLayout.stageColumn - 14
    static let rowSpacing: CGFloat = 4

    // MARK: Layout, shared by the view and the stage's height

    /// The status icon's column; message, field and answers hang after it.
    static let indent: CGFloat = 23
    static let headerHeight: CGFloat = 20
    static let messageFont = NSFont.systemFont(ofSize: 12.5)
    static let lineHeight = messageFont.ascender - messageFont.descender + messageFont.leading
    static let messageGap: CGFloat = 4
    static let changesGap: CGFloat = 6, changesHeight: CGFloat = 14
    static let commandGap: CGFloat = 8, commandHeight: CGFloat = 24
    static let answersGap: CGFloat = 10, answerHeight: CGFloat = 26
    static let topPadding: CGFloat = 8, bottomPadding: CGFloat = 16

    var bodyWidth: CGFloat { max(1, textWidth - Self.indent) }

    /// Lines the message takes at the column width: up to three, two when answers or a command follow.
    var messageLines: Int {
        guard !detail.isEmpty else { return 0 }
        let bounds = (detail as NSString).boundingRect(with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin], attributes: [.font: Self.messageFont])
        let lines = max(1, Int((bounds.height / Self.lineHeight).rounded()))
        return min(answerRows > 0 || command != nil ? 2 : 3, lines)
    }

    var answersHeight: CGFloat {
        let rows = CGFloat(answerRows)
        return rows > 0 ? rows * Self.answerHeight + (rows - 1) * Self.rowSpacing : 0
    }

    /// The stage body under the band, measured from its content. With the
    /// mascot it keeps the room its 150-point figure needs.
    func bodyHeight(mascot: Bool) -> CGFloat {
        let lines = messageLines
        var height = Self.topPadding + Self.headerHeight + Self.bottomPadding
        if lines > 0 { height += Self.messageGap + ceil(CGFloat(lines) * Self.lineHeight) }
        if changes != nil { height += Self.changesGap + Self.changesHeight }
        if command != nil { height += Self.commandGap + Self.commandHeight }
        if answerRows > 0 { height += Self.answersGap + answersHeight }
        return mascot ? max(NotchGeometry.mascotStageBodyHeight, height) : height
    }

    static func pack(_ choices: [GlanceQuickReply.Choice], width: CGFloat = column) -> [[GlanceQuickReply.Choice]] {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        var rows: [[GlanceQuickReply.Choice]] = []
        var used: CGFloat = 0
        for choice in choices {
            // A small pill: its label with 9 points either side, 6 between pills.
            let pill = ceil((choice.label as NSString).size(withAttributes: [.font: font]).width) + 18
            if let last = rows.indices.last, used + 6 + pill <= width {
                rows[last].append(choice)
                used += 6 + pill
            } else {
                rows.append([choice])
                used = pill
            }
        }
        return rows
    }
}

extension AppModel {
    var stageTextInset: CGFloat { mascotEnabled ? MascotLayout.stageColumn : 20 }

    var stageContent: StageContent? {
        guard updateStyle == .popup, let announcement else { return nil }
        return StageContent.make(announcement, sessions: sessions, requests: requests,
                                 textWidth: NotchGeometry.stageWidth - stageTextInset - 14,
                                 mascot: mascotEnabled ? mascotCharacter.label : nil)
    }

    /// The current stage's body height; the host sizes the stage with it.
    var stageBodyHeight: CGFloat { stageContent?.bodyHeight(mascot: mascotEnabled) ?? NotchGeometry.mascotStageBodyHeight }
}

/// The stage's text, beside the mascot when selected: the acting status icon,
/// title and faint meta, the message, then a change line, an approval's
/// command or the question's answers. Clicking opens the session and hovering
/// away lets it retract, so it carries no buttons of its own. The mascot itself
/// is drawn by the eyes' layer.
struct NotchStageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let stage = model.notchPresentation.stage
        if let announcement = model.announcement, let content = model.stageContent {
            let lines = content.messageLines
            ZStack {
                // Everything but the answers, the mascot included, opens the session.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.openAnnouncedSession() }
                    .pressableCursor()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            AnnouncementIcon(announcement: announcement, reducedMotion: model.reducedMotion, size: 14)
                                .frame(width: StageContent.indent, alignment: .leading)
                            Text(content.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 10)
                            if let meta = content.meta {
                                Text(meta).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(IslandStyle.faint)
                                    .lineLimit(1).fixedSize()
                            }
                        }
                        .frame(height: StageContent.headerHeight)
                        .glanceReveal(peek: stage, index: 0, reducedMotion: model.reducedMotion)
                        Group {
                            if lines > 0 {
                                Text(content.detail).font(Font(StageContent.messageFont))
                                    .foregroundStyle(IslandStyle.text.opacity(0.78))
                                    .lineLimit(lines)
                                    .frame(height: ceil(CGFloat(lines) * StageContent.lineHeight), alignment: .topLeading)
                                    .padding(.top, StageContent.messageGap)
                            }
                            if let changes = content.changes { changeLine(changes) }
                            if let command = content.command { commandField(command) }
                        }
                        .padding(.leading, StageContent.indent)
                        .glanceReveal(peek: stage, index: 1, reducedMotion: model.reducedMotion)
                    }
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(announcement, content))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.openAnnouncedSession() }
                    .accessibilityAction(named: "Dismiss") { model.dismissStage?() }
                    if content.answerRows > 0 {
                        answers(content)
                            .padding(.top, StageContent.answersGap)
                            .padding(.leading, StageContent.indent)
                            .glanceReveal(peek: stage, index: 2, reducedMotion: model.reducedMotion)
                    }
                }
                .padding(.leading, model.stageTextInset)
                .padding(.trailing, 14)
                .padding(.top, StageContent.topPadding)
                .padding(.bottom, StageContent.bottomPadding)
                // Beside the mascot the text centres on the figure; with the eyes it starts under the band.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.mascotEnabled ? .leading : .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(IslandStyle.text)
            .accessibilityElement(children: .contain)
        }
    }

    private func spoken(_ announcement: NotchAnnouncement, _ content: StageContent) -> String {
        var parts = ["\(announcement.kind.verb): \(content.title)"]
        if !content.detail.isEmpty { parts.append(content.detail) }
        if let command = content.command { parts.append(command) }
        if let changes = content.changes {
            parts.append("\(changes.allFiles.count) changed files, \(Self.added(changes)) lines added, \(Self.removed(changes)) removed")
        }
        return parts.joined(separator: ". ")
    }

    private static func added(_ changes: TurnChanges) -> Int { changes.allFiles.compactMap(\.additions).reduce(0, +) }
    private static func removed(_ changes: TurnChanges) -> Int { changes.allFiles.compactMap(\.deletions).reduce(0, +) }

    /// "4 files  +120 −8", quiet, the counts in their diff colors.
    private func changeLine(_ changes: TurnChanges) -> some View {
        let files = changes.allFiles.count
        return HStack(spacing: 8) {
            Text("\(files) \(files == 1 ? "file" : "files")").foregroundStyle(IslandStyle.secondary)
            HStack(spacing: 5) {
                Text("+\(Self.added(changes))").foregroundStyle(IslandStyle.indicatorColor(.finished))
                Text("−\(Self.removed(changes))").foregroundStyle(IslandStyle.error)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .frame(height: StageContent.changesHeight)
        .padding(.top, StageContent.changesGap)
    }

    /// What an approval wants to run: one monospaced line, truncated in the middle.
    private func commandField(_ command: String) -> some View {
        Text(command)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(IslandStyle.text.opacity(0.9))
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: StageContent.commandHeight, maxHeight: StageContent.commandHeight, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
            .padding(.top, StageContent.commandGap)
    }

    @ViewBuilder private func answers(_ content: StageContent) -> some View {
        let answering = content.request.map { model.answeringRequestIDs.contains($0.id) } ?? false
        VStack(alignment: .leading, spacing: StageContent.rowSpacing) {
            if content.answered {
                Label("Answer sent", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(IslandStyle.accent)
                    .frame(height: StageContent.answerHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if let request = content.request {
                ForEach(Array(content.choiceRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(row) { choice in
                            Button(choice.label) { model.answerFromGlance(requestID: request.id, choice: choice.value) }
                                .buttonStyle(IslandPillButtonStyle(prominent: choice.primary, small: true))
                                .accessibilityLabel("\(choice.label), answer \(content.title)")
                        }
                    }
                    .frame(height: StageContent.answerHeight)
                }
                if content.acceptsText {
                    StageReplyField(placeholder: content.quickReply == nil ? "Type your answer…" : "Or type an answer…",
                                    label: "Your answer to \(content.title)") {
                        model.answerFromGlance(requestID: request.id, choice: $0)
                    }
                    .id(request.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(answering)
        .overlay(alignment: .topTrailing) {
            if answering { ProgressView().controlSize(.mini).frame(height: StageContent.answerHeight) }
        }
        .animation(model.reducedMotion ? nil : .snappy(duration: 0.25), value: content.answered)
    }
}

/// One line answers the question; Return sends it. A failed send keeps the text.
private struct StageReplyField: View {
    var placeholder: String
    var label: String
    var send: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).focusEffectDisabled().font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75))
            .textCursor()
            .onSubmit {
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty { send(answer) }
            }
            .accessibilityLabel(label)
    }
}
