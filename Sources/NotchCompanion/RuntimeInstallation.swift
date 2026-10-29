import Foundation

enum RuntimeInstallationError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Finds installed code without running a shell, importing a runtime, or reading
/// credentials. Installation paths never select or change a conversation profile.
enum RuntimeInstallation {
    static func executable(for runtime: RuntimeKind,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                           configuredExecutable: String? = nil,
                           searchSystemLocations: Bool = true) throws -> URL {
        guard runtime.isSupported, runtime != .hermes else { throw AppError("Choose a supported native CLI installation.") }
        let configured = configuredExecutable ?? runtime.installationLocation.saved()
        if runtime == .codex { return try codex(environment: environment, userHome: userHome,
                                               configuredExecutable: configured, searchSystemLocations: searchSystemLocations) }
        let override = "NOTCH_\(runtime.rawValue.uppercased())_EXECUTABLE"
        if let path = nonempty(configured) ?? nonempty(environment[override]) {
            guard let executable = absoluteURL(path, userHome: userHome), isExecutable(executable) else {
                throw AppError("The selected \(runtime.title) executable is unavailable. Choose its installed \(runtime.commandName) CLI in Settings, or clear the custom location. Check \(override) if set.")
            }
            return executable
        }
        let candidates = executableDirectories(environment: environment, userHome: userHome, searchSystemLocations: searchSystemLocations)
            + [userHome.appendingPathComponent(".opencode/bin"), userHome.appendingPathComponent(".bun/bin"),
               userHome.appendingPathComponent(".npm-global/bin")]
        guard let executable = candidates.map({ $0.appendingPathComponent(runtime.commandName) }).first(where: isExecutable) else {
            throw AppError("\(runtime.title) was not found. Install and sign in through its native CLI, then select the existing executable in Settings. Nothing is installed automatically.")
        }
        return executable
    }
    struct Hermes: Equatable {
        let source: URL
        let python: URL
    }

    static func hermes(environment: [String: String], userHome: URL,
                       configuredSource: String? = nil, searchSystemLocations: Bool = true) throws -> Hermes {
        if let path = nonempty(configuredSource) ?? nonempty(environment["NOTCH_HERMES_SOURCE"]) {
            guard let source = absoluteURL(path, userHome: userHome), let found = hermesSource(source) else {
                throw RuntimeInstallationError.unavailable("The selected Hermes installation is unavailable or incomplete. Choose the Hermes source folder containing hermes_cli and its installed Python environment in Settings, or clear the custom location to detect it again. Check NOTCH_HERMES_SOURCE if it is set.")
            }
            return found
        }

        for directory in executableDirectories(environment: environment, userHome: userHome, searchSystemLocations: searchSystemLocations) {
            if let found = hermesLauncher(directory.appendingPathComponent("hermes"), userHome: userHome) {
                return found
            }
        }
        // The Hermes installer defaults to $HERMES_HOME/hermes-agent and also
        // supports HERMES_INSTALL_DIR. These are source hints, not profile IDs.
        let homes = [environment["NOTCH_HERMES_SOURCE_HOME"], environment["HERMES_HOME"]]
            .compactMap { $0.flatMap { absoluteURL($0, userHome: userHome) } }
            .map { hermesRoot($0, userHome: userHome) }
            + [userHome.appendingPathComponent(".hermes")]
        let sources = [environment["HERMES_INSTALL_DIR"].flatMap { absoluteURL($0, userHome: userHome) }]
            .compactMap { $0 } + homes.map { $0.appendingPathComponent("hermes-agent") }
        for source in sources {
            if let found = hermesSource(source) { return found }
        }
        throw RuntimeInstallationError.unavailable("Hermes was not found. Install and set up Hermes normally, then reconnect. For a custom installation, choose its source folder in Settings; it must include hermes_cli and its installed Python environment.")
    }

