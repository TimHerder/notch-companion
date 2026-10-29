import Foundation

/// Keep unknown identifiers intact so an older app never drops or retargets a
/// conversation created by a newer adapter.
struct RuntimeKind: RawRepresentable, Codable, CaseIterable, Hashable, Identifiable {
    let rawValue: String
    init?(rawValue: String) { guard !rawValue.isEmpty else { return nil }; self.rawValue = rawValue }
    static let hermes = Self(rawValue: "hermes")!
    static let codex = Self(rawValue: "codex")!
    static let opencode = Self(rawValue: "opencode")!
    static let deepseek = Self(rawValue: "deepseek")!
    static let pi = Self(rawValue: "pi")!
    static let antigravity = Self(rawValue: "antigravity")!
    static let openclaw = Self(rawValue: "openclaw")!
    static let claude = Self(rawValue: "claude")!
    static let cursor = Self(rawValue: "cursor")!
    static let allCases: [Self] = [.hermes, .codex, .opencode, .pi, .openclaw, .claude, .deepseek, .antigravity, .cursor]
    var id: Self { self }
    var isSupported: Bool { Self.allCases.contains(self) }
    var title: String {
        switch self {
        case .hermes: return "Hermes"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .deepseek: return "DeepSeek Harness"
        case .pi: return "Pi"
        case .antigravity: return "Antigravity CLI"
        case .openclaw: return "OpenClaw"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor CLI"
        default: return "Unavailable agent (\(rawValue))"
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        rawValue = value // Preserve even malformed/empty future IDs; never default to Hermes.
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer(); try value.encode(rawValue)
    }
}

/// Stable profile identity, separate from a live connection or native session.
struct RuntimeRoute: Hashable {
    var runtime: RuntimeKind
    var profileID: String
    var legacy: Bool = false

    init(runtime: RuntimeKind, profileID: String? = nil, legacy: Bool = false) {
        self.runtime = runtime
        self.legacy = legacy
        self.profileID = profileID ?? Self.defaultProfile(runtime, legacy: legacy)
    }

    static func defaultProfile(_ runtime: RuntimeKind, legacy: Bool = false,
                               environment env: [String: String] = ProcessInfo.processInfo.environment,
                               userHome home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               defaults: UserDefaults = .standard) -> String {
        let env = env.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard runtime.isSupported else { return "unavailable:\(runtime.rawValue)" }
        let path: String
        if legacy {
            path = env["NOTCH_HERMES_HOME"] ?? home.appendingPathComponent("Library/Application Support/NotchCompanion/hermes").path
        } else if runtime == .hermes {
            path = RuntimeLocation.hermesProfile.saved(in: defaults) ?? env["NOTCH_HERMES_SOURCE_HOME"]
                ?? env["HERMES_HOME"] ?? home.appendingPathComponent(".hermes").path
        } else if runtime == .codex {
            path = RuntimeLocation.codexProfile.saved(in: defaults) ?? env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        } else {
            let nativeDefault: String
            if runtime == .opencode, let root = env["XDG_CONFIG_HOME"], root.hasPrefix("/") {
                nativeDefault = URL(fileURLWithPath: root).appendingPathComponent("opencode").path
            } else if runtime == .deepseek, let root = env["DSH_HOME"] { nativeDefault = root }
            else { nativeDefault = home.appendingPathComponent(runtime.defaultProfileDirectory).path }
            path = runtime.profileLocation.saved(in: defaults) ?? env[runtime.profileEnvironmentKey] ?? nativeDefault
        }
        let expanded = path == "~" ? home.path : path.hasPrefix("~/")
            ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        return runtime == .openclaw ? RuntimeProfileIdentity.openClaw(directory: canonical,
            agent: defaults.string(forKey: "runtime.openclaw.agent") ?? (try? OpenClawConfiguration.defaultAgent(profileID: canonical)) ?? "") : canonical
    }
    var title: String { legacy ? "Legacy Hermes" : runtime.title }
    var eventKey: String { "\(runtime.rawValue)|\(legacy)|\(profileID)" }
}

extension CompanionSession {
    var route: RuntimeRoute { RuntimeRoute(runtime: runtime, profileID: profileID, legacy: isLegacyPrivate) }
}

/// Owns only adapters and sessions explicitly created/resumed by the local
/// registry. Never imports a runtime's global list. Live aliases prevent ID and
/// approval collisions between runtimes/profiles; durable IDs stay native.
@MainActor
final class RuntimeRouter: RuntimeTransport {
    typealias Factory = (RuntimeRoute) -> any RuntimeTransport
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    private let factory: Factory
    private var clients: [RuntimeRoute: any RuntimeTransport] = [:]
    private var states: [RuntimeRoute: (connected: Bool, message: String)] = [:]
    private var connecting: [RuntimeRoute: Task<Void, Error>] = [:]
    private struct Binding { let route: RuntimeRoute; let native: String }
    private var bindings: [String: Binding] = [:]
    private var pendingEvents: [RuntimeRoute: [(String, [String: Any])]] = [:]
    private var openingRoutes: Set<RuntimeRoute> = []
    private var generation = UUID()

