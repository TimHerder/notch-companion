import Foundation

/// Capabilities are deliberately separate from installation/authentication.
/// Native negotiation may narrow these defaults for an installed version.
struct RuntimeCapabilities: Codable, Equatable {
    var resume = false
    var attachments = false
    var images = false
    var approvals = false
    var questions = false
    var modelSelection = false
    var contextUsage = false
    var delegation = false
    /// Raw `PermissionMode` values the harness maps natively. Optional, and
    /// strings, so registries saved before (or by a newer build) still decode.
    var permissionModes: [String]? = nil
    /// The runtime reports account limits (percentage used and reset time).
    var rateLimits: Bool? = nil
    /// Native input priority support, when it depends on the connected CLI.
    var steering: Bool? = nil

    var supportedPermissionModes: [PermissionMode] { (permissionModes ?? []).compactMap(PermissionMode.init(rawValue:)) }

    mutating func merge(_ values: [String: Any]) {
        if let value = values["resume"] as? Bool { resume = value }
        if let value = values["attachments"] as? Bool { attachments = value }
        if let value = values["images"] as? Bool { images = value }
        if let value = values["approvals"] as? Bool { approvals = value }
        if let value = values["questions"] as? Bool { questions = value }
        if let value = values["modelSelection"] as? Bool { modelSelection = value }
        if let value = values["contextUsage"] as? Bool { contextUsage = value }
        if let value = values["delegation"] as? Bool { delegation = value }
        if let value = values["permissionModes"] as? [String] { permissionModes = value }
        if let value = values["rateLimits"] as? Bool { rateLimits = value }
        if let value = values["steering"] as? Bool { steering = value }
    }
}

/// How much an agent may do without asking, chosen per session. No choice
/// (Inherit) keeps the native profile's own approvals and sandbox.
enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    case ask, autoEdit, plan, fullAccess
    var id: Self { self }
    var title: String {
        switch self {
        case .ask: return "Ask"
        case .autoEdit: return "Auto-edit"
        case .plan: return "Plan"
        case .fullAccess: return "Full access"
        }
    }
    var detail: String {
        switch self {
        case .ask: return "Asks before editing files or running commands"
        case .autoEdit: return "Edits files without asking; asks for the rest"
        case .plan: return "Plans first and makes no changes"
        case .fullAccess: return "Runs anything without asking"
        }
    }
    var symbol: String {
        switch self {
        case .ask: return "hand.raised"
        case .autoEdit: return "pencil"
        case .plan: return "list.bullet.clipboard"
        case .fullAccess: return "exclamationmark.shield"
        }
    }
}

