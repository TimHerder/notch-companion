import Foundation

struct OpenClawRPCError: LocalizedError, RuntimeDefinitiveRejection {
    var code: String
    var message: String
    var errorDescription: String? { message }
}

/// An authenticated UI connection to an existing local Gateway. Disconnect only
/// closes this WebSocket; the Gateway, configured agents and channels stay alive.
@MainActor
final class OpenClawClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let profileID: String
    private let directory: String
    private let agent: String
    private let deviceOverride: OpenClawDevice?
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var ready = false
    private var challenge: [String: Any]?
    private var challengeWaiter: CheckedContinuation<[String: Any], Error>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var state = OpenClawProtocolState()
    private var images: [String: [String]] = [:]
    private var nativeIDs: [String: String] = [:]
    private var leafIDs: [String: Any] = [:]
    private var maxPayload = 16 * 1024 * 1024
    private var maxImage = 6 * 1024 * 1024
    private var features = Set<String>()
    private var receivedAt = Date()
    private var nodeSetup: (endpoint: URL, account: String, config: OpenClawConfiguration)?
    private var nodeLink: OpenClawNodeLink?
    private var grants: [String: OpenClawNodeLink.Grant] = [:]
    private var noticeKey: String?

    init(profileID: String, device: OpenClawDevice? = nil) {
        self.profileID = profileID
        self.deviceOverride = device
        let identity = RuntimeProfileIdentity.decodeOpenClaw(profileID)
        self.directory = identity.directory; self.agent = identity.agent
    }

    func connect() async throws {
        if ready { return }
        let config = try OpenClawConfiguration.load(directory: directory)
        guard try OpenClawConfiguration.configuredAgents(profileID: directory).contains(agent) else { throw AppError("The selected OpenClaw agent is no longer configured. Choose an existing agent in Settings; saved sessions retain their original agent.") }
        let endpoint = try config.endpoint()
        let account = OpenClawDevice.account(directory: directory, endpoint: endpoint)
        let device = try deviceOverride ?? OpenClawDevice.load(account: account)
        let auth = try device.token.map { ["token": $0] } ?? config.auth(environment: ProcessInfo.processInfo.environment)
        let scopes = device.token == nil ? OpenClawDevice.requiredScopes : device.scopes
        guard Set(OpenClawDevice.requiredScopes).isSubset(of: Set(scopes)) else { throw AppError("This OpenClaw pairing lacks the chat, approval or question scopes implemented by the companion. Review this device's pairing in OpenClaw, then reconnect.") }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 32 * 1024 * 1024
        self.urlSession = session; self.socket = socket
        let run = UUID(); generation = run; receivedAt = Date()
        receiver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, self.generation == run else { return }
                    let data: Data
                    switch message { case .data(let bytes): data = bytes; case .string(let value): data = Data(value.utf8); @unknown default: throw AppError("OpenClaw sent an unsupported WebSocket frame.") }
                    guard data.count <= 32 * 1024 * 1024, let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError("OpenClaw sent an invalid Gateway frame.") }
                    self.receivedAt = Date(); self.receive(frame)
                } catch {
                    guard let self, self.generation == run else { return }
                    self.fail(AppError("The OpenClaw Gateway disconnected. Reconnect to recover native history and active work before sending again.")); return
                }
            }
        }
        socket.resume()
        do {
            let challenge = try await waitForChallenge()
            guard let nonce = challenge["nonce"] as? String, !nonce.isEmpty,
                  let timestamp = challenge["ts"] as? Int, timestamp >= 0 else { throw AppError("OpenClaw sent an invalid pairing challenge. Check the installed Gateway protocol version.") }
            let proof = try device.proof(nonce: nonce, timestamp: timestamp, token: auth["token"], scopes: scopes)
            let result = try await rpc("connect", ["minProtocol": 4, "maxProtocol": 4,
                "client": ["id": "gateway-client", "displayName": "Notch Companion", "version": "0.3.0", "platform": "macos", "deviceFamily": "mac", "mode": "ui"],
                "role": "operator", "scopes": scopes, "caps": ["tool-events", "exec-approvals", "approvals"], "auth": auth, "device": proof])
            guard result["type"] as? String == "hello-ok", result["protocol"] as? Int == 4 else { throw AppError("This OpenClaw Gateway is incompatible. Notch Companion implements Gateway wire protocol 4.") }
            let granted = result["auth"] as? [String: Any] ?? [:]
            guard Set(OpenClawDevice.requiredScopes).isSubset(of: Set(granted["scopes"] as? [String] ?? [])) else { throw AppError("OpenClaw did not grant the companion's required chat, approval and question scopes. Review device pairing in OpenClaw.") }
            if let token = granted["deviceToken"] as? String, token != device.token, deviceOverride == nil {
                // Read-modify-write, so a node token the shared link saved meanwhile is kept.
                var latest = try OpenClawDevice.load(account: account)
                latest.token = token; latest.scopes = granted["scopes"] as? [String] ?? []
                try latest.save(account: account)
            }
            features = Set((result["features"] as? [String: Any])?["methods"] as? [String] ?? [])
            let required: Set<String> = ["chat.send", "chat.history", "chat.abort", "sessions.create", "sessions.messages.subscribe", "question.resolve", "exec.approval.resolve"]
            guard required.isSubset(of: features) else { throw AppError("This OpenClaw Gateway does not expose the native chat, persistence and interaction methods required by this adapter. Check its version and enabled capabilities.") }
            let policy = result["policy"] as? [String: Any] ?? [:]
            maxPayload = min(32 * 1024 * 1024, policy["maxPayload"] as? Int ?? 16 * 1024 * 1024)
            maxImage = min(6 * 1024 * 1024, (policy["attachments"] as? [String: Any])?["maxImageBytes"] as? Int ?? 6 * 1024 * 1024)
            let quietSeconds = max(30, min(180, (policy["tickIntervalMs"] as? Int ?? 30_000) * 2 / 1000))
            watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.generation == run else { return }
                    if Date().timeIntervalSince(self.receivedAt) > Double(quietSeconds) { self.fail(AppError("The OpenClaw Gateway stopped responding. Reconnect to check saved work.")); return }
                }
            }
            nodeSetup = (endpoint, account, config)
            ready = true; onConnectionChange?(true, nil)
        } catch { fail(error); throw error }
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard ready else { throw AppError("OpenClaw is disconnected. Start your existing Gateway normally, then reconnect in Settings.") }
        if method == "runtime.models" {
            let response = try await rpc("models.list", ["agentId": agent])
            let models = response["models"] as? [[String: Any]] ?? []
            let options = models.compactMap { row -> RuntimeModelOption? in
                guard let id = row["id"] as? String else { return nil }
                return RuntimeModelOption(choice: RuntimeModelChoice(model: id, provider: row["provider"] as? String), title: row["name"] as? String ?? id)
            }
            return ["catalog": RuntimeModelCatalog(models: options, note: "Configured OpenClaw agent: \(agent). Its native Gateway selects the default model and workspace.")]
        }
        if method == "session.create" {
            let key = "agent:\(agent):notch:\(UUID().uuidString.lowercased())"
            var arguments: [String: Any] = ["key": key, "agentId": agent, "idempotencyKey": UUID().uuidString]
            if let title = params["title"] as? String, !title.isEmpty { arguments["displayName"] = title }
            if let cwd = params["cwd"] as? String, !cwd.isEmpty {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let native = try OpenClawConfiguration.workspace(profileID: directory, agent: agent)
                let expanded = native?.replacingOccurrences(of: "~/", with: home + "/")
                let folder = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
                guard let expanded else { throw AppError("OpenClaw did not report this agent's workspace. Select its configured native workspace before creating a session.") }
                let workspace = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
                guard folder == workspace || folder.hasPrefix(workspace + "/") else { throw AppError("This OpenClaw agent uses \(workspace). Choose a folder inside that workspace; the companion does not request Gateway administration access.") }
                arguments["cwd"] = folder
            }
            let created = try await rpc("sessions.create", arguments)
            guard created["key"] as? String == key else { throw AppError("OpenClaw created a different session than requested. No existing messaging session was selected.") }
            state.owned.insert(key)
            if let native = created["sessionId"] as? String { nativeIDs[key] = native }
            let hydrated = try await hydrate(key)
            offerTools(to: key, params["delegation"])
            return hydrated
        }
        if method == "session.resume" {
            guard let key = params["session_id"] as? String, key.hasPrefix("agent:\(agent):notch:") else { throw AppError("This saved OpenClaw session does not belong to the selected companion agent.") }
            let hydrated = try await hydrate(key, pendingTurnID: params["pending_turn_id"] as? String)
            offerTools(to: key, params["delegation"])
            return hydrated
        }
        guard let key = params["session_id"] as? String, state.owned.contains(key) else { throw AppError("This OpenClaw session is not registered with the companion.") }
        switch method {
        case "session.model.set":
            guard !state.busy(key), let model = params["model"] as? String else { throw AppError("Wait for this OpenClaw session and its children to settle before changing models.") }
            let provider = params["provider"] as? String
            let value = provider.map { model.hasPrefix($0 + "/") ? model : $0 + "/" + model } ?? model
            var arguments: [String: Any] = ["key": key, "agentId": agent, "model": value]
            if let native = nativeIDs[key] { arguments["expectedSessionId"] = native }
            let result = try await rpc("sessions.patch", arguments)
            let row = result["entry"] as? [String: Any] ?? result
            let confirmedModel = row["model"] as? String ?? (result["resolved"] as? [String: Any])?["model"] as? String
            let confirmedProvider = row["modelProvider"] as? String ?? (result["resolved"] as? [String: Any])?["modelProvider"] as? String
            let confirmed = confirmedProvider.map { provider in confirmedModel.map { $0.hasPrefix(provider + "/") ? $0 : provider + "/" + $0 } } ?? confirmedModel
            guard confirmed == value || (provider == nil && confirmedModel == model) else { throw AppError("OpenClaw did not confirm the requested session model. No prompt was sent; inspect the native session before continuing.") }
            var info = OpenClawProtocolState.info(row)
            info["model"] = confirmedModel; info["provider"] = confirmedProvider
            onEvent?("session.info", info.merging(["session_id": key]) { _, new in new })
            return ["info": info]
        case "session.rename":
            _ = try await rpc("sessions.patch", ["key": key, "agentId": agent, "label": params["title"] as? String ?? ""])
            return ["renamed": true]
        case "file.attach", "image.attach":
            let file = try PiProtocolState.readableFile(params["path"] as? String)
            if method == "image.attach" {
                if !(images[key] ?? []).contains(file.path) { images[key, default: []].append(file.path) }
                return ["path": file.path]
            }
            return ["ref_text": "Attached local file (read using your configured Gateway agent tools): " + CodexProtocolState.describe([file.path])]
        case "image.detach":
            images[key]?.removeAll { $0 == params["path"] as? String }; return ["detached": true]
        case "prompt.submit":
            guard !state.busy(key) else { throw OpenClawRPCError(code: "LOCAL_BUSY", message: "This OpenClaw session or delegated work is still active. Reconnect to recover its state, or wait for completion before sending again.") }
            let revision = state.activityRevision(key)
            let snapshot: [String: Any]
            do { snapshot = try await rpc("chat.history", ["sessionKey": key, "agentId": agent, "limit": 1, "maxBytes": 65536]) }
            catch { throw OpenClawRPCError(code: "LOCAL_PREFLIGHT", message: "OpenClaw could not check the current native session before sending. No prompt was submitted; reconnect and try again.") }
            state.register(key, history: snapshot, expectedRevision: revision)
            guard !state.busy(key) else { throw OpenClawRPCError(code: "LOCAL_BUSY", message: "OpenClaw reports active native work in this session. No prompt was submitted.") }
            leafIDs[key] = snapshot["leafEntryId"]
            let run = params["turn_id"] as? String ?? UUID().uuidString
            let attachments: [[String: Any]] = try (images[key] ?? []).map { path in
                let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maxImage else { throw AppError("This image exceeds the local OpenClaw Gateway's attachment limit.") }
                let image = try PiProtocolState.image(path)
                return ["type": "image", "mimeType": image["mimeType"] ?? "", "content": image["data"] ?? "", "fileName": URL(fileURLWithPath: path).lastPathComponent]
            }
            var arguments: [String: Any] = ["sessionKey": key, "agentId": agent, "message": params["text"] as? String ?? "", "idempotencyKey": run, "attachments": attachments, "deliver": false]
            if let leaf = leafIDs[key] { arguments["expectedLeafEntryId"] = leaf }
            // Serialize first: local validation failures must not poison busy state.
            try validateFrame(["type": "req", "id": run, "method": "chat.send", "params": arguments])
            state.begin(key, run: run)
            do {
                let response = try await rpc("chat.send", arguments)
                state.accepted(key, run: response["runId"] as? String ?? run)
                images[key] = []
                return ["accepted": true, "turn_id": response["runId"] as? String ?? run]
            } catch {
                if error is OpenClawRPCError { state.rejected(key) }
                throw error // A lost acknowledgement stays busy until native recovery.
            }
        case "session.interrupt":
            for ownedKey in [key] + state.parents.filter({ $0.value == key }).map(\.key) {
                var arguments: [String: Any] = ["sessionKey": ownedKey, "agentId": agent, "discardPendingInput": true]
                if let run = state.active[ownedKey] { arguments["runId"] = run }
                _ = try await rpc("chat.abort", arguments)
            }
            return ["interrupted": true]
        case "approval.respond", "clarify.respond":
            if let reply = try state.answer(params, session: key) {
                _ = try await rpc(reply.0, reply.1)
                state.answered(params["request_id"] as? String ?? "")
            }
            return ["resolved": true]
        default: throw AppError("OpenClaw does not support \(method) through this companion.")
        }
    }

    private func hydrate(_ key: String, pendingTurnID: String? = nil) async throws -> [String: Any] {
        // Register only this requested companion key before subscribing: pending
        // input may arrive before the subscription's own response.
        let revision = state.activityRevision(key)
        let wasOwned = state.owned.contains(key)
        state.owned.insert(key)
        var succeeded = false
        defer { if !succeeded && !wasOwned { state.owned.remove(key) } }
        _ = try await rpc("sessions.messages.subscribe", ["key": key, "agentId": agent, "includeApprovals": true])
        var historyRequest: [String: Any] = ["sessionKey": key, "agentId": agent, "limit": 1000, "maxBytes": 8 * 1024 * 1024]
        if let pendingTurnID, !pendingTurnID.isEmpty, pendingTurnID.count <= 256 { historyRequest["inputRunIds"] = [pendingTurnID] }
        let history = try await rpc("chat.history", historyRequest)
        if let actual = history["sessionKey"] as? String, actual != key { throw AppError("OpenClaw returned history for another session. The original session was preserved.") }
        state.register(key, history: history, expectedRevision: revision)
        let info = history["sessionInfo"] as? [String: Any] ?? [:]
        if let native = history["sessionId"] as? String ?? info["sessionId"] as? String { nativeIDs[key] = native }
        if let leaf = history["leafEntryId"] { leafIDs[key] = leaf }
        for (method, resultKey, event) in [("exec.approval.list", "approvals", "exec.approval.requested"), ("question.list", "questions", "question.requested")] where features.contains(method) {
            let result = try await rpc(method, [:])
            for record in result[resultKey] as? [[String: Any]] ?? [] { deliver(state.consume(event, record)) }
        }
        let receipt = OpenClawProtocolState.acceptedReceipt(history, requestedID: pendingTurnID)
        if receipt.queued, let id = receipt.ids.first { state.adoptQueuedReceipt(key, id: id) }
        succeeded = true
        return ["accepted_turn_ids": receipt.ids, "session_id": key, "stored_session_id": key, "profile_id": profileID,
                "messages": OpenClawProtocolState.history(history), "history_complete": false, "running": state.busy(key), "info": OpenClawProtocolState.info(info)]
    }

    /// A session launched with delegation gets the tools through the account's
    /// shared node link, which opens with the first such session and closes with
    /// the last connection using it.
    private func offerTools(to key: String, _ launch: Any?) {
        guard let launch = launch as? [String: Any], let url = (launch["url"] as? String).flatMap(URL.init(string:)),
              let token = launch["token"] as? String, !token.isEmpty, let setup = nodeSetup else { return }
        grants[key] = OpenClawNodeLink.Grant(url: url, token: token)
        noticeKey = key
        let link = nodeLink ?? OpenClawNodeLink.shared(endpoint: setup.endpoint, config: setup.config, account: setup.account, device: deviceOverride)
        nodeLink = link
        // Only a companion-owned session with its own grant may call; any other agent on the Gateway sees the tools but is refused.
        link.attach(self, grant: { [weak self] key in self?.state.owned.contains(key) == true ? self?.grants[key] : nil }) { [weak self] message in
            guard let self, let key = self.noticeKey else { return }
            self.onEvent?("runtime.notice", ["session_id": key, "message": message])
        }
        if !link.isOpen { Task { @MainActor in await link.start() } }
    }

    private func deliver(_ events: [(String, [String: Any])]) {
        for (name, payload) in events {
            if name == "runtime.cancelQuestion", let id = payload["request_id"] as? String {
                let run = generation
                Task { @MainActor [weak self] in
                    guard let self, self.generation == run else { return }
                    do { _ = try await self.rpc("question.resolve", ["id": id, "cancel": true]) }
                    catch { guard self.generation == run else { return }; self.onEvent?("runtime.notice", ["session_id": payload["session_id"] ?? "", "message": "An unsupported OpenClaw secret, browser or resource question could not be cancelled. Resolve it in OpenClaw's native UI."]); return }
                    guard self.generation == run else { return }
                    self.onEvent?("runtime.notice", ["session_id": payload["session_id"] ?? "", "message": "An OpenClaw secret, browser or resource question needs its native UI and was cancelled here."])
                }
            } else if name == "runtime.reconcile" {
                // Losing even one lifecycle event can hide a pending child or
                // terminal failure. Detach the projection, then recover exact
                // native state through the normal reconnect/resume path.
                fail(AppError("OpenClaw event delivery had a sequence gap. Reconnect to recover native history and active runs before sending again."))
                return
            } else { onEvent?(name, payload) }
        }
    }

    private func waitForChallenge() async throws -> [String: Any] {
        if let challenge { return challenge }
        return try await withCheckedThrowingContinuation { continuation in
            challengeWaiter = continuation
            timeouts["challenge"] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.challengeWaiter?.resume(throwing: AppError("The existing OpenClaw Gateway did not send its pairing challenge. Check that it is running and supports protocol 4.")); self?.challengeWaiter = nil
            }
        }
    }
    private func receive(_ frame: [String: Any]) {
        if frame["type"] as? String == "res", let id = frame["id"] as? String, let waiter = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if frame["ok"] as? Bool == true { waiter.resume(returning: frame["payload"] as? [String: Any] ?? [:]) }
            else if frame["ok"] as? Bool == false {
                let error = frame["error"] as? [String: Any] ?? [:], details = error["details"] as? [String: Any] ?? [:]
                let code = details["code"] as? String ?? error["code"] as? String ?? "GATEWAY_ERROR"
                var message = error["message"] as? String ?? "OpenClaw rejected the request."
                if code == "PAIRING_REQUIRED" {
                    message = "Approve Notch Companion in OpenClaw's native device pairing, then reconnect. Pairing request: " + (details["requestId"] as? String ?? "see OpenClaw devices list")
                } else if code.hasPrefix("AUTH_") { message = "OpenClaw rejected this device's authentication or scopes (\(code)). Review its native Gateway/device setup, then reconnect." }
                waiter.resume(throwing: OpenClawRPCError(code: code, message: message))
            } else { waiter.resume(throwing: AppError("OpenClaw returned a malformed acknowledgement. Check native history before retrying.")) }
            return
        }
        guard frame["type"] as? String == "event", let event = frame["event"] as? String else { return }
        let payload = frame["payload"] as? [String: Any] ?? [:]
        if event == "connect.challenge" {
            guard challenge == nil else { return }
            challenge = payload; timeouts.removeValue(forKey: "challenge")?.cancel()
            challengeWaiter?.resume(returning: payload); challengeWaiter = nil
        } else if ready { deliver(state.consume(event, payload)) }
    }
    private func validateFrame(_ frame: [String: Any]) throws {
        guard try JSONSerialization.data(withJSONObject: frame).count <= maxPayload else { throw AppError("This message exceeds the OpenClaw Gateway's frame limit. Remove large attachments before sending.") }
    }
    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let socket else { throw AppError("OpenClaw is disconnected.") }
        let id = UUID().uuidString
        let frame: [String: Any] = ["type": "req", "id": id, "method": method, "params": params]
        try validateFrame(frame)
        let data = try JSONSerialization.data(withJSONObject: frame), run = generation
        guard let text = String(data: data, encoding: .utf8) else { throw AppError("The Gateway request could not be encoded.") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.generation == run else { return }
                self.timeouts.removeValue(forKey: id)
                self.pending.removeValue(forKey: id)?.resume(throwing: AppError("OpenClaw did not acknowledge \(method). Reconnect to recover native state before retrying."))
            }
            Task { @MainActor [weak self] in
                do { try await socket.send(.string(text)) }
                catch {
                    guard let self, self.generation == run else { return }
                    self.fail(AppError("OpenClaw disconnected while sending. Check the native session before retrying."))
                }
            }
        }
    }
    func disconnect() { cleanup(AppError("OpenClaw disconnected.")); onConnectionChange?(false, nil) }
    private func fail(_ error: Error) { cleanup(error); onConnectionChange?(false, error.localizedDescription) }
    private func cleanup(_ error: Error) {
        generation = UUID(); ready = false; challenge = nil
        receiver?.cancel(); receiver = nil; watchdog?.cancel(); watchdog = nil
        challengeWaiter?.resume(throwing: error); challengeWaiter = nil
        for timeout in timeouts.values { timeout.cancel() }; timeouts.removeAll()
        for waiter in pending.values { waiter.resume(throwing: error) }; pending.removeAll()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        urlSession?.invalidateAndCancel(); urlSession = nil
        state = OpenClawProtocolState(); images.removeAll(); nativeIDs.removeAll(); leafIDs.removeAll(); features.removeAll()
        // The Gateway withdraws a node's tools when it disconnects.
        nodeLink?.detach(self); nodeLink = nil; grants.removeAll(); noticeKey = nil; nodeSetup = nil
    }
}

