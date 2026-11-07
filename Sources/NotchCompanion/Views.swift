import SwiftUI
import AppKit

struct MascotView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { proxy in
            let geometry = model.geometry
            let presentation = model.notchPresentation
            let progress = presentation.progress
            let rest = geometry.map(presentation.restingEyeCenter) ?? CGPoint(x: 29, y: 16)
            let faceX = rest.x + (NotchGeometry.expandedEyeX - rest.x) * progress
            let faceY = rest.y + (geometry.map { $0.eyeCenterY(progress: progress) - $0.eyeCenterY(progress: 0) } ?? 0)
            ZStack(alignment: .topLeading) {
                let indicators = model.restingIndicators
                // Dots and the live activity leave early on either tier so they
                // never resurface while a glance hands over to the full panel.
                let opening: CGFloat = (1 - min(1, 3 * progress)) * (1 - min(1, 3 * presentation.peek))
                let restingOpacity = Double(opening * (1 - min(1, 3 * presentation.stage)) * (1 - presentation.hello))
                SessionIndicatorsView(indicators: indicators,
                                      layout: geometry?.indicatorLayout
                                        ?? SessionIndicatorLayout(count: indicators.count,
                                                                  availableWidth: proxy.size.width - 58),
                                      size: proxy.size, reducedMotion: model.reducedMotion)
                    .opacity(restingOpacity)
                    .allowsHitTesting(false)
                if let live = model.liveActivity, let geometry, geometry.liveSessionIDs == live.sessionIDs,
                   presentation.live > 0 {
                    let span = geometry.liveSpan
                    // Ride the growing shoulder: keep the content's distance from the
                    // right edge, like the dots, so it never slides under them mid-spring.
                    let fromRight = geometry.collapsedFrame.width - span.lowerBound
                    LiveActivityLabel(activity: live, reducedMotion: model.reducedMotion)
                        .frame(width: span.upperBound - span.lowerBound, height: proxy.size.height, alignment: .trailing)
                        .offset(x: proxy.size.width - fromRight)
                        // Materialize once the shoulder has room, island-style.
                        .opacity(restingOpacity * Double(EyeMotion.smoothstep((presentation.live - 0.5) / 0.4)))
                        .blur(radius: model.reducedMotion ? 0 : 4 * (1 - EyeMotion.smoothstep((presentation.live - 0.5) / 0.4)))
                        .allowsHitTesting(false)
                }
                if let announcement = model.announcement, let geometry, presentation.announce > 0 {
                    let span = geometry.announcementLabelSpan
                    let shown = EyeMotion.smoothstep((presentation.announce - 0.55) / 0.4)
                    AnnouncementLabel(announcement: announcement, reducedMotion: model.reducedMotion)
                        .frame(width: span.upperBound - span.lowerBound, height: proxy.size.height, alignment: .leading)
                        .offset(x: span.lowerBound)
                        .blur(radius: model.reducedMotion ? 0 : 4 * (1 - shown))
                        .opacity(Double(shown))
                        .allowsHitTesting(false)
                }
                if presentation.peek > 0 {
                    let start = (geometry?.glanceCameraMaxX ?? (geometry?.mascotWidth ?? 58) + 40) + 10
                    GlanceBandSummary(summary: model.glanceSummary)
                        .frame(width: max(0, proxy.size.width - start - 18), height: proxy.size.height, alignment: .trailing)
                        .offset(x: start)
                        .opacity(UnifiedNotchView.glanceOpacity(peek: presentation.peek))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .overlay(alignment: .topLeading) {
                // The glance enlarges the eyes slightly; only the full panel
                // moves them into the header row. With a mascot, the notch draws
                // the eyes itself so they can travel onto its face. Unclipped
                // by the band, so the launch's hello can lower them below it.
                if !model.mascotEnabled {
                    CompanionCharacter(model: model, expansion: progress + 0.15 * presentation.peek + 0.43 * presentation.hello)
                        .position(x: faceX, y: faceY)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            // A live glyph opens its session; elsewhere the band opens the panel.
            let width = model.notchPresentation.frame.width
            if let geometry = model.geometry, let live = model.liveActivity, model.notchPresentation.live > 0.5,
               model.notchPresentation.peek == 0, !model.expanded,
               location.x >= width - (geometry.collapsedFrame.width - geometry.liveSpan.lowerBound) - 8 {
                let end = width - (geometry.collapsedFrame.width - geometry.liveSpan.upperBound)
                model.openSessionFromNotch(live.sessionID(atDistanceFromEnd: end - location.x))
            } else {
                model.openAnnouncedSession()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notch Companion. \(indicatorSummary)")
        .accessibilityValue(model.expanded ? "Expanded" : model.glancing ? "Glance" : "Collapsed")
        .accessibilityHint("Hover to glance at your sessions, or click to open for input")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.activatePanel?() }
        .help("\(indicatorSummary)\nControl Option Space to open")
    }

    private var indicatorSummary: String {
        if let announcement = model.announcement, model.notchPresentation.announce > 0.5 {
            return announcement.spoken
        }
        let indicators = model.sessionIndicators
        return indicators.isEmpty ? "Ready." : indicators.map { "\($0.title): \($0.status.label)" }.joined(separator: ". ")
    }

}

/// Working dots breathe slowly; results stay still until read.
private struct SessionIndicatorsView: View {
    var indicators: [SessionIndicator]
    var layout: SessionIndicatorLayout
    var size: CGSize
    var reducedMotion: Bool

    var body: some View {
        let breathes = !reducedMotion && indicators.contains { $0.status == .running }
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !breathes)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            let breath = 0.5 + 0.5 * cos(phase * 2 * .pi)
            ZStack(alignment: .topLeading) {
                ForEach(Array(indicators.enumerated()), id: \.element.id) { entry in
                    let running = entry.element.status == .running && breathes
                    IndicatorDot(status: entry.element.status, reducedMotion: reducedMotion)
                        .opacity(running ? 0.5 + 0.5 * breath : 1)
                        .position(layout.center(at: entry.offset, in: size))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

}

/// A dot pops and sends out one ring when a result or question lands on it.
private struct IndicatorDot: View {
    var status: CollapsedStatus
    var reducedMotion: Bool
    @State private var landings = 0

    var body: some View {
        let color = IslandStyle.indicatorColor(status)
        let diameter = SessionIndicatorLayout.diameter
        Color.clear
            .keyframeAnimator(initialValue: CGFloat(1), trigger: landings) { _, t in
                let ring = 1 - pow(1 - t, 3)
                ZStack {
                    Circle().stroke(color.opacity(Double(0.85 * (1 - t))), lineWidth: 1)
                        .frame(width: diameter * (1 + 2.2 * ring), height: diameter * (1 + 2.2 * ring))
                    Circle().fill(color)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(1 + 0.6 * (t < 0.35 ? sin(.pi * t / 0.35) : 0))
                }
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.9)
            }
            .frame(width: diameter, height: diameter)
            .onChange(of: status, initial: true) { _, new in
                if new != .running && !reducedMotion { landings += 1 }
            }
    }
}

struct QuietIconButton: View {
    var symbol: String
    var label: String
    var size: CGFloat = 28
    var filled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(NotchIconButtonStyle(size: size, filled: filled))
            .help(label).accessibilityLabel(label)
    }
}

struct StateLabel: View {
    var state: WorkState
    var showsDot = true
    var dotColor: Color? = nil
    var label: String? = nil
    var body: some View {
        switch PanelTheme.current {
        case .refined, .tahoe:
            let refined = PanelTheme.current == .refined
            HStack(spacing: refined ? 6 : 5) {
                if showsDot {
                    Circle().fill(dotColor ?? CompanionStyle.color(state)).frame(width: 6, height: 6)
                }
                Text(label ?? CompanionStyle.label(state)).font(refined ? CompanionStyle.caption : .system(size: 11.5))
            }.foregroundStyle(CompanionStyle.secondary)
        case .instrument:
            let attention = state == .waiting || state == .failed
            HStack(spacing: 6) {
                // A read result keeps an unlit lamp so labels stay on one column.
                LED(color: showsDot ? dotColor ?? CompanionStyle.color(state) : CompanionStyle.faint,
                    lit: showsDot, pulsing: showsDot && state == .working, size: 5)
                Text(label ?? CompanionStyle.label(state)).microLabel(9.5, tracking: 0.7)
            }.foregroundStyle(attention ? CompanionStyle.signal : CompanionStyle.secondary)
        }
    }
}

struct MarkAllAsReadButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 28
    var filled = false

    var body: some View {
        QuietIconButton(symbol: "checkmark", label: "Mark all as read", size: size, filled: filled) { model.markAllAsRead() }
            .disabled(model.unreadResultCount == 0)
    }
}

/// The merged header. Its top row is the notch band: MascotView draws the eyes
/// at the left with the live status beside them, and icon controls sit at the
/// right, all on the resting eyes' centerline. The page title row follows below,
/// on the 20-point content margin, so no text ever sits behind a camera.
struct NotchHeaderView: View {
    /// Control circles leave 6 points above them in the top row (the eyes have about 8).
    static let control: CGFloat = 24
    @ObservedObject var model: AppModel

    var body: some View {
        // The status starts 16 points after the eyes' right edge.
        let statusX = 20 + 18 * EyesDrawing.expandedScale + 16
        let theme = PanelTheme.current
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if case .welcome(let step) = model.page {
                    // The welcome owns the panel: only a way out, never session controls.
                    Spacer(minLength: 0)
                    if step < WelcomeView.steps - 1 {
                        Button("Skip") { model.finishWelcome() }
                            .buttonStyle(NotchTextButtonStyle())
                            .modifier(SkipLabelStyle())
                            .help("Keep the defaults and close")
                    }
                } else {
                    statusText
                        .frame(maxWidth: model.geometry?.expandedCameraMinX.map { max(0, $0 - 8 - statusX) } ?? .infinity,
                               alignment: .leading)
                    Spacer(minLength: 0)
                    if model.page == .sessions { MarkAllAsReadButton(model: model, size: Self.control, filled: true) }
                    QuietIconButton(symbol: "plus", label: "New session", size: Self.control, filled: true) {
                        Task { await model.newSession() }
                    }
                    settingsButton
                }
            }
            .padding(.leading, statusX - 20)
            .frame(height: model.geometry?.expandedTopRowHeight ?? 36)
            HStack(spacing: 6) {
                if !model.page.isWelcome {
                    backButton
                    titleButton.layoutPriority(1)
                    if model.page == .session { FullAccessMarker(session: model.current) }
                    Spacer(minLength: 8)
                    if model.page == .session, let session = model.current, !session.agents.isEmpty { teamButton(session) }
                    if model.page == .sessions {
                        if model.showUsage {
                            QuietIconButton(symbol: "chart.bar", label: "Usage", size: 24) { model.page = .usage }
                        }
                        QuietIconButton(symbol: "folder.badge.plus", label: "New project", size: 24) { model.addProject() }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // The mascot stands in the header's left column, beside both rows.
            .padding(.leading, model.mascotEnabled ? statusX - 20 : 0)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(CompanionStyle.text)
        .background(alignment: .topLeading) {
            if theme == .refined { eyeBloom }
            // Instrument: a viewfinder frames the eyes, the one living thing on the grid.
            if theme == .instrument && !model.mascotEnabled {
                // Centered where the open eyes rest: they look a little right and down, toward the content.
                Reticle()
                    .frame(width: 46, height: 34)
                    .position(x: NotchGeometry.expandedEyeX + 2.2, y: (model.geometry?.eyeCenterY(progress: 1) ?? 18) + 2.5)
            }
        }
        .overlay(alignment: .bottom) {
            if theme == .instrument && !model.page.isWelcome {
                HeaderRule().padding(.horizontal, 20)
                    // A mascot stands in the header's left column, over the rule's start.
                    .padding(.leading, model.mascotEnabled ? 20 + 18 * EyesDrawing.expandedScale + 16 - 20 : 0)
            }
        }
    }

    /// Settings is one press away and shows it is open: the disc rises (lights
    /// up in Tahoe and Instrument) and the gear turns a quarter, then turns
    /// back when pressed again.
    private var settingsButton: some View {
        let open = model.page == .settings || model.page == .runtimeChooser(defaultSelection: true)
            || { if case .runtimeSetup = model.page { return true }; return false }()
        return Button { model.page = open ? .session : .settings } label: {
            Image(systemName: "gearshape").font(.system(size: PanelTheme.pick(12, 12, 11.5), weight: .medium))
                .rotationEffect(.degrees(open && !model.reducedMotion ? 90 : 0))
        }
        .buttonStyle(NotchIconButtonStyle(size: Self.control, filled: true, selected: open))
        .animation(model.reducedMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7), value: open)
        .help(open ? "Close settings" : "Settings")
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    @ViewBuilder private var backButton: some View {
        // A delegated child's conversation leads back to its parent's team.
        let child = model.page == .session && model.current?.parentSessionID != nil
        if model.page != .session || child {
            // The chevron, not its hover disc, lines up with the content margin.
            QuietIconButton(symbol: "chevron.left", label: child ? "Back to the parent session" : "Back", size: 24) {
                if child { model.openDelegationParent() }
                else if case .agent = model.page { model.page = .team }
                else if case .runtimeChooser(let defaults) = model.page { model.page = defaults ? .settings : .session }
                else if model.page.isRuntimeSetup { model.page = .settings }
                else if model.page == .usage { model.page = .sessions }
                // Archived steps back to the active list before leaving the page.
                else if model.page == .sessions && model.sessionFilter == .archived { model.sessionFilter = .all }
                else { model.page = .session }
            }.padding(.leading, -7)
        }
    }

    private var titleButton: some View {
        Button { model.page = model.page == .sessions ? .session : .sessions } label: {
            HStack(spacing: PanelTheme.pick(6, 5, 6)) {
                let title = Text(headerTitle).font(.system(size: 15, weight: .semibold))
                (PanelTheme.current == .instrument ? title.tracking(-0.2) : title).lineLimit(1)
                if model.page == .session {
                    Image(systemName: "chevron.down")
                        .font(.system(size: PanelTheme.pick(10, 10, 8.5), weight: PanelTheme.pick(.semibold, .bold, .bold)))
                        .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.faint))
                }
            }
        }.buttonStyle(NotchTextButtonStyle())
    }

    /// Refined: a faint light the open eyes cast on the black, so they read as
    /// the panel's character rather than an icon. It only exists in the open header.
    @ViewBuilder private var eyeBloom: some View {
        if !model.mascotEnabled {
            // An ellipse that hugs the pair of eyes rather than a round smudge.
            EllipticalGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0)], center: .center,
                               startRadiusFraction: 0.12, endRadiusFraction: 0.5)
                .frame(width: 84, height: 52)
                .position(x: NotchGeometry.expandedEyeX, y: (model.geometry?.expandedTopRowHeight ?? 36) / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var statusText: some View {
        let state = model.page == .session ? (model.current?.displayState ?? .idle) : model.overallState
        let session = model.page == .session ? model.current : nil
        let status = Self.status(state: state, session: session, waitingOnChild: session.map { model.delegationWaits[$0.id] != nil } ?? false)
        let working = [.thinking, .working, .answering].contains(CompanionMood.resolve(overall: state, current: session))
        let lit = working || status.color != CompanionStyle.secondary
        // Status changes resolve through a blur rather than snapping.
        return HStack(spacing: 7) {
            if PanelTheme.current == .instrument {
                LED(color: status.color == CompanionStyle.secondary ? (lit ? CompanionStyle.text : CompanionStyle.faint) : status.color,
                    lit: lit, pulsing: working, size: 6)
            }
            ZStack(alignment: .leading) {
                Group {
                    switch PanelTheme.current {
                    case .refined: Text(status.text).font(.system(size: 12, weight: .medium))
                    case .tahoe: Text(status.text).font(.system(size: 12.5, weight: .semibold))
                    case .instrument: Text(status.text).microLabel(10.5, tracking: 1)
                    }
                }
                    .foregroundStyle(status.color).lineLimit(1)
                    .workingShimmer(working, reducedMotion: model.reducedMotion)
                    .id(status.text)
                    .transition(model.reducedMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
        }
        .animation(model.reducedMotion ? nil : .smooth(duration: 0.32), value: status.text)
    }

    /// Live status in words, colored like the session's indicator dot.
    static func status(state: WorkState, session: CompanionSession?, waitingOnChild: Bool = false) -> (text: String, color: Color) {
        if session?.nativeActivityUnverified != nil { return ("Check native work", CompanionStyle.amber) }
        let collapsed = session.map { CollapsedStatus.resolve(session: $0) } ?? .none
        let color = PanelTheme.current == .refined
            // Without a session (secondary pages) the overall work still uses the palette.
            ? session == nil && [.working, .waiting].contains(state) ? CompanionStyle.color(state) : CompanionStyle.statusColor(collapsed)
            : collapsed == .none ? CompanionStyle.secondary : CompanionStyle.indicatorColor(collapsed)
        // A turn blocked on a delegation wait says so, whatever it last streamed.
        if waitingOnChild, state == .working { return ("Waiting on a child", color) }
        switch CompanionMood.resolve(overall: state, current: session) {
        case .thinking: return ("Thinking…", color)
        case .answering: return ("Writing…", color)
        case .working: return (session?.tools.last(where: { $0.state == .working })?.displayName ?? "Working…", color)
        case .waiting: return ("Needs your answer", color)
        case .done: return ("Done", color)
        case .failed: return (session?.pendingSubmission != nil ? "Send unconfirmed" : collapsed == .none ? "Failed" : "Needs attention", color)
        case .ready, .sleeping: return (state == .interrupted ? "Stopped" : "Ready", color)
        }
    }

    private var headerTitle: String {
        switch model.page { case .sessions: return model.sessionFilter == .archived ? "Archived" : "Your sessions"; case .team: return "Delegated work"; case .agent: return "Agent details"; case .activity: return "Activity"; case .settings: return "Settings"; case .usage: return "Usage"; case .runtimeSetup(let runtime): return "Set up \(runtime.title)"; case .runtimeChooser(let defaults): return defaults ? "Default agent" : "Choose agent"; case .welcome: return "Welcome"; case .session: return model.current?.title ?? "New session" }
    }

    private func teamButton(_ session: CompanionSession) -> some View {
        Button { model.page = .team } label: {
            switch PanelTheme.current {
            case .refined:
                HStack(spacing: 5) { Image(systemName: "person.2"); Text("Team \(session.agents.count)"); Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)) }
            case .tahoe:
                HStack(spacing: 5) { Image(systemName: "person.2.fill"); Text("Team \(session.agents.count)"); Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(CompanionStyle.secondary) }
            case .instrument:
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                    Text("Team")
                    Text(String(format: "%02d", session.agents.count)).foregroundStyle(CompanionStyle.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                }
            }
        }.buttonStyle(NotchPillButtonStyle(small: true)).fixedSize(horizontal: true, vertical: false).accessibilityLabel("Team, \(session.agents.filter { $0.state == .working }.count) working, \(session.agents.count) total")
    }

}

/// The welcome's Skip: plain text (Refined, Tahoe) or a micro-label (Instrument).
private struct SkipLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        switch PanelTheme.current {
        case .refined: content.font(.system(size: 12, weight: .medium)).foregroundStyle(CompanionStyle.secondary)
        case .tahoe: content.font(.system(size: 12.5, weight: .medium)).foregroundStyle(CompanionStyle.secondary)
        case .instrument: content.microLabel(10.5, tracking: 0.8).foregroundStyle(CompanionStyle.secondary)
        }
    }
}

