import SwiftUI

/// One inset tray floats above the subdued conversation. Both destinations stay
/// side by side; the underlying views retain their state and reading position.
struct FileDropChoiceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let layout = FileDropLayout(size: proxy.size, headerHeight: model.geometry?.expandedBandHeight ?? 64)
            let tray = layout.trayFrame
            let shape = RoundedRectangle(cornerRadius: layout.cornerRadius, style: .circular)
            let targets = HStack(spacing: 0) {
                ForEach(FileDropDestination.allCases, id: \.self) { destination in
                    if PanelTheme.current == .refined {
                        // Each half of the tray is its own drop zone, inset so the two read
                        // as separate places to put the file.
                        target(destination)
                            .padding(destination == .currentSession ? .leading : .trailing, 10)
                            .padding(destination == .currentSession ? .trailing : .leading, 5)
                            .padding(.vertical, 10)
                            .frame(width: layout.frame(for: destination).width, height: tray.height)
                    } else {
                        target(destination)
                            .frame(width: layout.frame(for: destination).width, height: tray.height)
                    }
                }
            }
            .frame(width: tray.width, height: tray.height)
            Group {
                switch PanelTheme.current {
                case .refined:
                    targets
                        .background(shape.fill(CompanionStyle.background).shadow(color: .black.opacity(0.5), radius: 24, y: 10))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
                case .tahoe:
                    targets
                        .background(CompanionStyle.surface)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(GlassEdge.gradient(0.16), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                case .instrument:
                    let square = RoundedRectangle(cornerRadius: CompanionStyle.cardRadius, style: .continuous)
                    targets
                        .background(Color.black)
                        .clipShape(square)
                        .overlay(square.strokeBorder(CompanionStyle.ruleStrong, lineWidth: 1))
                        .overlay {
                            Rectangle()
                                .fill(CompanionStyle.rule)
                                .frame(width: 0.5, height: tray.height)
                                .accessibilityHidden(true)
                        }
                }
            }
            .position(x: tray.midX, y: tray.midY)
        }
        .foregroundStyle(CompanionStyle.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File destinations")
    }

    private func target(_ destination: FileDropDestination) -> some View {
        let isCurrent = destination == .currentSession
        let session = model.fileDropCurrentSession
        let enabled = !isCurrent || session != nil
        let selected = enabled && model.fileDropChoice?.destination == destination
        let theme = PanelTheme.current
        return VStack(spacing: PanelTheme.pick(16, 18, 20)) {
            icon(isCurrent: isCurrent, selected: selected)
            VStack(spacing: PanelTheme.pick(6, 8, 8)) {
                Text(isCurrent ? "Current session" : "New session")
                    .font(PanelTheme.pick(CompanionStyle.title, .system(size: 15, weight: .semibold), .system(size: 16, weight: .semibold)))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(isCurrent ? (session?.title ?? "No current session") : "Start a separate conversation")
                    .font(theme == .refined ? CompanionStyle.callout : .system(size: 12))
                    .foregroundStyle(CompanionStyle.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 48, alignment: .top)
            }
            hint(enabled: enabled, selected: selected)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(DropZoneSurface(selected: selected))
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(enabled ? (selected ? "Release to attach" : "Drop target") : "Unavailable")
    }

    @ViewBuilder private func icon(isCurrent: Bool, selected: Bool) -> some View {
        switch PanelTheme.current {
        case .refined:
            Image(systemName: isCurrent ? "text.bubble" : "plus.bubble")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(selected ? CompanionStyle.accent : CompanionStyle.secondary)
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(selected ? 0 : 0.05), in: Circle())
                .accessibilityHidden(true)
        case .tahoe:
            Image(systemName: isCurrent ? "text.bubble.fill" : "plus.bubble.fill")
                .font(.system(size: 34)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(selected ? CompanionStyle.accent : CompanionStyle.secondary)
                .frame(height: 44)
                .accessibilityHidden(true)
        case .instrument:
            Image(systemName: isCurrent ? "text.bubble" : "plus.bubble")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(selected ? CompanionStyle.text : CompanionStyle.secondary)
                .frame(width: 64, height: 56)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func hint(enabled: Bool, selected: Bool) -> some View {
        let title = selected ? "Release to attach" : (enabled ? "Drop files here" : "Use New session")
        switch PanelTheme.current {
        case .refined, .tahoe:
            let tahoe = PanelTheme.current == .tahoe
            Label(title, systemImage: enabled ? (selected ? "arrow.down.circle.fill" : "arrow.down.circle") : "arrow.right")
                .font(tahoe ? .system(size: 12, weight: selected ? .semibold : .regular) : .system(size: 11, weight: .medium))
                .foregroundStyle(selected ? CompanionStyle.accent : tahoe ? CompanionStyle.secondary : CompanionStyle.tertiary)
        case .instrument:
            Label(title, systemImage: enabled ? "arrow.down.to.line" : "arrow.right")
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? CompanionStyle.onAccent : CompanionStyle.secondary)
                .padding(.horizontal, 9).frame(height: 22)
                .background(selected ? CompanionStyle.text : Color.clear, in: RoundedRectangle(cornerRadius: CompanionStyle.radius))
                .overlay(RoundedRectangle(cornerRadius: CompanionStyle.radius).strokeBorder(selected ? Color.clear : CompanionStyle.rule, lineWidth: 0.5))
        }
    }
}

/// The fill and edge of one destination in the current design.
private struct DropZoneSurface: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        switch PanelTheme.current {
        case .refined:
            // Concentric with the tray: its radius less the 10-point inset.
            let zone = RoundedRectangle(cornerRadius: 8, style: .continuous)
            content
                .background(selected ? CompanionStyle.accent.opacity(0.1) : Color.white.opacity(0.03), in: zone)
                .overlay(zone.strokeBorder(selected ? CompanionStyle.accent.opacity(0.6) : Color.white.opacity(0.14),
                                           style: StrokeStyle(lineWidth: 1, dash: selected ? [] : [5, 4])))
        case .tahoe:
            let well = RoundedRectangle(cornerRadius: 12, style: .continuous)
            content
                // A dashed drop well, the Finder's own invitation to drop.
                .background(selected ? CompanionStyle.accent.opacity(0.14) : Color.white.opacity(0.03), in: well)
                .overlay(well.strokeBorder(selected ? AnyShapeStyle(CompanionStyle.accent) : AnyShapeStyle(Color.white.opacity(0.2)),
                                           style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: [6, 5])))
                .padding(10)
        case .instrument:
            content
                .background(selected ? Color.white.opacity(0.05) : .clear)
        }
    }
}
