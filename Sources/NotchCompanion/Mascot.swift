import AppKit
import ImageIO
import SwiftUI

/// How the notch presents a finished, failed or waiting session.
enum NotchUpdateStyle: String, CaseIterable, Identifiable {
    /// The resting band widens beside the camera to name the session.
    case compact
    /// The notch opens a larger popup with details and answers.
    case popup
    static let key = "notch.updateStyle"
    var id: Self { self }
    var label: String { self == .compact ? "Compact" : "Popup" }
}

enum CompanionAppearance: String, CaseIterable, Identifiable {
    case eyes, mascot
    static let key = "notch.companionAppearance"
    var id: Self { self }
    var label: String { self == .eyes ? "Eyes" : "Mascot" }
}

/// Which Blender-rendered mascot the companion becomes.
enum MascotCharacter: String, CaseIterable, Identifiable {
    case mote, fold, soot
    static let key = "notch.mascotCharacter"
    var id: Self { self }
    var label: String { rawValue.capitalized }
}

/// One mascot, rendered in Blender by `scripts/mascot/<id>.py`: one sprite
/// sheet per clip, plus where the face sits in every frame so the live eyes
/// can be drawn on it. Sheets decode off the main thread on first use and only
/// a few stay decoded.
final class MascotLibrary: ObservableObject {
    struct Anchor: Equatable {
        /// The face's centre, and one eye unit along its x and y-down axes,
        /// as fractions of the frame's side.
        var center: CGPoint
        var x: CGVector
        var y: CGVector
        /// 1 while the face looks at the camera, 0 or less when turned away.
        var facing: CGFloat

        static let neutral = Anchor(center: CGPoint(x: 0.5, y: 0.56), x: CGVector(dx: 0.0089, dy: 0),
                                    y: CGVector(dx: 0, dy: 0.0089), facing: 1)
    }

    struct Clip {
        let frames: Int
        let loops: Bool
        let columns: Int
        let anchors: [Anchor]
        /// Where the island's bottom edge crosses the frame (fraction from the
        /// top), for a clip whose body hides behind it.
        var ledge: CGFloat? = nil
    }

    /// Clips with this prefix replace their base clip on the popup stage.
    static let stagePrefix = "stage-"
    /// One library per character; only the selected one keeps decoded sheets.
    @MainActor private static var cache: [MascotCharacter: MascotLibrary] = [:]
    @MainActor private static var selected: MascotCharacter?

    @MainActor static func library(_ character: MascotCharacter) -> MascotLibrary {
        if selected != character {
            selected = character
            for (other, library) in cache where other != character { library.trim(keeping: []) }
        }
        if let library = cache[character] { return library }
        let library = MascotLibrary(character.rawValue)
        cache[character] = library
        return library
    }

    /// Each decoded sheet holds a whole clip (about 8–21 MB); keep a few.
    var maxDecodedSheets = 3

    let fps: Double
    let frameSize: Int
    /// The feet's line as a fraction of the frame's height, from the top.
    let ground: CGFloat
    let clips: [String: Clip]
    let frameCounts: [String: Int]
    var isAvailable: Bool { clips["idle"] != nil && clips[MascotTimeline.emerge] != nil }
    private let sheetURL: (String) -> URL?
    @Published private var sheets: [String: [CGImage]] = [:]
    private var loading: Set<String> = []
    private var recent: [String] = []

    private struct Manifest: Decodable {
        struct Entry: Decodable { let frames: Int; let loops: Bool; let columns: Int; let anchors: [[Double]]; let ledge: Double? }
        let size: Int
        let fps: Double
        let ground: Double
        let clips: [String: Entry]
    }

