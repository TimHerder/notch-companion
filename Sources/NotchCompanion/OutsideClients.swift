import Foundation

/// A token an MCP client outside the app uses. Only the token's SHA-256 is kept.
struct OutsideClient: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var tokenHash: Data
    var createdAt = Date()
    var lastUsedAt: Date?
}

/// A token just created, shown once with its snippets.
struct RevealedOutsideToken: Equatable {
    var clientID: String
    var token: String
}

/// Outside MCP clients (Claude Desktop, Codex, Cursor and so on) reach the
/// delegation server with a token the user created. They may read companion
/// sessions and send to top-level ones, never delegate, interrupt, change a
/// session or answer anything.
enum OutsideClients {
    static let enabledKey = "outside.enabled"
    static let clientsKey = "outside.clients"
    /// The last port outside clients were given, kept while the setting is on.
    static let portKey = "outside.port"
    /// The port the user last saw in Settings.
    static let seenPortKey = "outside.seenPort"
    /// Not `notch`: that name is the per-session server the app gives its own sessions.
    static let serverName = "notch-companion"
    static let denied = "Outside clients can only list, read and wait on sessions, send to top-level ones, create sessions and read pending questions."
    static let toolNames: Set<String> = ["notch_session_list", "notch_session_read", "notch_session_send", "notch_session_wait",
                                         "create_sessions", "pending_request_list", "pending_request_read"]

    static let instructions = """
    ## Notch Companion

    These tools reach the user's Notch Companion sessions: AI agent conversations in other harnesses on this Mac.

    - `notch_session_list` lists top-level sessions of every project, newest first; pass `projectPath` for one folder and `includeSubagents` for delegated children.
    - Read a session with `notch_session_read` before you answer about it or send to it.
    - `notch_session_send` sends to a top-level session (`auto`, `queue` or `steer`). It runs with that session's own harness, model and permission mode, and the user sees it as from you.
    - `notch_session_wait` waits for a session's turn to end.
    - `create_sessions` starts new sessions with the user's default harness, in the default folder or a project that already has sessions. Only when the user asks for a new session.
    - `pending_request_list` and `pending_request_read` show a session's questions. Answers and approvals are the user's, in Notch Companion.
    """

    static func isAllowed(_ name: String) -> Bool { toolNames.contains(name) }

    /// Constant-time, so a guess learns nothing from how long the comparison took.
    static func matches(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static let tools: [[String: Any]] = {
        let sessionID: [String: Any] = ["type": "string", "description": "A sessionId from notch_session_list."]
        let clientRequestID: [String: Any] = ["type": "string", "maxLength": 256, "description": "Reuse it to retry the same call. A new call gets a new key."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [], readOnly: Bool) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
        }
        return [
            tool("notch_session_list", "List Notch Companion sessions, newest first: every project's top-level sessions, or one project's with projectPath. Page with the cursor.",
                 ["projectPath": ["type": "string"], "statuses": ["type": "array", "items": ["type": "string"], "maxItems": 10],
                  "titleContains": ["type": "string", "maxLength": 256], "includeSubagents": ["type": "boolean"],
                  "cursor": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 100]], readOnly: true),
            tool("notch_session_read", "Read a session by id: its messages (default) or `activity` with tool calls. Page with afterPosition=nextPosition.",
                 ["sessionId": sessionID, "view": ["type": "string", "enum": ["messages", "activity"]],
                  "afterPosition": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                  "maxCharsPerItem": ["type": "integer", "minimum": 1, "maximum": 50000]], required: ["sessionId"], readOnly: true),
            tool("notch_session_send", "Send a message to a top-level session, with its own harness and permission mode. `auto` starts an idle session, steers a running turn where the harness can, or queues. `queue`: after the current turn. `steer`: into the running turn.",
                 ["sessionId": sessionID, "message": ["type": "string", "maxLength": Delegation.maxTaskCharacters],
                  "mode": ["type": "string", "enum": ["auto", "queue", "steer"]], "clientRequestId": clientRequestID],
                 required: ["sessionId", "message"], readOnly: false),
            tool("notch_session_wait", "Wait for a session's turn to end. Idle: at once. Default 10 min, at most 60. On timeout, call again.",
                 ["sessionId": sessionID, "timeoutMs": ["type": "number"]], required: ["sessionId"], readOnly: true),
            tool("create_sessions", "Create new Notch Companion sessions with the user's default harness, only when the user asks for new sessions. projectPath: the default folder (omit) or a project that already has sessions.",
                 ["sessions": ["type": "array", "minItems": 1, "maxItems": Delegation.maxBatchSessions, "items": ["type": "object", "properties": [
                     "prompt": ["type": "string", "maxLength": Delegation.maxTaskCharacters, "description": "Sent as the first message. Omit for an empty session."],
                     "title": ["type": "string", "maxLength": 512]], "additionalProperties": false]],
                  "projectPath": ["type": "string"], "clientRequestId": clientRequestID], required: ["sessions"], readOnly: false),
            tool("pending_request_list", "List a session's pending questions. Approvals are not listed.", ["sessionId": sessionID], required: ["sessionId"], readOnly: true),
            tool("pending_request_read", "Read one pending question. The user answers it in Notch Companion.",
                 ["sessionId": sessionID, "requestId": ["type": "string"]], required: ["sessionId", "requestId"], readOnly: true)
        ]
    }()

    /// Copyable configuration for a client; without the token, a placeholder.
    /// Nothing is written to any other app's configuration.
    static func snippets(url: URL, token: String?, bridge: String?) -> [(title: String, text: String)] {
        let token = token ?? "<token>"
        let address = url.absoluteString
        var snippets: [(String, String)] = [
            ("MCP Streamable HTTP (JSON)", """
            {
              "mcpServers": {
                "\(serverName)": {
                  "type": "http",
                  "url": "\(address)",
                  "headers": { "Authorization": "Bearer \(token)" }
                }
              }
            }
            """),
            ("Claude Code", "claude mcp add --transport http \(serverName) \(address) --header \"Authorization: Bearer \(token)\""),
            // `codex mcp add --url` takes no header, only a bearer environment variable.
            ("Codex (~/.codex/config.toml)", """
            [mcp_servers.\(serverName)]
            url = "\(address)"
            http_headers = { Authorization = "Bearer \(token)" }
            """)
        ]
        // Clients that start only stdio servers (Claude Desktop) run the app's own bridge.
        if let bridge {
            snippets.append(("Stdio bridge (Claude Desktop)", """
            {
              "mcpServers": {
                "\(serverName)": {
                  "command": "\(bridge)",
                  "args": ["\(DelegationBridge.flag)"],
                  "env": { "\(DelegationBridge.urlKey)": "\(address)", "\(DelegationBridge.tokenKey)": "\(token)" }
                }
              }
            }
            """))
        }
        return snippets
    }
}

