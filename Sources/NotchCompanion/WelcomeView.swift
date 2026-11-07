import SwiftUI

/// First-run choices inside the notch: agent, look, updates, then folder and
/// login. One centred step at a time, each choice showing itself: the live
/// mascots, drawings of both update styles (and a real sample on the notch),
/// and where each agent is installed. Every choice is an existing setting.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let step: Int
    /// Installed harnesses and where; nil until the first check.
    @State private var installed: [(runtime: RuntimeKind, path: String)]?
    @State private var checks = 0
    static let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Each step is one composition, centred a little above the middle.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if PanelTheme.current == .instrument {
                    Text(String(format: "%02d / %02d", step + 1, Self.steps)).microLabel(10, tracking: 1.2)
                        .foregroundStyle(CompanionStyle.faint).padding(.bottom, 10)
                }
                Text(title).font(.system(size: PanelTheme.pick(20, 22, 22), weight: PanelTheme.pick(Font.Weight.semibold, .bold, .semibold)))
                    .tracking(PanelTheme.pick(-0.2, -0.3, -0.4))
                Text(subtitle).font(.system(size: PanelTheme.pick(13, 13, 12.5))).foregroundStyle(CompanionStyle.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460).padding(.top, 6)
                content.padding(.top, 24)
                Spacer(minLength: 0)
                Spacer(minLength: 0).frame(maxHeight: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(model.reducedMotion ? AnyTransition.opacity
                        : AnyTransition(.blurReplace).combined(with: .scale(scale: 0.985, anchor: .top)))
            footer
        }
        .animation(model.reducedMotion ? nil : .smooth(duration: 0.34), value: step)
        .padding(.bottom, 2)
        .task(id: checks) {
            let found = RuntimeKind.allCases.compactMap { runtime in
                runtime.installationPath.map { (runtime: runtime, path: $0) }
            }
            installed = found
            if !found.contains(where: { $0.runtime == model.defaultRuntime }), let first = found.first {
                model.chooseWelcomeRuntime(first.runtime)
            }
        }
    }

    private var noAgent: Bool { installed?.isEmpty == true }

    private var title: String {
        switch step {
        case 0: return noAgent ? "Install an agent" : "Choose your agent"
        case 1: return "Pick a companion"
        case 2: return "How should updates appear?"
        default: return "Final touches"
        }
    }

    private var subtitle: String {
        switch step {
        case 0: return noAgent ? "No supported agent was found on this Mac. Install one, then check again."
            : "Found on this Mac. You can switch any time in Settings."
        case 1: return "It rests as eyes beside the notch and comes out when it opens."
        case 2: return "Choose one to see a sample on your notch."
        default: return "New sessions start in this folder. Both can be changed in Settings."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: agent
        case 1: look
        case 2: updates
        default: start
        }
    }

    // MARK: Agent

    @ViewBuilder private var agent: some View {
        if let installed, installed.isEmpty {
            VStack(spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(112), spacing: 8), count: 4), spacing: 8) {
                    ForEach(RuntimeKind.allCases.filter { $0.setupURL != nil }) { runtime in
                        Button { NSWorkspace.shared.open(runtime.setupURL!) } label: {
                            HStack(spacing: 5) {
                                Text(runtime.title).lineLimit(1)
                                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(CompanionStyle.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NotchPillButtonStyle(height: 30))
                        .help("Open \(runtime.title)’s setup instructions")
                        .accessibilityLabel("\(runtime.title) setup instructions")
                    }
                }
                Button { checks += 1 } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    .buttonStyle(NotchPillButtonStyle(height: 28))
            }
        } else {
            let rows = installed ?? []
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.runtime) { index, row in
                        if index > 0 {
                            Rectangle().fill(PanelTheme.pick(Color.white.opacity(0.06), CompanionStyle.separator, Color.white.opacity(0.08)))
                                .frame(height: 0.5).padding(.leading, PanelTheme.pick(72, 72, 0))
                        }
                        agentRow(row.runtime, path: row.path)
                    }
                }
                .background(PanelTheme.pick(Color.white.opacity(0.045), CompanionStyle.fill, Color.black.opacity(0.25)))
                .clipShape(RoundedRectangle(cornerRadius: listRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: listRadius, style: .continuous)
                    .strokeBorder(PanelTheme.pick(CompanionStyle.hairline, Color.white.opacity(0.06), CompanionStyle.rule), lineWidth: 0.5))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 420)
            .frame(maxHeight: 290)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var listRadius: CGFloat { PanelTheme.pick(CompanionStyle.Radius.card, 12, CompanionStyle.cardRadius) }

    private func agentRow(_ runtime: RuntimeKind, path: String) -> some View {
        let selected = model.defaultRuntime == runtime
        return Button { model.chooseWelcomeRuntime(runtime) } label: {
            HStack(spacing: 12) {
                if PanelTheme.current == .instrument {
                    ChoiceMark(selected: selected, round: true)
                } else {
                    ZStack {
                        Circle().strokeBorder(selected ? Color.clear : PanelTheme.pick(CompanionStyle.faint, Color.white.opacity(0.28), CompanionStyle.faint),
                                              lineWidth: PanelTheme.pick(1.2, 1, 1.2))
                        // Refined: selection lights white like the eyes; sage stays on Continue.
                        if selected {
                            Circle().fill(PanelTheme.pick(CompanionStyle.text, CompanionStyle.accent, CompanionStyle.accent))
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(PanelTheme.pick(CompanionStyle.background, CompanionStyle.onAccent, CompanionStyle.onAccent))
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                AgentLogo(runtime: runtime)
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.title).font(.system(size: 13, weight: .medium)).foregroundStyle(CompanionStyle.text)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(PanelTheme.current == .instrument ? CompanionStyle.mono(10.5) : .system(size: 11))
                        .foregroundStyle(PanelTheme.current == .instrument ? CompanionStyle.secondary : CompanionStyle.secondary.opacity(0.85))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(WelcomeRowStyle(selected: selected))
        .help(path)
        .accessibilityLabel("\(runtime.title), installed at \(path)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Look

    private var look: some View {
        HStack(spacing: 10) {
            tile(selected: model.companionAppearance == .eyes, name: "Eyes", detail: "Just the eyes") {
                model.companionAppearance = .eyes
            } art: { WelcomeEyesArt(reducedMotion: model.reducedMotion) }
            ForEach(Array(MascotCharacter.allCases.enumerated()), id: \.element) { index, mascot in
                let selected = model.companionAppearance == .mascot && model.mascotCharacter == mascot
                tile(selected: selected, name: mascot.label, detail: Self.signature(mascot)) {
                    // Character first, so leaving Eyes brings this one straight in.
                    model.mascotCharacter = mascot
                    model.companionAppearance = .mascot
                } art: {
                    WelcomeMascotArt(character: mascot, lit: selected, side: 146, phase: Double(index + 1) * 1.7,
                                     reducedMotion: model.reducedMotion)
                }
            }
        }
    }

    private static func signature(_ mascot: MascotCharacter) -> String {
        switch mascot {
        case .mote: return "Phases through"
        case .fold: return "Unfolds from paper"
        case .soot: return "Climbs up to peek"
        }
    }

    // MARK: Updates

    private var updates: some View {
        HStack(spacing: 12) {
            ForEach(NotchUpdateStyle.allCases) { style in
                // Every press plays a sample; the panel reopens here when it ends.
                tile(selected: model.updateStyle == style, name: style.label,
                     detail: style == .compact ? "Beside the notch" : "Details and quick replies", artHeight: 150) {
                    model.updateStyle = style
                    model.previewStatusEffect(title: "Sample update")
                } art: { WelcomeUpdateArt(style: style) }
            }
        }
    }

    // MARK: Start

    private var start: some View {
        VStack(spacing: 18) {
            // The companion just chosen, ready to go.
            Group {
                if model.mascotEnabled {
                    WelcomeMascotArt(character: model.mascotCharacter, lit: true, side: 150, phase: 0,
                                     reducedMotion: model.reducedMotion)
                        .id(model.mascotCharacter)
                } else {
                    WelcomeEyesArt(reducedMotion: model.reducedMotion).scaleEffect(1.25)
                }
            }
            .frame(width: 200, height: model.mascotEnabled ? 132 : 64)
            SettingsGroup {
                SettingsRow("Default folder", symbol: "folder.fill", tint: .blue) { DefaultWorkspaceButton(model: model) }
                SettingsRow("Open at login", symbol: "power", tint: .gray, divider: true) { OpenAtLoginToggle(model: model) }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(width: 420)
        }
    }

    // MARK: Shared

    private func tile<Art: View>(selected: Bool, name: String, detail: String, artHeight: CGFloat = 176,
                                 action: @escaping () -> Void, @ViewBuilder art: () -> Art) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                art().frame(maxWidth: .infinity).frame(height: artHeight).clipped()
                VStack(spacing: PanelTheme.pick(2, 2, 4)) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(CompanionStyle.text)
                    if PanelTheme.current == .instrument {
                        Text(detail).microLabel(8.5, weight: .regular, tracking: 0.5).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                    } else {
                        Text(detail).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .buttonStyle(WelcomeTileStyle(selected: selected))
        .accessibilityLabel("\(name), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: PanelTheme.pick(5, 5, 3)) {
                ForEach(0..<Self.steps, id: \.self) { index in
                    switch PanelTheme.current {
                    case .refined:
                        Capsule().fill(index == step ? CompanionStyle.text : index < step ? CompanionStyle.secondary : CompanionStyle.faint.opacity(0.7))
                            .frame(width: index == step ? 16 : 6, height: 6)
                    case .tahoe:
                        Circle().fill(index == step ? CompanionStyle.text : CompanionStyle.faint)
                            .frame(width: 7, height: 7)
                    case .instrument:
                        Rectangle().fill(index == step ? CompanionStyle.text : index < step ? CompanionStyle.secondary : Color.white.opacity(0.16))
                            .frame(width: index == step ? 18 : 10, height: 3)
                    }
                }
            }
            .animation(model.reducedMotion ? nil : CompanionStyle.spring, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(Self.steps)")
            Spacer(minLength: 0)
            Group {
                if PanelTheme.current == .instrument {
                    Button("Back") { model.page = .welcome(step: step - 1) }
                        .buttonStyle(NotchTextButtonStyle())
                        .microLabel(10.5, tracking: 0.8)
                } else {
                    Button("Back") { model.page = .welcome(step: step - 1) }
                        .buttonStyle(NotchTextButtonStyle())
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(CompanionStyle.secondary)
            .opacity(step > 0 ? 1 : 0).disabled(step == 0)
            Button { next() } label: { Text(step == Self.steps - 1 ? "Done" : "Continue").frame(minWidth: PanelTheme.pick(72, 84, 72)) }
                .buttonStyle(NotchPillButtonStyle(prominent: true, height: PanelTheme.pick(30, 32, 30)))
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 32)
    }

    private func next() {
        // Connect the chosen agent now, as Check connection would, so it is ready to use.
        if step == 0, installed?.contains(where: { $0.runtime == model.defaultRuntime }) == true {
            let runtime = model.defaultRuntime
            Task { await model.connectRuntime(runtime) }
        }
        if step == Self.steps - 1 { model.finishWelcome() } else { model.page = .welcome(step: step + 1) }
    }
}

/// A selectable card: lifts on hover, presses in, and wears a warm white ring when chosen.
private struct WelcomeTileStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View { WelcomeTileBody(configuration: configuration, selected: selected) }
}

private struct WelcomeTileBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = PanelTheme.current
        let shape = RoundedRectangle(cornerRadius: theme == .instrument ? CompanionStyle.cardRadius : 14, style: .continuous)
        configuration.label
            .background(Color.white.opacity(PanelTheme.pick(selected ? 0.075 : hovering ? 0.06 : 0.035,
                                                            selected ? 0.08 : hovering ? 0.065 : 0.045,
                                                            selected ? 0.05 : hovering ? 0.04 : 0.015)), in: shape)
            .clipShape(shape)
            .overlay {
                switch theme {
                case .refined:
                    shape.strokeBorder(selected ? CompanionStyle.text.opacity(0.9) : Color.white.opacity(hovering ? 0.14 : 0.07),
                                       lineWidth: selected ? 1.5 : 0.5)
                case .tahoe:
                    shape.strokeBorder(Color.white.opacity(hovering ? 0.14 : 0.07), lineWidth: 0.5)
                case .instrument:
                    shape.strokeBorder(selected ? CompanionStyle.text : hovering ? CompanionStyle.ruleStrong : CompanionStyle.rule,
                                       lineWidth: selected ? 1 : 0.5)
                }
            }
            // Tahoe: the chosen tile wears an accent ring with a gap, like the Appearance picker.
            .overlay {
                if selected && theme == .tahoe {
                    RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(CompanionStyle.accent, lineWidth: 2.5)
                        .padding(-4)
                }
            }
            .overlay(alignment: .topLeading) { if selected && theme == .instrument { Reticle(arm: 7).padding(6).opacity(0.9) } }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : CompanionStyle.press, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.18), value: selected)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}

/// A row in an inset list: a faint highlight on hover and when chosen.
private struct WelcomeRowStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View { WelcomeRowBody(configuration: configuration, selected: selected) }
}

private struct WelcomeRowBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : selected ? 0.05 : hovering ? 0.035 : 0))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}

