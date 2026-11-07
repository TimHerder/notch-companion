import SwiftUI
import AppKit

/// Where a message goes, in the composer's bar: a draft's harness, the folder
/// and, on secondary pages, the session.
struct ComposerDestinationView: View {
    @ObservedObject var model: AppModel
    var showsTitle = false

    var body: some View {
        HStack(spacing: PanelTheme.pick(2, 6, 6)) {
            sessionControls
            WorkspaceButton(model: model)
            if showsTitle, model.current?.isLegacyPrivate != true {
                // After the model label, the session's name gives way before the harness and folder.
                destinationTitle(model.current?.title ?? "New session").layoutPriority(-1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func destinationTitle(_ title: String) -> some View {
        Group {
            switch PanelTheme.current {
            case .refined:
                Label(title, systemImage: "bubble.left").labelStyle(DestinationLabelStyle())
                    .font(CompanionStyle.callout).foregroundStyle(CompanionStyle.tertiary).padding(.horizontal, 8)
            case .tahoe:
                Label(title, systemImage: "bubble.left").labelStyle(DestinationLabelStyle())
                    .font(.system(size: 12)).foregroundStyle(CompanionStyle.secondary).padding(.horizontal, 4)
            case .instrument:
                HStack(spacing: 6) {
                    Text("To").microLabel(9.5).foregroundStyle(CompanionStyle.faint)
                    Text(title).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
                }.padding(.horizontal, 4)
            }
        }
        .lineLimit(1)
        .help("Messages and attachments go to \(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Message \(title)")
    }

    @ViewBuilder private var sessionControls: some View {
        if let session = model.current {
            SessionRuntimeControl(model: model, session: session)
            if session.isLegacyPrivate {
                ContinueLegacySessionButton(model: model, session: session)
            }
        }
        if model.current?.isArchived == true, let id = model.currentID {
            Button { model.restoreSession(id) } label: {
                // A tight bar keeps the icon rather than an empty pill.
                ViewThatFits(in: .horizontal) {
                    Label("Restore archived session", systemImage: "tray.and.arrow.up").lineLimit(1)
                    Image(systemName: "tray.and.arrow.up")
                }
            }
            .buttonStyle(NotchPillButtonStyle(small: true))
            .help("Restore this conversation to your sessions")
            .accessibilityLabel("Restore archived session")
        }
    }
}

/// Refined: the destination's icon and name, at the toolbar's icon scale.
private struct DestinationLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.imageScale(.small); configuration.title }
    }
}

private extension View {
    /// Refined's quiet toolbar control; the other designs' small pill.
    @ViewBuilder func destinationButtonStyle() -> some View {
        if PanelTheme.current == .refined { buttonStyle(NotchToolbarButtonStyle()) }
        else { buttonStyle(NotchPillButtonStyle(small: true)) }
    }
}

/// A draft chooses its working folder; a started session's folder is fixed
/// by its native session, so the same button shows it in Finder.
private struct WorkspaceButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let path = model.currentWorkspacePath
        let choosing = model.canChooseCurrentWorkspace
        Button {
            if choosing { model.chooseSessionWorkspace() }
            else { model.openExternally(URL(fileURLWithPath: path, isDirectory: true)) }
        } label: {
            HStack(spacing: 5) {
                if PanelTheme.current == .refined {
                    Image(systemName: "folder").imageScale(.small)
                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                } else {
                    Label(URL(fileURLWithPath: path).lastPathComponent,
                          systemImage: PanelTheme.current == .tahoe ? "folder.fill" : "folder").lineLimit(1).truncationMode(.middle)
                }
                if choosing { Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold)) }
            }
            // A long folder name stops here, so the model, the gauge and Send keep their room.
            .frame(maxWidth: 150)
        }
        .destinationButtonStyle()
        .help(choosing ? "Choose this session’s working folder · \(path)" : "Show this session’s working folder in Finder · \(path)")
        .accessibilityLabel(choosing ? "Working folder, \(path)" : "Show this session’s working folder in Finder, \(path)")
        .accessibilityHint(choosing ? "Choose another folder for this new session" : "")
    }
}

/// Runtime choice belongs to a draft. A saved conversation always keeps its
/// native identity, so changing the default cannot move it between agents.
struct SessionRuntimeControl: View {
    @ObservedObject var model: AppModel
    var session: CompanionSession
    @State private var choosingRuntime = false
    @StateObject private var popupDismissal = PopupDismissalMonitor()

