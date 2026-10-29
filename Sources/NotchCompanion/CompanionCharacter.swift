import SwiftUI

/// What the eyes express, derived only from real session state.
enum CompanionMood: Equatable {
    case ready, thinking, working, answering, waiting, done, failed
    /// Nothing has happened for a while and nobody is near: the eyes doze.
    case sleeping

    /// While the band announces a result, the eyes react to that session.
    init(announcement kind: NotchAnnouncement.Kind) {
        switch kind {
        case .finished, .hello: self = .done
        case .failed: self = .failed
        case .needsInput: self = .waiting
        }
    }

    /// Only a calm companion dozes; work, questions and failures keep it awake.
    var canDoze: Bool { self == .ready || self == .done }

    static func resolve(overall: WorkState, current: CompanionSession?) -> Self {
        switch overall {
        case .waiting: return .waiting
        case .failed: return .failed
        case .finished: return .done
        case .idle, .interrupted: return .ready
        case .working:
            // Another session's work only reads as generic work.
            guard let current, current.state == .working else { return .working }
            if current.tools.contains(where: { $0.state == .working }) { return .working }
            // Assistant messages appear when streaming starts, so a trailing
            // user message means no answer has begun yet.
            return current.messages.last?.role == "user" ? .thinking : .answering
        }
    }
}

/// Eye parameters. Gaze is a unit direction (-1...1); `pointer` weights the
/// already-filtered live pointer gaze supplied by the host.
struct EyeExpression: Equatable {
    var pointer: CGFloat = 1
    var gazeX: CGFloat = 0
    var gazeY: CGFloat = 0
    var width: CGFloat = 1
    var height: CGFloat = 1
    /// Degrees; the left eye uses +tilt and the right eye -tilt.
    var tilt: CGFloat = 0
    /// 0 is a capsule, 1 a happy arc.
    var smile: CGFloat = 0
    /// 0...1 upward bounce.
    var hop: CGFloat = 0
    /// 0 is open, 1 a closed, downward-curving lid (dozing).
    var doze: CGFloat = 0

    static func mix(_ a: Self, _ b: Self, _ amount: CGFloat) -> Self {
        let t = min(1, max(0, amount))
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return Self(pointer: m(a.pointer, b.pointer), gazeX: m(a.gazeX, b.gazeX), gazeY: m(a.gazeY, b.gazeY),
                    width: m(a.width, b.width), height: m(a.height, b.height), tilt: m(a.tilt, b.tilt),
                    smile: m(a.smile, b.smile), hop: m(a.hop, b.hop), doze: m(a.doze, b.doze))
    }
}

/// Pure time-based expression timeline. Reduced motion keeps each mood's
/// static pose and drops scanning, hops, shakes, glances, and timed smiles.
enum EyeMotion {
    static let blend: TimeInterval = 0.22
    static let smileDuration: TimeInterval = 1.8
    static let glanceDuration: TimeInterval = 0.75
    static let chompDuration: TimeInterval = 1.3
    static let feedingPose = EyeExpression(width: 1.15, height: 1.3)

    // ponytail: expanded attention uses fixed directions toward the transcript
    // and request area, not tracked row anchors; pass anchor frames if gaze must
    // land on exact rows.
    static func pose(_ mood: CompanionMood, expanded: Bool, time: TimeInterval,
                     since: TimeInterval, reducedMotion: Bool) -> EyeExpression {
        let moving = !reducedMotion
        var e = EyeExpression()
        switch mood {
        case .ready:
            break
        case .thinking:
            guard expanded else { break }
            e.pointer = 0
            e.gazeX = 0.55 + (moving ? 0.25 * CGFloat(sin(time * 0.9)) : 0)
            e.gazeY = -0.9
            e.height = 0.88
        case .working:
            guard expanded else { break }
            // Reading: a steady left-right scan.
            e.pointer = 0
            e.height = 0.78
            let scan = moving ? 0.8 * CGFloat(sin(time * 2.6)) : 0
            e.gazeX = 0.35 + scan * 0.6
            e.gazeY = 0.55
        case .answering:
            guard expanded else { break }
            e.pointer = 0
            e.height = 0.9
            e.gazeX = 0.45
            e.gazeY = 0.8
        case .waiting:
            e.width = 1.08
            e.height = 1.2
            if expanded { e.pointer = 0; e.gazeX = 0.5; e.gazeY = 0.8 }
            if moving {
                let phase = since.truncatingRemainder(dividingBy: 2.6)
                e.hop = phase >= 0 && phase < 0.36 ? CGFloat(sin(phase / 0.36 * .pi)) : 0
            }
        case .done:
            e.smile = moving ? pulse(since, length: smileDuration) : 0
        case .failed:
            // Flat ovals with inner ends raised read as worried; one short shake.
            e.pointer = 0
            e.gazeY = 0.6
            e.width = 1.3
            e.height = 0.42
            e.tilt = -16
            if moving, since >= 0, since < 0.55 { e.gazeX = CGFloat(sin(since * 38) * 0.7 * (1 - since / 0.55)) }
        case .sleeping:
            // Closed lids, curved like a soft smile turned down, rising and
            // falling with slow breaths.
            e.pointer = 0
            e.doze = 1
            e.height = 0.2
            e.gazeY = 0.45 + (moving ? 0.22 * CGFloat(sin(time * 2 * .pi / 4.2)) : 0)
        }
        return e
    }