extension RuntimeKind {
    var commandName: String {
        switch self {
        case .deepseek: return "dsh"
        case .antigravity: return "agy"
        // The installer links `agent` too; this name cannot collide with another tool.
        case .cursor: return "cursor-agent"
        default: return rawValue
        }
    }
    var profileEnvironmentKey: String {
        switch self {
        case .hermes: return "HERMES_HOME"
        case .codex: return "CODEX_HOME"
        case .opencode: return "OPENCODE_CONFIG_DIR"
        case .pi: return "PI_CODING_AGENT_DIR"
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .openclaw: return "OPENCLAW_STATE_DIR"
        case .deepseek: return "NOTCH_DEEPSEEK_PROFILE"
        case .cursor: return "CURSOR_CONFIG_DIR"
        default: return "NOTCH_\(rawValue.uppercased())_PROFILE"
        }
    }
    var defaultProfileDirectory: String {
        switch self {
        case .hermes: return ".hermes"
        case .codex: return ".codex"
        case .opencode: return ".config/opencode"
        case .pi: return ".pi/agent"
        case .claude: return ".claude"
        case .openclaw: return ".openclaw"
        case .antigravity: return ".gemini/antigravity-cli"
        case .deepseek: return ".dsh"
        case .cursor: return ".cursor"
        default: return ".notch-unavailable/\(rawValue)"
        }
    }
    var requiresProjectTrust: Bool { self == .claude || self == .antigravity || self == .cursor }
    /// Runs only its native default profile; the companion never sets a profile override.
    var usesNativeProfileOnly: Bool { self == .antigravity || self == .cursor }
    var capabilities: RuntimeCapabilities {
        switch self {
        case .hermes:
            return .init(resume: true, attachments: true, images: true, approvals: true, questions: true,
                         modelSelection: true, contextUsage: true, delegation: true)
        case .codex:
            return .init(resume: true, attachments: true, images: true, approvals: true, questions: true,
                         modelSelection: true, contextUsage: true, delegation: true, permissionModes: PermissionMode.allCases.map(\.rawValue), rateLimits: true)
        case .opencode:
            return .init(resume: true, attachments: true, images: true, approvals: true, questions: true,
                         modelSelection: true, contextUsage: true, delegation: true)
        case .pi:
            return .init(resume: true, attachments: true, images: true, questions: true, modelSelection: true, contextUsage: true)
        case .openclaw:
            return .init(resume: true, attachments: true, images: true, approvals: true, modelSelection: true)
        case .claude:
            return .init(resume: true, attachments: true, images: true, approvals: true, questions: true, modelSelection: true, contextUsage: true,
                         permissionModes: PermissionMode.allCases.map(\.rawValue), rateLimits: true)
        case .deepseek:
            return .init(resume: true, attachments: true, approvals: true, modelSelection: true)
        case .antigravity:
            return .init(resume: true, attachments: true, approvals: true, questions: true, modelSelection: true, contextUsage: true)
        case .cursor:
            return .init(resume: true, attachments: true, approvals: true, questions: true, modelSelection: true, contextUsage: true,
                         permissionModes: [PermissionMode.plan.rawValue])
        default: return .init()
        }
    }
    var capabilityNote: String {
        switch self {
        case .hermes: return "Uses your configured Hermes provider, tools and memory. Sign-in stays in Hermes."
        case .codex: return "Uses your existing Codex account, configuration and native threads."
        case .opencode: return "Supports OpenCode 1.18.34–1.18.x and 2.0.30–2.0.x with your native profile, tools, questions, models and saved sessions."
        case .pi: return "Uses native RPC, models, context usage and extensions. The companion adds a native question tool for its UI; terminal-only extension interfaces still need Pi's terminal. Pi has no built-in tool approval gate."
        case .openclaw: return "Connects to your existing local Gateway and chosen agent. Native pairing may be required. Remote Gateways are not supported."
        case .claude: return "Uses your unmodified Claude CLI, native sign-in, hooks and memory. Trust this working folder before starting its hooks."
        case .deepseek: return "Choose your existing ACP-enabled launch profile. Its plugin composition must match your usual setup; the companion never substitutes a minimal profile."
        case .antigravity: return AntigravityClient.protocolNote
        case .cursor: return "Uses your installed Cursor CLI over its native ACP server, with your sign-in, rules, MCP servers and saved chats. Sign in with cursor-agent login first. Trust this working folder before starting its project hooks and MCP servers. Dashboard team MCP servers are unavailable over ACP."
        default: return "This app does not include this adapter. Saved history and drafts remain available."
        }
    }
    var setupURL: URL? {
        let address: String
        switch self {
        case .hermes: address = "https://hermes-agent.nousresearch.com/docs/"
        case .codex: address = "https://developers.openai.com/codex/cli/"
        case .opencode: address = "https://opencode.ai/docs/cli/"
        case .pi: address = "https://github.com/earendil-works/pi/tree/main/packages/coding-agent"
        case .openclaw: address = "https://docs.openclaw.ai/gateway/clients"
        case .claude: address = "https://code.claude.com/docs/en/headless"
        case .deepseek: address = "https://github.com/deepseek-ai/deepseek-harness/tree/master/apps/cli"
        case .antigravity: address = "https://antigravity.google/docs/ide/extensions/acp/"
        case .cursor: address = "https://cursor.com/docs/cli/acp"
        default: return nil
        }
        return URL(string: address)
    }
}

