import SwiftUI

/// The expanded panel's design, chosen in Settings. `CompanionStyle` reads
/// `current`, and the panel roots rebuild (`panelThemed()`) when it changes.
/// The island tiers use `IslandStyle` and look the same in every design.
enum PanelTheme: String, CaseIterable, Identifiable {
    /// Quiet, Refined: graphite, warm white and sage on one grid and type scale.
    case refined
    /// Native Tahoe: the system accent, label opacities and grouped inset lists.
    case tahoe
    /// Instrument: monochrome plus one orange signal, mono labels, hairlines.
    case instrument

    static let key = "notch.panelTheme"
    /// Read on every token lookup, so it is cached rather than read from defaults.
    nonisolated(unsafe) static var current = stored
    static var stored: PanelTheme {
        UserDefaults.standard.string(forKey: key).flatMap(PanelTheme.init(rawValue:)) ?? .refined
    }

    var id: Self { self }
    var label: String {
        switch self {
        case .refined: return "Refined"
        case .tahoe: return "Tahoe"
        case .instrument: return "Instrument"
        }
    }

    /// One value per design; the common way a token differs between them.
    static func pick<T>(_ refined: T, _ tahoe: T, _ instrument: T) -> T {
        switch current {
        case .refined: return refined
        case .tahoe: return tahoe
        case .instrument: return instrument
        }
    }
}

private struct PanelThemed: ViewModifier {
    @AppStorage(PanelTheme.key) private var theme = PanelTheme.refined

    func body(content: Content) -> some View {
        // Sync before the subtree builds, so its tokens read the new design.
        let _ = PanelTheme.current = theme
        content.id(theme)
    }
}

extension View {
    /// Rebuilds the subtree in the current design when the setting changes.
    /// Navigation, drafts and sessions live in the model and survive.
    func panelThemed() -> some View { modifier(PanelThemed()) }
}

/// The expanded panel's tokens in the current `PanelTheme`. Tokens shared by
/// every design dispatch on it; tokens only one design uses are grouped below
/// under that design. The island tiers keep `IslandStyle`.
enum CompanionStyle {
    private static func pick<T>(_ refined: T, _ tahoe: T, _ instrument: T) -> T {
        PanelTheme.pick(refined, tahoe, instrument)
    }

