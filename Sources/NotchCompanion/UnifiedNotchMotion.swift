import Foundation

/// The only visual clock for the notch. Native bounds and SwiftUI contents use
/// the same snapshot, rather than independently animating their target states.
struct NotchPresentation: Equatable {
    var frame: CGRect
    var progress: CGFloat
    var bandHeight: CGFloat
    /// The small island tier: 1 while the hover glance or the hold-to-ask
    /// island is settled, 0 at rest or open.
    var peek: CGFloat = 0
    /// A transient status announcement widening the resting band's shoulder.
    var announce: CGFloat = 0
    /// The live activity: a working or waiting session shown in the resting
    /// band's right shoulder, like an island's compact trailing content.
    var live: CGFloat = 0
    /// The mascot stage: the mascot presents a result or question on a larger island.
    var stage: CGFloat = 0
    /// The launch hello: the eyes lowered into the middle of a drop below the
    /// camera, and larger. This half follows the height...
    var hello: CGFloat = 0
    /// ...and this half, centring them across the drop, follows the width.
    var helloCentre: CGFloat = 0
    /// How far the flares have formed: 0 on the launch seed, so it matches the bare camera.
    var flares: CGFloat = 1

    var size: CGSize { frame.size }
    var bodyVisibleHeight: CGFloat { max(0, frame.height - bandHeight) }
    var cornerRadius: CGFloat { min(10 + 12 * progress + 8 * peek + 14 * stage + 10 * hello, min(frame.width, frame.height) / 2) }
    /// The window extends this far past both sides of the body to draw the flares.
    static let flareMargin: CGFloat = 12
    /// Concave fillets where the island meets the screen's top edge, as if it
    /// hung from it like liquid; they form as a drop emerges and grow with the tiers.
    var flare: CGFloat { flares * min(8 + 4 * max(progress, peek, stage, hello), Self.flareMargin, frame.height / 3) }

    /// The resting eyes' centre in local coordinates: in the left extension, or
    /// while the launch says hello, in the middle of the drop below the camera.
    func restingEyeCenter(_ geometry: NotchGeometry) -> CGPoint {
        let rest = CGPoint(x: geometry.mascotWidth / 2, y: geometry.eyeCenterY(progress: 0))
        let below = geometry.hasHardware ? bandHeight : 0
        return CGPoint(x: rest.x + (frame.width / 2 - rest.x) * helloCentre,
                       y: rest.y + ((below + frame.height) / 2 - rest.y) * hello)
    }
    var contentIsInteractive: Bool { progress >= 0.95 }
    var glanceIsInteractive: Bool { peek >= 0.95 }

    /// Local coordinates begin at the top-left, matching the unified SwiftUI root.
    /// The top corners are square; only the bottom corners are rounded.
    func contains(_ point: CGPoint) -> Bool {
        guard point.x >= 0, point.x < frame.width, point.y >= 0, point.y < frame.height else { return false }
        let radius = cornerRadius
        guard radius > 0, point.y > frame.height - radius else { return true }
        let circleX: CGFloat
        if point.x < radius { circleX = radius }
        else if point.x > frame.width - radius { circleX = frame.width - radius }
        else { return true }
        let dx = point.x - circleX
        let dy = point.y - (frame.height - radius)
        return dx * dx + dy * dy <= radius * radius
    }

    /// Squeezed under a held click: a few points narrower about the centre
    /// (and a little shorter for the glance), keeping the top on the screen edge.
    var pressed: NotchPresentation {
        var copy = self
        let inset = max(3, frame.width * 0.02)
        let lift = peek > 0.5 || stage > 0.5 ? max(2, (frame.height - bandHeight) * 0.03) : 0
        copy.frame = CGRect(x: frame.minX + inset, y: frame.minY + lift,
                            width: max(1, frame.width - 2 * inset), height: max(bandHeight, frame.height - lift))
        return copy
    }

    static let restingPlaceholder = NotchPresentation(
        frame: CGRect(x: 0, y: 0, width: 258, height: 32), progress: 0, bandHeight: 32
    )

    static func resting(_ geometry: NotchGeometry) -> Self {
        Self(frame: geometry.collapsedFrame, progress: 0, bandHeight: geometry.bandHeight,
             announce: geometry.announcing ? 1 : 0, live: geometry.showsLiveActivity ? 1 : 0)
    }

    static func glance(_ geometry: NotchGeometry) -> Self {
        Self(frame: geometry.glanceFrame, progress: 0, bandHeight: geometry.bandHeight, peek: 1)
    }

    /// Hold to ask shares the glance's tier; only its frame and content differ.
    static func ask(_ geometry: NotchGeometry) -> Self {
        Self(frame: geometry.askFrame, progress: 0, bandHeight: geometry.bandHeight, peek: 1)
    }

    static func stage(_ geometry: NotchGeometry) -> Self {
        Self(frame: geometry.stageFrame, progress: 0, bandHeight: geometry.bandHeight, stage: 1)
    }

