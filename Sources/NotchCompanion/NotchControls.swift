import AppKit
import SwiftUI

// Controls for the expanded notch in each `PanelTheme`. The island tiers
// keep their own controls in IslandStyle.swift.

// MARK: - Pointer

/// The notch panel never activates this accessory app, and the window server
/// ignores cursor changes from a background app, so AppKit cursor rects and
/// `pointerStyle` alone never show there. Hover regions set the cursor.
@MainActor
enum HoverCursor {
    private static var regions: [(id: UUID, cursor: NSCursor)] = []

    /// The most recently entered region wins, so one control's exit and its
    /// neighbor's entry may arrive in either order.
    static func update(_ id: UUID, cursor: NSCursor?) {
        let previous = regions.last?.cursor
        regions.removeAll { $0.id == id }
        if let cursor { regions.append((id, cursor)) }
        if regions.last?.cursor !== previous { (regions.last?.cursor ?? .arrow).set() }
    }

    static func reset() {
        guard !regions.isEmpty else { return }
        regions.removeAll()
        NSCursor.arrow.set()
    }

    /// `SetsCursorInBackground` is a private window-server connection property.
    /// It is resolved at runtime, so a macOS without it only loses the cursor.
    static func allowInBackground() {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let process = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(process, "_CGSDefaultConnection"),
              let setProperty = dlsym(process, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: Connection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    let style: PointerStyle
    @State private var id = UUID()
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            // Native style for an active app; the hover path covers the panel.
            .pointerStyle(isEnabled ? style : nil)
            .onHover { inside in hovering = inside; apply(inside) }
            .onChange(of: isEnabled) { apply(hovering) }
            .onDisappear { HoverCursor.update(id, cursor: nil) }
    }

    private func apply(_ inside: Bool) {
        HoverCursor.update(id, cursor: inside && isEnabled ? cursor : nil)
    }
}

extension View {
    func pressableCursor() -> some View { modifier(HoverCursorModifier(cursor: .pointingHand, style: .link)) }
    func textCursor() -> some View { modifier(HoverCursorModifier(cursor: .iBeam, style: .horizontalText)) }
}

// MARK: - Buttons

/// A circular icon control (a square key in Instrument). `filled` keeps a
/// visible disc for floating header controls; otherwise the disc appears on
/// hover. `selected` raises the disc (Refined), fills it with the accent
/// (Tahoe) or lights it white (Instrument); `prominent` is the primary
/// action (Send, Stop).
struct NotchIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var filled = false
    var selected = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        NotchIconButtonBody(configuration: configuration, style: self)
    }
}