    static func expression(mood: CompanionMood, previous: CompanionMood, sinceMood: TimeInterval,
                           expanded: Bool, time: TimeInterval, feeding: CGFloat,
                           sinceGlance: TimeInterval, sinceChomp: TimeInterval,
                           sincePoke: TimeInterval = 100, reducedMotion: Bool) -> EyeExpression {
        var e = pose(mood, expanded: expanded, time: time, since: sinceMood, reducedMotion: reducedMotion)
        let from = pose(previous, expanded: expanded, time: time, since: 100, reducedMotion: false)
        if !reducedMotion, sinceMood >= 0, mood == .sleeping, previous != .sleeping, sinceMood < nodOffDuration {
            // Nodding off: heavy lids droop and sink, then settle into the doze.
            let open = openness(noddingOff: sinceMood)
            var drowsy = from
            drowsy.pointer *= open
            drowsy.height *= max(0.15, open)
            drowsy.gazeY += 0.35 * (1 - open)
            e = .mix(drowsy, e, smoothstep(CGFloat((sinceMood - 1.75) / (nodOffDuration - 1.75))))
        } else if !reducedMotion, sinceMood >= 0, sinceMood < blend {
            e = .mix(from, e, smoothstep(CGFloat(sinceMood / blend)))
        }
        if !reducedMotion, previous == .sleeping, mood != .sleeping {
            // Woken: wide eyes and a little start before settling.
            e = .mix(e, startledPose, pulse(sinceMood, length: startleDuration, rampIn: 0.06, rampOut: 0.4))
        }
        if expanded, !reducedMotion {
            var glance = e
            glance.pointer = 0
            glance.gazeX = 0.5
            glance.gazeY = 0.85
            e = .mix(e, glance, pulse(sinceGlance, length: glanceDuration, rampIn: 0.1))
        }
        e = .mix(e, feedingPose, feeding)
        if !reducedMotion, sincePoke >= 0, sincePoke < pokeDuration {
            // Booped: the eyes flinch shut, then pop into a happy ^ ^ that bounces.
            var flinch = e
            flinch.pointer = 0; flinch.gazeX = 0; flinch.gazeY = 0
            flinch.width = 1.3; flinch.height = 0.25; flinch.smile = 0
            e = .mix(e, flinch, pulse(sincePoke, length: 0.2, rampIn: 0.04, rampOut: 0.1))
            e.smile = max(e.smile, pulse(sincePoke - 0.14, length: pokeDuration - 0.14, rampIn: 0.08, rampOut: 0.22))
            e.hop = max(e.hop, CGFloat(sin(.pi * min(1, max(0, (sincePoke - 0.14) / 0.42)))))
        }
        if !reducedMotion, sinceChomp >= 0, sinceChomp < chompDuration {
            // Two chomps, then a satisfied smile.
            e.pointer = 0; e.gazeX = 0; e.gazeY = 0; e.tilt = 0; e.hop = 0
            if sinceChomp < 0.12 || (sinceChomp >= 0.24 && sinceChomp < 0.36) {
                e.width = 1.2; e.height = 0.12; e.smile = 0
            } else if sinceChomp < 0.24 {
                e.width = 1; e.height = 1.1; e.smile = 0
            } else {
                e.width = 1; e.height = 1
                e.smile = pulse(sinceChomp - 0.36, length: chompDuration - 0.36)
            }
        }
        return e
    }

    static func chomping(_ sinceChomp: TimeInterval) -> Bool { sinceChomp >= 0 && sinceChomp < chompDuration }