/// A session with Full access always says so beside its title.
struct FullAccessMarker: View {
    var session: CompanionSession?
    var body: some View {
        if let session, session.permissionMode == .fullAccess {
            Image(systemName: PermissionMode.fullAccess.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(CompanionStyle.amber)
                .help("Full access: \(session.runtime.title) runs commands and edits files here without asking.")
                .accessibilityLabel("Full access is on for this session")
        }
    }
}

struct CompactPanelView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        let theme = PanelTheme.current
        VStack(spacing: 0) {
            if !model.connection && model.connectionMessage != "Connects when you send a message." && !model.page.isRuntimeSetup
                && model.current.map({ model.canChangeRuntime($0.id) }) != true {
                connectionNotice
            }
            if let error = model.errorMessage { errorNotice(error) }
            DeferredOperationBanner(model: model)
            if model.page == .session { FailedAgentBanner(model: model) }
            content.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            if model.page == .session, model.projectTrustSessionID == model.currentID, model.projectTrustSessionID != nil {
                ProjectTrustView(model: model).padding(.top, 8)
            } else if model.page == .session, let request = model.currentRequest {
                switch theme {
                case .refined:
                    // The card sizes to its question and scrolls past a cap, so a
                    // short approval never leaves a void above its buttons.
                    RequestView(model: model, request: request, compact: true).padding(.top, 8)
                case .tahoe:
                    // Sized to its content (details scroll past a cap), ahead of the conversation.
                    RequestView(model: model, request: request, compact: true)
                        .padding(.top, 8).layoutPriority(1)
                case .instrument:
                    RequestView(model: model, request: request, compact: true)
                        .frame(height: request.kind == .approval ? nil : 190).padding(.top, 8)
                }
            } else if model.page != .settings && model.page != .sessions && !model.page.isRuntimeSetup && !model.page.isWelcome {
                if theme == .refined {
                    ComposerView(model: model, focused: $focused, showsTitle: model.page != .session)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .zIndex(1)
                } else {
                    ComposerDestinationView(model: model, showsTitle: model.page != .session)
                        .padding(.top, 8).padding(.bottom, 5).zIndex(0.5)
                    if model.current?.attachments.isEmpty == false {
                        AttachmentStrip(model: model).frame(height: 28).padding(.bottom, 4)
                    }
                    ComposerView(model: model, focused: $focused).fixedSize(horizontal: false, vertical: true)
                        .zIndex(1)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, theme == .refined ? 4 : 6).padding(.bottom, theme == .refined ? 12 : 14)
        .frame(width: model.geometry?.panelWidth ?? 560, height: model.geometry?.bodyHeight ?? 480, alignment: .top)
        .background { if theme == .instrument && !model.page.isWelcome { InstrumentGrid() } }
        .foregroundStyle(CompanionStyle.text)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.composerFocusRequest) { _, _ in
            if model.expanded { focused = true }
        }
        .onChange(of: model.expanded) { _, open in if !open { focused = false } }
        .onExitCommand { model.togglePanel?() }
    }