private struct NotchIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: NotchIconButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hot = hovering && enabled
        let pressed = configuration.isPressed && enabled
        Group {
            switch PanelTheme.current {
            case .refined: refined(hot: hot, pressed: pressed)
            case .tahoe: tahoe(hot: hot, pressed: pressed)
            case .instrument: instrument(hot: hot, pressed: pressed)
            }
        }
            .opacity(enabled || style.prominent ? 1 : 0.35)
            .animation(reduceMotion ? nil : CompanionStyle.press, value: pressed)
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }

    private func refined(hot: Bool, pressed: Bool) -> some View {
        let primary = style.prominent && enabled
        return configuration.label
            .font(.system(size: (style.size * 0.46).rounded(), weight: .semibold))
            .foregroundStyle(primary ? CompanionStyle.onAccent
                             : style.prominent ? CompanionStyle.faint
                             : hot || style.selected ? CompanionStyle.text : CompanionStyle.secondary)
            .frame(width: style.size, height: style.size)
            .background {
                if style.prominent {
                    Circle().fill(primary ? CompanionStyle.accent : Color.white.opacity(0.08))
                        .brightness(primary ? (pressed ? -0.08 : hot ? 0.06 : 0) : 0)
                } else {
                    // Selected is a raised graphite disc: it reads as open
                    // without a second white shape competing with the eyes.
                    ZStack {
                        if style.filled { Color.clear.notchControlBackground(Circle(), fallback: CompanionStyle.controlFill) }
                        Circle().fill(Color.white.opacity(pressed ? 0.2 : style.selected ? 0.15 : hot ? 0.09 : 0))
                    }
                }
            }
            .contentShape(Circle())
            .scaleEffect(pressed && !reduceMotion ? 0.86 : 1)
    }

    private func tahoe(hot: Bool, pressed: Bool) -> some View {
        let primary = style.prominent && enabled
        return configuration.label
            .font(.system(size: (style.size * 0.46).rounded(), weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(style.selected || primary ? CompanionStyle.onAccent
                             : style.prominent ? CompanionStyle.faint
                             : hot ? CompanionStyle.text : CompanionStyle.secondary)
            .frame(width: style.size, height: style.size)
            .background {
                if style.selected || style.prominent {
                    Circle().fill(style.selected || primary ? CompanionStyle.accent : CompanionStyle.controlFill)
                        .brightness(style.selected || primary ? (pressed ? -0.08 : hot ? 0.06 : 0) : 0)
                } else {
                    ZStack {
                        if style.filled {
                            // A lit disc over the glass, like Dynamic Island's controls.
                            Color.clear.notchControlBackground(Circle(), fallback: CompanionStyle.controlFill)
                            Circle().fill(Color.white.opacity(0.1))
                        }
                        Circle().fill(Color.white.opacity(pressed ? 0.18 : hot ? 0.1 : 0))
                    }
                }
            }
            .contentShape(Circle())
            .scaleEffect(pressed && !reduceMotion ? 0.88 : 1)
    }

    private func instrument(hot: Bool, pressed: Bool) -> some View {
        let primary = style.prominent && enabled
        let shape = RoundedRectangle(cornerRadius: CompanionStyle.radius, style: .continuous)
        return configuration.label
            .font(.system(size: (style.size * 0.44).rounded(), weight: .medium))
            .foregroundStyle(style.selected || primary ? CompanionStyle.onAccent
                             : style.prominent ? CompanionStyle.faint
                             : hot ? CompanionStyle.text : CompanionStyle.secondary)
            .frame(width: style.size, height: style.size)
            .background {
                if style.selected {
                    shape.fill(CompanionStyle.text)
                } else if style.prominent {
                    shape.fill(primary ? CompanionStyle.signal : Color.clear)
                        .brightness(primary ? (pressed ? -0.1 : hot ? 0.06 : 0) : 0)
                        .overlay { if !primary { shape.strokeBorder(CompanionStyle.rule, lineWidth: 1) } }
                } else {
                    shape.fill(Color.white.opacity(pressed ? 0.16 : hot ? 0.08 : style.filled ? 0.02 : 0))
                        .overlay { if style.filled { shape.strokeBorder(hot ? CompanionStyle.ruleStrong : CompanionStyle.rule, lineWidth: 0.5) } }
                }
            }
            .contentShape(shape)
            .scaleEffect(pressed && !reduceMotion ? 0.9 : 1)
    }
}

/// Text buttons: capsules (Refined), capsules with a glass edge (Tahoe) or
/// square-cornered keys with tracked SF Mono capitals (Instrument).
/// `prominent` is the primary action; `selected` is a chosen filter chip.
struct NotchPillButtonStyle: ButtonStyle {
    var prominent = false
    var small = false
    var selected = false
    var height: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        NotchPillButtonBody(configuration: configuration, style: self)
    }
}

