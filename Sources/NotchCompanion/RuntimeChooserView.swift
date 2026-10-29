import SwiftUI

struct RuntimeChooserView: View {
    @ObservedObject var model: AppModel
    var defaultSelection: Bool
    @State private var installed: Set<RuntimeKind> = []
    private var selected: RuntimeKind { defaultSelection ? model.defaultRuntime : model.current?.runtime ?? model.defaultRuntime }
    private var ordered: [RuntimeKind] {
        RuntimeKind.allCases.sorted {
            let a = installed.contains($0), b = installed.contains($1)
            return a == b ? RuntimeKind.allCases.firstIndex(of: $0)! < RuntimeKind.allCases.firstIndex(of: $1)! : a
        }
    }
    var body: some View {
        let theme = PanelTheme.current
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(defaultSelection ? "Used for new drafts. Existing conversations keep their agent and profile."
                     : "Your draft and files stay here. The chosen agent uses its own native setup.")
                    .font(PanelTheme.pick(CompanionStyle.callout, .system(size: 12.5), .system(size: 12.5))).foregroundStyle(CompanionStyle.secondary)
                    .padding(.horizontal, theme == .instrument ? 0 : 4)
                switch theme {
                case .refined:
                    SettingsGroup {
                        ForEach(Array(ordered.enumerated()), id: \.element) { index, runtime in
                            if index > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 44) }
                            HStack(spacing: 8) {
                                choose(runtime) {
                                    HStack(spacing: 12) {
                                        Image(systemName: selected == runtime ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 15))
                                            .foregroundStyle(selected == runtime ? CompanionStyle.text : CompanionStyle.tertiary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(runtime.title).font(.system(size: 13, weight: .medium))
                                            Text(detail(runtime)).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, 14).padding(.vertical, 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(NotchRowButtonStyle(cornerRadius: 10))
                                setUp(runtime).padding(.trailing, 12)
                            }
                        }
                    }
                case .tahoe:
                    VStack(spacing: 0) {
                        ForEach(Array(ordered.enumerated()), id: \.element) { index, runtime in
                            if index > 0 { Rectangle().fill(CompanionStyle.separator).frame(height: 0.5).padding(.leading, 44) }
                            HStack(spacing: 8) {
                                choose(runtime) {
                                    HStack(spacing: 10) {
                                        Image(systemName: selected == runtime ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 16))
                                            .foregroundStyle(selected == runtime ? CompanionStyle.accent : CompanionStyle.faint)
                                            .frame(width: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(runtime.title).font(.system(size: 13, weight: .medium))
                                            Text(detail(runtime)).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 46)
                                }.buttonStyle(NotchRowButtonStyle(cornerRadius: 9))
                                setUp(runtime)
                            }.padding(4).padding(.trailing, 4)
                        }
                    }.notchGroup()
                case .instrument:
                    ForEach(Array(ordered.enumerated()), id: \.element) { index, runtime in
                        HStack(spacing: 10) {
                            choose(runtime) {
                                HStack(spacing: 10) {
                                    Text(String(format: "%02d", index + 1)).font(CompanionStyle.mono(10.5)).foregroundStyle(CompanionStyle.faint)
                                    ChoiceMark(selected: selected == runtime, round: true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(runtime.title).font(.system(size: 13, weight: .medium))
                                        Text(detail(runtime))
                                            .microLabel(9.5, weight: .regular, tracking: 0.6)
                                            .foregroundStyle(installed.contains(runtime) ? CompanionStyle.secondary : CompanionStyle.faint)
                                    }
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 44)
                            }.buttonStyle(NotchRowButtonStyle(selected: selected == runtime))
                                .overlay(RoundedRectangle(cornerRadius: CompanionStyle.radius).strokeBorder(CompanionStyle.rule, lineWidth: 0.5))
                            setUp(runtime)
                        }
                    }
                }
                Text(selected.capabilityNote)
                    .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), .system(size: 11)))
                    .foregroundStyle(theme == .refined ? CompanionStyle.tertiary : CompanionStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, theme == .instrument ? 0 : 4)
            }
            .padding(.top, theme == .refined ? 8 : 10).padding(.bottom, theme == .refined ? 12 : 10)
        }
        Group {
            if theme == .refined { scroll.scrollEdgeFade() } else { scroll }
        }
        .task(id: model.runtimeSettingsRevision) { installed = Set(RuntimeKind.allCases.filter(\.installationFound)) }
    }

    private func detail(_ runtime: RuntimeKind) -> String {
        (runtime.isExperimental ? "Experimental · " : "") + (installed.contains(runtime) ? "Installation found" : "Setup needed")
    }

    private func choose(_ runtime: RuntimeKind, @ViewBuilder label: () -> some View) -> some View {
        Button {
            if defaultSelection { model.defaultRuntime = runtime; model.page = .settings }
            else if let id = model.currentID { model.setRuntime(runtime, for: id); model.page = .session }
        } label: { label() }
            .accessibilityLabel("Use \(runtime.title), \(installed.contains(runtime) ? "setup found" : "setup needed")")
            .accessibilityAddTraits(selected == runtime ? .isSelected : [])
    }

    private func setUp(_ runtime: RuntimeKind) -> some View {
        Button("Set up") { model.page = .runtimeSetup(runtime) }
            .buttonStyle(NotchPillButtonStyle(small: true))
            .accessibilityLabel("Set up \(runtime.title)")
    }
}

