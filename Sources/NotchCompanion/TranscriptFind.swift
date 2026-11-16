import SwiftUI

/// One transcript row containing the find text: a message or a tool call, with
/// what has to open for it to show.
struct TranscriptFindMatch: Equatable {
    /// The row's identity, `message:<id>` or `tool:<id>`.
    let id: String
    /// The top-level timeline item that holds the row.
    let item: String
    /// The folded “Worked for” turn it sits in, which unfolds to show it.
    var work: String? = nil
    /// The tool run whose collapsed “N tool calls” line hides it.
    var group: String? = nil

    /// The row's scroll identity, apart from the timeline's own item identities.
    var scrollID: String { "find:\(id)" }
}

enum TranscriptFind {
    /// The menu commands the full-session window answers (Edit → Find).
    enum Command { case show, next, previous }
    static let command = Notification.Name("NotchCompanion.transcriptFind")

    /// Every matching row in transcript order: your messages, answers, commentary,
    /// delegation results and tool calls (name and detail), folded or not.
    static func matches(_ query: String, in items: [ConversationTimelineItem]) -> [TranscriptFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        func contains(_ text: String) -> Bool { text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var found: [TranscriptFindMatch] = []
        func visit(_ entry: ConversationTimelineItem, item: String, work: String?, inWork: Bool) {
            switch entry {
            case .message(let message), .commentary(let message):
                if contains(message.delegationSummary ?? message.text) { found.append(TranscriptFindMatch(id: "message:\(message.id)", item: item, work: work)) }
            case .tools(let group):
                for tool in group.tools where contains(tool.name) || contains(tool.detail) {
                    // Outside a turn's work, only a live run's newest calls show without opening it.
                    let hidden = !inWork && !group.liveTools.contains { $0.id == tool.id }
                    found.append(TranscriptFindMatch(id: "tool:\(tool.id)", item: item, work: work, group: hidden ? group.id : nil))
                }
            case .work(let turn):
                for nested in turn.entries { visit(nested, item: item, work: turn.folds ? turn.id : nil, inWork: true) }
            case .changes: break
            }
        }
        for item in items { visit(item, item: item.id, work: nil, inWork: false) }
        return found
    }
}

extension EnvironmentValues {
    /// The row the find field has selected, highlighted wherever it renders.
    @Entry var transcriptFindTarget: String? = nil
}

extension View {
    /// Gives a transcript row its find identity and draws the highlight while it is the current match.
    func transcriptFindRow(_ id: String) -> some View { modifier(TranscriptFindRow(id: id)) }
}

private struct TranscriptFindRow: ViewModifier {
    let id: String
    @Environment(\.transcriptFindTarget) private var target

    func body(content: Content) -> some View {
        content
            .background {
                if target == id {
                    // Find's yellow in Refined and Tahoe; Instrument's one signal also marks focus.
                    let color = PanelTheme.pick(Color.yellow, Color.yellow, CompanionStyle.signal)
                    let shape = RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.row, 10, CompanionStyle.radius), style: .continuous)
                    shape.fill(color.opacity(PanelTheme.pick(0.12, 0.14, 0.08)))
                        .overlay(shape.strokeBorder(color.opacity(0.55), lineWidth: PanelTheme.pick(1, 1, 0.75)))
                        // Out past the leading and vertical edges only: the trailing edge is the column's, which clips.
                        .padding(.vertical, -4).padding(.leading, -6)
                }
            }
            .id("find:\(id)")
    }
}

/// The full-session window's find field: “N of M”, previous and next, and Done.
struct TranscriptFindBar: View {
    @Binding var query: String
    var current: Int?
    var count: Int
    var move: (Bool) -> Void
    var close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        chrome(HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: PanelTheme.pick(13, 13, 11)))
                .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                .accessibilityHidden(true)
            TextField("Find in conversation", text: $query)
                .textFieldStyle(.plain).focused($focused).focusEffectDisabled()
                .frame(maxWidth: .infinity)
                .onSubmit { move(true) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    move(false); return .handled
                }
                .onExitCommand(perform: close)
                .accessibilityLabel("Find in conversation")
                .textCursor()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(count == 0 ? "No matches" : "\((current ?? 0) + 1) of \(count)")
                    .font(.system(size: PanelTheme.pick(11, 11.5, 11)).monospacedDigit())
                    .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                    .fixedSize()
            }
            QuietIconButton(symbol: "chevron.up", label: "Previous match", size: 22) { move(false) }.disabled(count == 0)
            QuietIconButton(symbol: "chevron.down", label: "Next match", size: 22) { move(true) }.disabled(count == 0)
            Button("Done", action: close).buttonStyle(NotchPillButtonStyle(small: true))
        })
        .onAppear { focused = true }
        // ⌘F while open selects the field again.
        .onReceive(NotificationCenter.default.publisher(for: TranscriptFind.command)) { note in
            if note.object as? TranscriptFind.Command == .show { focused = true }
        }
    }

    @ViewBuilder private func chrome(_ field: some View) -> some View {
        // The session search capsule's look in each design.
        switch PanelTheme.current {
        case .refined:
            field.font(CompanionStyle.body).padding(.leading, 12).padding(.trailing, 5).frame(height: 32)
                .background(Color.white.opacity(focused ? 0.08 : 0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.2 : 0.08), lineWidth: 0.5))
        case .tahoe:
            field.font(.system(size: 13)).padding(.leading, 12).padding(.trailing, 4).frame(height: 32)
                .background(CompanionStyle.fill, in: Capsule())
                .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(CompanionStyle.accent.opacity(0.7)) : AnyShapeStyle(Color.white.opacity(0.06)),
                                                lineWidth: focused ? 1.5 : 0.5))
        case .instrument:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.cardRadius, style: .continuous)
            field.font(.system(size: 12.5)).padding(.leading, 11).padding(.trailing, 5).frame(height: 32)
                .background(CompanionStyle.inset, in: shape)
                .overlay(shape.strokeBorder(focused ? Color.white.opacity(0.34) : CompanionStyle.ruleStrong, lineWidth: 0.75))
        }
    }
}