    /// At launch the island pops out of the top edge (or the camera) as this
    /// drop, the eyes in its middle, before settling into the resting band.
    static func hello(_ geometry: NotchGeometry) -> Self {
        let width = geometry.hasHardware ? geometry.hardware.width : 160
        let height = geometry.bandHeight + 30
        let midX = geometry.hasHardware ? geometry.hardware.midX : geometry.screen.midX
        return Self(frame: CGRect(x: midX - width / 2, y: geometry.collapsedFrame.maxY - height, width: width, height: height),
                    progress: 0, bandHeight: geometry.bandHeight, hello: 1, helloCentre: 1)
    }

    /// What the hello drop grows from: the bare physical notch, the eyes hidden
    /// behind it, or without one a bead on the top edge.
    static func launchSeed(_ geometry: NotchGeometry) -> Self {
        var seed = hello(geometry)
        if geometry.hasHardware {
            seed.frame = geometry.hardware
        } else {
            let width = seed.frame.width * 0.45
            seed.frame = CGRect(x: seed.frame.midX - width / 2, y: seed.frame.maxY - 1, width: width, height: 1)
        }
        seed.hello = 0
        seed.flares = 0
        return seed
    }

    static func expanded(_ geometry: NotchGeometry) -> Self {
        Self(frame: geometry.expandedFrame, progress: 1, bandHeight: geometry.expandedBandHeight)
    }
}

/// One top-anchored morph for the complete silhouette, sampled in uptime seconds.
/// Every tier opens on a spring, island-style: the small glance, announcement
/// and live tiers with a light bounce, the full panel with a firmer one.
/// Springs are organic: whichever dimension grows leads, so an opening island
/// stretches down before it spreads, like a drop, and a shrinking one spreads
/// before it is drawn back up. Closing keeps a quick ease-out.
struct UnifiedNotchMotion {
    enum Curve: Equatable { case easeOut, spring, panelSpring, liquid }

    static let expansionDuration: TimeInterval = 0.26
    static let collapseDuration: TimeInterval = 0.20
    /// Settling time of the glance/announcement spring (residual < 0.5%).
    static let springDuration: TimeInterval = 0.46
    /// Settling time of the full panel's firmer spring (residual < 0.5%).
    static let panelSpringDuration: TimeInterval = 0.5
    /// A held click squeezes the island this quickly.
    static let pressDuration: TimeInterval = 0.11
    /// An announcement retracts more gently than a panel collapses.
    static let announcementCollapseDuration: TimeInterval = 0.34
    /// Each launch phase settles within this (residual < 0.5 point).
    static let liquidDuration: TimeInterval = 1.4

    var from: NotchPresentation
    var to: NotchPresentation
    var startedAt: TimeInterval
    var duration: TimeInterval
    var curve: Curve

    init(from: NotchPresentation, to: NotchPresentation, startedAt: TimeInterval,
         duration: TimeInterval? = nil, curve requested: Curve? = nil) {
        self.from = from
        self.to = to
        self.startedAt = startedAt
        let deltaProgress = to.progress - from.progress
        let deltaPeek = to.peek - from.peek
        let deltaAnnounce = to.announce - from.announce
        let deltaLive = to.live - from.live
        let deltaStage = to.stage - from.stage
        let opening = deltaProgress > 0
            || (deltaProgress == 0 && (deltaPeek > 0 || deltaStage > 0
                || (deltaPeek == 0 && deltaStage == 0
                    && (deltaAnnounce > 0 || deltaLive > 0 || (deltaAnnounce == 0 && deltaLive == 0)))))
        // Small tiers settle with a light spring and the full panel with a firmer one.
        let springs = opening && deltaProgress == 0 && to.progress == 0
            && (to.peek > 0 || to.announce > 0 || to.live > 0 || to.stage > 0)
        let panelSprings = deltaProgress > 0 && to.progress == 1
        curve = requested ?? (springs ? .spring : panelSprings ? .panelSpring : .easeOut)
        // A reversal travels only the remaining distance; a nearly closed notch
        // should not spend another full transition easing into its resting band.
        let distance = Double(max(abs(deltaProgress), abs(deltaPeek), abs(deltaAnnounce), abs(deltaLive), abs(deltaStage)))
        let base: TimeInterval
        switch curve {
        case .spring: base = Self.springDuration
        case .panelSpring: base = Self.panelSpringDuration
        case .liquid: base = Self.liquidDuration
        case .easeOut:
            if opening { base = Self.expansionDuration }
            else if deltaProgress == 0 && deltaPeek == 0 { base = Self.announcementCollapseDuration }
            else { base = Self.collapseDuration }
        }
        // Geometry can change without changing expansion progress. Retargeting
        // those bounds still receives a transition unless the host requests a snap.
        let scale = curve != .easeOut ? 1 : (distance > 0 ? distance : from == to ? 0 : 1)
        self.duration = duration ?? (from == to ? 0 : base * scale)
    }

    func isComplete(at time: TimeInterval) -> Bool { duration <= 0 || time >= startedAt + duration }

    /// A failure shakes the whole island "no", like a rejected Face ID.
    static let shakeDuration: TimeInterval = 0.5

