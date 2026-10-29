import AppKit
import SwiftUI

/// The resting notch's compact trailing content while agents work or wait,
/// like an island's live activity: the eyes lead on the left, and the right
/// shoulder shows one animated glyph per busy session.
struct LiveActivity: Equatable {
    enum Kind: Equatable { case working, waiting }

    struct Item: Equatable {
        let sessionID: String
        let title: String
        let kind: Kind
        /// SF Symbol for the running tool or phase; it morphs as tools change.
        let symbol: String
        /// Length of the answer being written, so the glyph can pulse as text arrives.
        var written = 0
    }

    /// The phase glyph while an answer streams; the live row draws a waveform for it.
    static let writingSymbol = "text.alignleft"

    static let enabledKey = "notch.liveActivity"
    /// More sessions than this keep their dots.
    static let maxItems = 4

    let items: [Item]
    var sessionIDs: [String] { items.map(\.sessionID) }

    /// Needs you first (most recent), then the most recently started work.
    static func resolve(sessions: [CompanionSession]) -> LiveActivity? {
        var ranked: [(rank: Int, date: Date, item: Item)] = []
        for session in sessions {
            let status = CollapsedStatus.resolve(session: session)
            guard status == .waiting || status == .running else { continue }
            let since = session.messages.last(where: { $0.role == "user" && SessionHistory.isVisibleConversation($0) })?.createdAt
                ?? session.updatedAt
            let symbol = status == .waiting ? "questionmark" : symbol(for: session)
            let item = Item(sessionID: session.id, title: session.title, kind: status == .waiting ? .waiting : .working,
                            symbol: symbol,
                            written: symbol == writingSymbol ? session.messages.last?.text.utf8.count ?? 0 : 0)
            ranked.append(status == .waiting ? (0, session.updatedAt, item) : (1, since, item))
        }
        let items = ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.date > $1.date }.prefix(maxItems).map(\.item)
        return items.isEmpty ? nil : LiveActivity(items: items)
    }

    /// What the agent is doing right now, as one glyph.
    static func symbol(for session: CompanionSession) -> String {
        if let tool = session.tools.last(where: { $0.state == .working }) { return symbol(forTool: tool.name) }
        if session.agents.contains(where: { $0.state == .working && ($0.turnID == nil || $0.turnID == session.latestUserTurnID) }) {
            return "person.2.fill"
        }
        // Assistant messages appear when streaming starts.
        return session.messages.last?.role == "assistant" ? writingSymbol : "sparkles"
    }

    /// Tool names differ by harness (Hermes `terminal`, Claude `Bash`, Codex
    /// `commandExecution`, OpenCode `bash`…); match whole name tokens.
    static func symbol(forTool name: String) -> String {
        let words = Set(tokens(name))
        func has(_ stems: String...) -> Bool { stems.contains(where: words.contains) }
        if has("todo", "todowrite", "plan", "think") { return "checklist" }
        if has("delegate", "subagent", "agent", "task", "spawn") { return "person.2.fill" }
        if has("terminal", "bash", "shell", "command", "exec", "execution", "python", "run", "sh", "zsh") { return "terminal.fill" }
        if has("web", "websearch", "webfetch", "browser", "fetch", "url", "http", "navigate") { return "globe" }
        if has("search", "grep", "glob", "find", "rg", "ripgrep") { return "magnifyingglass" }
        if has("write", "edit", "multiedit", "patch", "apply", "change", "create", "replace") { return "pencil" }
        if has("read", "view", "open", "cat", "list", "ls", "file") { return "doc.text.fill" }
        if has("image", "vision", "screenshot", "screen") { return "photo" }
        if has("mcp", "tool") { return "wrench.and.screwdriver.fill" }
        return "gearshape.fill"
    }

    /// "commandExecution" → command, execution; "read_file" → read, file.
    static func tokens(_ name: String) -> [String] {
        var words: [String] = []
        var word = ""
        var previousLower = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty { words.append(word.lowercased()); word = "" }
                previousLower = false
                continue
            }
            if character.isUppercase, previousLower, !word.isEmpty { words.append(word.lowercased()); word = "" }
            word.append(character)
            previousLower = character.isLowercase || character.isNumber
        }
        if !word.isEmpty { words.append(word.lowercased()) }
        return words
    }

    // MARK: Layout

    static let glyphSize: CGFloat = 16
    static let spacing: CGFloat = 5
    /// Keeps a short row's shoulder about as wide as the eyes' extension.
    static let minimumWidth: CGFloat = 38

    var glyphsWidth: CGFloat { CGFloat(items.count) * (Self.glyphSize + Self.spacing) - Self.spacing }
    var contentWidth: CGFloat { max(Self.minimumWidth, glyphsWidth) }

    /// How strongly the waveform moves: lively while text arrives, settling
    /// to a murmur within about a second of the stream pausing.
    static func voice(sinceText elapsed: TimeInterval) -> CGFloat {
        0.25 + 0.75 * CGFloat(exp(-max(0, elapsed) / 0.35))
    }

    /// One waveform bar's height in points, between 2 and 7.
    static func barHeight(_ index: Int, time: TimeInterval, voice: CGFloat) -> CGFloat {
        let wobble = 0.5 + 0.5 * sin(time * (9 + 2.3 * Double(index)) + 1.7 * Double(index))
        return 2 + 5 * min(1, max(0, voice)) * CGFloat(wobble)
    }

    /// The session under a point measured leftward from the row's trailing end.
    func sessionID(atDistanceFromEnd distance: CGFloat) -> String {
        let fromEnd = min(items.count - 1, max(0, Int(distance / (Self.glyphSize + Self.spacing))))
        return items[items.count - 1 - fromEnd].sessionID
    }
}

