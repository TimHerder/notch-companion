import AppKit
import SwiftUI

/// A transient status moment for the collapsed notch: the band names the
/// session briefly and the aura lights the silhouette's edge.
struct NotchAnnouncement: Identifiable, Equatable {
    enum Kind: Equatable, CaseIterable {
        case finished, failed, needsInput
        /// The first launch says hello and shows where to hover.
        case hello

        var verb: String {
            switch self {
            case .finished: return "Done"
            case .failed: return "Failed"
            case .needsInput: return "Needs you"
            case .hello: return "Hi!"
            }
        }

        var symbol: String {
            switch self {
            case .finished: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .needsInput: return "questionmark.circle.fill"
            case .hello: return "hand.wave.fill"
            }
        }

        var color: Color {
            switch self {
            case .finished: return IslandStyle.indicatorColor(.finished)
            case .failed: return IslandStyle.indicatorColor(.failed)
            case .needsInput: return IslandStyle.amber
            case .hello: return IslandStyle.accent
            }
        }

        /// How long the widened band names the session before retracting.
        var bannerDuration: TimeInterval {
            switch self {
            case .finished: return 4.2
            case .failed: return 5
            case .needsInput: return 6
            case .hello: return 6
            }
        }

        /// The mascot stage holds longer: it has more to read, and hovering it
        /// holds it further.
        var stageDuration: TimeInterval {
            switch self {
            case .finished: return 6.5
            case .failed: return 7.5
            case .needsInput: return 12
            case .hello: return 7
            }
        }

        /// The aura's bright core and its softer surrounding light.
        var core: Color {
            switch self {
            case .finished: return Color(red: 0.80, green: 1.0, blue: 0.86)
            case .failed: return Color(red: 1.0, green: 0.82, blue: 0.78)
            case .needsInput: return Color(red: 1.0, green: 0.90, blue: 0.72)
            case .hello: return Color(red: 0.97, green: 0.98, blue: 0.94)
            }
        }

        var glow: Color {
            switch self {
            case .finished: return Color(red: 0.28, green: 0.93, blue: 0.56)
            case .failed: return Color(red: 1.0, green: 0.34, blue: 0.30)
            case .needsInput: return Color(red: 1.0, green: 0.74, blue: 0.28)
            case .hello: return Color(red: 0.73, green: 0.86, blue: 0.66)
            }
        }
    }

    var id = UUID()
    let kind: Kind
    let sessionID: String
    let title: String

    /// Natural width of the announcement label, so the band widens only as
    /// far as the title needs (bounded so long titles still truncate).
    var labelWidth: CGFloat {
        let verb = (kind.verb as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width
        let name = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5)]).width
        return min(230, max(120, ceil(14 + 6 + verb + 6 + name + 2)))
    }
}

/// Intensities of one aura sample. Positions run along each half of the
/// outline, from the bottom centre (0) to the top corner (1).
struct AuraSample: Equatable {
    var head: CGFloat = 0
    var headGlow: CGFloat = 0
    var trail: CGFloat = 0
    var flash: CGFloat = 0
    var ripple: CGFloat = 0
    var rippleOpacity: CGFloat = 0
    var bloom: CGFloat = 0
    /// Moving dashes along the flaring edge, and their travel in points.
    var energy: CGFloat = 0
    var dashPhase: CGFloat = 0

    var isDark: Bool { max(headGlow, trail, flash, rippleOpacity, bloom) < 0.005 }
}

/// Pure, deterministic aura choreography sampled by elapsed seconds.
/// - Finished: two light traces race from the bottom centre around both
///   corners, the whole edge flares green, and a soft ring expands outward.
/// - Failed: a red double flicker, then a short fade, while the host shakes the
///   whole island (and this window with it).
/// - Needs input: two slow amber breaths and a gentle ring.
/// Reduced motion keeps only a soft fade of the edge light.
enum NotchAuraTimeline {
    static let traceDuration: TimeInterval = 0.72

    static func duration(_ kind: NotchAnnouncement.Kind, reducedMotion: Bool) -> TimeInterval {
        if reducedMotion { return 1.6 }
        switch kind {
        case .finished, .hello: return 2.1
        case .failed: return 1.5
        case .needsInput: return 2.4
        }
    }