extension AppModel {
    func loadOutsideClients() {
        outsideClients = preferences.data(forKey: OutsideClients.clientsKey).flatMap { try? JSONDecoder().decode([OutsideClient].self, from: $0) } ?? []
        outsideClientsEnabled = preferences.bool(forKey: OutsideClients.enabledKey)
    }

    private func saveOutsideClients() {
        preferences.set(try? JSONEncoder().encode(outsideClients), forKey: OutsideClients.clientsKey)
    }

    /// Turning outside clients on starts the server on their saved port;
    /// turning them off closes their open requests at once.
    func outsideClientsChanged() {
        if outsideClientsEnabled {
            Task { @MainActor in _ = try? await startDelegationServer() }
        } else {
            outsideURL = nil
            revealedOutsideToken = nil
            for client in outsideClients { delegationServer.disconnect(sessionID: "outside:" + client.id) }
        }
    }

    /// Starts the delegation server, on outside clients' saved port while they
    /// are allowed, so their configured URL keeps working.
    @discardableResult
    func startDelegationServer() async throws -> URL {
        let saved = outsideClientsEnabled ? UInt16(exactly: preferences.integer(forKey: OutsideClients.portKey)).flatMap { $0 == 0 ? nil : $0 } : nil
        let url = try await delegationServer.start(preferredPort: saved)
        if outsideClientsEnabled, let port = url.port {
            preferences.set(port, forKey: OutsideClients.portKey)
            if preferences.object(forKey: OutsideClients.seenPortKey) == nil { preferences.set(port, forKey: OutsideClients.seenPortKey) }
            outsideURL = url
        }
        return url
    }

    /// The port moved since the user last saw the URL, so configured clients need the new one.
    var outsidePortChanged: Bool {
        guard let port = outsideURL?.port, let seen = preferences.object(forKey: OutsideClients.seenPortKey) as? Int else { return false }
        return seen != port
    }

    func acknowledgeOutsidePort() {
        guard let port = outsideURL?.port else { return }
        objectWillChange.send()
        preferences.set(port, forKey: OutsideClients.seenPortKey)
    }

    /// A new token for a named client, shown once; only its hash is saved.
    @discardableResult
    func createOutsideClient(name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outsideClientsEnabled, !name.isEmpty else { return nil }
        let token = DelegationServer.newToken()
        let client = OutsideClient(name: String(name.prefix(80)), tokenHash: DelegationServer.hash(token))
        outsideClients.append(client)
        saveOutsideClients()
        revealedOutsideToken = RevealedOutsideToken(clientID: client.id, token: token)
        acknowledgeOutsidePort() // the URL in its snippets is the current one
        return token
    }