    /// How long the eyes, and a visible mascot's body, react to the pointer touching them.
    static let pokeDuration: TimeInterval = 0.85

    static let nodOffDuration: TimeInterval = 2.2
    static let startleDuration: TimeInterval = 0.6
    static let startledPose = EyeExpression(pointer: 0, width: 1.12, height: 1.3, hop: 1)
    /// (seconds, openness): droop, flutter back open, droop further, close.
    private static let nodOffKeys: [(TimeInterval, CGFloat)] = [(0, 1), (0.55, 0.42), (0.8, 0.85), (1.45, 0.3), (1.65, 0.5), (2.2, 0)]

    static func openness(noddingOff t: TimeInterval) -> CGFloat {
        guard let next = nodOffKeys.firstIndex(where: { $0.0 > t }) else { return nodOffKeys[nodOffKeys.count - 1].1 }
        guard next > 0 else { return nodOffKeys[0].1 }
        let (t0, v0) = nodOffKeys[next - 1]
        let (t1, v1) = nodOffKeys[next]
        return v0 + (v1 - v0) * smoothstep(CGFloat((t - t0) / (t1 - t0)))
    }

    /// A twinkle beside the eyes, in resting points from the face's centre.
    struct Sparkle: Equatable {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var degrees: Double
    }

    static let sparkleDuration: TimeInterval = 1.1

    /// Three twinkles pop around the eyes, one after another, as a turn finishes.
    static func sparkles(sinceDone t: TimeInterval, reducedMotion: Bool) -> [Sparkle] {
        guard !reducedMotion, t >= 0, t < sparkleDuration else { return [] }
        let seeds: [(x: CGFloat, y: CGFloat, delay: TimeInterval, radius: CGFloat)] =
            [(15, -6, 0.08, 3.4), (-15, -4, 0.24, 2.6), (11, 7, 0.4, 2.2)]
        return seeds.compactMap { seed in
            let life = (t - seed.delay) / 0.62
            guard life >= 0, life < 1 else { return nil }
            return Sparkle(x: seed.x, y: seed.y - 2 * CGFloat(life), radius: seed.radius * CGFloat(sin(.pi * life)),
                           degrees: 60 * life)
        }
    }

    /// 0 outside [0, length); eases in and out at the edges.
    static func pulse(_ t: TimeInterval, length: TimeInterval, rampIn: TimeInterval = 0.12,
                      rampOut: TimeInterval = 0.2) -> CGFloat {
        guard t >= 0, t < length else { return 0 }
        return smoothstep(CGFloat(min(1, t / rampIn, (length - t) / rampOut)))
    }

    static func smoothstep(_ value: CGFloat) -> CGFloat {
        let v = min(1, max(0, value))
        return v * v * (3 - 2 * v)
    }
}

/// The eyes are the whole character: white on the black notch at every size.
/// Fixed 76 × 64 canvas centered at (38, 32). Expansion comes from the host's
/// single frame-morph clock and must not be animated again here.
///
/// With a `mascot` scene the same eyes draw over the whole notch instead and
/// travel onto the mascot's face as the island opens.
struct CompanionCharacter: View {
    @ObservedObject var model: AppModel
    var expansion: CGFloat
    var mascot: MascotScene? = nil
    @State private var mood = CompanionMood.ready
    @State private var previousMood = CompanionMood.ready
    @State private var moodStart: TimeInterval = -100
    @State private var glanceStart: TimeInterval = -100
    @State private var chompStart: TimeInterval = -100
    @State private var pokeStart: TimeInterval = -100
    @State private var performance = MascotPerformance(.calm, start: -100)
    /// The pose fading out: a previous act, or the same act in the other clip set.
    @State private var replaced: MascotPerformance?
    @State private var replacedOnStage = false
    @State private var replacedAt: TimeInterval = -100
    @State private var appearedAt: TimeInterval = -100

    private struct ActivityCount: Equatable { var session: String?; var count: Int }