    /// Loads `<id>.json` and its `<id>-<clip>.webp` sheets from the bundle.
    init(_ id: String, bundle: Bundle = CompanionResources.bundle) {
        func url(_ name: String, _ ext: String) -> URL? {
            bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Mascot")
        }
        sheetURL = { url("\(id)-\($0)", "webp") }
        guard let data = url(id, "json").flatMap({ try? Data(contentsOf: $0) }),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            fps = 24; frameSize = 0; ground = 0.9; clips = [:]; frameCounts = [:]
            return
        }
        fps = manifest.fps
        frameSize = manifest.size
        ground = CGFloat(manifest.ground)
        clips = manifest.clips.mapValues { entry in
            Clip(frames: entry.frames, loops: entry.loops, columns: max(1, entry.columns), anchors: entry.anchors.compactMap { row in
                guard row.count >= 7 else { return nil }
                return Anchor(center: CGPoint(x: row[0], y: row[1]), x: CGVector(dx: row[2], dy: row[3]),
                              y: CGVector(dx: row[4], dy: row[5]), facing: CGFloat(row[6]))
            }, ledge: entry.ledge.map { CGFloat($0) })
        }
        frameCounts = clips.mapValues(\.frames)
    }

    /// The clip a base name plays: its `stage-` variant on the stage when rendered.
    func variant(_ name: String, onStage: Bool) -> String {
        onStage && clips[Self.stagePrefix + name] != nil ? Self.stagePrefix + name : name
    }

    /// Frame counts under base names, for the clip set in use.
    func frameCounts(onStage: Bool) -> [String: Int] {
        guard onStage else { return frameCounts }
        return Dictionary(uniqueKeysWithValues: frameCounts.keys.filter { !$0.hasPrefix(Self.stagePrefix) }.map {
            ($0, frameCounts[variant($0, onStage: true)] ?? 0)
        })
    }

    /// The performance's frame from the stage's clips or the header's.
    func frame(_ performance: MascotPerformance, appeared: TimeInterval, at time: TimeInterval, onStage: Bool,
               reducedMotion: Bool) -> MascotTimeline.Frame {
        var frame = MascotTimeline.frame(performance, appeared: appeared, at: time, frames: frameCounts(onStage: onStage),
                                         fps: fps, reducedMotion: reducedMotion)
        frame.clip = variant(frame.clip, onStage: onStage)
        return frame
    }

    func emergeLength(onStage: Bool) -> TimeInterval {
        Double(frameCounts[variant(MascotTimeline.emerge, onStage: onStage)] ?? 0) / fps
    }

    /// The line placed on the island's bottom edge, as a fraction of the frame
    /// from the top: a clip's ledge, else the stage's standing line.
    func edge(_ clip: String) -> CGFloat {
        clips[clip]?.ledge ?? ground + MascotLayout.stageStanding / MascotLayout.stageSide
    }

    /// Where the eyes sit in a frame. During an emerge (base or stage) they keep
    /// the size and turn of its last frame, so the body grows around eyes of
    /// settled size; only the centre follows each frame.
    func anchor(_ frame: MascotTimeline.Frame) -> Anchor? {
        guard let anchors = clips[frame.clip]?.anchors, !anchors.isEmpty, let settled = anchors.last else { return nil }
        var anchor = anchors[min(max(0, frame.index), anchors.count - 1)]
        if frame.clip == MascotTimeline.emerge || frame.clip == Self.stagePrefix + MascotTimeline.emerge {
            anchor.x = settled.x
            anchor.y = settled.y
        }
        return anchor
    }

    /// The frame's image, or nil while its sheet is still decoding.
    func image(_ frame: MascotTimeline.Frame) -> CGImage? {
        guard let images = sheets[frame.clip], !images.isEmpty else {
            prepare([frame.clip])
            return nil
        }
        if recent.last != frame.clip { recent.removeAll { $0 == frame.clip }; recent.append(frame.clip) }
        return images[min(max(0, frame.index), images.count - 1)]
    }

    /// Decodes off the main thread; offscreen fixtures decode synchronously.
    func prepare(_ names: [String], synchronously: Bool = false) {
        for name in names where sheets[name] == nil && !loading.contains(name) {
            guard let clip = clips[name], let url = sheetURL(name) else { continue }
            let size = frameSize
            if synchronously {
                store(name, Self.decode(url, frames: clip.frames, columns: clip.columns, size: size))
                continue
            }
            loading.insert(name)
            DispatchQueue.global(qos: .userInitiated).async {
                let images = Self.decode(url, frames: clip.frames, columns: clip.columns, size: size)
                DispatchQueue.main.async { self.store(name, images) }
            }
        }
    }

    private func store(_ name: String, _ images: [CGImage]) {
        loading.remove(name)
        sheets[name] = images
        recent.removeAll { $0 == name }
        recent.append(name)
        while recent.count > maxDecodedSheets { sheets[recent.removeFirst()] = nil }
    }

    /// Hidden again: keep only what the next appearance starts with.
    func trim(keeping names: Set<String> = [MascotTimeline.emerge, stagePrefix + MascotTimeline.emerge]) {
        for name in sheets.keys where !names.contains(name) { sheets[name] = nil }
        recent.removeAll { !names.contains($0) }
    }

    private static func decode(_ url: URL, frames: Int, columns: Int, size: Int) -> [CGImage] {
        guard size > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return [] }
        return (0..<frames).compactMap { index in
            sheet.cropping(to: CGRect(x: index % columns * size, y: index / columns * size, width: size, height: size))
        }
    }
}

