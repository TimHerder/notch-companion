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
        var device = try deviceOverride ?? OpenClawDevice.load(account: account)
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
            if let token = granted["deviceToken"] as? String, token != device.token {
                device.token = token; device.scopes = granted["scopes"] as? [String] ?? []
                if deviceOverride == nil { try device.save(account: account) }
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
            return try await hydrate(key)
        }
        if method == "session.resume" {
            guard let key = params["session_id"] as? String, key.hasPrefix("agent:\(agent):notch:") else { throw AppError("This saved OpenClaw session does not belong to the selected companion agent.") }
            return try await hydrate(key, pendingTurnID: params["pending_turn_id"] as? String)
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
    }
}