    var body: some View {
        let presentation = model.notchPresentation
        // A stage presents its announcement just as the widened band does.
        let announced = presentation.announce > 0.5 || presentation.stage > 0.3 ? model.announcement?.kind : nil
        let base = CompanionMood.resolve(overall: model.overallState, current: model.current)
        let resolved = announced.map(CompanionMood.init(announcement:))
            ?? (model.drowsy && base.canDoze ? .sleeping : base)
        let act = MascotAct(mood: resolved, announcement: announced)
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: model.reducedMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let eyes = EyesDrawing(
                expansion: min(1, max(0, expansion)),
                mood: mood, previousMood: previousMood, sinceMood: time - moodStart,
                sinceGlance: time - glanceStart, sinceChomp: time - chompStart, time: time,
                feeding: model.eating ? 1 : 0,
                // The mascot's face leaves a little less room to look around in.
                pointer: CGSize(width: min(3.5, max(-3.5, model.pointerOffset.width)) * (mascot == nil ? 1 : 0.7),
                                height: min(2.5, max(-2.5, model.pointerOffset.height)) * (mascot == nil ? 1 : 0.7)),
                blink: !model.eating && !model.hovering && !model.reducedMotion
                    ? CGFloat(MascotMotion.blinkAmount(at: time)) : 0,
                reducedMotion: model.reducedMotion,
                sincePoke: time - pokeStart
            )
            if let mascot {
                let library = model.mascotLibrary
                let frame = library.frame(performance, appeared: appearedAt, at: time, onStage: mascot.onStage,
                                          reducedMotion: model.reducedMotion)
                let fade = MascotTimeline.fade(replaced: replaced != nil, changed: replacedAt, appeared: appearedAt, at: time,
                                               emergeLength: library.emergeLength(onStage: mascot.onStage),
                                               reducedMotion: model.reducedMotion)
                let ghost = replaced.map { library.frame($0, appeared: appearedAt, at: time, onStage: replacedOnStage,
                                                         reducedMotion: false) }
                MascotDrawing(scene: mascot, eyes: eyes, frame: frame,
                              fading: ghost.map { ($0, fade) }, library: library,
                              wobble: MascotTimeline.wobble(sincePoke: time - pokeStart, reducedMotion: model.reducedMotion))
            } else {
                eyes.animation(model.reducedMotion ? nil : .spring(response: 0.29, dampingFraction: 0.78), value: model.eating)
            }
        }
        .frame(width: mascot?.size.width ?? 76, height: mascot?.size.height ?? 64)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: resolved, initial: true) { old, new in
            guard old != new else { mood = new; previousMood = new; return }
            previousMood = mood
            mood = new
            moodStart = Date().timeIntervalSinceReferenceDate
        }
        .onChange(of: act, initial: true) { _, new in
            guard performance.restarts(for: new) else { return }
            let now = Date().timeIntervalSinceReferenceDate
            replace(at: now)
            performance = MascotPerformance(new, start: now)
            prepare([performance.entry, performance.loop])
        }
        .onChange(of: mascot?.onStage ?? false) { wasOnStage, _ in
            // Handing the stage over to the panel swaps clip sets with a crossfade.
            replace(at: Date().timeIntervalSinceReferenceDate, onStage: wasOnStage)
            prepare([MascotTimeline.emerge, performance.entry, performance.loop])
        }
        .onChange(of: (mascot?.reveal ?? 0) > 0, initial: true) { _, shown in
            guard mascot != nil else { return }
            guard shown else {
                model.mascotLibrary.trim()
                return
            }
            let now = Date().timeIntervalSinceReferenceDate
            appear(at: now)
            // A celebration from minutes ago does not replay on every visit.
            if now - performance.start > 1 { performance.entry = nil }
            prepare([MascotTimeline.emerge, performance.entry, performance.loop])
        }
        .onChange(of: model.mascotCharacter) { _, _ in
            // A newly chosen mascot emerges in its predecessor's place.
            guard (mascot?.reveal ?? 0) > 0 else { return }
            appear(at: Date().timeIntervalSinceReferenceDate)
            prepare([MascotTimeline.emerge, performance.entry, performance.loop])
        }
        .onChange(of: ActivityCount(session: model.currentID, count: model.current?.tools.count ?? 0)) { old, new in
            if old.session == new.session, new.count > old.count { glanceStart = Date().timeIntervalSinceReferenceDate }
        }
        .onChange(of: model.attachmentFeedEvent) { _, _ in
            // A new-session drop changes selection and attachments together.
            // Feed on explicit acceptance, never on browsing stored attachments.
            chompStart = Date().timeIntervalSinceReferenceDate
        }
        .onChange(of: model.pokeEvent) { _, _ in pokeStart = Date().timeIntervalSinceReferenceDate }
        .onAppear { prepare([MascotTimeline.emerge]) }
    }

    private func replace(at time: TimeInterval, onStage: Bool? = nil) {
        replaced = performance
        replacedOnStage = onStage ?? mascot?.onStage ?? false
        replacedAt = time
    }

    private func appear(at time: TimeInterval) {
        appearedAt = time
        replaced = nil
    }

    /// Decodes the clips the current clip set plays under these base names.
    private func prepare(_ names: [String?]) {
        guard let mascot else { return }
        let library = model.mascotLibrary
        library.prepare(names.compactMap { $0.map { library.variant($0, onStage: mascot.onStage) } })
    }
}