    static var background: Color {
        pick(Color(red: 0.035, green: 0.043, blue: 0.04), Color(red: 0.07, green: 0.07, blue: 0.075), Color(white: 0.02))
    }
    /// Opaque raised surface.
    static var surface: Color {
        pick(Color(red: 0.105, green: 0.12, blue: 0.11), Color(red: 0.11, green: 0.11, blue: 0.118), Color(white: 0.085))
    }
    static var text: Color {
        pick(Color(red: 0.95, green: 0.95, blue: 0.91), Color.white.opacity(0.92), Color(white: 0.96))
    }
    static var secondary: Color {
        pick(Color(red: 0.68, green: 0.71, blue: 0.67), Color.white.opacity(0.56), Color(white: 0.64))
    }
    /// Tahoe: decorative only (chevrons, page dots). Instrument: the quietest
    /// text that still meets AA contrast on black.
    static var faint: Color {
        pick(Color(red: 0.43, green: 0.45, blue: 0.42), Color.white.opacity(0.3), Color(white: 0.48))
    }
    /// Sage, the system accent color, or the instrument's signal orange.
    static var accent: Color {
        pick(Color(red: 0.73, green: 0.82, blue: 0.66), Color.accentColor, signal)
    }
    /// Text and glyphs on the accent.
    static var onAccent: Color {
        pick(Color(red: 0.063, green: 0.078, blue: 0.055), Color.white, Color.black)
    }
    /// Resting fill for controls outside the notch body.
    static var controlFill: Color {
        pick(Color.white.opacity(0.08), Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.26), Color.white.opacity(0.035))
    }
    static var amber: Color {
        pick(Color(red: 0.95, green: 0.76, blue: 0.43), Color(red: 1, green: 0.624, blue: 0.039), signal)
    }
    static var error: Color {
        pick(Color(red: 1, green: 0.57, blue: 0.52), Color(red: 1, green: 0.271, blue: 0.227), signal)
    }
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.79)
    /// Press feedback: quick in, slight overshoot out.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.6)

    /// Refined: one status palette matching the island's dots. Tahoe: the
    /// system status colors. Instrument: white for activity and results, the
    /// signal when it needs you.
    static func color(_ state: WorkState) -> Color {
        switch PanelTheme.current {
        case .refined:
            switch state {
            case .working: return indicatorColor(.running)
            case .waiting: return amber
            case .finished: return indicatorColor(.finished)
            case .failed: return error
            default: return secondary
            }
        case .tahoe:
            switch state { case .working, .waiting: return amber; case .finished: return green; case .failed: return error; default: return secondary }
        case .instrument:
            switch state { case .working, .finished: return text; case .waiting, .failed: return signal; default: return secondary }
        }
    }
    static func label(_ state: WorkState) -> String {
        switch state { case .idle: return "Ready"; case .working: return "Working"; case .waiting: return "Needs you"; case .finished: return "Finished"; case .failed: return "Needs attention"; case .interrupted: return "Stopped" }
    }
    /// Unread and activity dots inside the panel (the island's own dots use
    /// `IslandStyle.indicatorColor`).
    static func indicatorColor(_ status: CollapsedStatus) -> Color {
        switch PanelTheme.current {
        case .refined: return IslandStyle.indicatorColor(status)
        case .tahoe:
            switch status {
            case .running, .waiting: return amber
            case .finished: return green
            case .failed: return error
            case .none: return .clear
            }
        case .instrument:
            switch status {
            case .running, .finished: return text
            case .waiting, .failed: return signal
            case .none: return .clear
            }
        }
    }

    // MARK: Refined

    /// Metadata: times, runtimes, hints and placeholders (6.6:1 on black).
    static let tertiary = Color(red: 0.55, green: 0.57, blue: 0.54)
    /// Cards that sit on the body: code, tools, changes, settings groups.
    static let well = Color.white.opacity(0.045)
    /// The user's own messages and lit rows.
    static let raised = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.08)
    /// Opaque menus that float over the transcript.
    static let popover = Color(red: 0.095, green: 0.1, blue: 0.095)

    /// Type scale: display for empty states, title for the header, body for
    /// reading, callout for controls and previews, caption for metadata.
    static let display = Font.system(size: 20, weight: .semibold)
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let callout = Font.system(size: 12)
    static let caption = Font.system(size: 11)

    /// Corner radii: small marks, rows and transcript cards, settings cards,
    /// and the docked field, bubbles and menus.
    enum Radius {
        static let small: CGFloat = 6
        static let row: CGFloat = 10
        static let card: CGFloat = 14
        static let field: CGFloat = 18
    }

    static func statusColor(_ status: CollapsedStatus) -> Color {
        switch status {
        case .running: return color(.working)
        case .waiting: return color(.waiting)
        case .finished: return color(.finished)
        case .failed: return color(.failed)
        case .none: return secondary
        }
    }

    // MARK: Tahoe

    /// Popovers, menus and the sent-message bubble.
    static let elevated = Color(red: 0.165, green: 0.165, blue: 0.175)
    /// Translucent fill of grouped sections and cards, `quaternarySystemFill`.
    static let fill = Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.17)
    /// Hairline separators and card edges.
    static let separator = Color.white.opacity(0.1)
    static let green = Color(red: 0.188, green: 0.82, blue: 0.345)

    // MARK: Instrument

    /// International orange: needs you, and the one primary action in view.
    static let signal = Color(red: 1, green: 0.353, blue: 0.122)
    /// Hairline rules and outlines.
    static let rule = Color.white.opacity(0.13)
    static let ruleStrong = Color.white.opacity(0.24)
    /// An inset field reads as a dark readout on any body.
    static let inset = Color.black.opacity(0.42)
    /// Corner radii: keys and fields, and cards.
    static let radius: CGFloat = 3
    static let cardRadius: CGFloat = 4
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Refined helpers