/// The companion as an OpenClaw node: a second Gateway connection with role
/// `node` and the same Keychain device, publishing the delegation tools with
/// `node.pluginTools.update`. The agent calls one through `node.invoke`, which
/// arrives here with the calling session's key. Pairing and command approval
/// stay with OpenClaw; a failure is a notice and never affects chat.
/// Every agent profile of a Gateway shares the Keychain device and so the node
/// id, so one link per account serves all their clients.
@MainActor
final class OpenClawNodeLink {
    nonisolated static let command = "mcp.tools.call.v1"
    struct Grant { var url: URL; var token: String }
    private static var links: [String: OpenClawNodeLink] = [:]
    private var clients: [ObjectIdentifier: (grant: (String) -> Grant?, notice: (String) -> Void)] = [:]
    private(set) var isOpen = false
    private let endpoint: URL
    private let config: OpenClawConfiguration
    private let account: String
    private let persists: Bool
    private var device: OpenClawDevice?
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiver: Task<Void, Never>?
    private var generation = UUID()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var invocations: [String: Task<Void, Never>] = [:]
    private var ready = false
    nonisolated private static let http = URLSession(configuration: .ephemeral)

    init(endpoint: URL, config: OpenClawConfiguration, account: String, device: OpenClawDevice?) {
        self.endpoint = endpoint; self.config = config; self.account = account
        self.device = device; persists = device == nil
    }

