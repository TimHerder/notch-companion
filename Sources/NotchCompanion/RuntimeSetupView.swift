import SwiftUI

struct RuntimeSetupView: View {
    @ObservedObject var model: AppModel
    let runtime: RuntimeKind
    @State private var installationPath = "Looking for your installation…"
    @State private var installationError: String?
    @State private var configuredAgents: [String] = []

    var body: some View {
        let theme = PanelTheme.current
        let scroll = ScrollView {
            // Tahoe: grouped like Settings: a connection section, a location section, footnotes below.
            VStack(alignment: .leading, spacing: theme == .refined ? 12 : 18) {
                if !runtime.isSupported {
                    Text("Update the app to set up \(runtime.rawValue). Its saved conversation and profile remain intact.")
                        .foregroundStyle(CompanionStyle.secondary)
                } else {
                    switch theme {
                    case .refined: refinedContent
                    case .tahoe: tahoeContent
                    case .instrument: instrumentContent
                    }
                }
            }
            .font(PanelTheme.pick(CompanionStyle.body, .system(size: 13), .system(size: 12.5)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
        Group {
            if theme == .refined { scroll.scrollEdgeFade() } else { scroll }
        }
        .task(id: model.runtimeSettingsRevision) { detectInstallation() }
        .onChange(of: runtime) { detectInstallation() }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile changes apply to new sessions and the current unsent draft. Existing conversations keep their original profile.")
            Text("Finish authentication in \(runtime.title). The companion never asks for account credentials. Only conversations started here appear in your sessions.")
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var setupInstructions: some View {
        if let url = runtime.setupURL {
            Button("Open native setup instructions") { NSWorkspace.shared.open(url) }
                .buttonStyle(NotchPillButtonStyle(small: true))
        }
    }

    // MARK: Refined

    @ViewBuilder private var refinedContent: some View {
        Text(runtime.capabilityNote)
            .foregroundStyle(CompanionStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4).padding(.bottom, 4)

        let status = model.connectionStatus(for: runtime)
        let pending = model.runtimeSettingsPending.contains(runtime)
        SettingsGroup {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: pending ? "arrow.clockwise.circle" : status.connected ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(pending ? CompanionStyle.amber : status.connected ? CompanionStyle.color(.finished) : CompanionStyle.tertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending ? "Reconnect to apply changes" : status.connected ? "Connected" : "Connect on demand")
                        .fontWeight(.medium)
                    if !pending {
                        Text(status.message).font(CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button(pending ? "Reconnect when idle" : "Check connection") {
                    Task {
                        if pending { await model.reconnect() }
                        else { await model.connectRuntime(runtime) }
                    }
                }
                .buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }

        SettingsGroup {
            if runtime != .openclaw { refinedLocation(runtime.installationLocation, path: installationPath, error: installationError) }
            if runtime.usesNativeProfileOnly {
                detailRow("Native profile", path: RuntimeRoute.defaultProfile(runtime), divider: true)
            } else {
                refinedLocation(runtime.profileLocation, path: RuntimeProfileIdentity.directory(RuntimeRoute.defaultProfile(runtime), runtime: runtime),
                                divider: runtime != .openclaw)
            }
        }
        if runtime == .openclaw {
            if let installationError {
                Text(installationError).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            Text("Configured agent").font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary)
                .padding(.horizontal, 4).padding(.top, 4)
            let selected = RuntimeProfileIdentity.decodeOpenClaw(RuntimeRoute.defaultProfile(.openclaw)).agent
            if configuredAgents.isEmpty {
                Text("Configure an agent in OpenClaw, then check again.").foregroundStyle(CompanionStyle.secondary)
                    .padding(.horizontal, 4)
            } else {
                SettingsGroup {
                    ForEach(configuredAgents, id: \.self) { agent in
                        Button { model.setOpenClawAgent(agent) } label: {
                            HStack { Text(agent); Spacer(); if selected == agent { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) } }
                                .padding(.horizontal, 14).frame(height: 36)
                        }
                        .buttonStyle(NotchRowButtonStyle(selected: selected == agent, cornerRadius: CompanionStyle.Radius.card))
                        .accessibilityAddTraits(selected == agent ? .isSelected : [])
                    }
                }
            }
        }

        footnotes
            .font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4).padding(.top, 4)
        setupInstructions
    }

    /// A location the runtime reads, with its path underneath and the way to change it.
    private func refinedLocation(_ setting: RuntimeLocation, path: String, error: String? = nil, divider: Bool = false) -> some View {
        detailRow(setting.title, path: path, error: error, divider: divider) {
            if setting.saved() != nil {
                Button("Automatic") { model.resetRuntimeLocation(setting) }
                    .buttonStyle(NotchPillButtonStyle(small: true))
                    .accessibilityLabel("Use automatic \(setting.title.lowercased())")
            }
            Button("Choose…") { model.chooseRuntimeLocation(setting) }
                .buttonStyle(NotchPillButtonStyle(small: true))
                .accessibilityLabel("Choose \(setting.title.lowercased())")
        }
    }

    private func detailRow(_ title: String, path: String, error: String? = nil, divider: Bool = false,
                           @ViewBuilder controls: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 14) }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(path).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Text(error).font(CompanionStyle.callout).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                controls()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: Tahoe

    @ViewBuilder private var tahoeContent: some View {
        Text(runtime.capabilityNote)
            .foregroundStyle(CompanionStyle.secondary).padding(.horizontal, 4)

        let status = model.connectionStatus(for: runtime)
        let pending = model.runtimeSettingsPending.contains(runtime)
        SettingsGroup("Connection") {
            HStack(spacing: 10) {
                SettingsIcon(symbol: pending ? "arrow.triangle.2.circlepath" : status.connected ? "checkmark" : "powerplug.fill",
                             tint: pending ? .orange : status.connected ? .green : .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending ? "Reconnect to apply changes" : status.connected ? "Connected" : "Connect on demand")
                    if !pending {
                        Text(status.message).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button(pending ? "Reconnect when idle" : "Check connection") {
                    Task {
                        if pending { await model.reconnect() }
                        else { await model.connectRuntime(runtime) }
                    }
                }
                    .buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }

        SettingsGroup("Location") {
            if runtime != .openclaw { tahoeLocation(runtime.installationLocation, path: installationPath, error: installationError) }
            if runtime.usesNativeProfileOnly {
                row(divider: true) {
                    Text("Native profile")
                    Spacer(minLength: 8)
                    Text(RuntimeRoute.defaultProfile(runtime)).font(.system(size: 11.5))
                        .foregroundStyle(CompanionStyle.secondary).textSelection(.enabled)
                }
            } else {
                tahoeLocation(runtime.profileLocation, path: RuntimeProfileIdentity.directory(RuntimeRoute.defaultProfile(runtime), runtime: runtime),
                              divider: runtime != .openclaw)
            }
        }
        if runtime == .openclaw {
            let selected = RuntimeProfileIdentity.decodeOpenClaw(RuntimeRoute.defaultProfile(.openclaw)).agent
            SettingsGroup("Configured agent") {
                if let installationError {
                    row { Text(installationError).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true) }
                }
                ForEach(Array(configuredAgents.enumerated()), id: \.element) { index, agent in
                    Button { model.setOpenClawAgent(agent) } label: {
                        row(divider: index > 0 || installationError != nil) {
                            Text(agent)
                            Spacer(minLength: 8)
                            if selected == agent {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.accent)
                            }
                        }
                    }
                    .buttonStyle(NotchRowButtonStyle(selected: false, cornerRadius: 12))
                    .accessibilityAddTraits(selected == agent ? .isSelected : [])
                }
                if configuredAgents.isEmpty {
                    row(divider: installationError != nil) {
                        Text("Configure an agent in OpenClaw, then check again.").foregroundStyle(CompanionStyle.secondary)
                    }
                }
            }
        }

        footnotes
            .font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        setupInstructions
    }

    /// A grouped-list row; separators start at the label, as in System Settings.
    private func row<Content: View>(divider: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(CompanionStyle.separator).frame(height: 0.5).padding(.leading, 12) }
            HStack(spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 42)
        }
        .contentShape(Rectangle())
    }

    private func tahoeLocation(_ setting: RuntimeLocation, path: String, error: String? = nil, divider: Bool = false) -> some View {
        row(divider: divider) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.title)
                Text(path).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if setting.saved() != nil {
                Button("Automatic") { model.resetRuntimeLocation(setting) }
                    .buttonStyle(NotchPillButtonStyle(small: true))
                    .accessibilityLabel("Use automatic \(setting.title.lowercased())")
            }
            Button("Choose…") { model.chooseRuntimeLocation(setting) }
                .buttonStyle(NotchPillButtonStyle(small: true))
                .accessibilityLabel("Choose \(setting.title.lowercased())")
        }
    }

    // MARK: Instrument

    @ViewBuilder private var instrumentContent: some View {
        Text(runtime.capabilityNote)
            .foregroundStyle(CompanionStyle.secondary)

        let status = model.connectionStatus(for: runtime)
        VStack(alignment: .leading, spacing: 6) {
            Label(model.runtimeSettingsPending.contains(runtime) ? "Reconnect to apply changes"
                  : status.connected ? "Connected" : "Connect on demand",
                  systemImage: status.connected && !model.runtimeSettingsPending.contains(runtime) ? "checkmark.circle" : "info.circle")
                .microLabel(11, weight: .semibold)
            if !model.runtimeSettingsPending.contains(runtime) {
                Text(status.message).foregroundStyle(CompanionStyle.secondary).textSelection(.enabled)
            }
            Button(model.runtimeSettingsPending.contains(runtime) ? "Reconnect when idle" : "Check connection") {
                Task {
                    if model.runtimeSettingsPending.contains(runtime) { await model.reconnect() }
                    else { await model.connectRuntime(runtime) }
                }
            }
                .buttonStyle(NotchPillButtonStyle(prominent: true))
        }

        if runtime != .openclaw { instrumentLocation(runtime.installationLocation, path: installationPath, error: installationError) }
        if runtime.usesNativeProfileOnly {
            Text("Native profile · \(RuntimeRoute.defaultProfile(runtime))")
                .font(CompanionStyle.mono(10.5)).foregroundStyle(CompanionStyle.secondary).textSelection(.enabled)
        } else {
            instrumentLocation(runtime.profileLocation, path: RuntimeProfileIdentity.directory(RuntimeRoute.defaultProfile(runtime), runtime: runtime))
        }
        if runtime == .openclaw {
            VStack(alignment: .leading, spacing: 8) {
                if let installationError { Text(installationError).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true) }
                Text("Configured agent").microLabel(10, weight: .semibold)
                let selected = RuntimeProfileIdentity.decodeOpenClaw(RuntimeRoute.defaultProfile(.openclaw)).agent
                ForEach(configuredAgents, id: \.self) { agent in
                    Button { model.setOpenClawAgent(agent) } label: {
                        HStack { Text(agent); Spacer(); if selected == agent { Image(systemName: "checkmark") } }
                    }.buttonStyle(NotchPillButtonStyle(small: true))
                }
                if configuredAgents.isEmpty { Text("Configure an agent in OpenClaw, then check again.").foregroundStyle(CompanionStyle.secondary) }
            }
        }

        Text("Profile changes apply to new sessions and the current unsent draft. Existing conversations keep their original profile.")
            .font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
        Text("Finish authentication in \(runtime.title). The companion never asks for account credentials. Only conversations started here appear in your sessions.")
            .font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).textSelection(.enabled)
        setupInstructions
    }

    private func instrumentLocation(_ setting: RuntimeLocation, path: String, error: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
            HStack {
                Text(setting.title).microLabel(10, weight: .semibold)
                Spacer()
                if setting.saved() != nil {
                    Button("Automatic") { model.resetRuntimeLocation(setting) }
                        .buttonStyle(NotchPillButtonStyle(small: true))
                        .accessibilityLabel("Use automatic \(setting.title.lowercased())")
                }
                Button("Choose…") { model.chooseRuntimeLocation(setting) }
                    .buttonStyle(NotchPillButtonStyle(small: true))
                    .accessibilityLabel("Choose \(setting.title.lowercased())")
            }
            Text(path).font(CompanionStyle.mono(10.5)).foregroundStyle(CompanionStyle.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detectInstallation() {
        guard runtime.isSupported else { return }
        do {
            let environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser
            if runtime == .hermes {
                installationPath = try RuntimeInstallation.hermes(environment: environment, userHome: home,
                                                                  configuredSource: runtime.installationLocation.saved()).source.path
            } else if runtime == .openclaw {
                let profile = RuntimeProfileIdentity.decodeOpenClaw(RuntimeRoute.defaultProfile(runtime)).directory
                configuredAgents = try OpenClawConfiguration.configuredAgents(profileID: profile)
                installationPath = "Your existing local Gateway"
            } else {
                installationPath = try RuntimeInstallation.executable(for: runtime, environment: environment, userHome: home,
                                                                     configuredExecutable: runtime.installationLocation.saved()).path
            }
            installationError = nil
        } catch {
            installationPath = runtime.installationLocation.saved() ?? "No compatible installation found"
            installationError = error.localizedDescription
        }
    }
}
