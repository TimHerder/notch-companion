import Foundation

/// Only installation locations live here. Providers and credentials stay in
/// the runtime's own configuration, and saved conversations keep their profile.
enum RuntimeLocation: String, CaseIterable {
    case unavailableExecutable = "runtime.unavailable.executable"
    case unavailableProfile = "runtime.unavailable.profile"
    case hermesSource = "runtime.hermes.source"
    case hermesProfile = "runtime.hermes.profile"
    case codexExecutable = "runtime.codex.executable"
    case codexProfile = "runtime.codex.profile"
    case opencodeExecutable = "runtime.opencode.executable"
    case opencodeProfile = "runtime.opencode.profile"
    case deepseekExecutable = "runtime.deepseek.executable"
    case deepseekProfile = "runtime.deepseek.profile"
    case piExecutable = "runtime.pi.executable"
    case piProfile = "runtime.pi.profile"
    case antigravityExecutable = "runtime.antigravity.executable"
    case antigravityProfile = "runtime.antigravity.profile"
    case openclawExecutable = "runtime.openclaw.executable"
    case openclawProfile = "runtime.openclaw.profile"
    case claudeExecutable = "runtime.claude.executable"
    case claudeProfile = "runtime.claude.profile"
    case cursorExecutable = "runtime.cursor.executable"
    case cursorProfile = "runtime.cursor.profile"

    var runtime: RuntimeKind { RuntimeKind(rawValue: rawValue.split(separator: ".")[1].description)! }
    var isProfile: Bool { rawValue.hasSuffix(".profile") }
    var isDirectory: Bool { isProfile || self == .hermesSource }
    var title: String { isProfile ? "Native profile folder" : self == .hermesSource ? "Hermes installation" : "\(runtime.title) executable" }
    var explanation: String {
        if self == .hermesSource { return "Choose the Hermes installation containing hermes_cli and its Python environment." }
        if isProfile { return "Choose your existing \(runtime.title) profile. Its configuration, resources and sign-in stay managed by \(runtime.title)." }
        return "Choose the installed, unmodified \(runtime.commandName) executable."
    }

    func saved(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: rawValue).flatMap { $0.isEmpty ? nil : $0 }
    }

    func validate(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                  userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        guard runtime.isSupported else { throw AppError("This adapter is unavailable. Update the app to configure it; existing runtime settings were left unchanged.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        if isProfile {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AppError("Choose an existing \(runtime.title) profile folder.")
            }
            if self == .hermesProfile {
                let config = url.appendingPathComponent("config.yaml").resolvingSymlinksInPath()
                guard (try? config.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      FileManager.default.isReadableFile(atPath: config.path) else {
                    throw AppError("This folder has no readable Hermes config.yaml. Choose a configured profile, or finish setup in Hermes first.")
                }
            }
            if self == .codexProfile {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                guard names.contains(where: { ["config.toml", "auth.json", "sessions", "session_index.jsonl"].contains($0)
                    || ($0.hasPrefix("state_") && $0.hasSuffix(".sqlite")) }) else {
                    throw AppError("This folder does not look like an existing Codex home. Choose your configured Codex folder, or finish setup in Codex first.")
                }
            }
            if self == .deepseekProfile { _ = try ACPRuntimeClient.deepSeekLaunch(profileID: url.path) }
            if self == .openclawProfile { _ = try OpenClawConfiguration.configuredAgents(profileID: url.path) }
            if runtime.usesNativeProfileOnly {
                let native = userHome.appendingPathComponent(runtime.defaultProfileDirectory).standardizedFileURL.resolvingSymlinksInPath()
                guard url == native else { throw AppError("\(runtime.title) uses its native default profile here. Custom profile selection is not supported.") }
            }
        } else if self == .hermesSource {
            _ = try RuntimeInstallation.hermes(environment: environment, userHome: userHome, configuredSource: url.path)
        } else {
            _ = try RuntimeInstallation.executable(for: runtime, environment: environment, userHome: userHome, configuredExecutable: url.path)
        }
        // Preserve executable symlinks: a venv interpreter/wrapper may depend on
        // the invoked path. Profiles and source folders use canonical identity.
        return !isDirectory ? URL(fileURLWithPath: path).standardizedFileURL.path : url.path
    }
}

extension RuntimeKind {
    var installationLocation: RuntimeLocation { RuntimeLocation(rawValue: "runtime.\(rawValue).\(self == .hermes ? "source" : "executable")") ?? .unavailableExecutable }
    var profileLocation: RuntimeLocation { RuntimeLocation(rawValue: "runtime.\(rawValue).profile") ?? .unavailableProfile }
}