/// What the mascot acts out, from the same state the eyes express.
enum MascotAct: Equatable {
    case calm, busy, asking, celebrating, failing, greeting

    init(mood: CompanionMood, announcement: NotchAnnouncement.Kind?) {
        if announcement == .hello { self = .greeting; return }
        switch mood {
        case .ready, .sleeping: self = .calm
        case .thinking, .working, .answering: self = .busy
        case .waiting: self = .asking
        case .done: self = .celebrating
        case .failed: self = .failing
        }
    }

    /// A one-off entrance: the celebration, the raised hand, the slump.
    var entry: String? {
        switch self {
        case .asking, .greeting: return "wave"
        case .celebrating: return "done"
        case .failing: return "fail"
        case .calm, .busy: return nil
        }
    }

    var loop: String {
        switch self {
        case .busy: return "work"
        case .asking: return "wait"
        case .failing: return "sad"
        case .calm, .celebrating, .greeting: return "idle"
        }
    }
}

/// One act on the mascot's clock: its entrance plays once, then its loop.
struct MascotPerformance: Equatable {
    var entry: String?
    var loop: String
    var start: TimeInterval

    init(_ act: MascotAct, start: TimeInterval) {
        entry = act.entry
        loop = act.loop
        self.start = start
    }

    /// A new act restarts the mascot unless it only settles into the loop already playing.
    func restarts(for act: MascotAct) -> Bool { act.entry != nil || act.loop != loop }
}

/// Pure frame selection, so the clock is testable without assets.
enum MascotTimeline {
    static let emerge = "emerge"
    /// A changed act fades the previous pose out over this long.
    static let crossfade: TimeInterval = 0.22

    struct Frame: Equatable {
        var clip: String
        var index: Int
    }

    /// The mascot emerges first after appearing; an act's entrance waits for that,
    /// then its loop repeats. Reduced motion holds the loop's first pose.
    static func frame(_ performance: MascotPerformance, appeared: TimeInterval, at time: TimeInterval,
                      frames: [String: Int], fps: Double, reducedMotion: Bool) -> Frame {
        guard !reducedMotion else { return Frame(clip: performance.loop, index: 0) }
        let emergeLength = Double(frames[emerge] ?? 0) / fps
        let sinceAppear = time - appeared
        if sinceAppear >= 0, sinceAppear < emergeLength { return Frame(clip: emerge, index: Int(sinceAppear * fps)) }
        var elapsed = max(0, time - max(performance.start, appeared + emergeLength))
        if let entry = performance.entry, let count = frames[entry] {
            let index = Int(elapsed * fps)
            if index < count { return Frame(clip: entry, index: index) }
            elapsed -= Double(count) / fps
        }
        let count = max(1, frames[performance.loop] ?? 1)
        return Frame(clip: performance.loop, index: Int(elapsed * fps) % count)
    }