    init(factory: Factory? = nil, opencodeSupervisorURL: URL? = nil) {
        self.factory = factory ?? { route in
            if route.legacy { return HermesClient() }
            switch route.runtime {
            case .hermes: return SharedHermesClient(profileID: route.profileID)
            case .codex: return CodexClient(profileID: route.profileID)
            case .opencode: return OpenCodeClient(profileID: route.profileID, supervisorURL: opencodeSupervisorURL)
            case .deepseek, .cursor: return ACPRuntimeClient(runtime: route.runtime, profileID: route.profileID)
            case .pi: return PiClient(profileID: route.profileID)
            case .openclaw: return OpenClawClient(profileID: route.profileID)
            case .claude: return ClaudeClient(profileID: route.profileID)
            case .antigravity: return AntigravityClient(profileID: route.profileID)
            default: return UnavailableRuntimeClient(runtime: route.runtime)
            }
        }
    }

    func status(_ route: RuntimeRoute) -> (connected: Bool, message: String) {
        states[route] ?? (false, route.runtime.isSupported ? "Connects when you send a message." : "This app cannot open \(route.title). Update the app to resume it; its history is preserved.")
    }

    func connect() async throws {
        // Discovery is cheap; native frontends start only for an explicit send,
        // model request, or setup connection. Opening the app starts none.
    }

    func connect(_ route: RuntimeRoute) async throws {
        guard route.runtime.isSupported else { throw AppError(status(route).message) }
        guard !route.legacy || route.runtime == .hermes else { throw AppError("This saved legacy route is not Hermes. Its history was preserved without opening another runtime.") }
        if route.legacy && route.profileID != RuntimeRoute.defaultProfile(.hermes, legacy: true) {
            throw AppError("This legacy conversation belongs to a different private Hermes profile. Restore its original profile before resuming, or use Continue in Hermes.")
        }
        if status(route).connected { return }
        if let pending = connecting[route] { return try await pending.value }
        let adapter = clients[route] ?? factory(route)
        clients[route] = adapter
        let run = generation
        adapter.onEvent = { [weak self] name, payload in
            guard let self, self.generation == run else { return }
            self.forward(name, payload, route: route)
        }
        adapter.onConnectionChange = { [weak self] connected, message in
            guard let self, self.generation == run else { return }
            self.setStatus(route, connected: connected, message: message)
        }
        states[route] = (false, "Connecting to \(route.title)…")
        let task = Task { @MainActor in try await adapter.connect() }
        connecting[route] = task
        defer { if generation == run { connecting.removeValue(forKey: route) } }
        do {
            try await task.value
            guard generation == run else { throw AppError("Connection was cancelled.") }
            setStatus(route, connected: true, message: states[route]?.connected == true ? states[route]?.message : nil)
        } catch {
            if generation == run { setStatus(route, connected: false, message: error.localizedDescription) }
            throw error
        }
    }