    /// Revoking a token ends that client's open requests.
    func revokeOutsideClient(_ id: String) {
        outsideClients.removeAll { $0.id == id }
        saveOutsideClients()
        if revealedOutsideToken?.clientID == id { revealedOutsideToken = nil }
        delegationServer.disconnect(sessionID: "outside:" + id)
    }

    /// The caller an outside token stands for. Every saved hash is compared, in constant time.
    func outsideCaller(token: String) -> DelegationCaller? {
        guard outsideClientsEnabled else { return nil }
        let hash = DelegationServer.hash(token)
        var found: Int?
        for index in outsideClients.indices where OutsideClients.matches(outsideClients[index].tokenHash, hash) { found = index }
        guard let index = found else { return nil }
        // Saved at most once a minute: every call would otherwise write preferences.
        if outsideClients[index].lastUsedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            outsideClients[index].lastUsedAt = Date()
            saveOutsideClients()
        }
        // The runtime is unused for an outside caller: no OpenCode or OpenClaw rule applies.
        return DelegationCaller(sessionID: "outside:" + outsideClients[index].id, runtime: .claude, subagent: false, client: outsideClients[index].name)
    }

    /// Outside clients read and send; they never delegate, interrupt, change
    /// a session's mode or answer a request.
    func checkOutsideCall(_ name: String, _ arguments: [String: Any]) throws {
        guard outsideClientsEnabled else { throw DelegationFailure("capability_denied", "Outside MCP clients are turned off in Notch Companion's settings.") }
        guard OutsideClients.isAllowed(name) else { throw DelegationFailure("capability_denied", OutsideClients.denied) }
        let rows = [arguments] + (arguments["sessions"] as? [[String: Any]] ?? [])
        if rows.contains(where: { $0["runtimeMode"] != nil || $0["interactionMode"] != nil || $0["target"] != nil }) {
            throw DelegationFailure("capability_denied", "Outside clients cannot choose a harness or permission mode; sessions keep their own.")
        }
        if name == "notch_session_send", let mode = arguments["mode"] as? String, !["auto", "queue", "steer"].contains(mode) {
            throw DelegationFailure("capability_denied", "Outside clients send with auto, queue or steer, never restart.")
        }
    }

    /// New top-level sessions with the default harness and permission
    /// settings, in the default folder or a project that already has sessions.
    func createOutsideSessions(_ caller: DelegationCaller, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard let rows = arguments["sessions"] as? [[String: Any]], (1...Delegation.maxBatchSessions).contains(rows.count) else {
            throw DelegationFailure("invalid_request", "sessions takes 1 to 20 entries.")
        }
        let defaultFolder = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let folder = (arguments["projectPath"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? defaultFolder
        guard folder == defaultFolder || sessions.contains(where: { projectPath(of: $0) == folder }) else {
            throw DelegationFailure("capability_denied", "Outside clients create sessions only in the default folder or a project that already has sessions.")
        }
        let runtime = newDraftRuntime
        guard readyRuntimes.contains(runtime) else { throw DelegationFailure("provider_unavailable", "No harness is set up in Notch Companion.") }
        let key = try Delegation.clientRequestID(arguments)
        var created: [[String: Any]] = []
        for (index, row) in rows.enumerated() {
            let prompt = (row["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard prompt.count <= Delegation.maxTaskCharacters else { throw DelegationFailure("invalid_request", "A prompt is at most 120,000 characters.") }
            let id = Delegation.derivedID(caller: caller.sessionID, operation: "create_sessions.\(index)", clientRequestID: key)
            if let existing = sessions.first(where: { $0.id == id }) { created.append(sessionSummary(existing)); continue }
            var session = CompanionSession()
            session.id = id
            session.runtime = runtime
            session.profileID = RuntimeRoute.defaultProfile(runtime, defaults: preferences)
            session.workspacePath = folder == defaultFolder ? nil : folder
            applyNativeWorkspace(to: &session)
            if runtime.requiresProjectTrust {
                // Project trust stays the user's decision for that harness and folder.
                guard trustsProject(runtime, path: session.workspacePath) else {
                    throw DelegationFailure("capability_denied", "The user has not trusted this project for \(runtime.title) in Notch Companion.")
                }
                session.trustedProjectPath = URL(fileURLWithPath: session.workspacePath ?? workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
            }
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            session.title = !title.isEmpty ? String(title.prefix(160)) : prompt.isEmpty ? "New session" : String((prompt.components(separatedBy: .newlines).first ?? prompt).prefix(64))
            session.titleIsAutomatic = title.isEmpty && !prompt.isEmpty
            sessions.insert(session, at: 0)
            save()
            if !prompt.isEmpty { await submit(reply: prompt, target: id, kind: ChatMessage.agentMessage, from: caller.client) }
            created.append(sessionSummary(sessions.first { $0.id == id } ?? session))
        }
        return ["sessions": created]
    }
}