    @ViewBuilder private var connectionNotice: some View {
        let buttons = Group {
            Button("Set up") { model.page = .runtimeSetup(model.current?.runtime ?? model.defaultRuntime) }
                .buttonStyle(NotchPillButtonStyle(small: true))
            Button("Reconnect") { Task { await model.reconnect() } }
                .buttonStyle(NotchPillButtonStyle(small: true))
        }
        switch PanelTheme.current {
        case .refined:
            HStack(spacing: 8) {
                Text(model.connectionMessage).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.secondary).lineLimit(2)
                Spacer()
                buttons
            }.panelNotice(CompanionStyle.secondary)
        case .tahoe:
            HStack(spacing: 12) {
                Text(model.connectionMessage).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(2)
                Spacer()
                buttons
            }.padding(.vertical, 7)
        case .instrument:
            HStack(spacing: 10) {
                LED(color: CompanionStyle.signal, size: 5)
                Text(model.connectionMessage).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary).lineLimit(2)
                Spacer()
                buttons
            }.padding(.vertical, 7)
        }
    }

    @ViewBuilder private func errorNotice(_ error: String) -> some View {
        let dismiss = QuietIconButton(symbol: "xmark", label: "Dismiss error", size: 22) { model.errorMessage = nil }
        switch PanelTheme.current {
        case .refined:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                Text(error).font(CompanionStyle.callout).lineLimit(3).help(error)
                Spacer(minLength: 0)
                dismiss.padding(.vertical, -4)
            }.foregroundStyle(CompanionStyle.amber).panelNotice(CompanionStyle.amber)
        case .tahoe:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.hierarchical)
                Text(error).font(.system(size: 12.5)).lineLimit(3).help(error)
                Spacer(minLength: 0)
                dismiss.padding(.top, -3)
            }.foregroundStyle(CompanionStyle.amber).padding(.vertical, 8)
        case .instrument:
            HStack(alignment: .top, spacing: 8) {
                // The tag and rule carry the signal; the message itself stays readable white.
                Text("ERR").microLabel(9.5, weight: .semibold).foregroundStyle(CompanionStyle.signal).padding(.top, 2)
                Text(error).font(.system(size: 12)).foregroundStyle(CompanionStyle.text).lineLimit(3).help(error)
                Spacer(minLength: 0)
                dismiss.padding(.top, -3)
            }
            .padding(.vertical, 7).padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(CompanionStyle.signal).frame(width: 2) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .settings: SettingsContent(model: model)
        case .runtimeSetup(let runtime): RuntimeSetupView(model: model, runtime: runtime)
        case .runtimeChooser(let defaults): RuntimeChooserView(model: model, defaultSelection: defaults)
        case .sessions: sessionList
        case .team: TeamContent(model: model)
        case .agent(let id): AgentContent(agent: model.current?.agents.first { $0.id == id })
        case .activity: activityList
        case .usage: UsageView(model: model)
        case .session: ConversationHistoryView(model: model)
        case .welcome(let step): WelcomeView(model: model, step: step)
        }
    }

    private var sessionList: some View { SessionBrowserView(model: model) }

    private var activityList: some View {
        ScrollView { LazyVStack(spacing: PanelTheme.pick(8, 8, 2)) { ForEach(model.current?.tools ?? []) { ToolRow(tool: $0) } } }.padding(.top, 8)
    }
}