/// The resting look: the white eyes in a small black notch band, blinking.
private struct WelcomeEyesArt: View {
    var reducedMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reducedMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let band = CGRect(x: size.width / 2 - 34, y: size.height / 2 - 15, width: 68, height: 30)
                context.fill(Path(roundedRect: band, cornerRadius: 15, style: .continuous), with: .color(.black))
                context.stroke(Path(roundedRect: band, cornerRadius: 15, style: .continuous),
                               with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                var face = context
                face.translateBy(x: size.width / 2, y: size.height / 2)
                face.scaleBy(x: 1.45, y: 1.45)
                EyesDrawing(expansion: 1, mood: .ready, previousMood: .ready, sinceMood: 100, sinceGlance: 100, sinceChomp: 100,
                            time: time, feeding: 0, pointer: .zero,
                            blink: reducedMotion ? 0 : CGFloat(MascotMotion.blinkAmount(at: time + 0.9)), reducedMotion: reducedMotion)
                    .draw(in: face, expanded: true)
            }
        }
    }
}

/// A mascot idling with live eyes on its face, standing in a soft pool of light.
/// Its own library, so showing all three never trims the header's mascot.
private struct WelcomeMascotArt: View {
    let character: MascotCharacter
    var lit: Bool
    var side: CGFloat
    var phase: Double
    var reducedMotion: Bool
    @StateObject private var library: MascotLibrary

