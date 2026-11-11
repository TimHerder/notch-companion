import AppKit
import SwiftUI

/// Hold to ask: while its shortcut is held, the notch opens a small island
/// that shows the words as they are heard and grows with them. Releasing sends
/// them as a new session and the island closes; the panel never opens.
enum AskIsland {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    /// A longer prompt keeps its newest lines in view.
    static let maxLines = 6
    /// The waveform's column; the words hang after it.
    static let indent: CGFloat = 34
    static let sidePadding: CGFloat = 18
    static let topPadding: CGFloat = 6, bottomPadding: CGFloat = 14
    static let textWidth = NotchGeometry.glanceTargetWidth - 2 * sidePadding - indent

    /// Lines the words wrap to in the island's text column.
    static func lines(_ text: String) -> Int {
        let bounds = (text as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return max(1, Int((bounds.height / lineHeight).rounded()))
    }

    /// The body under the band, shared by the view and the island's height.
    static func bodyHeight(_ text: String) -> CGFloat {
        topPadding + CGFloat(min(maxLines, lines(text))) * lineHeight + bottomPadding
    }
}

extension AppModel {
    /// The finalized words, then those still being heard.
    var askText: String { Dictation.append(dictation.volatileText, to: quickAsk ?? "") }

    /// What the island says while there are no words yet.
    var askHint: String {
        switch dictation.phase {
        case .preparing(let step): step
        case .finishing: "Finishing…"
        case .listening, .idle: "Listening…"
        }
    }

    /// The island's body height; the host sizes the island with it.
    var askBodyHeight: CGFloat { quickAsk == nil ? 0 : AskIsland.bodyHeight(askText.isEmpty ? askHint : askText) }
}

/// The listening island's body: a waveform that moves with the voice, then the
/// words, those still being heard lighter than the settled ones.
struct NotchAskView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: Dictation

    var body: some View {
        let heard = model.quickAsk ?? ""
        let text = model.askText
        let lines = AskIsland.lines(text.isEmpty ? model.askHint : text)
        let shown = min(AskIsland.maxLines, lines)
        // Past the last line the island stops growing and the oldest line fades out.
        let fade: CGFloat = lines > shown ? 1 / CGFloat(shown) : 0
        HStack(alignment: .top, spacing: 0) {
            AskGlyph(dictation: dictation, listening: dictation.phase == .listening,
                     sending: dictation.phase == .finishing || (!model.asking && !text.isEmpty), reducedMotion: model.reducedMotion)
                .frame(width: AskIsland.indent, height: AskIsland.lineHeight, alignment: .leading)
            words(heard: heard, text: text)
                .font(Font(AskIsland.font))
                .frame(width: AskIsland.textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: CGFloat(shown) * AskIsland.lineHeight, alignment: .bottomLeading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black.opacity(fade > 0 ? 0 : 1), location: 0), .init(color: .black, location: fade)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .padding(.horizontal, AskIsland.sidePadding)
        .padding(.top, AskIsland.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glanceReveal(peek: model.notchPresentation.peek, index: 0, reducedMotion: model.reducedMotion)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.isEmpty ? model.askHint : "Listening: \(text)")
    }

    private func words(heard: String, text: String) -> Text {
        guard !text.isEmpty else { return Text(model.askHint).foregroundStyle(IslandStyle.secondary) }
        return Text("\(Text(heard).foregroundStyle(IslandStyle.text))\(Text(text.dropFirst(heard.count)).foregroundStyle(IslandStyle.text.opacity(0.55)))")
    }
}

/// Five bars that rise with the voice, and an arrow once the words are on their way.
private struct AskGlyph: View {
    /// Not observed: the timeline samples its level.
    var dictation: Dictation
    var listening: Bool
    var sending: Bool
    var reducedMotion: Bool

    var body: some View {
        if sending {
            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(IslandStyle.accent)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducedMotion || !listening)) { context in
                // A murmur keeps the bars alive through a pause; the voice lifts them.
                let voice = !listening ? 0 : reducedMotion ? 0.5 : 0.18 + 0.82 * dictation.level
                HStack(spacing: 2.5) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule().fill(listening ? IslandStyle.error : IslandStyle.faint)
                            .frame(width: 2.5, height: 2.2 * LiveActivity.barHeight(index, time: reducedMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                                                                                    voice: voice))
                    }
                }
            }
        }
    }
}