/// A tool call: an icon row (Refined, Tahoe) or a log line
/// (Instrument, `›  Terminal  swift test   0.4s  OK`).
struct ToolRow: View {
    var tool: ToolActivity
    var body: some View {
        let status = tool.state == .working ? "Running" : (tool.state == .failed ? "Failed" : (tool.state == .interrupted ? "Stopped" : "Done"))
        switch PanelTheme.current {
        case .refined:
            // One line; only work that needs a look carries colour, finished calls stay quiet.
            let tint = tool.state == .working || tool.state == .failed ? CompanionStyle.color(tool.state) : CompanionStyle.tertiary
            HStack(spacing: 8) {
                Image(systemName: tool.state == .working ? "ellipsis" : tool.state == .failed ? "exclamationmark.circle" : tool.state == .interrupted ? "minus" : "checkmark")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
                Text(tool.displayName).font(CompanionStyle.callout)
                    .foregroundStyle(tool.state == .failed ? tint : tool.state == .working ? CompanionStyle.text : CompanionStyle.secondary)
                    .lineLimit(1).layoutPriority(1)
                if !tool.detail.isEmpty {
                    Text(SessionDigest.oneLine(tool.detail)).font(.system(size: 11, design: .monospaced)).foregroundStyle(CompanionStyle.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24).help(tool.detail.isEmpty ? tool.displayName : tool.detail)
            .accessibilityElement(children: .combine).accessibilityValue(status)
        case .tahoe:
            HStack(spacing: 8) {
                Group {
                    if tool.state == .working { ProgressView().controlSize(.mini) }
                    else {
                        Image(systemName: tool.state == .failed ? "exclamationmark.circle.fill" : tool.state == .interrupted ? "stop.circle" : "checkmark.circle.fill")
                            .font(.system(size: 12)).symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tool.state == .interrupted ? CompanionStyle.secondary : CompanionStyle.color(tool.state))
                    }
                }.frame(width: 16)
                // A failed call's name takes the failure colour, so it reads at a glance.
                Text(tool.displayName).font(.system(size: 12)).lineLimit(1).layoutPriority(1)
                    .foregroundStyle(tool.state == .failed ? AnyShapeStyle(CompanionStyle.color(.failed)) : AnyShapeStyle(.primary))
                if !tool.detail.isEmpty {
                    Text(SessionDigest.oneLine(tool.detail)).font(.system(size: 11, design: .monospaced)).foregroundStyle(CompanionStyle.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24).help(tool.detail.isEmpty ? tool.displayName : tool.detail)
            .accessibilityElement(children: .combine).accessibilityValue(status)
        case .instrument:
            let tag = tool.state == .working ? "RUN" : (tool.state == .failed ? "ERR" : (tool.state == .interrupted ? "STOP" : "OK"))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if tool.state == .working { LED(color: CompanionStyle.text, pulsing: true, size: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] } }
                    else { Text("›").foregroundStyle(tool.state == .failed ? CompanionStyle.signal : CompanionStyle.faint) }
                }.frame(width: 9)
                Text(tool.displayName).foregroundStyle(CompanionStyle.text).lineLimit(1).layoutPriority(1)
                if !tool.detail.isEmpty { Text(tool.detail).foregroundStyle(CompanionStyle.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 6)
                if let duration = Self.duration(tool) { Text(duration).foregroundStyle(CompanionStyle.faint).fixedSize() }
                Text(tag).microLabel(9.5, weight: .semibold, tracking: 0.6)
                    .foregroundStyle(tool.state == .failed ? CompanionStyle.signal : tool.state == .working ? CompanionStyle.text : CompanionStyle.faint)
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityLabel(status)
            }
            .font(CompanionStyle.mono(11).monospacedDigit())
            .frame(height: 24).help(tool.detail.isEmpty ? tool.displayName : tool.detail)
        }
    }

    /// Elapsed time of a finished call: `0.4s`, `12s`, `3m 04s`.
    static func duration(_ tool: ToolActivity) -> String? {
        guard let end = tool.finishedAt else { return nil }
        let seconds = max(0, end.timeIntervalSince(tool.startedAt))
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct TeamContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let agents = model.current?.agents ?? []
        let summary = "\(agents.filter { $0.state == .working }.count) working · \(agents.filter { $0.state == .finished }.count) finished"
        switch PanelTheme.current {
        case .refined:
            ScrollView { VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).padding(.vertical, 8)
                ForEach(agents) { agent in
                    Button { open(agent) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: agent.sessionID == nil ? "person.crop.circle" : "arrow.triangle.branch")
                                .font(.system(size: 12)).foregroundStyle(CompanionStyle.tertiary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if let detail = agent.delegationDetail { Text(detail).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).lineLimit(1) }
                            }
                            Spacer(minLength: 8)
                            StateLabel(state: agent.state)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CompanionStyle.tertiary)
                        }
                        .padding(.vertical, 10).padding(.horizontal, 12)
                    }.buttonStyle(NotchRowButtonStyle()).padding(.horizontal, -12)
                }
                if agents.isEmpty { Text("Delegated work will appear here.").font(CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary) }
            } }
        case .tahoe:
            ScrollView { VStack(alignment: .leading, spacing: 8) {
                Text(summary).font(.system(size: 13, weight: .semibold)).padding(.top, 10).padding(.leading, 4)
                if !agents.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                            if index > 0 { Rectangle().fill(CompanionStyle.separator).frame(height: 0.5).padding(.leading, 46) }
                            Button { open(agent) } label: {
                                HStack(spacing: 10) {
                                    SettingsIcon(symbol: agent.sessionID == nil ? "person.fill" : "arrow.triangle.branch",
                                                 tint: agent.sessionID == nil ? .gray : .indigo)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.title).font(.system(size: 13)).lineLimit(1)
                                        if let detail = agent.delegationDetail { Text(detail).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(1) }
                                    }
                                    Spacer(); StateLabel(state: agent.state)
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CompanionStyle.faint)
                                }
                                .padding(.vertical, 8).padding(.horizontal, 8)
                            }.buttonStyle(NotchRowButtonStyle(cornerRadius: 8)).padding(4)
                        }
                    }.notchGroup()
                }
                if agents.isEmpty { Text("Delegated work will appear here.").font(.system(size: 13)).foregroundStyle(CompanionStyle.secondary).padding(.leading, 4) }
            } }.softTopEdge(bottom: 14)
        case .instrument:
            ScrollView { VStack(alignment: .leading, spacing: 0) {
                RuleLabel(summary).padding(.top, 10).padding(.bottom, 6)
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    Button { open(agent) } label: {
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1)).font(CompanionStyle.mono(10.5)).foregroundStyle(CompanionStyle.faint)
                            Image(systemName: agent.sessionID == nil ? "person.crop.circle" : "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if let detail = agent.delegationDetail { Text(detail).microLabel(9.5, weight: .regular, tracking: 0.5).foregroundStyle(CompanionStyle.secondary).lineLimit(1) }
                            }
                            Spacer(); StateLabel(state: agent.state); Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(CompanionStyle.faint)
                        }
                            .padding(.vertical, 10).padding(.horizontal, 8)
                    }.buttonStyle(NotchRowButtonStyle()).padding(.horizontal, -8)
                    Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
                }
                if agents.isEmpty { Text("Delegated work will appear here.").font(.system(size: 12)).foregroundStyle(CompanionStyle.secondary) }
            } }
        }
    }

    /// An app-owned child opens its own conversation; a native one its activity.
    private func open(_ agent: ChildAgent) {
        if let id = agent.sessionID { model.openDelegatedSession(id) } else { model.page = .agent(agent.id) }
    }
}

