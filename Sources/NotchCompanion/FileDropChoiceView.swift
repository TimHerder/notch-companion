import SwiftUI

/// One inset tray under the header lists where the files can go: the session
/// on screen, the most recently active others, then New session. Each row is
/// a drop target; the conversation stays mounted, subdued, behind it.
struct FileDropChoiceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // The same layout the drop is hit-tested with.
        if let choice = model.fileDropChoice, let layout = model.fileDropLayout(rows: choice.targets.count) {
            let tray = layout.trayFrame
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    title(files: choice.fileCount)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: layout.titleHeight, alignment: .top)
                    ForEach(choice.targets, id: \.self) { target in
                        row(target, choice: choice)
                            // Rows meet edge to edge as targets; their surfaces keep a small gap.
                            .padding(.vertical, 2)
                            .frame(height: layout.rowHeight)
                    }
                }
                .padding(layout.inset)
                .frame(width: tray.width, height: tray.height, alignment: .top)
                .background { surface(cornerRadius: layout.cornerRadius) }
                .position(x: tray.midX, y: tray.midY)
                .animation(model.reducedMotion ? nil : .easeOut(duration: 0.12), value: choice.destination)
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .foregroundStyle(CompanionStyle.text)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("File destinations")
        }
    }

    @ViewBuilder private func title(files: Int) -> some View {
        let text = "Attach \(files == 1 ? "file" : "\(files) files") to"
        switch PanelTheme.current {
        case .refined: Text(text).font(CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary)
        case .tahoe: Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary)
        case .instrument: RuleLabel(text)
        }
    }

    private func row(_ target: FileDropDestination, choice: FileDropChoice) -> some View {
        let session: CompanionSession? = {
            if case .session(let id) = target { return model.fileDropSession(id) }
            return nil
        }()
        let isNew = target == .newSession
        let enabled = isNew || session != nil
        let selected = enabled && choice.destination == target
        let isCurrent = session != nil && session?.id == choice.currentSessionID
        let theme = PanelTheme.current
        let shape = RoundedRectangle(cornerRadius: PanelTheme.pick(10, 10, CompanionStyle.radius), style: .continuous)
        let detail = selected ? "Release to attach"
            : isNew ? (model.newSessionRuntimeTitle ?? "")
            : isCurrent ? "Current" : session?.runtime.title ?? "Unavailable"
        return HStack(spacing: 10) {
            if theme == .instrument && isCurrent {
                LED(color: CompanionStyle.text, size: 5).frame(width: 18)
            } else {
                Image(systemName: isNew ? (theme == .tahoe ? "plus.bubble.fill" : "plus.bubble")
                      : (theme == .tahoe ? "text.bubble.fill" : "text.bubble"))
                    .font(.system(size: theme == .tahoe ? 15 : 14, weight: theme == .instrument ? .light : .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected && theme != .instrument ? CompanionStyle.accent : CompanionStyle.secondary)
                    .frame(width: 18)
            }
            Text(isNew ? "New session" : session?.title ?? "Session")
                .font(.system(size: PanelTheme.pick(13, 13, 12.5), weight: .medium))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Group {
                if selected && theme == .instrument {
                    Label(detail, systemImage: "arrow.down.to.line")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(CompanionStyle.onAccent)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(CompanionStyle.text, in: RoundedRectangle(cornerRadius: CompanionStyle.radius))
                } else if selected {
                    Label(detail, systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(CompanionStyle.accent)
                } else {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.tertiary)
                }
            }
            .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            switch theme {
            case .refined, .tahoe:
                shape.fill(selected ? CompanionStyle.accent.opacity(theme == .tahoe ? 0.2 : 0.12) : Color.white.opacity(0.04))
            case .instrument:
                shape.fill(selected ? Color.white.opacity(0.06) : Color.clear)
            }
        }
        .overlay {
            // New session is a dashed well, the Finder's own invitation to drop something new.
            let stroke = selected ? AnyShapeStyle(theme == .instrument ? CompanionStyle.ruleStrong : CompanionStyle.accent.opacity(0.6))
                : AnyShapeStyle(theme == .instrument ? CompanionStyle.rule : Color.white.opacity(0.1))
            shape.strokeBorder(stroke, style: StrokeStyle(lineWidth: selected && theme != .instrument ? 1 : 0.75,
                                                          dash: isNew && !selected ? [4, 3] : []))
        }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        // The harness tells apart sessions that share a title.
        .accessibilityLabel(isNew ? ["New session", model.newSessionRuntimeTitle].compactMap { $0 }.joined(separator: ", ")
                            : [session?.title ?? "Session", session?.runtime.title, isCurrent ? "current session" : nil]
                                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(enabled ? (selected ? "Release to attach" : "Drop target") : "Unavailable")
    }

    @ViewBuilder private func surface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch PanelTheme.current {
        case .refined:
            shape.fill(CompanionStyle.background).shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
        case .tahoe:
            shape.fill(CompanionStyle.surface).shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .overlay(shape.strokeBorder(GlassEdge.gradient(0.16), lineWidth: 0.5))
        case .instrument:
            shape.fill(Color.black).overlay(shape.strokeBorder(CompanionStyle.ruleStrong, lineWidth: 1))
        }
    }
}