    static func shared(endpoint: URL, config: OpenClawConfiguration, account: String, device: OpenClawDevice?) -> OpenClawNodeLink {
        if let link = links[account] { return link }
        let link = OpenClawNodeLink(endpoint: endpoint, config: config, account: account, device: device)
        links[account] = link
        return link
    }

    func attach(_ client: AnyObject, grant: @escaping (String) -> Grant?, notice: @escaping (String) -> Void) {
        clients[ObjectIdentifier(client)] = (grant, notice)
    }

    /// The last client closes the link, so the Gateway withdraws the tools.
    func detach(_ client: AnyObject) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        guard clients.isEmpty else { return }
        close()
        if Self.links[account] === self { Self.links.removeValue(forKey: account) }
    }

    private func grant(_ key: String) -> Grant? { clients.values.lazy.compactMap { $0.grant(key) }.first }
    private func onNotice(_ message: String) { for client in clients.values { client.notice(message) } }

    /// Descriptors for the Gateway's reserved `node-mcp` plugin id, which
    /// requires this command and an `mcp` route (`node-plugin-tool-snapshot.ts`).
    nonisolated static func descriptors(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return ["pluginId": "node-mcp", "name": DelegationServer.name + "_" + name,
                    "description": String((tool["description"] as? String ?? name).prefix(1024)),
                    "parameters": tool["inputSchema"] ?? [:], "command": command,
                    "mcp": ["server": DelegationServer.name, "tool": name]]
        }
    }

    func start() async {
        guard !isOpen else { return }
        isOpen = true
        let run = UUID(); generation = run
        do { try await open(run) } catch {
            guard generation == run else { return } // closed on purpose
            close()
            onNotice("OpenClaw sessions cannot delegate: \(error.localizedDescription) Chat keeps working.")
        }
    }

    private func open(_ run: UUID) async throws {
        let device = try self.device ?? OpenClawDevice.load(account: account) // Keychain: always the latest node token
        let auth = try device.nodeToken.map { ["token": $0] } ?? config.auth(environment: ProcessInfo.processInfo.environment)
        let session = URLSession(configuration: .ephemeral), socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 32 * 1024 * 1024
        urlSession = session; self.socket = socket
        receiver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let message = try? await socket.receive()
                guard let self, self.generation == run else { return }
                var frame: [String: Any]?
                switch message { case .data(let bytes)?: frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                case .string(let text)?: frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                default: break }
                guard let frame else {
                    // Before hello, the handshake's own error is the notice.
                    guard self.ready else { return self.failPending(AppError("OpenClaw closed the companion's node link.")) }
                    self.close()
                    self.onNotice("OpenClaw closed Notch Companion's node link, so OpenClaw sessions cannot delegate until you reopen one. Chat keeps working.")
                    return
                }
                self.receive(frame)
            }
        }
        socket.resume()
        let challenge = try await wait("challenge", seconds: 15)
        guard let nonce = challenge["nonce"] as? String, !nonce.isEmpty, let timestamp = challenge["ts"] as? Int, timestamp >= 0 else {
            throw AppError("OpenClaw sent an invalid pairing challenge.")
        }
        let proof = try device.proof(nonce: nonce, timestamp: timestamp, token: auth["token"], scopes: [], mode: "node", role: "node")
        let hello: [String: Any]
        do {
            hello = try await rpc("connect", ["minProtocol": 4, "maxProtocol": 4,
                "client": ["id": "gateway-client", "displayName": "Notch Companion", "version": "0.3.0", "platform": "macos", "deviceFamily": "mac", "mode": "node"],
                "role": "node", "scopes": [String](), "caps": [String](), "commands": [Self.command], "auth": auth, "device": proof])
        } catch let error as OpenClawRPCError where error.code.hasPrefix("AUTH_") && device.nodeToken != nil {
            // A removed node's token is stale; the next attempt pairs with the Gateway credential.
            try save { $0.nodeToken = nil }
            throw error
        }
        guard hello["type"] as? String == "hello-ok", hello["protocol"] as? Int == 4 else { throw AppError("This OpenClaw Gateway is incompatible with protocol 4.") }
        if let token = (hello["auth"] as? [String: Any])?["deviceToken"] as? String, token != device.nodeToken { try save { $0.nodeToken = token } }
        ready = true
        let tools = Self.descriptors(Delegation.tools)
        let published = try await rpc("node.pluginTools.update", ["tools": tools])
        // The Gateway drops descriptors whose command is not approved, or all of them when plugin tools are off.
        if (published["tools"] as? [Any])?.count ?? 0 < tools.count {
            onNotice("OpenClaw has not enabled Notch Companion's delegation tools. Approve its node commands in OpenClaw (openclaw nodes pending, then openclaw nodes approve) and keep gateway.nodes.pluginTools.enabled on. Chat keeps working.")
        }
    }

    /// Read-modify-write, so the operator connection's token is never dropped.
    private func save(_ change: (inout OpenClawDevice) -> Void) throws {
        if persists {
            var latest = try OpenClawDevice.load(account: account)
            change(&latest); try latest.save(account: account)
        } else if var device { change(&device); self.device = device }
    }

    private func receive(_ frame: [String: Any]) {
        if frame["type"] as? String == "res", let id = frame["id"] as? String, let waiter = pending.removeValue(forKey: id) {
            if frame["ok"] as? Bool == true { waiter.resume(returning: frame["payload"] as? [String: Any] ?? [:]); return }
            let error = frame["error"] as? [String: Any] ?? [:], details = error["details"] as? [String: Any] ?? [:]
            let code = details["code"] as? String ?? error["code"] as? String ?? "GATEWAY_ERROR"
            let message = code == "PAIRING_REQUIRED"
                ? "Approve Notch Companion as an OpenClaw node (device request \(details["requestId"] as? String ?? "in openclaw devices list")), then reopen the session."
                : error["message"] as? String ?? "OpenClaw refused the node link (\(code))."
            waiter.resume(throwing: OpenClawRPCError(code: code, message: message))
            return
        }
        guard frame["type"] as? String == "event", let payload = frame["payload"] as? [String: Any] else { return }
        switch frame["event"] as? String {
        case "connect.challenge": pending.removeValue(forKey: "challenge")?.resume(returning: payload)
        case "node.invoke.request": invoke(payload)
        case "node.invoke.cancel": (payload["invokeId"] as? String).flatMap { invocations.removeValue(forKey: $0) }?.cancel()
        default: break
        }
    }

    private func invoke(_ request: [String: Any]) {
        guard let id = request["id"] as? String, let node = request["nodeId"] as? String, invocations[id] == nil else { return }
        let run = generation, grant = (request["sessionKey"] as? String).flatMap(grant)
        invocations[id] = Task { @MainActor [weak self] in
            let reply = await Self.call(request, grant: grant)
            guard let self, self.generation == run, !Task.isCancelled else { return }
            self.invocations.removeValue(forKey: id)
            self.send(["type": "req", "id": UUID().uuidString, "method": "node.invoke.result",
                       "params": reply.merging(["id": id, "nodeId": node] as [String: Any]) { _, new in new }])
        }
    }

    /// One `tools/call` to the delegation server with the grant of the calling
    /// session (nil: not a companion session with delegation). The reply is
    /// `node.invoke.result` without its id: an MCP result, with companion errors
    /// as `isError` results like the HTTP server's.
    nonisolated static func call(_ request: [String: Any], grant: Grant?) async -> [String: Any] {
        func failure(_ code: String, _ message: String) -> [String: Any] {
            let text = String(data: (try? JSONSerialization.data(withJSONObject: ["code": code, "message": message], options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? message
            return ["ok": true, "payload": ["content": [["type": "text", "text": text]], "isError": true]]
        }
        guard request["command"] as? String == command,
              let call = (request["paramsJSON"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }),
              call["server"] as? String == DelegationServer.name, let tool = call["tool"] as? String else {
            return ["ok": false, "error": ["code": "INVALID_REQUEST", "message": "Notch Companion serves only its own MCP tools."]]
        }
        guard let grant else {
            return failure("capability_denied", "Notch Companion's tools work only in sessions Notch Companion started.")
        }
        // The Gateway's own deadline: once it gives up, closing the request cancels the call, so a wait never acknowledges a result nobody received.
        let budget = (request["timeoutMs"] as? Int).flatMap { $0 > 0 ? Double($0) / 1000 : nil } ?? 65 * 60
        var post = URLRequest(url: grant.url, timeoutInterval: budget)
        post.httpMethod = "POST"
        post.setValue("Bearer " + grant.token, forHTTPHeaderField: "Authorization")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                    "params": ["name": tool, "arguments": call["arguments"] as? [String: Any] ?? [:]]])
        guard let (data, response) = try? await http.data(for: post) else {
            return ["ok": false, "error": ["code": "UNAVAILABLE", "message": "Notch Companion did not answer in time."]]
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { return failure("capability_denied", "This session's Notch Companion token is no longer valid. Reopen the session to delegate.") }
        guard status == 200, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["ok": false, "error": ["code": "UNAVAILABLE", "message": "Notch Companion is not answering."]]
        }
        if let result = reply["result"] as? [String: Any] { return ["ok": true, "payload": result] }
        return failure("invalid_request", (reply["error"] as? [String: Any])?["message"] as? String ?? "Unknown tool")
    }

    private func wait(_ key: String, seconds: Double) async throws -> [String: Any] {
        let run = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, self.generation == run else { return }
                self.pending.removeValue(forKey: key)?.resume(throwing: AppError("The OpenClaw Gateway did not answer the companion's node link."))
            }
        }
    }
    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        send(["type": "req", "id": id, "method": method, "params": params])
        return try await wait(id, seconds: 30)
    }
    private func send(_ frame: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else { return }
        let run = generation
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in if self?.generation == run { self?.close() } }
        }
    }

    private func failPending(_ error: Error) {
        for waiter in pending.values { waiter.resume(throwing: error) }
        pending.removeAll()
    }

    func close() {
        generation = UUID(); isOpen = false; ready = false
        receiver?.cancel(); receiver = nil
        failPending(AppError("The OpenClaw node link closed."))
        for task in invocations.values { task.cancel() }
        invocations.removeAll()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        urlSession?.invalidateAndCancel(); urlSession = nil
    }
}