extension View {
    /// Refined: scrolling content softens as it passes under the header and
    /// into the composer instead of being cut at a hard edge.
    func scrollEdgeFade(top: CGFloat = 8, bottom: CGFloat = 12) -> some View {
        mask(VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
        })
    }

    /// Refined: banners above the content, one tinted, rounded notice style.
    func panelNotice(_ tint: Color) -> some View {
        font(CompanionStyle.caption)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: CompanionStyle.Radius.row, style: .continuous))
            .padding(.bottom, 8)
    }
}

// MARK: - Instrument components

extension View {
    /// The instrument's uppercase, tracked SF Mono micro-label.
    func microLabel(_ size: CGFloat = 10, weight: Font.Weight = .medium, tracking: CGFloat = 0.9) -> some View {
        font(CompanionStyle.mono(size, weight)).textCase(.uppercase).tracking(tracking)
    }
}

/// A status lamp. Lit lamps glow faintly; `pulsing` breathes for live work.
struct LED: View {
    var color: Color
    var lit = true
    var pulsing = false
    var size: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !pulsing || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let level = pulsing && !reduceMotion ? 0.45 + 0.55 * (0.5 + 0.5 * cos(phase * 2 * .pi)) : 1
            Group {
                if lit {
                    Circle().fill(color).shadow(color: color.opacity(0.7), radius: 2.5)
                } else {
                    Circle().strokeBorder(color, lineWidth: 1)
                }
            }
            .opacity(level)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A segmented bar meter, as on a hardware level display. The signal takes
/// over at the top of the scale.
struct SegmentMeter: View {
    var fraction: Double?
    var segments = 10
    var segmentWidth: CGFloat = 2.5
    var height: CGFloat = 9

    var body: some View {
        let lit = fraction.map { Int(($0 * Double(segments)).rounded(.up)) } ?? 0
        let hot = (fraction ?? 0) >= 0.9
        HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { index in
                Rectangle()
                    .fill(index < lit ? (hot ? CompanionStyle.signal : CompanionStyle.text) : Color.white.opacity(fraction == nil ? 0.1 : 0.18))
                    .frame(width: segmentWidth, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Section rule: a micro-label, then a hairline running to the trailing edge.
struct RuleLabel<Trailing: View>: View {
    var title: String
    var color: Color = CompanionStyle.secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).microLabel().foregroundStyle(color).lineLimit(1).layoutPriority(1)
            Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
            trailing
        }
    }
}

extension RuleLabel where Trailing == EmptyView {
    init(_ title: String, color: Color = CompanionStyle.secondary) {
        self.title = title
        self.color = color
        self.trailing = EmptyView()
    }
}

/// The panel's faint dot grid: the underlying measure the content sits on.
struct InstrumentGrid: View {
    var spacing: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            var y = spacing / 2
            while y < size.height {
                var x: CGFloat = 20
                while x <= size.width - 20 {
                    dots.addRect(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.white.opacity(0.07)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Four corner brackets, as in a camera viewfinder, around the header's eyes.
struct Reticle: View {
    var arm: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width, h = size.height
            for (x, y, dx, dy) in [(0, 0, 1, 1), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                path.move(to: CGPoint(x: x + dx * arm, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + dy * arm))
            }
            context.stroke(path, with: .color(.white.opacity(0.32)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hairline under the header, ruled like a scale: a tick every 8
/// points, a longer one every 40.
struct HeaderRule: View {
    var body: some View {
        Canvas { context, size in
            let y = size.height - 0.5
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: .color(.white.opacity(0.14)))
            var ticks = Path()
            var x: CGFloat = 0
            var index = 0
            while x <= size.width + 0.1 {
                let major = index % 5 == 0
                ticks.addRect(CGRect(x: min(x, size.width - 0.5), y: y - (major ? 4 : 2), width: 0.5, height: major ? 4 : 2))
                x += 8; index += 1
            }
            context.fill(ticks, with: .color(.white.opacity(0.16)))
        }
        .frame(height: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