private struct NotchPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: NotchPillButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hot = hovering && enabled
        let pressed = configuration.isPressed && enabled
        Group {
            switch PanelTheme.current {
            case .refined: refined(hot: hot, pressed: pressed)
            case .tahoe: tahoe(hot: hot, pressed: pressed)
            case .instrument: instrument(hot: hot, pressed: pressed)
            }
        }
            .opacity(enabled || style.prominent ? 1 : 0.4)
            .animation(reduceMotion ? nil : CompanionStyle.press, value: pressed)
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }

    private func refined(hot: Bool, pressed: Bool) -> some View {
        let primary = style.prominent && enabled
        let lit = style.selected && enabled
        return configuration.label
            .font(.system(size: style.small ? 11 : 12, weight: .medium))
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(lit ? CompanionStyle.background
                             : primary ? CompanionStyle.onAccent
                             : style.prominent ? CompanionStyle.secondary
                             : CompanionStyle.text.opacity(hot ? 1 : 0.86))
            .padding(.horizontal, style.small ? 9 : 12)
            .frame(height: style.height ?? (style.small ? 22 : 26))
            .background {
                Capsule()
                    .fill(lit ? CompanionStyle.text
                          : primary ? CompanionStyle.accent
                          : Color.white.opacity(pressed ? 0.17 : hot ? 0.12 : 0.075))
                    .brightness(lit ? (pressed ? -0.12 : hot ? -0.05 : 0)
                                : primary ? (pressed ? -0.08 : hot ? 0.05 : 0) : 0)
            }
            .overlay { Capsule().strokeBorder(Color.white.opacity(primary || lit ? 0 : 0.07), lineWidth: 0.5) }
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
    }

    private func tahoe(hot: Bool, pressed: Bool) -> some View {
        let tinted = (style.prominent || style.selected) && enabled
        return configuration.label
            .font(.system(size: style.small ? 11.5 : 13, weight: .medium))
            .labelStyle(PillLabelStyle())
            .symbolRenderingMode(.hierarchical)
            .lineLimit(1)
            .foregroundStyle(tinted ? CompanionStyle.onAccent
                             : style.prominent ? CompanionStyle.secondary
                             : CompanionStyle.text.opacity(hot ? 1 : 0.9))
            .padding(.horizontal, style.small ? 10 : 14)
            .frame(height: style.height ?? (style.small ? 24 : 30))
            .background {
                Capsule()
                    .fill(tinted ? CompanionStyle.accent
                          : Color.white.opacity(pressed ? 0.2 : hot ? 0.15 : 0.1))
                    .brightness(tinted ? (pressed ? -0.08 : hot ? 0.06 : 0) : 0)
            }
            .overlay { Capsule().strokeBorder(GlassEdge.gradient(tinted ? 0.22 : 0.12), lineWidth: 0.5) }
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
    }

    private func instrument(hot: Bool, pressed: Bool) -> some View {
        let primary = style.prominent && enabled
        let lit = style.selected && enabled
        let shape = RoundedRectangle(cornerRadius: CompanionStyle.radius, style: .continuous)
        return configuration.label
            .microLabel(style.small ? 10 : 10.5, tracking: 0.6)
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(lit || primary ? CompanionStyle.onAccent
                             : style.prominent ? CompanionStyle.faint
                             : CompanionStyle.text.opacity(hot ? 1 : 0.88))
            .padding(.horizontal, style.small ? 8 : 11)
            .frame(height: style.height ?? (style.small ? 22 : 26))
            .background {
                shape.fill(lit ? CompanionStyle.text
                           : primary ? CompanionStyle.signal
                           : Color.white.opacity(pressed ? 0.14 : hot ? 0.08 : 0.025))
                    .brightness(lit ? (pressed ? -0.12 : hot ? -0.05 : 0)
                                : primary ? (pressed ? -0.1 : hot ? 0.06 : 0) : 0)
            }
            .overlay { shape.strokeBorder(primary || lit ? Color.clear : hot ? CompanionStyle.ruleStrong : CompanionStyle.rule, lineWidth: 0.5) }
            .contentShape(shape)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
    }
}

/// Tahoe: the light catching a glass control's upper edge.
enum GlassEdge {
    static func gradient(_ top: Double) -> LinearGradient {
        LinearGradient(colors: [Color.white.opacity(top), Color.white.opacity(top * 0.25)], startPoint: .top, endPoint: .bottom)
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Refined: a quiet control for toolbars and secondary actions in the open
/// panel: no fill at rest, a soft rounded highlight on hover, secondary
/// until hovered.
struct NotchToolbarButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var weight: Font.Weight = .medium

    func makeBody(configuration: Configuration) -> some View {
        NotchToolbarButtonBody(configuration: configuration, style: self)
    }
}

private struct NotchToolbarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: NotchToolbarButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let hot = hovering && enabled
        let pressed = configuration.isPressed && enabled
        configuration.label
            .font(.system(size: 12, weight: style.weight))
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(hot ? CompanionStyle.text : CompanionStyle.secondary)
            .padding(.horizontal, 8)
            .frame(height: style.height)
            .background(RoundedRectangle(cornerRadius: min(8, style.height / 3), style: .continuous)
                .fill(Color.white.opacity(pressed ? 0.12 : hot ? 0.07 : 0)))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}

/// Full-width rows (sessions, delegated agents, menu choices): a quiet
/// highlight, no scale; Instrument adds a white cursor bar at the leading
/// edge of the selected row. A row inside an already highlighted group can
/// turn its hover off.
struct NotchRowButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = PanelTheme.pick(10, 10, CompanionStyle.radius)
    var highlightsHover = true

    func makeBody(configuration: Configuration) -> some View {
        NotchRowButtonBody(configuration: configuration, style: self)
    }
}