/// Internal so deterministic offscreen previews can inspect fixed timestamps.
struct EyesDrawing: View, Animatable {
    /// Eye size in the expanded header relative to the resting band.
    static let expandedScale: CGFloat = 1.7
    var expansion: CGFloat
    var mood: CompanionMood
    var previousMood: CompanionMood
    var sinceMood: TimeInterval
    var sinceGlance: TimeInterval
    var sinceChomp: TimeInterval
    var time: TimeInterval
    var feeding: CGFloat
    var pointer: CGSize
    var blink: CGFloat
    var reducedMotion: Bool
    var sincePoke: TimeInterval = 100

    // Only feeding interpolates here. Gaze arrives already filtered by the
    // host's 60 Hz sampler and expression changes blend on the timeline above.
    var animatableData: CGFloat {
        get { feeding }
        set { feeding = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            let reveal = min(1, max(0, expansion))
            let scale = 1 + (Self.expandedScale - 1) * reveal
            var face = context
            face.translateBy(x: 38, y: 32)
            face.scaleBy(x: scale, y: scale)
            draw(in: face, expanded: reveal > 0.5)
        }
    }

    /// Draws the eyes around the context's origin in resting points, so any
    /// transform places them: the header's larger scale or the mascot's face.
    func draw(in context: GraphicsContext, expanded: Bool) {
        let e = EyeMotion.expression(mood: mood, previous: previousMood, sinceMood: sinceMood,
                                     expanded: expanded, time: time, feeding: feeding,
                                     sinceGlance: sinceGlance, sinceChomp: sinceChomp,
                                     sincePoke: sincePoke, reducedMotion: reducedMotion)
        let closing = e.smile > 0.3 || EyeMotion.chomping(sinceChomp) || mood == .sleeping ? 0 : blink
        let width = 6 * e.width
        var height = max(1.8, 12 * e.height * (1 - 0.85 * closing))
        height += (width - height) * e.smile
        let dx = e.pointer * pointer.width + e.gazeX * 3.5
        let dy = e.pointer * pointer.height + e.gazeY * 2.5 - e.hop * 3
        let color = Color(white: 0.97)
        for side in [-1, 1] as [CGFloat] {
            var eye = context
            eye.translateBy(x: side * 6 + dx, y: dy)
            eye.rotate(by: .degrees(Double(-side * e.tilt)))
            if e.doze > 0 {
                var lid = eye
                lid.opacity *= Double(e.doze)
                let half = width * 0.62
                var path = Path()
                path.move(to: CGPoint(x: -half, y: -half * 0.25))
                path.addQuadCurve(to: CGPoint(x: half, y: -half * 0.25), control: CGPoint(x: 0, y: half * 0.9))
                lid.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width * 0.42, lineCap: .round))
            }
            if e.smile < 1, e.doze < 1 {
                var capsule = eye
                capsule.opacity *= Double((1 - e.smile) * (1 - e.doze))
                capsule.fill(Path(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                  cornerRadius: min(width, height) / 2), with: .color(color))
            }
            if e.smile > 0 {
                var arc = eye
                arc.opacity *= Double(e.smile)
                let half = width * 0.6
                var path = Path()
                path.move(to: CGPoint(x: -half, y: half * 0.5))
                path.addQuadCurve(to: CGPoint(x: half, y: half * 0.5), control: CGPoint(x: 0, y: -half * 1.4))
                arc.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width * 0.62, lineCap: .round))
            }
        }
        for sparkle in EyeMotion.sparkles(sinceDone: mood == .done ? sinceMood : -1, reducedMotion: reducedMotion) {
            var star = context
            star.translateBy(x: sparkle.x, y: sparkle.y)
            star.rotate(by: .degrees(sparkle.degrees))
            let r = sparkle.radius
            let k = r * 0.2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: -r))
            path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: k, y: -k))
            path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: k, y: k))
            path.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -k, y: k))
            path.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -k, y: -k))
            star.fill(path, with: .color(color))
        }
    }
}