struct AgentContent: View {
    var agent: ChildAgent?
    var body: some View {
        if let agent {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(agent.title).font(.system(size: 13, weight: PanelTheme.pick(.medium, .semibold, .medium))).lineLimit(1)
                    Spacer(); StateLabel(state: agent.state)
                }.padding(.top, PanelTheme.pick(8, 8, 6))
                if [.finished, .failed, .interrupted].contains(agent.state), !agent.text.isEmpty {
                    ScrollView { MarkdownContentView(text: agent.text) }
                } else if !agent.tools.isEmpty { ForEach(Array(agent.tools.suffix(3))) { ToolRow(tool: $0) } }
                else {
                    Text(agent.text.isEmpty ? "Working on this part of the task…" : agent.text)
                        .font(PanelTheme.pick(CompanionStyle.callout, .system(size: 13), .system(size: 12)))
                        .foregroundStyle(CompanionStyle.secondary).lineLimit(5)
                }
            }
        }
    }
}

struct AttachmentStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let theme = PanelTheme.current
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { ForEach(model.current?.attachments ?? []) { attachment in
                let shape = RoundedRectangle(cornerRadius: PanelTheme.pick(8, 8, CompanionStyle.radius), style: .continuous)
                HStack(spacing: PanelTheme.pick(6, 5, 6)) {
                    Image(systemName: attachment.isImage ? (theme == .tahoe ? "photo.fill" : "photo") : (theme == .tahoe ? "doc.fill" : "doc"))
                        .font(.system(size: PanelTheme.pick(11, 10, 10)))
                        .foregroundStyle(theme == .refined ? CompanionStyle.tertiary : CompanionStyle.secondary)
                    Group {
                        switch theme {
                        case .refined: Text(attachment.name).font(CompanionStyle.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                        case .tahoe: Text(attachment.name).font(.system(size: 11.5)).lineLimit(1).frame(maxWidth: 140)
                        case .instrument: Text(attachment.name).font(CompanionStyle.mono(10.5)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                        }
                    }
                    Button { model.removeAttachment(attachment.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(NotchIconButtonStyle(size: 18))
                        .help("Remove \(attachment.name)").accessibilityLabel("Remove \(attachment.name)")
                }
                .padding(.leading, PanelTheme.pick(8, 9, 8)).padding(.trailing, 3).frame(height: theme == .refined ? 26 : 24)
                .background {
                    switch theme {
                    case .refined: shape.fill(CompanionStyle.raised)
                    case .tahoe: Capsule().fill(Color.white.opacity(0.1))
                    case .instrument: shape.fill(CompanionStyle.controlFill)
                    }
                }
                .overlay {
                    switch theme {
                    case .refined: shape.strokeBorder(CompanionStyle.hairline, lineWidth: 0.5)
                    case .tahoe: Capsule().strokeBorder(GlassEdge.gradient(0.12), lineWidth: 0.5)
                    case .instrument: shape.strokeBorder(CompanionStyle.rule, lineWidth: 0.5)
                    }
                }
                .help("\(attachment.name) · Ready to send")
            } }.frame(height: theme == .refined ? 28 : 27)
        }
    }
}

/// Grouped rows: the label on the left, its control on the right, stacking
/// only where the full-session sidebar is too narrow for one line.
struct SettingsContent: View {
    @ObservedObject var model: AppModel
    /// The full-session window shows the same rows in its main pane.
    var inNotch = true
    @ObservedObject private var sounds = SoundPlayer.shared
    @AppStorage(NotchBodyStyle.key) private var bodyStyle = NotchBodyStyle.smoked
    @AppStorage(PanelTheme.key) private var panelTheme = PanelTheme.refined
    @AppStorage(Haptics.key) private var haptics = true

    var body: some View {
        if inNotch {
            switch PanelTheme.current {
            case .refined: ScrollView(.vertical) { rows.padding(.top, 8).padding(.bottom, 12) }.scrollEdgeFade()
            case .tahoe: ScrollView(.vertical) { rows.padding(.top, 10).padding(.bottom, 12) }.softTopEdge(bottom: 14)
            case .instrument: ScrollView(.vertical) { rows.padding(.top, 8).padding(.bottom, 6) }
            }
        } else {
            ScrollView(.vertical) { rows.padding(.top, 2).padding(.bottom, 18) }
        }
    }

    private var rows: some View {
        // Tahoe and Instrument head each group; their icon tiles are Tahoe's.
        VStack(alignment: .leading, spacing: PanelTheme.pick(12, 18, 14)) {
            SettingsGroup(PanelTheme.pick(nil, "Sessions", "Defaults")) {
                SettingsRow("Default agent for new sessions", symbol: "sparkle", tint: .purple) {
                    defaultAgentButton
                        .accessibilityLabel("Default agent for new sessions, \(model.defaultRuntime.title)")
                }
                SettingsRow("Default folder for new sessions", symbol: "folder.fill", tint: .blue, divider: true) { DefaultWorkspaceButton(model: model) }
                SettingsRow("Archive read sessions after", symbol: "archivebox.fill", tint: .gray, divider: true) {
                    // The 252-point sidebar fits only the list's own age style (1h, 12h, 3d).
                    ViewThatFits(in: .horizontal) {
                        NotchSegmentedControl(label: "Archive read sessions after", options: SessionAutoArchive.allCases,
                                              title: \.label, selection: $model.autoArchiveAfter, small: true)
                        NotchSegmentedControl(label: "Archive read sessions after", options: SessionAutoArchive.allCases,
                                              title: { $0.interval.map(SessionDigest.compactAge) ?? $0.label },
                                              selection: $model.autoArchiveAfter, small: true, spoken: \.label)
                    }
                        .help("Read, idle sessions move to Archived after this long without activity. Search and the Archived list still find them.")
                }
            }
            SettingsGroup(PanelTheme.pick(nil, "Composer", "Composer")) {
                SettingsRow("Show model picker", symbol: "cube.fill", tint: .indigo) {
                    Toggle("Show model picker", isOn: $model.showModelPicker).toggleStyle(NotchSwitchStyle())
                        .help("Choose a model above the composer, separately for each conversation.")
                }
                SettingsRow("Show context usage", symbol: "gauge.with.dots.needle.50percent", tint: .teal, divider: true) {
                    Toggle("Show context usage", isOn: $model.showContextUsage).toggleStyle(NotchSwitchStyle())
                        .help("Show the last reported token usage and context window above the composer.")
                }
                SettingsRow("Show SnapShot", symbol: "camera.viewfinder", tint: .gray, divider: true) {
                    Toggle("Show SnapShot", isOn: $model.showSnapShot).toggleStyle(NotchSwitchStyle())
                        .help("Add a composer button that attaches a picture of the window you were using when the notch opened. Needs Screen Recording permission on first use.")
                }
                SettingsRow("Show usage", symbol: "chart.bar.fill", tint: .green, divider: true) {
                    Toggle("Show usage", isOn: $model.showUsage).toggleStyle(NotchSwitchStyle())
                        .help("Add a Usage page to Your sessions: account limits your harnesses report and tokens from sessions started here.")
                }
                SettingsRow("Show permission modes", symbol: "lock.shield.fill", tint: .orange, divider: true) {
                    Toggle("Show permission modes", isOn: $model.showPermissionModes).toggleStyle(NotchSwitchStyle())
                        .help("Choose how much the agent may do without asking, separately for each conversation. Harnesses without a native mapping keep their own settings.")
                }
                SettingsRow("Cross-agent delegation", symbol: "arrow.triangle.branch", tint: .pink, divider: true) {
                    Toggle("Cross-agent delegation", isOn: $model.delegationEnabled).toggleStyle(NotchSwitchStyle())
                        .help("Let sessions of any harness (OpenCode from 2.0) hand a task to another harness you set up here. The child appears in the parent's team. Applies to sessions opened from now on.")
                }
            }
            SettingsGroup(PanelTheme.pick(nil, "Notch", "Notch")) {
                SettingsRow("Open on hover", symbol: "cursorarrow.rays", tint: .blue) {
                    Toggle("Open on hover", isOn: $model.openOnHover)
                        .toggleStyle(NotchSwitchStyle())
                        .help("Preview the companion when hovering over the notch. When off, click to open.")
                        .accessibilityHint("When off, click the notch to open the companion.")
                }
                SettingsRow("Hover preview", symbol: "rectangle.topthird.inset.filled", tint: .cyan, divider: true) {
                    NotchSegmentedControl(label: "Hover preview", options: HoverPreview.allCases,
                                          title: \.label, selection: $model.hoverPreview)
                        .disabled(!model.openOnHover)
                        .opacity(model.openOnHover ? 1 : 0.45)
                        .help("Glance shows a small summary of recent sessions; Full panel opens the conversation.")
                }
                SettingsRow("Notch updates", symbol: "bell.badge.fill", tint: .red, divider: true) {
                    NotchSegmentedControl(label: "Notch updates", options: NotchUpdateStyle.allCases,
                                          title: \.label, selection: $model.updateStyle)
                        .help("Compact extends the notch to the right with an animated update. Popup opens a larger view with details and replies.")
                }
                SettingsRow("Companion", symbol: "eyes", tint: .gray, divider: true) {
                    NotchSegmentedControl(label: "Companion", options: CompanionAppearance.allCases,
                                          title: \.label, selection: $model.companionAppearance)
                        .help("Eyes keeps just the white eyes. Mascot brings a character into the popup and open panel. Both rest as eyes beside the notch.")
                }
                if model.companionAppearance == .mascot {
                    SettingsRow("Mascot", symbol: "pawprint.fill", tint: .brown, divider: true) {
                        NotchSegmentedControl(label: "Mascot", options: MascotCharacter.allCases,
                                              title: \.label, selection: $model.mascotCharacter)
                            .help("Mote phases up through the edge, Fold unfolds from paper, Soot climbs up and peeks over it.")
                    }
                }
                SettingsRow("Notch body", symbol: "paintpalette.fill", tint: .orange, divider: true) {
                    NotchSegmentedControl(label: "Notch body", options: NotchBodyStyle.allCases,
                                          title: \.label, selection: $bodyStyle)
                        .help("Applies to the notch and the full-session window.")
                }
                SettingsRow("Panel design", symbol: "macwindow", tint: .blue, divider: true) {
                    // Set the cached theme first so the rebuilt panel reads the new design.
                    let selection = Binding(get: { panelTheme }, set: { PanelTheme.current = $0; panelTheme = $0 })
                    // The full-session sidebar is too narrow for the regular size.
                    ViewThatFits(in: .horizontal) {
                        NotchSegmentedControl(label: "Panel design", options: PanelTheme.allCases, title: \.label, selection: selection)
                        NotchSegmentedControl(label: "Panel design", options: PanelTheme.allCases, title: \.label, selection: selection, small: true)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(PanelTheme.allCases) { theme in
                                Button { selection.wrappedValue = theme } label: {
                                    HStack(spacing: 8) { ChoiceMark(selected: panelTheme == theme, round: true); Text(theme.label) }
                                        .padding(.vertical, 3).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).pressableCursor()
                                .accessibilityAddTraits(panelTheme == theme ? .isSelected : [])
                            }
                        }
                    }
                        .help("Refined is the quiet default; Tahoe follows macOS and its accent color; Instrument is monochrome with one orange signal.")
                }
                SettingsRow("Status effects", symbol: "sparkles", tint: .yellow, divider: true) {
                    HStack(spacing: 10) {
                        Button("Preview") { model.previewStatusEffect() }
                            .buttonStyle(NotchPillButtonStyle(small: true))
                            .disabled(!model.statusEffects)
                            .help("Close the notch and play the finished-session effect")
                        Toggle("Status effects", isOn: $model.statusEffects)
                            .toggleStyle(NotchSwitchStyle())
                    }
                    .help("Light the notch edge and briefly name a session when it finishes, fails, or needs you.")
                }
                SettingsRow("Live activity", symbol: "timer", tint: .orange, divider: true) {
                    Toggle("Live activity", isOn: $model.liveActivityEnabled).toggleStyle(NotchSwitchStyle())
                        .help("While an agent works or waits, show its current tool and running time beside the notch.")
                }
                SettingsRow("Pointer pull", symbol: "hand.point.up.left.fill", tint: .mint, divider: true) {
                    Toggle("Pointer pull", isOn: $model.pointerPull).toggleStyle(NotchSwitchStyle())
                        .help("The resting notch gently stretches toward the pointer as it comes near.")
                }
                SettingsRow("Sounds", symbol: "speaker.wave.2.fill", tint: .pink, divider: true) {
                    HStack(spacing: 12) {
                        // Releasing the knob plays a cue at the chosen level.
                        NotchSlider(value: $sounds.volume, range: 0...0.7, label: "Sound volume") {
                            SoundPlayer.shared.play(.attach)
                        }
                        .frame(width: 88).disabled(!sounds.enabled).help("Sound volume")
                        Toggle("Sounds", isOn: $sounds.enabled).toggleStyle(NotchSwitchStyle())
                    }
                }
            }
            SettingsGroup(PanelTheme.pick(nil, "General", "System")) {
                SettingsRow("Open at login", symbol: "power", tint: .gray) { OpenAtLoginToggle(model: model) }
                SettingsRow("Swipe on the notch", symbol: "hand.draw.fill", tint: .blue, divider: true) {
                    Toggle("Swipe on the notch", isOn: $model.swipeGestures).toggleStyle(NotchSwitchStyle())
                        .help("Two-finger swipe down on the notch to open it, and up to close it.")
                }
                SettingsRow("Haptic feedback", symbol: "hand.tap.fill", tint: .purple, divider: true) {
                    Toggle("Haptic feedback", isOn: $haptics).toggleStyle(NotchSwitchStyle())
                        .help("A light tap on a Force Touch trackpad as the glance opens, a swipe lands, or a file moves between destinations.")
                }
                SettingsRow("Welcome", symbol: "hand.wave.fill", tint: .yellow, divider: true) {
                    Button("Show again") { model.page = .welcome(step: 0); model.activatePanel?() }
                        .buttonStyle(NotchPillButtonStyle(small: true))
                        .help("Choose the agent, look and notch updates again.")
                }
            }
            SettingsGroup(PanelTheme.pick(nil, "Agents", "Harnesses")) {
                ForEach(Array(RuntimeKind.allCases.enumerated()), id: \.element) { index, runtime in
                    let status = model.connectionStatus(for: runtime)
                    SettingsRow(runtime.title, divider: index > 0) {
                        runtimeStatus(runtime, status: status)
                    }
                    .help(status.message)
                    .accessibilityElement(children: .combine)
                    if status.connected && runtime.capabilities.modelSelection { RuntimeDefaultModelView(model: model, runtime: runtime) }
                }
            }
            HStack(spacing: 8) {
                if inNotch {
                    let footer = Text(model.geometry?.hasHardware == true ? "Quiet Companion · native notch" : "Quiet Companion · external display mode")
                    switch PanelTheme.current {
                    case .refined: footer.font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).lineLimit(1)
                    case .tahoe: footer.font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                    case .instrument: footer.microLabel(9.5, weight: .regular, tracking: 0.6).foregroundStyle(CompanionStyle.faint).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button("Reconnect") { Task { await model.reconnect() } }
                    .buttonStyle(NotchPillButtonStyle(small: true)).help("Reconnect owned runtime connections when work is idle")
                if inNotch {
                    Button("Open full session") { model.openFullSession?() }
                        .buttonStyle(NotchPillButtonStyle(small: true))
                }
            }
            .padding(.leading, PanelTheme.pick(4, 4, 0)).padding(.top, PanelTheme.pick(4, 0, 2))
            Text(AppVersion.label)
                .font(.system(size: 11))
                .foregroundStyle(CompanionStyle.secondary)
                .textSelection(.enabled)
                .padding(.leading, PanelTheme.pick(4, 4, 0))
        }
    }

    @ViewBuilder private var defaultAgentButton: some View {
        let open = { model.page = .runtimeChooser(defaultSelection: true) }
        switch PanelTheme.current {
        case .refined:
            Button(action: open) {
                HStack(spacing: 5) {
                    Text(model.defaultRuntime.title)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(CompanionStyle.tertiary)
                }
            }.buttonStyle(NotchPillButtonStyle(small: true))
        case .tahoe:
            Button(action: open) {
                HStack(spacing: 6) {
                    Text(model.defaultRuntime.title).foregroundStyle(CompanionStyle.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CompanionStyle.faint)
                }.font(.system(size: 13))
            }.buttonStyle(NotchTextButtonStyle())
        case .instrument:
            Button(action: open) {
                Label(model.defaultRuntime.title, systemImage: "chevron.right")
            }.buttonStyle(NotchPillButtonStyle(small: true))
        }
    }

    @ViewBuilder private func runtimeStatus(_ runtime: RuntimeKind, status: (connected: Bool, message: String)) -> some View {
        let ready = model.readyRuntimes.contains(runtime)
        let text = model.runtimeSettingsPending.contains(runtime) ? "Check again" : status.connected ? "Connected" : ready ? "Ready" : "Set up needed"
        let setUp = Button("Set up") { model.page = .runtimeSetup(runtime) }
            .buttonStyle(NotchPillButtonStyle(small: true))
            .accessibilityLabel("Set up \(runtime.title)")
        switch PanelTheme.current {
        case .refined, .tahoe:
            let tahoe = PanelTheme.current == .tahoe
            HStack(spacing: 6) {
                Circle().fill(status.connected ? CompanionStyle.color(.finished) : CompanionStyle.amber)
                    .frame(width: tahoe ? 7 : 6, height: tahoe ? 7 : 6)
                Text(text)
                setUp
            }
            .font(tahoe ? .system(size: 12.5) : CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary)
        case .instrument:
            HStack(spacing: 7) {
                // Connected is lit, ready is an unlit lamp, and setup needs you.
                LED(color: status.connected || ready ? CompanionStyle.text : CompanionStyle.signal,
                    lit: status.connected || !ready, size: 5)
                Text(text)
                    .microLabel(9.5, tracking: 0.6)
                    .foregroundStyle(status.connected || ready ? CompanionStyle.secondary : CompanionStyle.signal)
                setUp.padding(.leading, 3)
            }
            .foregroundStyle(CompanionStyle.secondary)
        }
    }
}

/// The working folder for new sessions, shared by Settings and the welcome.
struct DefaultWorkspaceButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let name = URL(fileURLWithPath: model.workspacePath).lastPathComponent
        Group {
            if PanelTheme.current == .tahoe {
                // A System Settings pop-up: the value in secondary text with up/down chevrons.
                Button { model.chooseWorkspace() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").font(.system(size: 11))
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CompanionStyle.faint)
                    }
                    .font(.system(size: 13)).foregroundStyle(CompanionStyle.secondary)
                }
                .buttonStyle(NotchTextButtonStyle())
                .accessibilityLabel("Default folder, \(name)")
            } else {
                Button { model.chooseWorkspace() } label: {
                    Label(name, systemImage: "folder")
                        .truncationMode(.middle)
                }
                .buttonStyle(NotchPillButtonStyle(small: PanelTheme.current == .refined))
            }
        }
        .help("Choose the working folder for new sessions · \(model.workspacePath)")
    }
}

