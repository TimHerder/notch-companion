import Foundation

/// A single fast gaze filter sampled by the host. Drawing uses these offsets
/// directly so a second SwiftUI spring cannot accumulate tracking latency.
enum PointerGazeMotion {
    static let sampleInterval: TimeInterval = 1.0 / 60.0
    static let responseTime: TimeInterval = 0.018
    static let trackingRadius: CGFloat = 1_200

    /// Gaze can follow distant movement on the mascot's display. This range is
    /// deliberately independent of the nearby expression and notch hover trigger.
    static func target(at location: CGPoint, mascotCenter: CGPoint, screen: CGRect,
                       reducedMotion: Bool = false) -> CGSize {
        guard !reducedMotion, screen.contains(location) else { return .zero }
        let deltaX = location.x - mascotCenter.x
        let deltaY = location.y - mascotCenter.y
        guard hypot(deltaX, deltaY) <= trackingRadius else { return .zero }
        return CGSize(width: min(3, max(-3, deltaX / 45)),
                      height: min(2, max(-2, -deltaY / 45)))
    }

    static func step(from current: CGSize, toward target: CGSize, elapsed: TimeInterval,
                     reducedMotion: Bool = false) -> CGSize {
        guard !reducedMotion else { return .zero }
        let blend = 1 - exp(-min(0.1, max(0, elapsed)) / responseTime)
        let next = CGSize(width: current.width + (target.width - current.width) * blend,
                          height: current.height + (target.height - current.height) * blend)
        return abs(target.width - next.width) + abs(target.height - next.height) <= 0.005 ? target : next
    }
}

/// The resting outline yielding toward a nearby pointer: distance sets how far
/// the nearest contour reaches, direction how it bends. Sampled with the gaze.
struct NotchPull: Equatable {
    /// The followed pointer in the body's top-left coordinates; held while it releases.
    var pointer = CGPoint.zero
    /// How far the contour reaches toward it, in points.
    var depth: CGFloat = 0
    var velocity: CGFloat = 0

    static let radius: CGFloat = 90
    static let reach: CGFloat = 10
    /// How much contour either side of the nearest point follows (a Gaussian's sigma).
    static let spread: CGFloat = 24
    static let followTime: TimeInterval = 0.06
    /// The critically damped spring's angular frequency: soft, never wobbling.
    static let stiffness: CGFloat = 14

    static func nearestEdge(to point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }

    /// Strongest close by, tapering to nothing at the edge so the contour never
    /// passes the pointer or snaps as it enters the band.
    static func targetDepth(distance: CGFloat) -> CGFloat {
        guard distance > 0, distance < radius else { return 0 }
        let t = 1 - distance / radius
        return min(reach * t * t * (3 - 2 * t), 0.7 * distance)
    }

    /// `pointer` nil releases the pull, as does one inside the band or out of range.
    func stepped(toward pointer: CGPoint?, size: CGSize, elapsed: TimeInterval) -> NotchPull {
        let dt = CGFloat(min(0.1, max(0, elapsed)))
        var next = self
        var target: CGFloat = 0
        if let pointer {
            let edge = Self.nearestEdge(to: pointer, size: size)
            target = Self.targetDepth(distance: hypot(pointer.x - edge.x, pointer.y - edge.y))
            if target > 0 {
                let blend = depth > 0 ? 1 - exp(-dt / CGFloat(Self.followTime)) : 1
                next.pointer = CGPoint(x: self.pointer.x + (pointer.x - self.pointer.x) * blend,
                                       y: self.pointer.y + (pointer.y - self.pointer.y) * blend)
            }
        }
        let offset = depth - target
        let carry = velocity + Self.stiffness * offset
        let decay = exp(-Self.stiffness * dt)
        next.depth = max(0, target + (offset + carry * dt) * decay)
        next.velocity = (velocity - Self.stiffness * carry * dt) * decay
        if abs(next.depth - target) < 0.01, abs(next.velocity) < 0.05 {
            next.depth = target
            next.velocity = 0
        }
        return next
    }
}

/// Deterministic interaction policy. Times are monotonic uptime seconds supplied
/// by the host; this type neither schedules timers nor reads desktop state.
struct NotchInteraction {
    enum Mode: Equatable { case closed, hover, intentional }
    enum Action: Equatable { case showPassively, activate, close }