    init(model: AppModel, session: CompanionSession, choosingRuntime: Bool = false) {
        self.model = model
        self.session = session
        _choosingRuntime = State(initialValue: choosingRuntime)
    }

    var body: some View {
        if model.canChangeRuntime(session.id) {
            if model.readyRuntimes.isEmpty {
                Button("Connect a harness in Settings") { model.page = .settings }
                    .destinationButtonStyle()
            } else {
                Button { choosingRuntime.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(model.readyRuntimes.contains(session.runtime) ? session.runtime.title : "Choose harness").lineLimit(1)
                        Image(systemName: choosingRuntime ? "chevron.up" : "chevron.down")
                            .font(PanelTheme.current == .instrument ? .system(size: 7.5, weight: .bold) : .system(size: 8, weight: .semibold))
                    }
                }
                .destinationButtonStyle()
                .accessibilityLabel("Choose harness for this new session")
                .accessibilityValue(model.readyRuntimes.contains(session.runtime) ? session.runtime.title : "None selected")
                .accessibilityHint(choosingRuntime ? "Close harness choices" : "Show configured harnesses")
                .help("Choose a harness configured in Settings")
                .background(PopupDismissalRegion(monitor: popupDismissal))
                .overlay(alignment: .bottomLeading) {
                    if choosingRuntime { runtimeChoices }
                }
                .onChange(of: model.currentID) { _, _ in choosingRuntime = false }
                .onChange(of: model.page) { _, _ in choosingRuntime = false }
                .onChange(of: model.expanded) { _, expanded in if !expanded { choosingRuntime = false } }
                .onChange(of: model.readyRuntimes) { _, _ in choosingRuntime = false }
                .onChange(of: choosingRuntime, initial: true) { _, presented in
                    if presented {
                        popupDismissal.start { choosingRuntime = false }
                    } else { popupDismissal.stop() }
                }
                .onDisappear { popupDismissal.stop() }
            }
        } else if session.isLegacyPrivate || PanelTheme.current != .tahoe {
            // Tahoe names a started session's harness in its placeholder ("Ask Codex…") alone;
            // the placeholder hides behind a draft or the busy hint, so the others keep the label.
            fixedRuntime
                .help(session.isLegacyPrivate
                      ? "This conversation uses the companion’s earlier private Hermes profile."
                      : "\(session.runtime.title) · \(session.profileID ?? "Existing local profile")")
        }
    }

    /// Truncates rather than holding its width, so a tight bar keeps the gauge and Send in the field.
    @ViewBuilder private var fixedRuntime: some View {
        let title = session.isLegacyPrivate ? "Legacy Hermes" : session.runtime.title
        switch PanelTheme.current {
        case .refined:
            Text(title)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(CompanionStyle.secondary)
                .lineLimit(1).padding(.horizontal, 8)
        case .tahoe:
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        case .instrument:
            HStack(spacing: 6) {
                Rectangle().fill(CompanionStyle.text).frame(width: 5, height: 5)
                Text(title).microLabel(10, weight: .semibold).lineLimit(1)
            }
                .foregroundStyle(CompanionStyle.secondary)
        }
    }

    private func choose(_ runtime: RuntimeKind) {
        model.chooseReadyRuntime(runtime, for: session.id)
        choosingRuntime = false
    }

    @ViewBuilder private var runtimeChoices: some View {
        switch PanelTheme.current {
        case .refined:
            VStack(spacing: 2) {
                ForEach(model.readyRuntimes) { runtime in
                    Button { choose(runtime) } label: {
                        HStack(spacing: 8) {
                            Text(runtime.title)
                            Spacer(minLength: 0)
                            if session.runtime == runtime { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                        }
                        .font(CompanionStyle.callout).padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NotchRowButtonStyle(cornerRadius: 8))
                    .accessibilityAddTraits(session.runtime == runtime ? .isSelected : [])
                }
            }
            .padding(6).frame(width: 196)
            .notchPopover()
            .background(PopupDismissalRegion(monitor: popupDismissal))
            .offset(y: -36)
        case .tahoe:
            VStack(spacing: 2) {
                ForEach(model.readyRuntimes) { runtime in
                    Button { choose(runtime) } label: {
                        HStack(spacing: 8) {
                            Text(runtime.title)
                            Spacer(minLength: 0)
                            if session.runtime == runtime { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.accent) }
                        }
                        .font(.system(size: 13)).padding(.horizontal, 9).frame(height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NotchRowButtonStyle(cornerRadius: 7))
                    .accessibilityAddTraits(session.runtime == runtime ? .isSelected : [])
                }
            }
            .padding(5).frame(width: 196)
            .notchPopover(cornerRadius: 12)
            .background(PopupDismissalRegion(monitor: popupDismissal))
            .offset(y: -30)
        case .instrument:
            VStack(spacing: 0) {
                ForEach(Array(model.readyRuntimes.enumerated()), id: \.element) { index, runtime in
                    Button { choose(runtime) } label: {
                        HStack(spacing: 9) {
                            Text(String(format: "%02d", index + 1)).font(CompanionStyle.mono(10)).foregroundStyle(CompanionStyle.faint)
                            Text(runtime.title).font(.system(size: 12.5, weight: .medium))
                            Spacer(minLength: 0)
                            if session.runtime == runtime { LED(color: CompanionStyle.text, size: 6) }
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NotchRowButtonStyle(selected: session.runtime == runtime))
                    .accessibilityAddTraits(session.runtime == runtime ? .isSelected : [])
                }
            }
            .padding(5).frame(width: 188)
            .instrumentPopup()
            .background(PopupDismissalRegion(monitor: popupDismissal))
            .offset(y: -30)
        }
    }
}

struct ContinueLegacySessionButton: View {
    @ObservedObject var model: AppModel
    var session: CompanionSession

    var body: some View {
        Button("Continue in Hermes…") { reviewContinuation() }
            .buttonStyle(NotchPillButtonStyle(small: true))
            // Truncates in the composer's bar instead of pushing the gauge and Send out.
            .lineLimit(1)
            .disabled(session.isBusy || model.submitting)
            .help(session.isBusy ? "Wait for this session and its delegated work to finish."
                  : "Create a separate conversation in your existing Hermes profile with this history attached.")
    }

    private func reviewContinuation() {
        let alert = NSAlert()
        alert.messageText = "Continue in your Hermes profile?"
        alert.informativeText = "A new Hermes draft will include this conversation’s transcript as an attachment, along with your draft and files. Review them before sending. The original conversation stays available in Legacy Hermes."
        alert.addButton(withTitle: "Create Continuation")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        if alert.runAboveNotch() == .alertFirstButtonReturn {
            Task { await model.continueLegacySession(session.id) }
        }
    }
}

struct DeferredOperationBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let operation = model.deferredOperation {
            let row = HStack(spacing: 8) {
                switch PanelTheme.current {
                case .refined: Image(systemName: "clock")
                case .tahoe: Image(systemName: "clock.fill")
                case .instrument: LED(color: CompanionStyle.signal, pulsing: true, size: 5)
                }
                Text(operation.waitingMessage).lineLimit(2)
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelDeferredOperation() }.buttonStyle(NotchPillButtonStyle(small: true))
            }
            if PanelTheme.current == .refined {
                row.foregroundStyle(CompanionStyle.amber)
                    .panelNotice(CompanionStyle.amber)
            } else {
                row.font(.system(size: PanelTheme.pick(11, 12, 11.5))).foregroundStyle(CompanionStyle.amber)
                    .padding(.vertical, 7)
            }
        }
    }
}

struct FailedAgentBanner: View {
    @ObservedObject var model: AppModel
    var onInspect: (() -> Void)? = nil
    var body: some View {
        if let agent = model.currentFailedAgent {
            let row = HStack(spacing: 8) {
                switch PanelTheme.current {
                case .refined:
                    Image(systemName: "exclamationmark.circle")
                    Text("Delegated task needs attention").lineLimit(1)
                case .tahoe:
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("Delegated task needs attention").lineLimit(1)
                case .instrument:
                    LED(color: CompanionStyle.signal, size: 5)
                    Text("Delegated task needs attention").microLabel(10, weight: .semibold).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Review") {
                    model.openFailedAgent()
                    onInspect?()
                }.buttonStyle(NotchPillButtonStyle(small: true)).help("Review \(agent.title)")
            }
            if PanelTheme.current == .refined {
                row.foregroundStyle(CompanionStyle.error)
                    .panelNotice(CompanionStyle.error)
            } else {
                row.font(.system(size: PanelTheme.pick(11, 12, 11))).foregroundStyle(CompanionStyle.error)
                    .padding(.vertical, 7)
            }
        }
    }
}