private struct NotchRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: NotchRowButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let hot = hovering && enabled && style.highlightsHover
        let pressed = configuration.isPressed && enabled
        // Pressed, selected and hover fills.
        let fill = PanelTheme.pick((0.11, 0.09, 0.045), (0.14, 0.1, 0.06), (0.1, 0.06, 0.035))
        configuration.label
            .contentShape(Rectangle())
            .background(Color.white.opacity(pressed ? fill.0 : style.selected ? fill.1 : hot ? fill.2 : 0),
                        in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .overlay(alignment: .leading) {
                if style.selected && PanelTheme.current == .instrument {
                    Rectangle().fill(CompanionStyle.text).frame(width: 2).padding(.vertical, 6)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}

/// Text that acts as a control (the page title, disclosure labels): the
/// highlight extends past the text so it stays aligned to its margin.
struct NotchTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotchTextButtonBody(configuration: configuration)
    }
}

private struct NotchTextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let hot = hovering && enabled
        let pressed = configuration.isPressed && enabled
        // Pressed and hover fills, corner radius and outset.
        let look = PanelTheme.pick((0.11, 0.06, CGFloat(7), CGFloat(7)), (0.12, 0.07, 7, 7), (0.1, 0.055, CompanionStyle.radius, 6))
        configuration.label
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: look.2, style: .continuous)
                    .fill(Color.white.opacity(pressed ? look.0 : hot ? look.1 : 0))
                    .padding(.horizontal, -look.3).padding(.vertical, -3)
            }
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}

// MARK: - Surfaces

extension View {
    /// Opaque menus that rise over the transcript, like a native menu.
    /// Refined always uses its card radius; Instrument has `instrumentPopup()`.
    func notchPopover(cornerRadius: CGFloat = 14) -> some View {
        Group {
            if PanelTheme.current == .refined {
                let shape = RoundedRectangle(cornerRadius: CompanionStyle.Radius.card, style: .continuous)
                // The shadow belongs to the surface alone, never to the text on it.
                background(shape.fill(CompanionStyle.popover).shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            } else {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                background(CompanionStyle.elevated, in: shape)
                    .overlay(shape.strokeBorder(GlassEdge.gradient(0.16), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 8)
            }
        }
    }

    /// Tahoe: a grouped-list section or card, Apple's gray fill and a hairline edge.
    func notchGroup(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(CompanionStyle.fill, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    /// Tahoe: scrolling content fades out under the header (and, with
    /// `bottom`, above the composer) instead of being cut, like a system scroll edge.
    func softTopEdge(_ height: CGFloat = 12, bottom: CGFloat = 0) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: height)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
            }
        }
    }
}

/// Tahoe: a System Settings row icon, a white symbol on a small rounded tile.
struct SettingsIcon: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Selection

/// A segmented control whose chosen thumb slides to the choice: a graphite
/// capsule (Refined), a raised gray capsule (Tahoe) or a lit white key
/// (Instrument). Plain buttons, no menu tracking, so 60 Hz redraws cannot
/// disturb it.
struct NotchSegmentedControl<Value: Hashable>: View {
    var label: String
    var options: [Value]
    var title: (Value) -> String
    @Binding var selection: Value
    var small = false
    /// What VoiceOver reads when the visible titles are abbreviated.
    var spoken: ((Value) -> String)? = nil
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: { Text(title(option)) }
                    .buttonStyle(SegmentButtonStyle(selected: option == selection, small: small, thumb: thumb))
            }
        }
        .padding(2)
        .background { track }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: selection)
        .fixedSize()
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { Text((spoken ?? title)($0)).tag($0) }
            }.pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var track: some View {
        switch PanelTheme.current {
        case .refined:
            Capsule().fill(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        case .tahoe:
            Capsule().fill(CompanionStyle.controlFill)
        case .instrument:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.radius, style: .continuous)
            shape.fill(Color.white.opacity(0.02))
                .overlay(shape.strokeBorder(CompanionStyle.rule, lineWidth: 0.5))
        }
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    var selected: Bool
    var small: Bool
    var thumb: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, style: self)
    }
}