/// The compact trailing content: one glyph per busy session.
struct LiveActivityLabel: View {
    var activity: LiveActivity
    var reducedMotion: Bool

    var body: some View {
        HStack(spacing: LiveActivity.spacing) {
            ForEach(activity.items, id: \.sessionID) { item in
                LiveActivityGlyph(kind: item.kind, symbol: item.symbol, written: item.written, reducedMotion: reducedMotion)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(reducedMotion ? nil : .snappy(duration: 0.3), value: activity.sessionIDs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.items.map { "\($0.title) \($0.kind == .waiting ? "needs you" : "is working")" }
            .joined(separator: ", "))
    }
}
/// A spinning arc around the current tool's glyph; amber pulses for a question.
/// While an answer streams, a small waveform speaks as its text arrives.
struct LiveActivityGlyph: View {
    var kind: LiveActivity.Kind
    var symbol: String
    var written = 0
    var reducedMotion: Bool
    var size: CGFloat = LiveActivity.glyphSize
    @State private var lastText: TimeInterval = -100

    var body: some View {
        let color = kind == .waiting ? IslandStyle.amber : IslandStyle.indicatorColor(.running)
        ZStack {
            Circle().fill(color.opacity(0.16))
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducedMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    if kind == .working {
                        let turn = time.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Circle().trim(from: 0, to: 0.3)
                            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(reducedMotion ? -90 : turn * 360))
                    } else {
                        let phase = time.truncatingRemainder(dividingBy: 1.8) / 1.8
                        Circle().stroke(color.opacity(reducedMotion ? 0.6 : 0.7 * (1 - phase)), lineWidth: 1.4)
                            .scaleEffect(reducedMotion ? 1 : 1 + 0.3 * phase)
                    }
                    if writing {
                        let voice = reducedMotion ? 0.5 : LiveActivity.voice(sinceText: time - lastText)
                        HStack(spacing: size * 0.09) {
                            ForEach(0..<3, id: \.self) { index in
                                Capsule().fill(color)
                                    .frame(width: size * 0.1, height: LiveActivity.barHeight(index, time: reducedMotion ? 0 : time, voice: voice)
                                           * size / LiveActivity.glyphSize)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            if !writing {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(color)
                    .contentTransition(reducedMotion ? .identity : .symbolEffect(.replace.downUp))
                    .transition(.opacity)
            }
        }
        .animation(reducedMotion ? nil : .smooth(duration: 0.35), value: symbol)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: written) { old, new in
            if new > old { lastText = Date().timeIntervalSinceReferenceDate }
        }
    }

    private var writing: Bool { kind == .working && symbol == LiveActivity.writingSymbol }
}