/// The login item switch, with System Settings one press away when macOS
/// still needs approval. Shared by Settings and the welcome.
struct OpenAtLoginToggle: View {
    @ObservedObject var model: AppModel
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.needsApproval

    var body: some View {
        HStack(spacing: 10) {
            if needsApproval {
                Button("Allow in System Settings") { LoginItem.openSystemSettings() }
                    .buttonStyle(NotchPillButtonStyle(small: true))
            }
            Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: set)).toggleStyle(NotchSwitchStyle())
        }
        .help("Start Notch Companion when you log in to this Mac.")
    }

    private func set(_ enabled: Bool) {
        do { try LoginItem.set(enabled) }
        catch { model.errorMessage = "Could not change Open at login: \(error.localizedDescription)" }
        opensAtLogin = LoginItem.isEnabled
        needsApproval = LoginItem.needsApproval
    }
}

/// A settings card. `title` heads it in Tahoe (bold, System Settings) and
/// Instrument (a rule label); Refined groups stay untitled.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        switch PanelTheme.current {
        case .refined:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.Radius.card, style: .continuous)
            VStack(spacing: 0) { content }
                .background(CompanionStyle.well, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        case .tahoe:
            VStack(alignment: .leading, spacing: 7) {
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) { content }.notchGroup()
            }
        case .instrument:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.cardRadius, style: .continuous)
            VStack(alignment: .leading, spacing: 7) {
                if let title {
                    RuleLabel(title).accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) { content }
                    .background(Color.black.opacity(0.25), in: shape)
                    .overlay(shape.strokeBorder(CompanionStyle.rule, lineWidth: 0.5))
            }
        }
    }
}