    /// How much of a replaced pose (a previous act, or the stage's clips after
    /// handing over to the panel) still shows: only for changes made after the
    /// mascot has fully emerged.
    static func fade(replaced: Bool, changed: TimeInterval, appeared: TimeInterval,
                     at time: TimeInterval, emergeLength: TimeInterval, reducedMotion: Bool) -> CGFloat {
        guard replaced, !reducedMotion, changed > appeared + emergeLength else { return 0 }
        return 1 - EyeMotion.smoothstep(CGFloat((time - changed) / crossfade))
    }

    /// A booped body's jelly wobble, as its (x, y) scale about the line it rests
    /// on: squashed first, then ringing out within `EyeMotion.pokeDuration`.
    static func wobble(sincePoke t: TimeInterval, reducedMotion: Bool) -> CGSize {
        guard !reducedMotion, t >= 0, t < EyeMotion.pokeDuration else { return CGSize(width: 1, height: 1) }
        let squash = CGFloat(0.13 * exp(-5.5 * t) * sin(2 * .pi * 3.2 * t))
        return CGSize(width: 1 + 0.6 * squash, height: 1 - squash)
    }
}

/// Where the pointer boops the companion, in the notch's local coordinates
/// (top-left origin).
struct PokeZone: Equatable {
    var center: CGPoint
    var radii: CGSize

    func contains(_ point: CGPoint) -> Bool {
        let dx = (point.x - center.x) / radii.width, dy = (point.y - center.y) / radii.height
        return dx * dx + dy * dy <= 1
    }

    /// The eyes alone; their pair spans 18 × 12 points at scale 1.
    static func eyes(at center: CGPoint, scale: CGFloat) -> Self {
        Self(center: center, radii: CGSize(width: 14 * scale, height: 10 * scale))
    }

    /// A mascot's body in its figure frame, from just below the frame's top to its feet.
    /// shortcut: an ellipse over the body's usual bulk, not the sprite's alpha;
    /// sample the current frame if pokes must follow raised arms or a tail.
    static func body(in figure: CGRect, ground: CGFloat) -> Self {
        let top = figure.minY + 0.2 * figure.height, bottom = figure.minY + ground * figure.height
        return Self(center: CGPoint(x: figure.midX, y: (top + bottom) / 2),
                    radii: CGSize(width: 0.3 * figure.width, height: (bottom - top) / 2))
    }
}

/// Where the mascot stands, in the notch's local coordinates (top-left origin): the
/// header's left column when the panel opens, the stage's left when a moment
/// is presented. Both ride the island's left edge and stay fixed to the top.
enum MascotLayout {
    static let headerSide: CGFloat = 76
    static let headerCenterX: CGFloat = 36
    static let stageSide: CGFloat = 150
    /// Clips without a ledge stand this far above the stage's bottom edge.
    static let stageStanding: CGFloat = 10
    /// How far a stage clip may reach below the island's bottom edge.
    static let overhang: CGFloat = 16
    /// The stage's text column begins here, beside the mascot.
    static let stageColumn: CGFloat = 150

    static func headerFigure(_ geometry: NotchGeometry, ground: CGFloat) -> CGRect {
        let feet = geometry.expandedBandHeight - 2
        return CGRect(x: headerCenterX - headerSide / 2, y: feet - ground * headerSide, width: headerSide, height: headerSide)
    }

    /// A frame whose edge line (see `MascotLibrary.edge`) lies on the stage's bottom edge.
    static func stageFigure(_ geometry: NotchGeometry, edge: CGFloat) -> CGRect {
        CGRect(x: 4, y: geometry.stageFrame.height - edge * stageSide, width: stageSide, height: stageSide)
    }

    static func stageFigure(_ geometry: NotchGeometry, ground: CGFloat) -> CGRect {
        stageFigure(geometry, edge: ground + stageStanding / stageSide)
    }