private struct SegmentBody: View {
    let configuration: ButtonStyleConfiguration
    let style: SegmentButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hot = hovering && enabled && !style.selected
        let pressed = configuration.isPressed && enabled && !reduceMotion
        Group {
            if PanelTheme.current == .instrument {
                let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
                configuration.label
                    .microLabel(style.small ? 9.5 : 10, tracking: 0.6)
                    .lineLimit(1)
                    .foregroundStyle(style.selected ? CompanionStyle.onAccent
                                     : hot ? CompanionStyle.text : CompanionStyle.secondary)
                    .scaleEffect(pressed ? 0.95 : 1)
                    .padding(.horizontal, style.small ? 8 : 10)
                    .frame(height: style.small ? 18 : 21)
                    .background {
                        if style.selected {
                            shape.fill(CompanionStyle.text)
                                .matchedGeometryEffect(id: "thumb", in: style.thumb)
                        } else if hot {
                            shape.fill(Color.white.opacity(0.06))
                        }
                    }
                    .contentShape(shape)
            } else {
                let tahoe = PanelTheme.current == .tahoe
                configuration.label
                    .font(.system(size: style.small ? 11 : 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(style.selected ? CompanionStyle.text
                                     : CompanionStyle.secondary.opacity(hot ? 1 : tahoe ? 0.9 : 0.85))
                    .scaleEffect(pressed ? 0.94 : 1)
                    .padding(.horizontal, style.small ? 9 : 11)
                    .frame(height: style.small ? 18 : 22)
                    .background {
                        if style.selected {
                            Capsule()
                                .fill(tahoe ? Color(white: 0.4).opacity(0.75) : Color.white.opacity(0.17))
                                .overlay(Capsule().strokeBorder(tahoe ? GlassEdge.gradient(0.22) : LinearGradient(
                                    colors: [Color.white.opacity(0.2), Color.white.opacity(0.03)],
                                    startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
                                .shadow(color: .black.opacity(tahoe ? 0.3 : 0.35), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: style.thumb)
                        } else if hot {
                            Capsule().fill(Color.white.opacity(tahoe ? 0.06 : 0.05))
                        }
                    }
                    .contentShape(Capsule())
            }
        }
            .opacity(enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : CompanionStyle.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .pressableCursor()
            .accessibilityAddTraits(style.selected ? .isSelected : [])
    }
}

/// On is lit white with a dark knob (Refined), the macOS accent switch
/// (Tahoe), or a square slide switch with a black key (Instrument).
struct NotchSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotchSwitch(configuration: configuration)
    }
}

private struct NotchSwitch: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let on = configuration.isOn
        let hot = hovering && enabled
        Button { configuration.isOn.toggle() } label: {
            switch PanelTheme.current {
            case .refined:
                Capsule()
                    .fill(on ? CompanionStyle.text : Color.white.opacity(hot ? 0.17 : 0.12))
                    .frame(width: 32, height: 19)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(on ? CompanionStyle.background : Color.white.opacity(0.85))
                            .frame(width: 15, height: 15)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                            .padding(2)
                    }
                    .contentShape(Capsule())
            case .tahoe:
                Capsule()
                    .fill(on ? AnyShapeStyle(CompanionStyle.accent) : AnyShapeStyle(Color.white.opacity(hot ? 0.2 : 0.15)))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 18, height: 16)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                            .padding(2)
                    }
                    .contentShape(Capsule())
            case .instrument:
                let shape = RoundedRectangle(cornerRadius: CompanionStyle.radius, style: .continuous)
                shape
                    .fill(on ? CompanionStyle.text : Color.white.opacity(hot ? 0.07 : 0.03))
                    .overlay { if !on { shape.strokeBorder(hot ? CompanionStyle.ruleStrong : CompanionStyle.rule, lineWidth: 1) } }
                    .frame(width: 32, height: 18)
                    .overlay(alignment: on ? .trailing : .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(on ? CompanionStyle.onAccent : CompanionStyle.secondary)
                            .frame(width: 12, height: 12)
                            .padding(3)
                    }
                    .contentShape(shape)
            }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : PanelTheme.current == .instrument
                   ? .spring(response: 0.26, dampingFraction: 0.8) : .spring(response: 0.28, dampingFraction: 0.76), value: on)
        .onHover { hovering = $0 }
        .pressableCursor()
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}