extension RuntimeKind {
    /// Where its native installation is on this Mac (OpenClaw: its configuration
    /// folder), or nil when absent; sign-in and connection are checked separately.
    var installationPath: String? {
        if self == .hermes {
            return (try? RuntimeInstallation.hermes(environment: ProcessInfo.processInfo.environment,
                userHome: FileManager.default.homeDirectoryForCurrentUser, configuredSource: installationLocation.saved()))?.source.path
        }
        if self == .openclaw {
            let path = RuntimeProfileIdentity.decodeOpenClaw(RuntimeRoute.defaultProfile(self)).directory
            return FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("openclaw.json").path) ? path : nil
        }
        return (try? RuntimeInstallation.executable(for: self))?.path
    }
    var installationFound: Bool { installationPath != nil }
}

struct ProjectTrustView: View {
    @ObservedObject var model: AppModel
    private var question: String { "Trust this project for \(model.current?.runtime.title ?? "this agent")?" }
    private let explanation = "Starting the native CLI loads project instructions, plugins and hooks, which can run commands. Continue only if you trust this folder."

    private var trustButton: some View {
        Button("Trust and send") { Task { await model.trustProjectAndSend() } }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
            .disabled(model.currentDraftNeedsSetup)
    }

    var body: some View {
        switch PanelTheme.current {
        case .refined:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.Radius.field, style: .continuous)
            // The same header as approvals and questions: an amber mark, then the ask.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 12)).foregroundStyle(CompanionStyle.amber)
                        .accessibilityHidden(true)
                    Text(question).font(.system(size: 13, weight: .semibold))
                }
                Text(explanation)
                    .font(CompanionStyle.body).lineSpacing(3).foregroundStyle(CompanionStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Label(model.currentWorkspacePath, systemImage: "folder").font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                    .lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    Button("Cancel") { model.projectTrustSessionID = nil }
                        .buttonStyle(NotchToolbarButtonStyle(height: 26)).padding(.leading, -8)
                    Spacer()
                    trustButton
                }.padding(.top, 2)
            }
            .padding(14)
            .background(CompanionStyle.well, in: shape)
            .overlay(shape.strokeBorder(CompanionStyle.amber.opacity(0.28), lineWidth: 0.75))
        case .tahoe, .instrument:
            let instrument = PanelTheme.current == .instrument
            let content = VStack(alignment: .leading, spacing: 9) {
                if instrument {
                    HStack(spacing: 8) {
                        LED(color: CompanionStyle.signal, pulsing: true, size: 6)
                        Text("Project trust").microLabel(10.5, weight: .semibold).foregroundStyle(CompanionStyle.signal)
                        Rectangle().fill(CompanionStyle.signal.opacity(0.35)).frame(height: 0.5)
                    }
                }
                Text(question).font(.system(size: instrument ? 14 : 13, weight: .semibold))
                Text(explanation).font(.system(size: instrument ? 12 : 12.5)).foregroundStyle(CompanionStyle.secondary)
                if instrument {
                    Text(model.currentWorkspacePath).font(CompanionStyle.mono(10.5)).foregroundStyle(CompanionStyle.secondary).lineLimit(2).truncationMode(.middle)
                } else {
                    Text(model.currentWorkspacePath).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                }
                HStack {
                    Button("Cancel") { model.projectTrustSessionID = nil }.buttonStyle(NotchPillButtonStyle())
                    Spacer()
                    trustButton
                }
            }
            if instrument {
                content
                    .padding(.vertical, 8).padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(CompanionStyle.signal).frame(width: 2) }
            } else {
                content.padding(14).notchGroup(cornerRadius: 18)
            }
        }
    }
}