    static func sample(_ kind: NotchAnnouncement.Kind, elapsed t: TimeInterval, reducedMotion: Bool) -> AuraSample {
        var s = AuraSample()
        guard t >= 0, t < duration(kind, reducedMotion: reducedMotion) else { return s }
        if reducedMotion {
            s.flash = 0.75 * ramp(t, from: 0, to: 0.25) * (1 - ramp(t, from: 0.8, to: 1.6))
            s.bloom = s.flash
            return s
        }
        switch kind {
        case .finished, .hello:
            let trace = traceDuration
            s.head = t < trace ? easeInOut(t / trace) : 1
            s.headGlow = t < trace ? 1 : max(0, 1 - (t - trace) / 0.15)
            s.trail = 0.75 * (1 - ramp(t, from: trace, to: trace + 1))
            s.flash = ramp(t, from: 0.58, to: 0.8) * (1 - ramp(t, from: 0.8, to: 2.05))
            let u = (t - trace) / 0.95
            if u >= 0, u < 1 {
                s.ripple = easeOut(u)
                s.rippleOpacity = 0.6 * pow(1 - u, 1.5)
            }
            s.bloom = max(0.45 * s.trail, s.flash)
            s.energy = 1
            s.dashPhase = CGFloat(t * 70)
        case .failed:
            let flicker: CGFloat = t < 0.08 ? 1 : t < 0.14 ? 0.2 : t < 0.24 ? 1 : 0
            s.flash = max(flicker, t >= 0.24 ? 0.9 * (1 - ramp(t, from: 0.24, to: 1.45)) : 0)
            let u = (t - 0.14) / 0.7
            if u >= 0, u < 1 {
                s.ripple = 0.6 * easeOut(u)
                s.rippleOpacity = 0.45 * pow(1 - u, 1.5)
            }
            s.bloom = 0.85 * s.flash
        case .needsInput:
            let period = 1.1
            let phase = t.truncatingRemainder(dividingBy: period) / period
            let breath = t < 2 * period ? CGFloat(pow(sin(Double.pi * phase), 2)) : 0
            s.flash = 0.8 * breath
            let u = (t - 0.35) / 1.1
            if u >= 0, u < 1 {
                s.ripple = 0.8 * easeOut(u)
                s.rippleOpacity = 0.4 * pow(1 - u, 1.5)
            }
            s.bloom = s.flash
            s.energy = 0.6
            s.dashPhase = CGFloat(t * 30)
        }
        return s
    }

    private static func ramp(_ t: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> CGFloat {
        EyeMotion.smoothstep(CGFloat((t - start) / (end - start)))
    }

    private static func easeInOut(_ x: Double) -> CGFloat {
        let v = min(1, max(0, x))
        return CGFloat(v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2)
    }

    private static func easeOut(_ x: Double) -> CGFloat {
        CGFloat(1 - pow(1 - min(1, max(0, x)), 3))
    }
}

/// The aura currently playing, timed on the reference-date clock that
/// SwiftUI timelines use.
struct NotchAuraEffect: Equatable {
    let kind: NotchAnnouncement.Kind
    let startedAt: TimeInterval
    let reducedMotion: Bool
    var duration: TimeInterval { NotchAuraTimeline.duration(kind, reducedMotion: reducedMotion) }
}

@MainActor
final class NotchAuraState: ObservableObject {
    @Published var effect: NotchAuraEffect?
    @Published var presentation = NotchPresentation.restingPlaceholder
}

/// Light drawn just outside the silhouette. The aura window sits behind the
/// notch, so the black body covers the inner half of every stroke and the
/// light appears to come from the notch's own edge.
struct NotchAuraView: View {
    @ObservedObject var state: NotchAuraState
    var margin: CGFloat = NotchAuraPanel.margin