    var hoverDelay: TimeInterval = 0.12
    var leaveDelay: TimeInterval = 0.30
    private(set) var mode: Mode = .closed
    private(set) var suppressedUntilTriggerExit = false
    private(set) var dragSources: Set<String> = []
    private var hoverBegan: TimeInterval?
    private var leaveBegan: TimeInterval?
    var hasActiveDrag: Bool { !dragSources.isEmpty }

    mutating func update(now: TimeInterval, insideTrigger: Bool, insideRegion: Bool,
                         protected: Bool = false, openOnHover: Bool = true) -> Action? {
        if !insideTrigger {
            hoverBegan = nil
            suppressedUntilTriggerExit = false
        }
        switch mode {
        case .closed:
            guard !protected, !suppressedUntilTriggerExit else {
                hoverBegan = nil
                return nil
            }
            if hasActiveDrag { return beginHover() }
            guard openOnHover else {
                hoverBegan = nil
                return nil
            }
            guard insideTrigger else { return nil }
            if hoverBegan == nil { hoverBegan = now }
            guard now - (hoverBegan ?? now) >= hoverDelay else { return nil }
            return beginHover()
        case .hover:
            if protected || insideRegion || hasActiveDrag {
                leaveBegan = nil
                return nil
            }
            if leaveBegan == nil { leaveBegan = now }
            guard now - (leaveBegan ?? now) >= leaveDelay else { return nil }
            mode = .closed
            hoverBegan = nil
            leaveBegan = nil
            return .close
        case .intentional:
            return nil
        }
    }

    /// Distinct sources avoid an exit from one NSPanel cancelling a drag that
    /// has already entered the other NSPanel. The leave timer bridges a gap.
    mutating func dragChanged(source: String, active: Bool, now: TimeInterval) -> Action? {
        if active {
            dragSources.insert(source)
            leaveBegan = nil
            guard mode == .closed, !suppressedUntilTriggerExit else { return nil }
            return beginHover()
        }
        dragSources.remove(source)
        if mode == .hover && !hasActiveDrag { leaveBegan = now }
        return nil
    }

    /// A click while peeking pins the existing panel instead of toggling it shut.
    mutating func activate() -> Action {
        mode = .intentional
        suppressedUntilTriggerExit = false
        hoverBegan = nil
        leaveBegan = nil
        return .activate
    }

    mutating func toggle() -> Action {
        mode == .closed ? activate() : dismiss()
    }

    mutating func dismiss() -> Action {
        mode = .closed
        suppressedUntilTriggerExit = true
        dragSources.removeAll()
        hoverBegan = nil
        leaveBegan = nil
        return .close
    }

    private mutating func beginHover() -> Action {
        mode = .hover
        hoverBegan = nil
        leaveBegan = nil
        return .showPassively
    }
}

/// Two-finger trackpad swipes on the notch, as a pure policy. Travel is the
/// finger's own direction (positive is downward) regardless of the natural
/// scrolling preference; each gesture acts at most once and momentum never acts.
struct NotchSwipe {
    enum Tier: Equatable { case resting, glance, expanded }
    enum Action: Equatable { case open, close }

    static let threshold: CGFloat = 24
    private(set) var travel: CGFloat = 0
    private var acted = false

    /// - Parameters:
    ///   - began/ended: the gesture's phase boundaries.
    ///   - momentum: the fling after the fingers lift.
    ///   - deltaY: `scrollingDeltaY`; `inverted` is `isDirectionInvertedFromDevice`.
    mutating func update(began: Bool, ended: Bool, momentum: Bool, deltaY: CGFloat, inverted: Bool,
                         tier: Tier) -> Action? {
        guard !momentum else { return nil }
        if began { travel = 0; acted = false }
        travel += (inverted ? 1 : -1) * deltaY
        var action: Action?
        if !acted {
            if travel > Self.threshold, tier != .expanded { action = .open }
            else if travel < -Self.threshold, tier != .resting { action = .close }
            if action != nil { acted = true }
        }
        if ended { travel = 0; acted = false }
        return action
    }
}
