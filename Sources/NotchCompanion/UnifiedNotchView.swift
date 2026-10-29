import AppKit
import SwiftUI

/// One surface, one outline, one presentation. The transcript never scales or
/// runs a second reveal animation; the changing native window clips its layout.
struct UnifiedNotchView: View {
    @ObservedObject var model: AppModel
    @AppStorage(NotchBodyStyle.key) private var bodyStyle = NotchBodyStyle.smoked

    var body: some View {
        let presentation = model.notchPresentation
        let size = presentation.size
        let bodyWidth = model.geometry?.panelWidth ?? 560
        let bodyHeight = model.geometry?.bodyHeight ?? 480
        let interactive = model.expanded && presentation.contentIsInteractive
        let choosingFiles = model.fileDropChoice != nil
        let contentOpacity = Self.contentOpacity(progress: presentation.progress)
        // Content materializes as the island opens: blurred, then sharp.
        let contentBlur = model.reducedMotion ? 0 : Self.materializeBlur(contentOpacity)
        let silhouette = UnevenRoundedRectangle(topLeadingRadius: 0,
                                                bottomLeadingRadius: presentation.cornerRadius,
                                                bottomTrailingRadius: presentation.cornerRadius,
                                                topTrailingRadius: 0)
        ZStack(alignment: .top) {
            NotchBodyBackground(style: bodyStyle, progress: presentation.progress,
                                notchHeight: model.geometry?.bandHeight ?? 32, shape: silhouette)
            VStack(spacing: 0) {
                MascotView(model: model)
                    .frame(width: size.width, height: presentation.bandHeight)
                    .allowsHitTesting(!choosingFiles)
                    .accessibilityHidden(choosingFiles)
                    .overlay {
                        NotchHeaderView(model: model)
                            .panelThemed()
                            .frame(width: bodyWidth, height: presentation.bandHeight)
                            .blur(radius: contentBlur)
                            .opacity(contentOpacity * (choosingFiles ? 0.45 : 1))
                            .allowsHitTesting(interactive && !choosingFiles)
                            .accessibilityHidden(!interactive || choosingFiles)
                    }
                CompactPanelView(model: model)
                    .panelThemed()
                    .frame(width: bodyWidth, height: bodyHeight)
                    .blur(radius: choosingFiles ? 3 : contentBlur)
                    .opacity(contentOpacity)
                    .allowsHitTesting(interactive && !choosingFiles)
                    .accessibilityHidden(!interactive || choosingFiles)
            }
            .fixedSize(horizontal: false, vertical: true)
            if presentation.peek > 0 {
                // The glance shares the one silhouette and clock; it only
                // fades in once the island has room for its natural-size text.
                NotchGlanceView(model: model)
                    .frame(width: model.geometry?.glanceFrame.width ?? 420,
                           height: max(0, size.height - presentation.bandHeight), alignment: .top)
                    .padding(.top, presentation.bandHeight)
                    .allowsHitTesting(model.glancing && presentation.glanceIsInteractive && !choosingFiles)
                    .accessibilityHidden(!model.glancing)
            }
            if presentation.stage > 0, let geometry = model.geometry {
                // The mascot stage shares the one silhouette and clock, like the glance.
                NotchStageView(model: model)
                    .frame(width: geometry.stageFrame.width,
                           height: max(0, geometry.stageFrame.height - presentation.bandHeight), alignment: .top)
                    .padding(.top, presentation.bandHeight)
                    .allowsHitTesting(model.staging && presentation.stage >= 0.95 && !choosingFiles)
                    .accessibilityHidden(!model.staging)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay {
            // A faint rim defines the open island against dark wallpapers;
            // it begins below the notch height so the band still merges.
            SilhouetteEdge(cornerRadius: presentation.cornerRadius)
                .stroke(LinearGradient(stops: Self.edgeStops(band: model.geometry?.bandHeight ?? 32, height: size.height),
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                .opacity(Double(max(presentation.progress, presentation.peek)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if model.overallState == .working, model.statusEffects, !model.reducedMotion,
               max(presentation.progress, presentation.peek) > 0 {
                WorkingRimLight(cornerRadius: presentation.cornerRadius,
                                fade: Self.edgeFade(band: model.geometry?.bandHeight ?? 32, height: size.height))
                    .opacity(Double(max(presentation.progress, presentation.peek)))
            }
        }
        .clipShape(silhouette)
        .overlay(alignment: .top) {
            if model.mascotEnabled, let geometry = model.geometry {
                // The eyes, and the mascot around them once the island opens. Its own
                // clip lets stage clips overhang the island's bottom edge a little.
                CompanionCharacter(model: model, expansion: 0,
                                   mascot: MascotLayout.scene(presentation, geometry: geometry, ground: model.mascotLibrary.ground,
                                                              staging: model.staging, expanded: model.expanded,
                                                              spotlight: model.announcement?.kind.color))
                    .opacity(choosingFiles ? 0.45 : 1)
                    .clipShape(silhouette.path(in: CGRect(x: 0, y: 0, width: size.width,
                                                          height: size.height + MascotLayout.overhangClip(presentation))))
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if let toast = model.panelToast, model.expanded, !choosingFiles {
                    PanelToastView(announcement: toast) { model.openPanelToast() }
                        .padding(.top, presentation.bandHeight + 10)
                        .padding(.horizontal, 20)
                        .opacity(contentOpacity)
                        .allowsHitTesting(interactive)
                        .transition(model.reducedMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .zIndex(2)
                }
                if choosingFiles {
                    // Instrument: deep enough that the signal-orange Send key does not glow around the tray.
                    Color.black.opacity(PanelTheme.pick(0.42, 0.42, 0.62))
                        .frame(width: bodyWidth, height: bodyHeight)
                        .padding(.top, presentation.bandHeight)
                        .opacity(contentOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    FileDropChoiceView(model: model)
                        .panelThemed()
                        .frame(width: bodyWidth, height: model.geometry?.expandedFrame.height ?? 544)
                        .opacity(contentOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(!interactive)
                }
            }
            .animation(model.reducedMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: model.panelToast?.id)
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(silhouette)
        }
        .contentShape(silhouette)
        // The flares sit just outside the body, in the window's side margins,
        // and stay pure black like the band they extend.
        .background(NotchFlares(radius: presentation.flare).fill(.black).allowsHitTesting(false))
        // The resting contour leaning toward a nearby pointer; any tier opening absorbs it.
        .background(NotchPullShape(pull: model.notchPull,
                                   depth: model.notchPull.depth
                                    * (1 - min(1, max(presentation.progress, presentation.peek, presentation.stage, presentation.hello))),
                                   cornerRadius: presentation.cornerRadius)
            .fill(.black).allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .environment(\.notchBodyStyle, bodyStyle)
        // AppKit rounds the window out to whole points mid-animation; pinning to
        // the top keeps the extra row at the bottom rather than a gap at the screen edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func glanceOpacity(peek: CGFloat) -> Double {
        let value = min(1, max(0, (peek - 0.55) / 0.4))
        return Double(value * value * (3 - 2 * value))
    }

    /// Blur that clears as content fades in, so it resolves rather than appears.
    static func materializeBlur(_ opacity: Double) -> CGFloat {
        opacity >= 1 ? 0 : CGFloat(6 * (1 - opacity))
    }

    static func edgeStops(band: CGFloat, height: CGFloat) -> [Gradient.Stop] {
        let fade = edgeFade(band: band, height: height)
        return [.init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0), location: fade.lowerBound),
                .init(color: .white.opacity(0.07), location: fade.upperBound),
                .init(color: .white.opacity(0.11), location: 1)]
    }

    /// Where the rim fades in, in unit height: from the band to 70 points below it.
    static func edgeFade(band: CGFloat, height: CGFloat) -> ClosedRange<CGFloat> {
        let start = min(1, max(0, band / max(1, height)))
        return start...min(1, max(start, (band + 70) / max(1, height)))
    }

    static func contentOpacity(progress: CGFloat) -> Double {
        // Let the single silhouette gain room before text becomes legible, so
        // natural-size lines are never visibly squeezed into the small notch.
        let value = min(1, max(0, (progress - 0.82) / 0.16))
        return Double(value * value * (3 - 2 * value))
    }
}

/// While agents work, a faint light travels the open island's rim: down one
/// side, along the bottom and up the other, emerging below the notch band.
struct WorkingRimLight: View {
    static let period: TimeInterval = 4
    var cornerRadius: CGFloat
    /// The rim's own fade, so the light also leaves the band merged.
    var fade: ClosedRange<CGFloat>

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Self.light(head: Self.head(at: context.date.timeIntervalSinceReferenceDate), cornerRadius: cornerRadius, fade: fade)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Internal so offscreen fixtures can render fixed lap positions.
    /// The silhouette clips the outer half of each stroke, so widths are doubled.
    static func light(head: CGFloat, cornerRadius: CGFloat, fade: ClosedRange<CGFloat>) -> some View {
        Canvas { context, size in
            let edge = SilhouetteEdge(cornerRadius: cornerRadius).path(in: CGRect(origin: .zero, size: size))
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 6))
                glow.stroke(edge.trimmedPath(from: max(0, head - 0.1), to: min(1, head)),
                            with: .color(IslandStyle.indicatorColor(.running).opacity(0.6)), lineWidth: 12)
            }
            // A comet: the tail's segments brighten toward the head.
            for (from, to, opacity) in [(0.14, 0.09, 0.2), (0.09, 0.045, 0.45), (0.045, 0.0, 0.85)] as [(CGFloat, CGFloat, Double)] {
                context.stroke(edge.trimmedPath(from: max(0, head - from), to: min(1, max(0, head - to))),
                               with: .color(.white.opacity(opacity)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: fade.lowerBound), .init(color: .white, location: fade.upperBound)],
                             startPoint: .top, endPoint: .bottom))
    }

    /// Lap position along the rim; it overshoots 1 so the light fully leaves
    /// the far side before the next lap begins.
    static func head(at time: TimeInterval) -> CGFloat {
        CGFloat(time.truncatingRemainder(dividingBy: period) / period) * 1.12
    }
}

/// The silhouette's sides and bottom, open along the screen's top edge.
struct SilhouetteEdge: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(cornerRadius, rect.width / 2, rect.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + radius, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Two concave fillets joining the body's sides to the screen's top edge,
/// drawn outside `rect` so the body itself keeps its exact geometry.
struct NotchFlares: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard radius > 0 else { return path }
        for (edge, outward) in [(rect.minX, -radius), (rect.maxX, radius)] {
            path.move(to: CGPoint(x: edge, y: rect.minY))
            path.addLine(to: CGPoint(x: edge + outward, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: edge, y: rect.minY + radius), control: CGPoint(x: edge, y: rect.minY))
            path.closeSubpath()
        }
        return path
    }
}

/// The resting outline with its nearest stretch drawn toward the pointer. It is
/// filled behind the body, so it only adds black outside it; the top stays put.
struct NotchPullShape: Shape {
    var pull: NotchPull
    var depth: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let anchor = NotchPull.nearestEdge(to: pull.pointer, size: rect.size)
        let towardX = pull.pointer.x - anchor.x, towardY = pull.pointer.y - anchor.y
        let length = hypot(towardX, towardY)
        guard depth > 0.05, length > 0.001, rect.height > 0 else { return path }
        let points = Self.outline(rect.size, radius: max(0, min(cornerRadius, rect.width / 2, rect.height / 2)))
        for (index, point) in points.enumerated() {
            let distance = (point.x - anchor.x) * (point.x - anchor.x) + (point.y - anchor.y) * (point.y - anchor.y)
            let weight = exp(-distance / (2 * NotchPull.spread * NotchPull.spread)) * min(1, 2 * point.y / rect.height)
            let moved = CGPoint(x: rect.minX + point.x + towardX / length * depth * weight,
                                y: rect.minY + point.y + towardY / length * depth * weight)
            if index == 0 { path.move(to: moved) } else { path.addLine(to: moved) }
        }
        path.closeSubpath()
        return path
    }

    /// Down the left side, round the bottom corners, and up the right, every 2 points.
    static func outline(_ size: CGSize, radius: CGFloat) -> [CGPoint] {
        let width = size.width, height = size.height, step: CGFloat = 2
        let arc = stride(from: 0, through: CGFloat.pi / 2, by: step / max(radius, 1))
        return stride(from: 0, to: height - radius, by: step).map { CGPoint(x: 0, y: $0) }
            + arc.map { CGPoint(x: radius - radius * cos($0), y: height - radius + radius * sin($0)) }
            + stride(from: radius, to: width - radius, by: step).map { CGPoint(x: $0, y: height) }
            + arc.map { CGPoint(x: width - radius + radius * sin($0), y: height - radius + radius * cos($0)) }
            + stride(from: height - radius, through: 0, by: -step).map { CGPoint(x: width, y: $0) }
    }
}

enum NotchBodyStyle: String, CaseIterable, Identifiable {
    case black, glass, smoked
    static let key = "notch.bodyStyle"
    var id: Self { self }
    var label: String {
        switch self {
        case .black: return "Black"
        case .glass: return "Glass"
        case .smoked: return "Smoked"
        }
    }
}

extension EnvironmentValues {
    /// Shared by the notch and full-session window; nil for standalone controls.
    @Entry var notchBodyStyle: NotchBodyStyle? = nil
}

/// Resting is always pure black so the band merges with the hardware notch.
/// Glass styles hand over below the notch height as the surface expands.
struct NotchBodyBackground: View {
    /// Smoked body darkness over the native window backdrop; tune here.
    static let smoke: CGFloat = 0.55
    var style: NotchBodyStyle
    var progress: CGFloat
    var notchHeight: CGFloat
    var shape: UnevenRoundedRectangle

    var body: some View {
        if style == .black {
            shape.fill(.black)
        } else {
            GeometryReader { proxy in
                let height = max(1, proxy.size.height)
                let band = min(1, notchHeight / height)
                let fadeEnd = min(1, max(band, (notchHeight + 80) / height))
                // Keep smoke independent of window focus, including hover previews.
                let tail = 1 - progress * (1 - (style == .smoked ? Self.smoke : 0))
                ZStack {
                    NotchWindowBackdrop()
                        .opacity(Double(progress))
                    shape.fill(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: band),
                        .init(color: .black.opacity(Double(tail)), location: fadeEnd)
                    ], startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }
}

/// Sample the desktop and other apps behind the notch or full-session window. A SwiftUI
/// glassEffect alone does not provide a reliable behind-window body backdrop.
/// Stay active during passive previews, when the notch deliberately isn't key.
struct NotchWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Floating controls: glass over the black body, a plain fill on a glass body
/// (glass on glass muddies both), and the original fill outside a themed body.
struct NotchControlBackground<S: Shape>: ViewModifier {
    @Environment(\.notchBodyStyle) private var style
    var shape: S
    var fallback: Color

    func body(content: Content) -> some View {
        switch style {
        case .black: content.glassEffect(.regular, in: shape)
        case .glass, .smoked: content.background(Color.white.opacity(0.08), in: shape)
        case nil: content.background(fallback, in: shape)
        }
    }
}

extension View {
    func notchControlBackground<S: Shape>(_ shape: S, fallback: Color) -> some View {
        modifier(NotchControlBackground(shape: shape, fallback: fallback))
    }
}