    static func codex(environment: [String: String], userHome: URL,
                      configuredExecutable: String? = nil, searchSystemLocations: Bool = true) throws -> URL {
        if let path = nonempty(configuredExecutable) ?? nonempty(environment["NOTCH_CODEX_EXECUTABLE"]) {
            guard let executable = absoluteURL(path, userHome: userHome), isExecutable(executable) else {
                throw RuntimeInstallationError.unavailable("The selected Codex executable is unavailable or cannot be run. Choose the codex executable in Settings, or clear the custom location to detect it again. Check NOTCH_CODEX_EXECUTABLE if it is set.")
            }
            return executable
        }
        let commands = executableDirectories(environment: environment, userHome: userHome, searchSystemLocations: searchSystemLocations)
            .map { $0.appendingPathComponent("codex") }
        let applicationFolders = [userHome.appendingPathComponent("Applications")]
            + (searchSystemLocations ? [URL(fileURLWithPath: "/Applications")] : [])
        let applications = applicationFolders
            .flatMap { folder in
                [folder.appendingPathComponent("Codex.app/Contents/Resources/codex"),
                 folder.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")]
            }
        guard let found = (commands + applications).first(where: isExecutable) else {
            throw RuntimeInstallationError.unavailable("Codex was not found. Install the Codex CLI or desktop app and sign in normally, then reconnect. For a custom installation, choose its codex executable in Settings.")
        }
        return found
    }

    private static func hermesSource(_ candidate: URL) -> Hermes? {
        let source = URL(fileURLWithPath: candidate.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
        guard isRegularFile(source.appendingPathComponent("hermes_cli/main.py")) else { return nil }
        // New Hermes installs publish a literal store-Python launcher instead
        // of a checkout-local venv. Read its command; never execute shell code.
        let launcher = source.appendingPathComponent(".hermes/bin/hermes")
        if isRegularFile(source.appendingPathComponent("hermes_bootstrap.py")),
           let python = launcherExecutable(launcher, userHome: FileManager.default.homeDirectoryForCurrentUser),
           python.lastPathComponent.hasPrefix("python"), isExecutable(python) {
            return Hermes(source: source, python: python)
        }
        for name in ["venv/bin/python", "venv/bin/python3", ".venv/bin/python", ".venv/bin/python3"] {
            let python = source.appendingPathComponent(name)
            if isExecutable(python) {
                // Keep the venv path: resolving the Python symlink to its base
                // interpreter would silently discard the installed environment.
                return Hermes(source: source, python: python)
            }
        }
        return nil
    }

    private static func hermesRoot(_ profile: URL, userHome: URL) -> URL {
        // Match Hermes get_default_hermes_root for installation hints without
        // rewriting the actual profile selected by the runtime/session registry.
        let standard = userHome.appendingPathComponent(".hermes").resolvingSymlinksInPath()
        let selected = profile.resolvingSymlinksInPath()
        if selected.path == standard.path || selected.path.hasPrefix(standard.path + "/") { return standard }
        if selected.deletingLastPathComponent().lastPathComponent == "profiles" {
            return selected.deletingLastPathComponent().deletingLastPathComponent()
        }
        return selected
    }

    private static func hermesLauncher(_ launcher: URL, userHome: URL,
                                       visited: Set<String> = []) -> Hermes? {
        guard visited.count < 4, !visited.contains(launcher.path), isExecutable(launcher) else { return nil }
        let resolved = launcher.resolvingSymlinksInPath()
        // Official launchers either live at the source root or in venv/bin.
        // Inspect the lexical path before following a Python executable symlink.
        for path in [launcher, resolved] {
            var folder = path
            for _ in 0..<3 {
                folder.deleteLastPathComponent()
                if let found = hermesSource(folder) { return found }
            }
        }
        guard let executable = launcherExecutable(resolved, userHome: userHome) else { return nil }
        return hermesLauncher(executable, userHome: userHome, visited: visited.union([launcher.path]))
    }

    private static func launcherExecutable(_ launcher: URL, userHome: URL) -> URL? {
        guard isExecutable(launcher), let handle = try? FileHandle(forReadingFrom: launcher) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), let text = String(data: data, encoding: .utf8) else { return nil }
        // Only literal exec paths or console-script shebangs are accepted.
        let pattern = #"(?m)^\s*exec\s+(?:"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s"']+))"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let match = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        var target: String?
        if let match {
            for index in 1...3 {
                if let range = Range(match.range(at: index), in: text) { target = String(text[range]); break }
            }
        } else if text.hasPrefix("#!/") {
            target = text.split(separator: "\n", maxSplits: 1).first.map { String($0.dropFirst(2)) }
        }
        guard let target, !target.contains("$"), !target.contains("`"), !target.contains("\\") else { return nil }
        return absoluteURL(target, userHome: userHome)
    }

    private static func executableDirectories(environment: [String: String], userHome: URL,
                                              searchSystemLocations: Bool) -> [URL] {
        let path = (environment["PATH"] ?? "").split(separator: ":")
            .compactMap { absoluteURL(String($0), userHome: userHome) }
        return path + [userHome.appendingPathComponent(".local/bin"), userHome.appendingPathComponent("bin")]
            + (searchSystemLocations ? [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")] : [])
    }

    private static func absoluteURL(_ path: String, userHome: URL) -> URL? {
        if path == "~" { return userHome.standardizedFileURL }
        if path.hasPrefix("~/") { return userHome.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL }
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isExecutable(_ url: URL) -> Bool {
        isRegularFile(url.resolvingSymlinksInPath()) && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