/// A settings row: the label on the left, its control on the right. Tahoe
/// leads with a System Settings icon tile when `symbol` is set.
struct SettingsRow<Control: View>: View {
    var title: String
    var symbol: String?
    var tint: Color
    var divider: Bool
    var control: Control

    init(_ title: String, symbol: String? = nil, tint: Color = .gray, divider: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.divider = divider
        self.control = control()
    }

    var body: some View {
        let theme = PanelTheme.current
        // Tahoe's separators start at the label, past the icon tile, as in System Settings.
        let icon = theme == .tahoe ? symbol : nil
        let inset: CGFloat = PanelTheme.pick(14, icon == nil ? 12 : 44, 0)
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PanelTheme.pick(Color.white.opacity(0.06), CompanionStyle.separator, Color.white.opacity(0.08)))
                    .frame(height: 0.5).padding(.leading, inset)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme == .tahoe ? 10 : 12) {
                    if let icon { SettingsIcon(symbol: icon, tint: tint) }
                    Text(title).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    // Caps a long folder name so it truncates instead of stacking; wide
                    // enough for the archive choices' full words (230 points in Instrument).
                    control.frame(maxWidth: 240, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if let icon { SettingsIcon(symbol: icon, tint: tint) }
                        Text(title)
                    }
                    control
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
            }
            .font(.system(size: 13))
            .padding(.horizontal, theme == .refined ? 14 : 12)
            .frame(minHeight: theme == .tahoe ? 42 : 40)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct FullSessionView: View {
    @ObservedObject var model: AppModel
    @AppStorage(NotchBodyStyle.key) private var bodyStyle = NotchBodyStyle.smoked
    @FocusState private var focused: Bool
    @State private var selectedTab: String
    /// Settings or Usage, shown in the main pane over the selected session.
    @State private var utility: PanelPage?
    /// Fixtures open another tab or page directly.
    init(model: AppModel, tab: String = "Conversation", utility: PanelPage? = nil) {
        self.model = model
        _selectedTab = State(initialValue: tab)
        _utility = State(initialValue: utility ?? Self.utility(for: model.page))
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                if PanelTheme.current == .tahoe {
                    Rectangle().fill(CompanionStyle.separator).frame(width: 0.5)
                } else {
                    Divider().overlay(CompanionStyle.surface)
                }
            }.ignoresSafeArea()
            VStack(spacing: 0) {
                if case .runtimeChooser(let defaults) = model.page {
                    header(defaults ? "Default agent" : "Choose agent", back: { model.page = .session })
                    ScrollView(.vertical) {
                        RuntimeChooserView(model: model, defaultSelection: defaults).readable().padding(.horizontal, 22).padding(.bottom, 18)
                    }
                } else if case .runtimeSetup(let runtime) = model.page {
                    header("Set up \(runtime.title)", back: { model.page = .session })
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            DeferredOperationBanner(model: model)
                            RuntimeSetupView(model: model, runtime: runtime)
                            if let error = model.errorMessage {
                                Text(error).font(.system(size: 12)).foregroundStyle(CompanionStyle.amber).textSelection(.enabled)
                            }
                        }.readable().padding(.horizontal, 22).padding(.bottom, 18)
                    }
                } else if utility == .settings {
                    header("Settings", width: 620, back: { utility = nil })
                    SettingsContent(model: model, inNotch: false).readable(620).padding(.horizontal, 22)
                } else if utility == .usage {
                    header("Usage", width: 620, back: { utility = nil })
                    UsageView(model: model).readable(620).padding(.horizontal, 22).padding(.bottom, 12)
                } else {
                    sessionPane
                }
            }
        }.frame(minWidth: 780, minHeight: 550)
        .background {
            ZStack {
                if bodyStyle == .black {
                    Color.black
                } else {
                    NotchWindowBackdrop()
                    Color.black.opacity(bodyStyle == .smoked ? Double(NotchBodyBackground.smoke) : 0)
                }
            }.ignoresSafeArea()
        }
        .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark)
        .environment(\.notchBodyStyle, bodyStyle)
        .onAppear {
            focused = true
            model.setSessionVisibility(fullConversationVisible: selectedTab == "Conversation")
        }
        .onChange(of: selectedTab) { _, tab in
            model.setSessionVisibility(fullConversationVisible: tab == "Conversation")
        }
        .onChange(of: model.currentID) { _, _ in utility = nil; focused = true }
        .onChange(of: model.page) { _, page in if let page = Self.utility(for: page) { utility = page } }
    }

    private static func utility(for page: PanelPage) -> PanelPage? {
        page == .settings || page == .usage ? page : nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                if model.sessionFilter == .archived {
                    QuietIconButton(symbol: "chevron.left", label: "Back to your sessions") { model.sessionFilter = .all }.padding(.leading, -7)
                }
                Text(model.sessionFilter == .archived ? "Archived" : "Your sessions").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                MarkAllAsReadButton(model: model)
                QuietIconButton(symbol: "folder.badge.plus", label: "New project") { model.addProject(showPanel: false) }
                QuietIconButton(symbol: "plus", label: "New session") { Task { await model.newSession(showPanel: false) } }
            }
            SessionBrowserView(model: model, compact: false)
            VStack(spacing: 2) {
                if model.showUsage { sidebarButton("Usage", symbol: "chart.bar", page: .usage) }
                sidebarButton("Settings", symbol: "gearshape", page: .settings)
            }
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14).frame(width: 252).background(Color.black.opacity(0.22))
    }

    private func sidebarButton(_ title: String, symbol: String, page: PanelPage) -> some View {
        let selected = utility == page
        return Button { utility = selected ? nil : page } label: {
            Label(title, systemImage: symbol).font(.system(size: 13))
                .foregroundStyle(selected ? CompanionStyle.text : CompanionStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(.horizontal, 10)
                .background(selected ? CompanionStyle.controlFill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One header for every page, so titles share a baseline and inset.
    private func header<Trailing: View>(_ title: String, subtitle: String? = nil, session: CompanionSession? = nil, width: CGFloat = 820,
                                        back: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            if let back { QuietIconButton(symbol: "chevron.left", label: "Back", action: back) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(1); FullAccessMarker(session: session) }
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .frame(minHeight: 44).readable(width).padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 14)
    }

    @ViewBuilder private var sessionPane: some View {
        header(model.current?.title ?? "New session",
               subtitle: model.currentDraftNeedsSetup ? "Connect a harness in Settings." : model.connectionMessage,
               session: model.current) {
            NotchSegmentedControl(label: "View", options: ["Conversation", "Activity", "Team"], title: { $0 }, selection: $selectedTab)
        }
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(error).font(.system(size: 12)).textSelection(.enabled); Spacer(); QuietIconButton(symbol: "xmark", label: "Dismiss error") { model.errorMessage = nil } }.foregroundStyle(CompanionStyle.amber).padding(.bottom, 10)
            }
            DeferredOperationBanner(model: model)
            FailedAgentBanner(model: model) { selectedTab = "Team" }
        }.readable().padding(.horizontal, 22)
        Group {
            if selectedTab == "Conversation" { ConversationHistoryView(model: model) }
            else if selectedTab == "Activity" { fullActivity }
            else { fullTeam }
        }.readable().padding(.horizontal, 22).frame(maxHeight: .infinity)
        VStack(spacing: 6) {
            if model.projectTrustSessionID == model.currentID, model.projectTrustSessionID != nil {
                ProjectTrustView(model: model)
            } else if let request = model.currentRequest {
                // Refined and Tahoe size the card to its question; Instrument only an approval.
                RequestView(model: model, request: request)
                    .frame(height: PanelTheme.current == .instrument && request.kind != .approval ? 210 : nil)
            } else if PanelTheme.current == .refined {
                ComposerView(model: model, focused: $focused, isCompact: false, showsTitle: selectedTab != "Conversation")
                    .fixedSize(horizontal: false, vertical: true).zIndex(1)
            } else {
                ComposerDestinationView(model: model, showsTitle: selectedTab != "Conversation").zIndex(0.5)
                if model.current?.attachments.isEmpty == false { AttachmentStrip(model: model).frame(height: 28) }
                ComposerView(model: model, focused: $focused, isCompact: false).fixedSize(horizontal: false, vertical: true).zIndex(1)
            }
        }.readable().padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 18).zIndex(1)
            .layoutPriority(PanelTheme.current == .tahoe ? 1 : 0)
    }

    @ViewBuilder private var fullActivity: some View {
        if let tools = model.current?.tools, !tools.isEmpty {
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(tools) { tool in
                DisclosureGroup { Text(tool.output.isEmpty ? (tool.detail.isEmpty ? "No output yet." : tool.detail) : tool.output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8) } label: { ToolRow(tool: tool) }
            } }.padding(.horizontal, 2).padding(.vertical, 10) }
        } else {
            emptyState("No activity yet", symbol: "wrench.and.screwdriver", detail: "Tools this session's agent runs appear here with their output.")
        }
    }

    @ViewBuilder private var fullTeam: some View {
        if case .agent(let id) = model.page {
            VStack(alignment: .leading, spacing: 10) {
                Button { model.page = .team } label: { Label("All delegated work", systemImage: "chevron.left") }
                    .buttonStyle(NotchTextButtonStyle()).font(.system(size: 12)).foregroundStyle(CompanionStyle.secondary)
                AgentContent(agent: model.current?.agents.first { $0.id == id })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else if let agents = model.current?.agents, !agents.isEmpty {
        ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(agents) { agent in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(agent.title).font(.system(size: 14, weight: .medium))
                    if let detail = agent.delegationDetail { Text(detail).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary) }
                    Spacer()
                    if let id = agent.sessionID {
                        Button("Open conversation") { model.openDelegatedSession(id) }.buttonStyle(NotchTextButtonStyle()).font(.system(size: 12))
                    }
                    StateLabel(state: agent.state)
                }
                if !agent.text.isEmpty { MarkdownContentView(text: agent.text) }
                ForEach(Array(agent.tools.suffix(3))) { ToolRow(tool: $0) }
            }.padding(16).modifier(FullTeamCard())
        } }.padding(.horizontal, 2).padding(.vertical, 10) }
        } else {
            emptyState("No delegated work", symbol: "arrow.triangle.branch", detail: "Tasks this session hands to another agent appear here.")
        }
    }

    private func emptyState(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(CompanionStyle.faint).padding(.bottom, 4)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(CompanionStyle.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Caps the width and centres it, so lines stay readable when the window is wide.
    func readable(_ width: CGFloat = 820) -> some View { frame(maxWidth: width).frame(maxWidth: .infinity) }
}

/// A delegated agent's card in the full-session window.
private struct FullTeamCard: ViewModifier {
    func body(content: Content) -> some View {
        if PanelTheme.current == .tahoe { content.notchGroup(cornerRadius: 14) }
        else { content.background(CompanionStyle.surface, in: RoundedRectangle(cornerRadius: 12)) }
    }
}