    /// Horizontal offset in points: about four quick swings that die away.
    static func shakeOffset(_ elapsed: TimeInterval) -> CGFloat {
        guard elapsed > 0, elapsed < shakeDuration else { return 0 }
        let decay = 1 - elapsed / shakeDuration
        return CGFloat(6 * decay * decay * sin(elapsed * 2 * .pi * 8))
    }

    func presentation(at time: TimeInterval) -> NotchPresentation {
        let fraction = duration > 0 ? min(1, max(0, (time - startedAt) / duration)) : 1
        if fraction == 0 { return from }
        if fraction == 1 { return to }
        // The silhouette may overshoot slightly on a spring; the scalar states
        // that drive opacity and interactivity never leave their endpoints.
        // On a spring the leading dimension moves first and the other follows a
        // beat later, overshooting as the first settles: stretch, squash, settle.
        // `amount` drives the height and `spread` the width.
        let elapsed = fraction * duration
        let lead: CGFloat
        let trail: CGFloat
        switch curve {
        case .spring:
            lead = Self.spring(elapsed)
            trail = Self.spring(lagged(elapsed, by: 0.05))
        case .panelSpring:
            lead = Self.panelSpring(elapsed)
            trail = Self.panelSpring(lagged(elapsed, by: 0.04))
        case .liquid:
            lead = Self.liquidLead(elapsed)
            trail = Self.liquidTrail(max(0, elapsed - 0.2))
        case .easeOut:
            lead = Self.easeOut(fraction)
            trail = lead
        }
        let heightLeads = to.frame.height >= from.frame.height
        let amount = heightLeads ? lead : trail
        let spread = heightLeads ? trail : lead
        let bounded = min(1, max(0, amount))
        func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * amount }
        func settle(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * bounded }
        let width = from.frame.width + (to.frame.width - from.frame.width) * spread
        // Never shorter than both ends: rising above the band would bare the camera's edge.
        let height = max(min(from.frame.height, to.frame.height), interpolate(from.frame.height, to.frame.height))
        let top = interpolate(from.frame.maxY, to.frame.maxY)
        // Keep the silhouette centred on its interpolated centre so a spring
        // overshoot grows both shoulders rather than sliding the band sideways
        // (and an announcement's camera-side edge stays put).
        let midX = from.frame.midX + (to.frame.midX - from.frame.midX) * spread
        return NotchPresentation(
            frame: CGRect(x: midX - width / 2, y: top - height, width: width, height: height),
            progress: settle(from.progress, to.progress),
            bandHeight: settle(from.bandHeight, to.bandHeight),
            peek: settle(from.peek, to.peek),
            announce: settle(from.announce, to.announce),
            live: settle(from.live, to.live),
            stage: settle(from.stage, to.stage),
            hello: settle(from.hello, to.hello),
            helloCentre: from.helloCentre + (to.helloCentre - from.helloCentre) * min(1, max(0, spread)),
            flares: settle(from.flares, to.flares)
        )
    }

    /// The width's clock: `lag` late, catching up so it settles with the height.
    private func lagged(_ elapsed: TimeInterval, by lag: TimeInterval) -> TimeInterval {
        duration > lag ? max(0, elapsed - lag) * duration / (duration - lag) : elapsed
    }

    private static func easeOut(_ fraction: Double) -> CGFloat {
        // Cubic timing curve (0, 0, 0.58, 1). All presentation properties share
        // this one eased fraction; no second animation occurs in the view tree.
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<14 {
            let position = (lower + upper) / 2
            let x = 3 * (1 - position) * position * position * 0.58 + position * position * position
            if x < fraction { lower = position } else { upper = position }
        }
        let position = (lower + upper) / 2
        return CGFloat(3 * position * position - 2 * position * position * position)
    }

    /// Under-damped step response (ζ 0.74, 0.4 s natural period): about a 3%
    /// overshoot, settled within `springDuration`.
    static func spring(_ elapsed: TimeInterval) -> CGFloat {
        step(elapsed, damping: 0.74, period: 0.4)
    }

    /// The full panel's firmer spring (ζ 0.8, 0.42 s): about a 1.5% overshoot,
    /// 95% of the way at 0.23 s, settled within `panelSpringDuration`.
    static func panelSpring(_ elapsed: TimeInterval) -> CGFloat {
        step(elapsed, damping: 0.8, period: 0.42)
    }

    /// A launch phase's leading dimension: a loose spring (ζ 0.45, 0.6 s) that
    /// overshoots about 20%.
    static func liquidLead(_ elapsed: TimeInterval) -> CGFloat {
        step(elapsed, damping: 0.45, period: 0.6)
    }

    /// The trailing dimension, started 0.2 s later (ζ 0.55, 0.62 s).
    static func liquidTrail(_ elapsed: TimeInterval) -> CGFloat {
        step(elapsed, damping: 0.55, period: 0.62)
    }

    private static func step(_ elapsed: TimeInterval, damping: Double, period: Double) -> CGFloat {
        let omega = 2 * Double.pi / period
        let dampedOmega = omega * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * omega * elapsed)
        let value = 1 - decay * (cos(dampedOmega * elapsed) + damping * omega / dampedOmega * sin(dampedOmega * elapsed))
        return CGFloat(value)
    }
}