extension CompanionSession {
    var capabilities: RuntimeCapabilities {
        var value = runtimeInfo?.capabilities ?? runtime.capabilities
        // Capabilities saved before permission modes existed still get the static mapping.
        if value.permissionModes == nil { value.permissionModes = runtime.capabilities.permissionModes }
        return value
    }
}

enum RuntimeProfileIdentity {
    static func openClaw(directory: String, agent: String) -> String {
        let canonical = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        // JSON escapes delimiters in both paths and agent names without collisions.
        let data = try! JSONEncoder().encode([canonical, agent])
        return "openclaw:" + data.base64EncodedString()
    }
    static func decodeOpenClaw(_ identity: String) -> (directory: String, agent: String) {
        guard identity.hasPrefix("openclaw:"), let data = Data(base64Encoded: String(identity.dropFirst(9))),
              let pair = try? JSONDecoder().decode([String].self, from: data), pair.count == 2 else { return (identity, "main") }
        return (pair[0], pair[1])
    }
    static func directory(_ identity: String, runtime: RuntimeKind) -> String {
        runtime == .openclaw ? decodeOpenClaw(identity).directory : identity
    }
}

/// Keep provider/tool configuration; remove only inherited frontend/session IPC
/// and explicit identity overrides which would attach to this host chat.
enum RuntimeEnvironment {
    static func native(environment: [String: String] = ProcessInfo.processInfo.environment,
                       runtime: RuntimeKind, profileID: String) -> [String: String] {
        var result = environment.filter { key, _ in
            !key.hasPrefix("CODEX_THREAD_") && !key.hasPrefix("CODEX_SESSION_") && !key.hasPrefix("CODEX_INTERNAL_")
                && !key.hasPrefix("CODEX_APP_")
                && !key.hasPrefix("HERMES_SESSION_") && !key.hasPrefix("HERMES_FRONTEND_")
                && !["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "HERMES_DESKTOP",
                     "HERMES_GATEWAY_SESSION_ID", "CODEX_IPC_PATH", "CODEX_APP_SERVER_SOCKET", "MCP_SERVER_PORT"].contains(key)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if !runtime.usesNativeProfileOnly && runtime != .deepseek {
            let directory = RuntimeProfileIdentity.directory(profileID, runtime: runtime)
            if runtime == .claude {
                // Setting even the default directory changes Claude's native
                // login namespace. Keep a matching explicit native override
                // exactly; otherwise leave its ordinary default implicit.
                let native = environment[runtime.profileEnvironmentKey]
                let defaultDirectory = home.appendingPathComponent(runtime.defaultProfileDirectory)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                if let native, native.hasPrefix("/"),
                   URL(fileURLWithPath: native).standardizedFileURL.resolvingSymlinksInPath().path == directory {
                    result[runtime.profileEnvironmentKey] = native
                } else if directory == defaultDirectory {
                    result.removeValue(forKey: runtime.profileEnvironmentKey)
                } else { result[runtime.profileEnvironmentKey] = directory }
            } else { result[runtime.profileEnvironmentKey] = directory }
        }
        if runtime == .openclaw { result.removeValue(forKey: "OPENCLAW_CONFIG_PATH") }
        if runtime == .deepseek {
            let profile = URL(fileURLWithPath: profileID)
            result["DSH_HOME"] = profile.deletingLastPathComponent().lastPathComponent == "profiles"
                ? profile.deletingLastPathComponent().deletingLastPathComponent().path : profileID
        }
        let fallbacks = [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".bun/bin").path,
                         "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        result["PATH"] = ([result["PATH"] ?? ""] + fallbacks).filter { !$0.isEmpty }.joined(separator: ":")
        return result
    }
}

@MainActor final class UnavailableRuntimeClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let runtime: RuntimeKind
    init(runtime: RuntimeKind) { self.runtime = runtime }
    func connect() async throws { throw AppError("This app does not include the \(runtime.rawValue) adapter. Its saved conversations have been preserved.") }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { try await connect(); return [:] }
    func disconnect() {}
}