    var body: some View {
        if let effect = state.effect {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate - effect.startedAt
                Self.drawing(kind: effect.kind,
                             sample: NotchAuraTimeline.sample(effect.kind, elapsed: elapsed, reducedMotion: effect.reducedMotion),
                             notch: state.presentation.size, cornerRadius: state.presentation.cornerRadius, margin: margin)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Internal so offscreen fixtures can render fixed samples.
    static func drawing(kind: NotchAnnouncement.Kind, sample: AuraSample, notch: CGSize,
                        cornerRadius: CGFloat, margin: CGFloat) -> some View {
        Canvas { context, _ in
            guard !sample.isDark else { return }
            // Sit just outside the edge so the black body hides less of each stroke.
            let outline = halves(notch: notch, radius: cornerRadius, margin: margin, inflate: 1)
            let glow = kind.glow
            let core = kind.core
            func stroke(_ paths: [Path], color: Color, width: CGFloat, blur: CGFloat = 0) {
                if blur > 0 {
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: blur))
                        for path in paths { layer.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round)) }
                    }
                } else {
                    for path in paths { context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round)) }
                }
            }
            if sample.bloom > 0.005 {
                stroke(outline, color: glow.opacity(0.8 * sample.bloom), width: 12, blur: 11)
            }
            if sample.rippleOpacity > 0.005 {
                let ring = halves(notch: notch, radius: cornerRadius, margin: margin, inflate: 2 + 18 * sample.ripple)
                stroke(ring, color: glow.opacity(Double(sample.rippleOpacity)), width: 2, blur: 3)
            }
            if sample.trail > 0.005, sample.head > 0 {
                let lit = outline.map { $0.trimmedPath(from: 0, to: sample.head) }
                stroke(lit, color: glow.opacity(0.8 * sample.trail), width: 4, blur: 2.5)
                stroke(lit, color: glow.opacity(Double(sample.trail)), width: 2)
            }
            if sample.headGlow > 0.005, sample.head > 0 {
                let comet = outline.map { $0.trimmedPath(from: max(0, sample.head - 0.16), to: sample.head) }
                stroke(comet, color: glow.opacity(0.9 * sample.headGlow), width: 14, blur: 8)
                stroke(comet, color: core.opacity(0.9 * sample.headGlow), width: 6, blur: 3)
                stroke(comet, color: core.opacity(Double(sample.headGlow)), width: 2.6)
            }
            if sample.flash > 0.005 {
                stroke(outline, color: glow.opacity(0.9 * sample.flash), width: 5, blur: 3)
                stroke(outline, color: core.opacity(Double(sample.flash)), width: 2.2)
                if sample.energy > 0.005 {
                    // Fine dashes stream outward along the lit edge.
                    for path in halves(notch: notch, radius: cornerRadius, margin: margin, inflate: 3.5) {
                        context.stroke(path, with: .color(core.opacity(Double(0.75 * sample.energy * sample.flash))),
                                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1.5, 7],
                                                          dashPhase: -sample.dashPhase))
                    }
                }
            }
        }
    }

    /// The silhouette's visible edge as two halves running from the bottom
    /// centre around each rounded corner to the top of the screen.
    static func halves(notch: CGSize, radius: CGFloat, margin: CGFloat, inflate: CGFloat) -> [Path] {
        let minX = margin - inflate
        let maxX = margin + notch.width + inflate
        let bottom = notch.height + inflate
        let corner = max(0, min(radius + inflate, bottom, (maxX - minX) / 2))
        let middle = CGPoint(x: (minX + maxX) / 2, y: bottom)
        var right = Path()
        right.move(to: middle)
        right.addArc(tangent1End: CGPoint(x: maxX, y: bottom), tangent2End: CGPoint(x: maxX, y: 0), radius: corner)
        right.addLine(to: CGPoint(x: maxX, y: 0))
        var left = Path()
        left.move(to: middle)
        left.addArc(tangent1End: CGPoint(x: minX, y: bottom), tangent2End: CGPoint(x: minX, y: 0), radius: corner)
        left.addLine(to: CGPoint(x: minX, y: 0))
        return [left, right]
    }
}

/// A click-through, purely decorative window ordered directly behind the
/// notch panel. It owns no geometry, input, or expansion: it only mirrors the
/// panel's current `NotchPresentation` while an aura plays, then orders out.
@MainActor
final class NotchAuraPanel: NSPanel {
    nonisolated static let margin: CGFloat = 40

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .statusBar
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .canJoinAllApplications]
        animationBehavior = .none
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The notch frame plus a light margin on the sides and below (the top is the screen edge).
    nonisolated static func frame(around notch: CGRect) -> CGRect {
        CGRect(x: notch.minX - margin, y: notch.minY - margin,
               width: notch.width + 2 * margin, height: notch.height + margin)
    }
}