    private func setStatus(_ route: RuntimeRoute, connected: Bool, message: String?) {
        states[route] = (connected, message ?? "\(route.title) \(connected ? "connected" : "disconnected")")
        if !connected { bindings = bindings.filter { $0.value.route != route } }
        onEvent?("runtime.connection", ["route": route.eventKey, "connected": connected, "message": states[route]!.message])
        onConnectionChange?(states.values.contains(where: { $0.connected }), message)
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method != "session.list" else { throw AppError("Only companion-created sessions are available here.") }
        var values = params
        if method == "runtime.models" || method == "runtime.rateLimits" {
            guard let kind = (params["runtime"] as? String).flatMap(RuntimeKind.init(rawValue:)) else {
                throw AppError("Choose a runtime first.")
            }
            let route = RuntimeRoute(runtime: kind, profileID: params["profile_id"] as? String)
            let runID = generation
            try await connect(route)
            let result = try await clients[route]!.request(method, params: method == "runtime.rateLimits" ? [:]
                : ["cwd": params["cwd"] ?? "", "project_trusted": params["project_trusted"] ?? false])
            guard generation == runID else { throw AppError("Connection changed while reading \(kind.title).") }
            return result
        }
        if method == "session.create" || method == "session.resume" {
            guard let owner = params["companion_id"] as? String, !owner.isEmpty,
                  let kind = (params["runtime"] as? String).flatMap(RuntimeKind.init(rawValue:)) else {
                throw AppError("A companion session identity is required.")
            }
            let route = RuntimeRoute(runtime: kind, profileID: params["profile_id"] as? String,
                                     legacy: params["legacy_private"] as? Bool ?? false)
            let runID = generation
            try await connect(route)
            guard generation == runID else { throw AppError("Connection changed before the session opened.") }
            for key in ["companion_id", "runtime", "profile_id", "legacy_private"] { values.removeValue(forKey: key) }
            openingRoutes.insert(route)
            defer { openingRoutes.remove(route); pendingEvents.removeValue(forKey: route) }
            var result = try await clients[route]!.request(method, params: values)
            guard generation == runID else { throw AppError("Connection changed while the session opened. No message was sent.") }
            guard let native = result["session_id"] as? String, !native.isEmpty else { throw AppError("The runtime returned no session identity.") }
            bindings = bindings.filter { $0.value.route != route || $0.value.native != native }
            let alias = UUID().uuidString
            bindings[alias] = Binding(route: route, native: native)
            result["session_id"] = alias
            result["profile_id"] = route.profileID
            // Creation/resume notifications may precede their RPC response. Let
            // AppModel record the binding before replaying those notifications.
            let events = pendingEvents[route] ?? []
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.generation == runID else { return }
                for (name, payload) in events { self.forward(name, payload, route: route) }
            }
            return result
        }
        guard let alias = params["session_id"] as? String, let binding = bindings[alias],
              let adapter = clients[binding.route] else { throw AppError("This session is disconnected. Reconnect to resume it.") }
        values["session_id"] = binding.native
        if let request = values["request_id"] as? String, request.hasPrefix(alias + ":") {
            values["request_id"] = String(request.dropFirst(alias.count + 1))
        }
        return try await adapter.request(method, params: values)
    }

    private func forward(_ name: String, _ original: [String: Any], route: RuntimeRoute) {
        // Account limits belong to the profile, not one session.
        if name == "runtime.rateLimits" {
            var payload = original
            payload["runtime"] = route.runtime.rawValue
            payload.removeValue(forKey: "session_id")
            onEvent?(name, payload)
            return
        }
        guard let native = original["session_id"] as? String,
              let alias = bindings.first(where: { $0.value.route == route && $0.value.native == native })?.key else {
            if openingRoutes.contains(route), pendingEvents[route, default: []].count < 256 {
                pendingEvents[route, default: []].append((name, original))
            }
            return
        }
        var payload = original
        payload["session_id"] = alias
        if let request = payload["request_id"] as? String { payload["request_id"] = alias + ":" + request }
        onEvent?(name, payload)
    }

    func disconnect() {
        generation = UUID()
        for task in connecting.values { task.cancel() }
        connecting.removeAll()
        for (route, adapter) in clients {
            adapter.onEvent = nil
            adapter.onConnectionChange = nil
            adapter.disconnect()
            states[route] = (false, "\(route.title) disconnected")
        }
        bindings.removeAll()
        pendingEvents.removeAll()
        onConnectionChange?(false, nil)
    }
}