    init(character: MascotCharacter, lit: Bool, side: CGFloat, phase: Double, reducedMotion: Bool) {
        self.character = character
        self.lit = lit
        self.side = side
        self.phase = phase
        self.reducedMotion = reducedMotion
        _library = StateObject(wrappedValue: {
            let library = MascotLibrary(character.rawValue)
            library.maxDecodedSheets = 1
            return library
        }())
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reducedMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let feet = proxy.size.height - 0.12 * side
                let frames = library.clips["idle"]?.frames ?? 1
                let index = reducedMotion ? 0 : Int((time + phase) * library.fps) % max(1, frames)
                MascotDrawing(
                    scene: MascotScene(size: proxy.size, restCenter: .zero, restScale: 1,
                                       figure: CGRect(x: (proxy.size.width - side) / 2, y: feet - library.ground * side,
                                                      width: side, height: side),
                                       reveal: 1, closing: false, spotlight: lit ? PanelTheme.pick(CompanionStyle.accent, IslandStyle.accent, IslandStyle.accent) : .white,
                                       spotlightAmount: lit ? 0.75 : 0.35, ground: library.ground),
                    eyes: EyesDrawing(expansion: 1, mood: .ready, previousMood: .ready, sinceMood: 100, sinceGlance: 100,
                                      sinceChomp: 100, time: time + phase, feeding: 0, pointer: .zero,
                                      blink: reducedMotion ? 0 : CGFloat(MascotMotion.blinkAmount(at: time + phase)),
                                      reducedMotion: reducedMotion),
                    frame: .init(clip: "idle", index: index), fading: nil, library: library)
            }
        }
        .opacity(library.isAvailable ? 1 : 0)
    }
}