    /// 0 on the stage, 1 in the header.
    static func towardHeader(_ presentation: NotchPresentation, staging: Bool) -> CGFloat {
        let total = presentation.progress + presentation.stage
        return total > 0.001 ? presentation.progress / total : (staging ? 0 : 1)
    }

    /// While a stage hands over to the panel, the mascot glides between the two spots.
    static func figure(_ presentation: NotchPresentation, geometry: NotchGeometry, ground: CGFloat, staging: Bool) -> CGRect {
        let toHeader = towardHeader(presentation, staging: staging)
        let from = stageFigure(geometry, ground: ground)
        let to = headerFigure(geometry, ground: ground)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * toHeader }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }

    static func scene(_ presentation: NotchPresentation, geometry: NotchGeometry, ground: CGFloat,
                      staging: Bool, expanded: Bool, spotlight: Color? = nil) -> MascotScene {
        let toHeader = towardHeader(presentation, staging: staging)
        // The canvas reaches below the island so stage clips can overhang it;
        // the notch clips it to the silhouette plus `overhangClip`.
        return MascotScene(size: CGSize(width: presentation.size.width, height: presentation.size.height + overhang),
                           restCenter: presentation.restingEyeCenter(geometry),
                           restScale: 1 + 0.15 * presentation.peek + 0.3 * presentation.hello,
                           figure: figure(presentation, geometry: geometry, ground: ground, staging: staging),
                           reveal: min(1, max(0, max(presentation.progress, presentation.stage))),
                           closing: !(expanded || staging),
                           spotlight: spotlight, spotlightAmount: min(1, max(0, presentation.stage)), ground: ground,
                           stageWeight: 1 - toHeader, onStage: !expanded && toHeader < 0.5)
    }

    /// How far below the current silhouette the mascot may draw: the full
    /// overhang on the stage, nothing in the panel or at rest.
    static func overhangClip(_ presentation: NotchPresentation) -> CGFloat {
        overhang * min(1, max(0, presentation.stage))
    }
}

/// Everything the mascot's drawing needs about its surroundings this frame.
struct MascotScene: Equatable {
    var size: CGSize
    /// The resting eyes' centre and scale, where the eyes start and return.
    var restCenter: CGPoint
    var restScale: CGFloat
    var figure: CGRect
    /// 0 is the eyes alone in the band, 1 is the mascot fully out.
    var reveal: CGFloat
    /// Shrinking back into the band rather than emerging.
    var closing: Bool
    /// On the stage, a soft pool of the moment's colour under the mascot's feet.
    var spotlight: Color? = nil
    var spotlightAmount: CGFloat = 0
    var ground: CGFloat = 0.9
    /// How much of the stage's placement applies (1 on the stage, 0 in the header).
    var stageWeight: CGFloat = 0
    /// Plays the `stage-` clips.
    var onStage = false

    /// Where a clip's frame goes: `figure` is placed for the standing line, so
    /// on the stage a clip with another edge line shifts until that line lies
    /// on the island's bottom edge.
    func figure(edge: CGFloat) -> CGRect {
        let standing = ground + MascotLayout.stageStanding / MascotLayout.stageSide
        return figure.offsetBy(dx: 0, dy: stageWeight * (standing - edge) * figure.height)
    }

    /// The live eyes stay above a ledge clip's edge line, in canvas points.
    func eyeLimit(ledge: CGFloat?) -> CGFloat? {
        ledge.map { figure(edge: $0).minY + $0 * figure.height }
    }
}

/// Draws the mascot's rendered body and the live eyes on its face. At reveal 0
/// the eyes sit exactly where the resting eyes are, so the hand-off is seamless.
struct MascotDrawing: View {
    var scene: MascotScene
    var eyes: EyesDrawing
    var frame: MascotTimeline.Frame
    var fading: (frame: MascotTimeline.Frame, amount: CGFloat)?
    @ObservedObject var library: MascotLibrary
    var wobble = CGSize(width: 1, height: 1)

