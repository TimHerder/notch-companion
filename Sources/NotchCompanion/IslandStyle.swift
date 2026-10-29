import SwiftUI

/// The notch tiers outside the expanded panel (resting dots, glance, live
/// activity, announcements, aura, mascot stage) keep their own palette and
/// controls, so restyling the panel never changes them.
enum IslandStyle {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.04)
    static let surface = Color(red: 0.105, green: 0.12, blue: 0.11)
    static let text = Color(red: 0.95, green: 0.95, blue: 0.91)
    static let secondary = Color(red: 0.68, green: 0.71, blue: 0.67)
    static let faint = Color(red: 0.43, green: 0.45, blue: 0.42)
    static let accent = Color(red: 0.73, green: 0.82, blue: 0.66)
    static let onAccent = Color(red: 0.063, green: 0.078, blue: 0.055)
    static let controlFill = Color.white.opacity(0.08)
    static let amber = Color(red: 0.95, green: 0.76, blue: 0.43)
    static let error = Color(red: 1, green: 0.57, blue: 0.52)
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.6)
    static func indicatorColor(_ status: CollapsedStatus) -> Color {
        switch status {
        case .running, .waiting: return Color(red: 1.0, green: 0.61, blue: 0.23)
        case .finished: return Color(red: 0.40, green: 0.82, blue: 0.53)
        case .failed: return error
        case .none: return .clear
        }
    }
}

/// The island's circular icon control.
struct IslandIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        IslandIconButtonBody(configuration: configuration, style: self)
    }
}

private struct IslandIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: IslandIconButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hot = hovering && enabled
        let pressed = configuration.isPressed && enabled
        configuration.label
            .font(.system(size: (style.size * 0.46).rounded(), weight: .semibold))
            .foregroundStyle(hot ? IslandStyle.text : IslandStyle.secondary)
            .frame(width: style.size, height: style.size)
            .background {
                ZStack {
                    if style.filled { Color.clear.notchControlBackground(Circle(), fallback: IslandStyle.controlFill) }
                    Circle().fill(Color.white.opacity(pressed ? 0.16 : hot ? 0.09 : 0))
                }
            }
            .contentShape(Circle())
            .scaleEffect(pressed && !reduceMotion ? 0.86 : 1)
            .opacity(enabled ? 1 : 0.35)
            .animation(reduceMotion ? nil : IslandStyle.press, value: pressed)
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}

/// The island's capsule text buttons; `prominent` is its sage primary action.
struct IslandPillButtonStyle: ButtonStyle {
    var prominent = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        IslandPillButtonBody(configuration: configuration, style: self)
    }
}

private struct IslandPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: IslandPillButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hot = hovering && enabled
        let pressed = configuration.isPressed && enabled
        let primary = style.prominent && enabled
        configuration.label
            .font(.system(size: style.small ? 11 : 12, weight: .medium))
            .labelStyle(IslandPillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(primary ? IslandStyle.onAccent
                             : style.prominent ? IslandStyle.secondary
                             : IslandStyle.text.opacity(hot ? 1 : 0.86))
            .padding(.horizontal, style.small ? 9 : 12)
            .frame(height: style.small ? 22 : 26)
            .background {
                Capsule()
                    .fill(primary ? IslandStyle.accent : Color.white.opacity(pressed ? 0.17 : hot ? 0.12 : 0.075))
                    .brightness(primary ? (pressed ? -0.08 : hot ? 0.05 : 0) : 0)
            }
            .overlay { Capsule().strokeBorder(Color.white.opacity(primary ? 0 : 0.07), lineWidth: 0.5) }
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(enabled || style.prominent ? 1 : 0.4)
            .animation(reduceMotion ? nil : IslandStyle.press, value: pressed)
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}

private struct IslandPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The island's full-width rows: a quiet highlight, no scale.
struct IslandRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        IslandRowButtonBody(configuration: configuration, style: self)
    }
}

private struct IslandRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: IslandRowButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let hot = hovering && enabled
        configuration.label
            .contentShape(Rectangle())
            .background(Color.white.opacity(configuration.isPressed && enabled ? 0.11 : hot ? 0.045 : 0),
                        in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hot)
            .onHover { hovering = $0 }
            .pressableCursor()
    }
}
