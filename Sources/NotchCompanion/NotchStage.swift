import AppKit
import SwiftUI

/// What the popup stage says about an announcement, derived from live state:
/// a question answered meanwhile shows that it landed.
struct StageContent: Equatable {
    var title: String
    var detail: String
    var runtime: String?
    /// The pending question or approval the stage answers in place.
    var request: PendingRequest?
    var quickReply: GlanceQuickReply?
    var answered = false
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
            return StageContent(title: announcement.title, detail: "", textWidth: textWidth)
        }
        let entry = SessionDigest.entry(session, requests: requests)
        let answered = announcement.kind == .needsInput && entry.status != .needsInput
        let request = announcement.kind == .needsInput && !answered && session.nativeActivityUnverified == nil && session.runtimeID != nil
            ? requests.first(where: { $0.sessionID == session.runtimeID }) : nil
        return StageContent(title: session.title, detail: entry.detail, runtime: entry.runtime, request: request,
                            quickReply: request.flatMap { GlanceQuickReply.make(for: $0, maxCharacters: .max) }, answered: answered,
                            textWidth: textWidth)
    }

    /// One typed line answers an open or single-choice question.
    var acceptsText: Bool {
        guard let request, !answered else { return false }
        return request.kind == .clarification && request.allowsFreeText && !request.multiSelect
    }

    /// Choices wrap across the text column the way the stage lays them out.
    var choiceRows: [[GlanceQuickReply.Choice]] { quickReply.map { Self.pack($0.choices, width: textWidth) } ?? [] }

    /// Rows under the question: choices, then a reply field; or the sent confirmation.
    var answerRows: Int { answered ? 1 : choiceRows.count + (acceptsText ? 1 : 0) }

    static let column = NotchGeometry.stageWidth - MascotLayout.stageColumn - 14
    static let rowSpacing: CGFloat = 4

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

    /// Answer rows the current stage shows; they size the stage.
    var stageAnswerRows: Int { stageContent?.answerRows ?? 0 }
}

/// The stage's text, beside the mascot when selected: verb, title, a little of the result, or the
/// question with its answers. Clicking opens the session and hovering away
/// lets it retract, so it carries no buttons of its own. The mascot itself is drawn
/// by the eyes' layer.
struct NotchStageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let stage = model.notchPresentation.stage
        if let announcement = model.announcement, let content = model.stageContent {
            let rows = CGFloat(content.answerRows)
            let answersHeight = rows > 0 ? rows * 26 + (rows - 1) * StageContent.rowSpacing + 6 : 0
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        AnnouncementLabel(announcement: announcement, reducedMotion: model.reducedMotion, showsTitle: false)
                        if let runtime = content.runtime {
                            Text("· \(runtime)").font(.system(size: 11)).foregroundStyle(IslandStyle.faint).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                    .glanceReveal(peek: stage, index: 0, reducedMotion: model.reducedMotion)
                    Text(content.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        .padding(.top, 4)
                        .glanceReveal(peek: stage, index: 1, reducedMotion: model.reducedMotion)
                    Text(content.detail).font(.system(size: 12)).foregroundStyle(IslandStyle.secondary)
                        .lineLimit(content.answerRows > 0 ? 2 : 3).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                        .glanceReveal(peek: stage, index: 2, reducedMotion: model.reducedMotion)
                    Spacer(minLength: 0)
                }
                .padding(.leading, model.stageTextInset)
                .padding(.trailing, 14)
                .padding(.top, 6)
                .padding(.bottom, 14 + answersHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Everything but the answers, the mascot included, opens the session.
                .contentShape(Rectangle())
                .onTapGesture { model.openAnnouncedSession() }
                .pressableCursor()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(announcement.kind.verb): \(content.title). \(content.detail)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Dismiss") { model.dismissStage?() }
                if content.answerRows > 0 {
                    answers(content)
                        .padding(.leading, model.stageTextInset)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                        .glanceReveal(peek: stage, index: 3, reducedMotion: model.reducedMotion)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(IslandStyle.text)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func answers(_ content: StageContent) -> some View {
        let answering = content.request.map { model.answeringRequestIDs.contains($0.id) } ?? false
        VStack(alignment: .leading, spacing: StageContent.rowSpacing) {
            if content.answered {
                Label("Answer sent", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(IslandStyle.accent)
                    .frame(height: 26)
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
                    .frame(height: 26)
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
            if answering { ProgressView().controlSize(.mini).frame(height: 26) }
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