/// Multiple-choice answers. The box fills when checked.
struct NotchCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: PanelTheme.pick(8, 9, 9)) {
                ChoiceMark(selected: configuration.isOn, round: false).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                configuration.label.multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressableCursor()
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox) }
    }
}

/// The checkbox or radio mark shared by clarification answers: white
/// (Refined), the accent (Tahoe), or a square box or round lamp (Instrument).
struct ChoiceMark: View {
    var selected: Bool
    var round: Bool

    var body: some View {
        mark
            .animation(.easeOut(duration: 0.12), value: selected)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        switch PanelTheme.current {
        case .refined:
            let shape = RoundedRectangle(cornerRadius: round ? 7.5 : 4.5, style: .continuous)
            shape.fill(selected ? CompanionStyle.text : Color.white.opacity(0.06))
                .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0 : 0.3), lineWidth: 1))
                .overlay {
                    if selected {
                        if round { Circle().fill(CompanionStyle.background).frame(width: 5, height: 5) }
                        else { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(CompanionStyle.background) }
                    }
                }
                .frame(width: 15, height: 15)
        case .tahoe:
            Group {
                if round { tahoeBox(Circle()) } else { tahoeBox(RoundedRectangle(cornerRadius: 4, style: .continuous)) }
            }
                .overlay {
                    if selected {
                        if round { Circle().fill(Color.white).frame(width: 6, height: 6) }
                        else { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                    }
                }
                .frame(width: 16, height: 16)
        case .instrument:
            let shape = round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            shape.fill(selected ? CompanionStyle.text : Color.clear)
                .overlay(shape.stroke(selected ? Color.clear : Color.white.opacity(0.4), lineWidth: 1).padding(0.5))
                .overlay {
                    if selected {
                        if round { Circle().fill(CompanionStyle.onAccent).frame(width: 5, height: 5) }
                        else { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(CompanionStyle.onAccent) }
                    }
                }
                .frame(width: 14, height: 14)
        }
    }

    private func tahoeBox<S: InsettableShape>(_ shape: S) -> some View {
        shape.fill(selected ? AnyShapeStyle(CompanionStyle.accent) : AnyShapeStyle(Color.white.opacity(0.08)))
            .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0 : 0.28), lineWidth: 1))
    }
}

/// A thin slider: a white (Refined) or accent (Tahoe) capsule with a round
/// knob, or a hairline fader with a square cap (Instrument).
struct NotchSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var label: String
    var onEnded: () -> Void = {}
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { proxy in
            let theme = PanelTheme.current
            let knob: CGFloat = PanelTheme.pick(13, 16, 8)
            let travel = max(1, proxy.size.width - knob)
            let span = range.upperBound - range.lowerBound
            let fraction = CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
            ZStack(alignment: .leading) {
                if theme == .instrument {
                    Rectangle().fill(Color.white.opacity(0.16)).frame(height: 2)
                    Rectangle().fill(CompanionStyle.text.opacity(0.9))
                        .frame(width: knob / 2 + travel * fraction, height: 2)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Color.white)
                        .frame(width: knob, height: 16)
                        .overlay(Rectangle().fill(CompanionStyle.onAccent).frame(width: 4, height: 1))
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .scaleEffect(dragging ? 1.12 : hovering && enabled ? 1.05 : 1)
                        .offset(x: travel * fraction)
                } else {
                    Capsule().fill(Color.white.opacity(theme == .tahoe ? 0.15 : 0.14)).frame(height: 4)
                    Capsule().fill(theme == .tahoe ? CompanionStyle.accent : CompanionStyle.text.opacity(0.9))
                        .frame(width: knob / 2 + travel * fraction, height: 4)
                    Circle().fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .scaleEffect(dragging ? 1.18 : hovering && enabled ? 1.08 : 1)
                        .offset(x: travel * fraction)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard enabled else { return }
                    dragging = true
                    let position = Float(min(1, max(0, (drag.location.x - knob / 2) / travel)))
                    value = range.lowerBound + position * span
                }
                .onEnded { _ in
                    guard dragging else { return }
                    dragging = false
                    onEnded()
                })
        }
        .frame(height: 19)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
        .onHover { hovering = $0 }
        .pressableCursor()
        .accessibilityRepresentation { Slider(value: $value, in: range) { Text(label) } }
    }
}