    var body: some View {
        Canvas { context, _ in
            let figure = scene.figure(edge: library.edge(frame.clip))
            let side = figure.width
            let anchor = library.anchor(frame) ?? .neutral
            let visor = CGPoint(x: figure.minX + anchor.center.x * side, y: figure.minY + anchor.center.y * side)
            // The pool lights the floor under a standing mascot; one hanging on a higher sill has none.
            let standing = abs(library.edge(frame.clip) - (library.ground + MascotLayout.stageStanding / MascotLayout.stageSide)) < 0.005
            if let spotlight = scene.spotlight, scene.spotlightAmount > 0, standing {
                var pool = context
                pool.translateBy(x: scene.figure.midX, y: scene.figure.minY + scene.ground * side)
                pool.scaleBy(x: 1, y: 0.16)
                let radius = side * 0.34
                pool.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)),
                          with: .radialGradient(Gradient(colors: [spotlight.opacity(0.42 * Double(scene.spotlightAmount)),
                                                                  spotlight.opacity(0)]),
                                                center: .zero, startRadius: 0, endRadius: radius))
            }
            let travel = EyeMotion.smoothstep(scene.reveal / 0.85)
            var context = context
            if travel > 0, wobble != CGSize(width: 1, height: 1) {
                // A boop jiggles the body and the eyes on its face about the line
                // it rests on: its feet, or the sill it hangs on.
                let base = CGPoint(x: figure.midX, y: figure.minY + (library.clips[frame.clip]?.ledge ?? library.ground) * side)
                context.translateBy(x: base.x, y: base.y)
                context.scaleBy(x: 1 + (wobble.width - 1) * travel, y: 1 + (wobble.height - 1) * travel)
                context.translateBy(x: -base.x, y: -base.y)
            }
            if scene.reveal > 0 {
                var body = context
                if scene.closing {
                    // Folding back into the band: shrink toward the eyes.
                    let k = EyeMotion.smoothstep(scene.reveal)
                    body.opacity = Double(k)
                    body.translateBy(x: visor.x, y: visor.y)
                    body.scaleBy(x: k, y: k)
                    body.translateBy(x: -visor.x, y: -visor.y)
                }
                if let fading, fading.amount > 0, let image = library.image(fading.frame) {
                    var ghost = body
                    ghost.opacity *= Double(fading.amount)
                    ghost.draw(Image(decorative: image, scale: 1).interpolation(.high), in: scene.figure(edge: library.edge(fading.frame.clip)))
                }
                if let image = library.image(frame) {
                    body.draw(Image(decorative: image, scale: 1).interpolation(.high), in: figure)
                }
            }
            let rest = CGAffineTransform(a: scene.restScale, b: 0, c: 0, d: scene.restScale,
                                         tx: scene.restCenter.x, ty: scene.restCenter.y)
            let target = CGAffineTransform(a: anchor.x.dx * side, b: anchor.x.dy * side,
                                           c: anchor.y.dx * side, d: anchor.y.dy * side, tx: visor.x, ty: visor.y)
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * travel }
            var face = context
            if travel > 0, let limit = scene.eyeLimit(ledge: library.clips[frame.clip]?.ledge) {
                // Behind the ledge, the eyes hide with the body.
                face.clip(to: Path(CGRect(x: -1000, y: -1000, width: scene.size.width + 2000, height: limit + 1000)))
            }
            face.concatenate(CGAffineTransform(a: mix(rest.a, target.a), b: mix(rest.b, target.b), c: mix(rest.c, target.c),
                                               d: mix(rest.d, target.d), tx: mix(rest.tx, target.tx), ty: mix(rest.ty, target.ty)))
            // Turned away, the face hides the eyes.
            let facing = EyeMotion.smoothstep((anchor.facing - 0.2) / 0.35)
            face.opacity = Double(1 - travel + travel * facing)
            if travel > 0 {
                // On the face the eyes glow softly, like a screen.
                face.addFilter(.shadow(color: .white.opacity(0.55 * Double(travel)), radius: 1.6))
            }
            eyes.draw(in: face, expanded: scene.reveal > 0.5)
        }
    }
}