/// A drawing of the top of a screen with the notch showing a finished turn:
/// extended beside the camera (Compact), or opened into a popup (Popup).
private struct WelcomeUpdateArt: View {
    let style: NotchUpdateStyle
    /// Refined and Tahoe: the finished green the real announcement and aura use.
    private var done: Color { PanelTheme.current == .instrument ? IslandStyle.accent : IslandStyle.indicatorColor(.finished) }

    var body: some View {
        ZStack(alignment: .top) {
            // A quiet desktop under a menu bar.
            LinearGradient(colors: [Color(red: 0.25, green: 0.29, blue: 0.27), Color(red: 0.13, green: 0.15, blue: 0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [PanelTheme.pick(done.opacity(0.12), CompanionStyle.accent.opacity(0.16), IslandStyle.accent.opacity(0.16)), .clear],
                           center: UnitPoint(x: 0.8, y: 1.05),
                           startRadius: 0, endRadius: 170)
            Rectangle().fill(Color.black.opacity(0.28)).frame(height: 16)
            if style == .compact { compact } else { popup }
        }
    }

    private var eyes: some View {
        HStack(spacing: 3.5) {
            Capsule().fill(Color(white: 0.97)).frame(width: 3.6, height: 7.5)
            Capsule().fill(Color(white: 0.97)).frame(width: 3.6, height: 7.5)
        }
    }

    private var compact: some View {
        HStack(spacing: 0) {
            eyes.frame(width: 30)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 9.5)).foregroundStyle(done)
                Text("Done").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(CompanionStyle.text)
                Text("Fix flaky tests").font(.system(size: 9.5)).foregroundStyle(CompanionStyle.secondary)
            }
            .padding(.trailing, 12)
        }
        .frame(width: 186, height: 26)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
        .overlay(alignment: .bottom) {
            // The edge light that accompanies an update.
            Capsule().fill(done.opacity(0.9)).frame(width: 130, height: 1.5).blur(radius: 2).offset(y: 2.5)
        }
    }

    private var popup: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyes.padding(.leading, 14).frame(height: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 9.5)).foregroundStyle(done)
                    Text("Done · Codex").font(.system(size: 9.5, weight: .medium)).foregroundStyle(CompanionStyle.secondary)
                }
                Text("Fix flaky tests").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(CompanionStyle.text)
                Text("All 42 tests pass on the last run.").font(.system(size: 9.5)).foregroundStyle(CompanionStyle.secondary)
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .frame(width: 214, height: 104, alignment: .topLeading)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous))
    }
}
