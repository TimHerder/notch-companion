import Foundation
import CryptoKit

struct OpenCodeHTTPRejection: LocalizedError, RuntimeDefinitiveRejection {
    let status: Int
    var endpoint: String = ""
    var errorDescription: String? { "OpenCode rejected \(endpoint.isEmpty ? "the request" : endpoint) (HTTP \(status)). Check its native authentication, permissions and configured provider." }
}
struct OpenCodeLocalRejection: LocalizedError, RuntimeDefinitiveRejection {
    let message: String
    var errorDescription: String? { message }
}

/// Native HTTP frontend. This owns the server that executes its work, so its
/// status API is authoritative; it never queries another ACP process's server.
@MainActor
final class OpenCodeClient: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    let profileID: String
    private let executableOverride: URL?
    private let supervisorOverride: URL?
    private var process: Process?
    private var parentInput: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var launchBuffer = Data()
    private var address: URL?
    private var password = ""
    private var generation = UUID()
    private var ready = false
    private var isV2 = false
    /// OpenCode 2 can add a runtime MCP server per session; 1.x cannot.
    private var hostsMCP = false
    /// Hosting sessions: their native folder and delegation launch.
    private var delegations: [String: (location: String, launch: [String: Any])] = [:]
    private var opening: CheckedContinuation<URL, Error>?
    private var deadline: Task<Void, Never>?
    private var streams: [String: Task<Void, Never>] = [:]
    private var streamReady: Set<String> = []
    private var streamWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var polling: [String: Task<Void, Never>] = [:]
    private var refreshing = Set<String>()
    private var refreshAgain = Set<String>()
    private var roots: [String: String] = [:]
    private var parent: [String: String] = [:]
    private var busy = Set<String>()
    private var pendingPrompts = Set<String>()
    private var promptIDs: [String: String] = [:]
    private var failures: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var awaitingChildStart = Set<String>()
    private var started = Set<String>()
    private var finished = Set<String>()
    private var delivered: [String: String] = [:]
    private var tools = Set<String>()
    private var messages: [String: [[String: Any]]] = [:]
    private var requests: [String: [String: Any]] = [:]
    private var answers: [String: [Int: [String]]] = [:]
    private var models: [String: RuntimeModelChoice] = [:]
    private var nativeAgents: [String: String] = [:]
    private var catalogs: [String: RuntimeModelCatalog] = [:]
    private var limits: [String: [String: Int]] = [:]
    private var images: [String: [String]] = [:]
    private var cancelled = Set<String>()
    private static var retiring: [Process] = []
    private let http = URLSession(configuration: .ephemeral, delegate: OpenCodeNoRedirect(), delegateQueue: nil)

    init(profileID: String, executableURL: URL? = nil, supervisorURL: URL? = nil) {
        self.profileID = URL(fileURLWithPath: profileID).standardizedFileURL.resolvingSymlinksInPath().path
        executableOverride = executableURL
        supervisorOverride = supervisorURL
    }
    nonisolated static func supportsVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return value.split(separator: ".", omittingEmptySubsequences: false).count == 3 && parts.count == 3
            && ((parts[0] == 1 && parts[1] == 18 && parts[2] >= 34) || (parts[0] == 2 && parts[1] == 0 && parts[2] >= 30))
    }

    func connect() async throws {
        if ready { return }
        guard process == nil else { throw AppError("OpenCode is already connecting.") }
        try await NativeJSONProcess.awaitPendingStops()
        let until = Date().addingTimeInterval(8)
        while Self.retiring.contains(where: \.isRunning) {
            guard Date() < until else { throw AppError("The previous owned OpenCode server has not finished shutting down.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        Self.retiring.removeAll()
        let executable = try executableOverride ?? RuntimeInstallation.executable(for: .opencode)
        guard let supervisor = supervisorOverride ?? Bundle.main.executableURL else { throw AppError("The app's native OpenCode supervisor is unavailable.") }
        let child = Process(), out = Pipe(), err = Pipe(), lifetime = Pipe()
        password = UUID().uuidString + UUID().uuidString
        var env = RuntimeEnvironment.native(runtime: .opencode, profileID: profileID)
        env["OPENCODE_SERVER_PASSWORD"] = password; env["OPENCODE_SERVER_USERNAME"] = "notch-companion"
        child.executableURL = supervisor; child.arguments = [OpenCodeSupervisor.flag, executable.path]
        child.environment = env; child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = lifetime; child.standardOutput = out; child.standardError = err
        parentInput = lifetime.fileHandleForWriting
        let run = UUID(); generation = run; process = child
        stdout = out.fileHandleForReading; stderr = err.fileHandleForReading
        stdout?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == run else { return }
                if data.isEmpty { self.fail(AppError("The owned OpenCode server closed. Resume its saved session before sending again.")); return }
                self.launchOutput(data)
            }
        }
        stderr?.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == run else { return }
                self.fail(AppError("The owned OpenCode server exited. Other native OpenCode frontends were not stopped."))
            }
        }
        do {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                opening = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, self.generation == run else { return }
                    self.fail(AppError("OpenCode did not report its owned HTTP server address. Check the selected native installation."))
                }
                do { try child.run() } catch { fail(error) }
            }
            address = url
            let health = try await get("/global/health") as? [String: Any] ?? [:]
            guard health["healthy"] as? Bool == true, let version = health["version"] as? String,
                  Self.supportsVersion(version), version.hasPrefix(isV2 ? "2." : "1.") else { throw AppError("This adapter supports OpenCode 1.18.34–1.18.x or 2.0.30–2.0.x with their native HTTP schemas. No conversation was opened.") }
            let doc = try await get("/doc") as? [String: Any] ?? [:]
            let paths = doc["paths"] as? [String: Any] ?? [:]
            let required = isV2 ? OpenCodeV2.requiredPaths : ["/session", "/session/status", "/session/{sessionID}", "/session/{sessionID}/children", "/session/{sessionID}/message", "/session/{sessionID}/prompt_async", "/session/{sessionID}/abort", "/event", "/permission", "/permission/{requestID}/reply", "/question", "/question/{requestID}/reply", "/question/{requestID}/reject", "/provider", "/config"]
            guard required.allSatisfy({ paths[$0] != nil }) else { throw AppError("OpenCode's native HTTP schema is missing required conversation, model, or interaction endpoints.") }
            hostsMCP = isV2 && Self.delegationPaths.allSatisfy { paths[$0] != nil }
            guard generation == run else { throw AppError("The OpenCode connection changed during initialization.") }
            ready = true; onConnectionChange?(true, "OpenCode \(version) native HTTP server connected. Provider authentication is checked on Send.")
        } catch { if generation == run { fail(error) }; throw error }
    }

    private func launchOutput(_ data: Data) {
        guard address == nil else { return }
        launchBuffer.append(data)
        guard launchBuffer.count <= 65_536 else { fail(AppError("OpenCode did not report a bounded native server startup address.")); return }
        while let end = launchBuffer.firstIndex(of: 10) {
            let line = String(decoding: launchBuffer[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            launchBuffer.removeSubrange(...end)
            let prefix = line.hasPrefix("server listening on ") ? "server listening on http://127.0.0.1:" : "opencode server listening on http://127.0.0.1:"
            if line.hasPrefix(prefix), let port = Int(line.dropFirst(prefix.count)), (1...65_535).contains(port),
               let url = URL(string: "http://127.0.0.1:\(port)") {
                isV2 = prefix.hasPrefix("server ")
                address = url; deadline?.cancel(); deadline = nil
                opening?.resume(returning: url); opening = nil; return
            }
        }
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard ready else { throw AppError("OpenCode's owned HTTP frontend is disconnected.") }
        let operation = generation
        if method == "runtime.models" {
            let cwd = try directory(params["cwd"] as? String)
            return ["catalog": try await catalog(cwd), "hosts_delegation": hostsMCP]
        }
        if method == "session.create" || method == "session.resume" {
            let cwd = try directory(params["cwd"] as? String)
            try await stream(cwd)
            try requireGeneration(operation)
            let info: [String: Any]
            if method == "session.create" {
                info = try await call("POST", "/session", cwd: cwd, body: ["title": params["title"] as? String ?? "Companion session", "metadata": ["notch_companion_transport": "http-v1"]]) as? [String: Any] ?? [:]
            } else {
                guard let id = params["session_id"] as? String, !id.isEmpty else { throw AppError("The saved native OpenCode ID is missing.") }
                info = try await get("/session/" + component(id), cwd: cwd) as? [String: Any] ?? [:]
                guard info["id"] as? String == id else { throw AppError("OpenCode returned a different native session ID.") }
                if params["activity_unverified"] as? Bool == true {
                    // A fresh HTTP process cannot prove work in an older ACP
                    // process is idle. Preserve that existing protection.
                    throw AppError("This session has unverified activity from another frontend. Its native history can be preserved, but a different HTTP server cannot certify that old work stopped.")
                }
            }
            guard let sid = info["id"] as? String, !sid.isEmpty,
                  let nativeDirectory = info["directory"] as? String, try directory(nativeDirectory) == cwd else { throw AppError("OpenCode returned a different native working folder. The saved session was not retargeted.") }
            try requireGeneration(operation)
            roots[sid] = cwd
            if let agent = info["agent"] as? String { nativeAgents[sid] = agent }
            if hostsMCP {
                // A reopen without a new launch keeps the server it was opened with.
                if let launch = params["delegation"] as? [String: Any] { delegations[sid] = (nativeDirectory, launch) }
                await openDelegation(sid, permissions: info["permissions"] as? [[String: Any]] ?? [])
                try requireGeneration(operation)
            }
            let models = try await catalog(cwd)
            // Initialization can emit late idle/diff events. Re-read a fenced
            // snapshot rather than strand an empty session as apparent work.
            let until = Date().addingTimeInterval(5)
            var snapshot = try await refresh(sid, restoring: true)
            while snapshot["activity_verified"] as? Bool != true {
                guard Date() < until else { throw AppError("OpenCode's activity is still changing. No new message was sent; reconnect to check its native session.") }
                try await Task.sleep(for: .milliseconds(25))
                snapshot = try await refresh(sid, restoring: true)
            }
            var sessionInfo: [String: Any] = ["capabilities": ["resume": true, "attachments": true, "images": true, "approvals": true, "questions": true, "modelSelection": true, "contextUsage": true, "delegation": true], "capability_note": "Native OpenCode V1 HTTP frontend with authoritative parent and child activity. Provider accounts and project resources stay in OpenCode."]
            sessionInfo["interface"] = isV2 ? "opencode-http-v2" : "opencode-http-v1"
            sessionInfo["capability_note"] = "Native OpenCode HTTP frontend with parent and child activity. Context is an estimate from the latest native model request; accounts and project resources stay in OpenCode."
            if let nativeModel = info["model"] as? [String: Any] { sessionInfo["model"] = nativeModel["id"]; sessionInfo["provider"] = nativeModel["providerID"] }
            sessionInfo.merge(snapshot["info"] as? [String: Any] ?? [:]) { _, new in new }
            var result = snapshot
            result["session_id"] = sid; result["stored_session_id"] = sid; result["profile_id"] = profileID
            result["cwd"] = cwd; result["info"] = sessionInfo; result["catalog"] = models; result["activity_verified"] = true
            result["hosts_delegation"] = hostsMCP
            return result
        }
        let sid = params["session_id"] as? String ?? ""
        guard let cwd = roots[sid] else { throw AppError("This OpenCode session is not registered with the companion.") }
        switch method {
        case "session.model.set":
            guard !isBusy(sid) else { throw AppError("Wait for the parent and all native children before changing models.") }
            let choice = RuntimeModelChoice(model: params["model"] as? String ?? "", provider: params["provider"] as? String)
            let native = try await catalog(cwd)
            try requireGeneration(operation)
            guard native.models.contains(where: { $0.choice == choice }) else { throw AppError("Choose a model from this native OpenCode provider catalog.") }
            if isV2 {
                _ = try await rawCall("POST", "/api/session/\(component(sid))/model", body: ["model": ["id": choice.model, "providerID": choice.provider ?? ""]])
                let actual = try await get("/session/\(component(sid))", cwd: cwd) as? [String: Any] ?? [:]
                let model = actual["model"] as? [String: Any] ?? [:]
                guard model["id"] as? String == choice.model, model["providerID"] as? String == choice.provider else { throw AppError("OpenCode did not confirm the selected model. No prompt was sent.") }
            }
            models[sid] = choice; return [:] // Applied by native prompt's model override.
        case "file.attach", "image.attach":
            guard let path = params["path"] as? String else { throw AppError("Attachment path is missing.") }
            let file = URL(fileURLWithPath: path).standardizedFileURL
            let values = try file.resourceValues(forKeys: [.isReadableKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.isReadable == true else { throw AppError("The attached local file is no longer readable.") }
            if method == "image.attach" {
                guard Self.mime(file) != nil else { throw AppError("OpenCode image attachments must be PNG, JPEG, GIF or WebP.") }
                if !(images[sid] ?? []).contains(file.path) { images[sid, default: []].append(file.path) }
                return ["path": file.path]
            }
            return ["ref_text": "Attached local file (read with your native tools): " + CodexProtocolState.describe([file.path])]
        case "image.detach":
            if let path = params["path"] as? String { images[sid]?.removeAll { $0 == path } }; return [:]
        case "prompt.steer":
            guard isV2, busy.contains(sid) else { throw OpenCodeLocalRejection(message: "Steering requires a running OpenCode 2 turn.") }
            var parts: [[String: Any]] = [["type": "text", "text": params["text"] as? String ?? ""]]
            for path in params["images"] as? [String] ?? [] {
                let file: URL
                do { file = try ClaudeClient.attachment(["path": path]) }
                catch { throw OpenCodeLocalRejection(message: error.localizedDescription) }
                guard let mime = Self.mime(file) else { throw OpenCodeLocalRejection(message: "Unsupported image type.") }
                parts.append(["type": "file", "mime": mime, "filename": file.lastPathComponent, "url": file.absoluteString])
            }
            let id = "msg_" + (params["turn_id"] as? String ?? UUID().uuidString)
            _ = try await call("POST", "/session/\(component(sid))/prompt_async", cwd: cwd, body: ["messageID": id, "parts": parts])
            try requireGeneration(operation)
            scheduleRefresh(sid)
            return ["steered": true, "turn_id": id]
        case "prompt.submit":
            guard !isBusy(sid) else { throw OpenCodeLocalRejection(message: "This OpenCode session or a delegated child is still active.") }
            // An idle folder drops runtime servers; re-adding an unchanged one keeps its connection.
            if delegations[sid] != nil, (try? await registerDelegation(sid)) == nil {
                event("runtime.notice", sid: sid, ["message": Self.delegationNotice])
            }
            // Reconcile just before sending, including background descendants.
            var checked: [String: Any]
            do {
                checked = try await refresh(sid)
                let until = Date().addingTimeInterval(2)
                // A late idle event can invalidate the read without indicating
                // new work. Recheck that uncertainty before rejecting the draft.
                while checked["activity_verified"] as? Bool != true, Date() < until {
                    try requireGeneration(operation)
                    try await Task.sleep(for: .milliseconds(25))
                    checked = try await refresh(sid)
                }
            }
            catch { throw OpenCodeLocalRejection(message: "No new prompt was sent. " + error.localizedDescription) }
            try requireGeneration(operation)
            guard checked["running"] as? Bool != true, !isBusy(sid) else { throw OpenCodeLocalRejection(message: "Native OpenCode reports active or changing work; another message was not sent.") }
            pendingPrompts.insert(sid); finished.remove(sid); started.remove(sid); delivered[sid] = ""
            let id = "msg_" + (params["turn_id"] as? String ?? UUID().uuidString)
            promptIDs[sid] = id; failures.removeValue(forKey: sid); cancelled.remove(sid)
            var parts: [[String: Any]] = [["type": "text", "text": params["text"] as? String ?? ""]]
            for path in images[sid] ?? [] { let file = URL(fileURLWithPath: path); parts.append(["type": "file", "mime": Self.mime(file)!, "filename": file.lastPathComponent, "url": file.absoluteString]) }
            var body: [String: Any] = ["messageID": id, "parts": parts]
            if let agent = nativeAgents[sid] { body["agent"] = agent }
            if let choice = models[sid], let provider = choice.provider { body["model"] = ["providerID": provider, "modelID": choice.model] }
            var queued = false
            do {
                _ = try await call("POST", "/session/\(component(sid))/prompt_async", cwd: cwd, body: body)
                queued = true
                images.removeValue(forKey: sid)
                // V1 queues prompt_async before its durable input is promised.
                // Wait for our exact native ID, not merely HTTP acceptance.
                let until = Date().addingTimeInterval(45)
                while !(messages[sid] ?? []).contains(where: { ($0["info"] as? [String: Any])?["id"] as? String == id }) {
                    try requireGeneration(operation)
                    let receipt = try await refresh(sid)
                    if failures[sid] != nil, receipt["running"] as? Bool == false {
                        // Session errors have no message ID. They cannot prove
                        // this queued input was rejected rather than an older
                        // operation failing. Retire, then reconcile exact history.
                        throw AppError("OpenCode reported a queued error without confirming this input's native ID. Reconnect and check the saved session before retrying.")
                    }
                    guard Date() < until else { throw AppError("OpenCode accepted a queue request but did not confirm its native message ID. Reconnect and check the saved session before retrying.") }
                    if !(messages[sid] ?? []).contains(where: { ($0["info"] as? [String: Any])?["id"] as? String == id }) { try await Task.sleep(for: .milliseconds(50)) }
                }
                if pendingPrompts.contains(sid), !finished.contains(sid) { start(sid) }; scheduleRefresh(sid)
                return ["accepted": true, "turn_id": id]
            } catch {
                let failure: Error = queued && error is RuntimeDefinitiveRejection
                    ? AppError("OpenCode accepted the queue request, but its delivery receipt could not be read. Reconnect and check the saved session before retrying.") : error
                if generation == operation {
                    if failure is RuntimeDefinitiveRejection { pendingPrompts.remove(sid) }
                    else { fail(failure) }
                }
                throw failure
            }
        case "session.interrupt":
            _ = try await refresh(sid)
            let ids = [sid] + parent.filter { $0.value == sid }.map(\.key)
            for id in ids {
                try requireGeneration(operation)
                cancelled.insert(id); _ = try await call("POST", "/session/\(component(id))/abort", cwd: cwd)
                awaitingChildStart.remove(id)
            }
            let until = Date().addingTimeInterval(5)
            repeat {
                try requireGeneration(operation)
                let settled = try await refresh(sid)
                if settled["running"] as? Bool == false, !isBusy(sid) { return ["interrupted": true] }
                try await Task.sleep(for: .milliseconds(75))
            } while Date() < until
            throw AppError("OpenCode accepted cancellation but still reports native work. Its activity remains visible.")
        case "approval.respond", "clarify.respond":
            return try await answer(params, approval: method == "approval.respond", sid: sid, cwd: cwd)
        case "session.rename":
            _ = try await call("PATCH", "/session/\(component(sid))", cwd: cwd, body: ["title": params["title"] as? String ?? ""]); return [:]
        default: throw AppError("OpenCode's native HTTP interface does not implement \(method) here.")
        }
    }

    private func directory(_ value: String?) throws -> String {
        guard let value, value.hasPrefix("/") else { throw AppError("Choose the conversation's existing native working folder.") }
        let url = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw AppError("The native working folder is unavailable.") }
        return url.path
    }
    private func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func isBusy(_ sid: String) -> Bool {
        pendingPrompts.contains(sid) || busy.contains(sid) || parent.contains { $0.value == sid && busy.contains($0.key) }
            || requests.values.contains { root($0["sessionID"] as? String ?? "") == sid }
    }
    private func root(_ sid: String) -> String? { roots[sid] != nil ? sid : parent[sid] }
    private func event(_ name: String, sid: String, _ payload: [String: Any] = [:]) {
        guard let owner = root(sid) else { return }
        var values = payload; values["session_id"] = owner
        if owner != sid { values["subagent_id"] = sid }
        onEvent?(name, values)
    }
    private func start(_ sid: String) {
        busy.insert(sid)
        if let expected = promptIDs[sid], !(messages[sid] ?? []).contains(where: { ($0["info"] as? [String: Any])?["id"] as? String == expected }) { return }
        if started.insert(sid).inserted { event(roots[sid] == nil ? "subagent.thinking" : "message.start", sid: sid, ["role": "assistant", "status": "working"]) }
    }

    private func catalog(_ cwd: String) async throws -> RuntimeModelCatalog {
        let run = generation
        if isV2 {
            let query = "?location%5Bdirectory%5D=" + component(cwd)
            let rows = try await v2List("/api/model" + query)
            let current = try await v2Data("GET", "/api/model/default" + query) as? [String: Any] ?? [:]
            let result = OpenCodeV2.catalog(rows, current: current)
            try requireGeneration(run)
            catalogs[cwd] = result
            limits[cwd] = Dictionary(rows.compactMap { row -> (String, Int)? in
                guard let model = row["id"] as? String, let provider = row["providerID"] as? String,
                      let limit = (row["limit"] as? [String: Any])?["context"] as? Int, limit > 0 else { return nil }
                return (provider + "/" + model, limit)
            }, uniquingKeysWith: { _, new in new })
            return result
        }
        let config = try await get("/config", cwd: cwd) as? [String: Any] ?? [:]
        let response = try await get("/provider", cwd: cwd) as? [String: Any] ?? [:]
        let connected = Set(response["connected"] as? [String] ?? [])
        var options: [RuntimeModelOption] = [], windows: [String: Int] = [:]
        for provider in response["all"] as? [[String: Any]] ?? [] {
            guard let id = provider["id"] as? String, connected.contains(id) else { continue }
            for (modelID, value) in provider["models"] as? [String: [String: Any]] ?? [:] {
                options.append(RuntimeModelOption(choice: RuntimeModelChoice(model: modelID, provider: id), title: value["name"] as? String ?? modelID))
                if let limit = (value["limit"] as? [String: Any])?["context"] as? Int, limit > 0 { windows[id + "/" + modelID] = limit }
            }
        }
        let configured = (config["model"] as? String)?.split(separator: "/", maxSplits: 1).map(String.init)
        let choice = configured?.count == 2 ? RuntimeModelChoice(model: configured![1], provider: configured![0]) : nil
        let result = RuntimeModelCatalog(defaultModel: choice, models: options.sorted { $0.title < $1.title }, configuredContextWindow: configured.map { windows[$0.joined(separator: "/")] } ?? nil,
            note: "Models from native connected providers. The first send inherits OpenCode's native default; explicit choices apply per prompt.")
        try requireGeneration(run)
        catalogs[cwd] = result; limits[cwd] = windows; return result
    }

    private func makeRequest(_ method: String, _ path: String, cwd: String?, body: [String: Any]?) throws -> URLRequest {
        guard let address, let url = URL(string: path, relativeTo: address)?.absoluteURL, url.host == "127.0.0.1", url.port == address.port else { throw AppError("The owned OpenCode address is unavailable.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 45
        request.setValue("Basic " + Data(((isV2 ? "opencode:" : "notch-companion:") + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let cwd { request.setValue(cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), forHTTPHeaderField: "x-opencode-directory") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func get(_ path: String, cwd: String? = nil) async throws -> Any { try await call("GET", path, cwd: cwd) }
    private func call(_ method: String, _ path: String, cwd: String? = nil, body: [String: Any]? = nil) async throws -> Any {
        if isV2 { return try await callV2(method, path, cwd: cwd, body: body) }
        return try await rawCall(method, path, cwd: cwd, body: body)
    }
    private func rawCall(_ method: String, _ path: String, cwd: String? = nil, body: [String: Any]? = nil) async throws -> Any {
        let run = generation
        let (bytes, response) = try await http.bytes(for: makeRequest(method, path, cwd: cwd, body: body))
        guard let response = response as? HTTPURLResponse else { throw AppError("OpenCode returned an invalid HTTP response.") }
        guard (200..<300).contains(response.statusCode) else {
            if [400, 401, 403, 404, 409, 422].contains(response.statusCode) {
                let data = try await Self.readBody(bytes)
                let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["_tag"] as? String ?? ""
                throw OpenCodeHTTPRejection(status: response.statusCode, endpoint: method + " " + String(path.split(separator: "?", maxSplits: 1)[0]) + (tag.isEmpty ? "" : " (" + tag + ")"))
            }
            throw AppError("OpenCode returned HTTP \(response.statusCode). A submitted message may have reached the native session; inspect history before retrying.")
        }
        let data = try await Self.readBody(bytes)
        guard generation == run else { throw AppError("The OpenCode connection changed during the request.") }
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // Native provider catalogs are several MB. Iterating AsyncBytes on the
    // main actor hops back for every byte, blocking startup and SSE heartbeats.
    nonisolated private static func readBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32 * 1024 * 1024 else { throw AppError("OpenCode's native history response exceeds the safe 32 MB limit; the local transcript was preserved.") }
            data.append(byte)
        }
        return data
    }

    private func stream(_ cwd: String) async throws {
        if streamReady.contains(cwd) { return }
        guard streams[cwd] == nil else { throw AppError("The native project event stream is still connecting.") }
        let run = generation
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            streamWaiters[cwd] = waiter
            streams[cwd] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    var request = try self.makeRequest("GET", self.isV2 ? "/api/event" : "/event", cwd: cwd, body: nil); request.timeoutInterval = 60
                    let (bytes, response) = try await self.http.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("OpenCode refused the native event stream.") }
                    var decoder = OpenCodeSSEDecoder()
                    for try await byte in bytes {
                        guard self.generation == run, !Task.isCancelled else { return }
                        if let frame = try decoder.append(byte) { self.receive(self.isV2 ? OpenCodeV2.event(frame) : frame, cwd: cwd) }
                    }
                    throw AppError("OpenCode's native event stream ended. Reconnect to reconcile exact session history before sending again.")
                } catch {
                    guard self.generation == run, !Task.isCancelled else { return }; self.fail(error)
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.generation == run, self.streamWaiters[cwd] != nil else { return }
                self.fail(AppError("OpenCode did not establish a native event subscription."))
            }
        }
    }

    private func receive(_ frame: [String: Any], cwd: String) {
        guard let type = frame["type"] as? String else { fail(AppError("OpenCode sent an invalid event.")); return }
        if type == "server.connected" { streamReady.insert(cwd); streamWaiters.removeValue(forKey: cwd)?.resume(); return }
        if type == "server.heartbeat" { return }
        if type == "server.instance.disposed" { fail(AppError("OpenCode disposed this native project. Reconnect before continuing.")); return }
        let props = frame["properties"] as? [String: Any] ?? [:]
        let info = props["info"] as? [String: Any] ?? [:]
        if type == "session.created", let sid = info["id"] as? String, let p = info["parentID"] as? String, let owner = root(p), roots[owner] == cwd {
            revisions[owner, default: 0] += 1; awaitingChildStart.insert(sid)
            parent[sid] = owner; busy.insert(sid); finished.remove(sid)
            event("subagent.start", sid: sid, ["name": info["title"] as? String ?? "OpenCode agent"])
            scheduleRefresh(owner)
            return
        }
        let sid = props["sessionID"] as? String ?? info["sessionID"] as? String ?? (props["part"] as? [String: Any])?["sessionID"] as? String ?? ""
        guard let owner = root(sid), roots[owner] == cwd else { return }
        revisions[owner, default: 0] += 1
        if type == "session.error" {
            let error = props["error"] as? [String: Any]
            failures[sid] = ((error?["data"] as? [String: Any])?["message"] as? String) ?? (error?["name"] as? String) ?? CodexProtocolState.describe(props["error"])
            event("runtime.notice", sid: sid, ["message": "OpenCode reported a native turn error. Checking its final state."])
        }
        if type == "session.status", let status = props["status"] as? [String: Any] {
            awaitingChildStart.remove(sid)
            if status["type"] as? String != "idle" { finished.remove(sid); start(sid) }
        }
        // Snapshot reconciliation handles complete and delta-only variants. It
        // retains native message/part identities and never ends at first reply.
        scheduleRefresh(owner)
    }

    private func scheduleRefresh(_ sid: String) {
        guard polling[sid] == nil else { refreshAgain.insert(sid); return }
        let run = generation
        polling[sid] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            guard let self, self.generation == run else { return }
            do { _ = try await self.refresh(sid) }
            catch { if self.generation == run { self.fail(error) } }
            guard self.generation == run else { return }
            self.polling.removeValue(forKey: sid)
            if self.refreshAgain.remove(sid) != nil { self.scheduleRefresh(sid) }
        }
    }

    private func refresh(_ sid: String, restoring: Bool = false) async throws -> [String: Any] {
        let run = generation
        guard let cwd = roots[sid] else { throw AppError("Unknown OpenCode root session.") }
        // Serialize snapshots per root; a control operation waits for an event
        // refresh rather than racing its status/history against a second one.
        while refreshing.contains(sid) { try await Task.sleep(for: .milliseconds(10)) }
        try requireGeneration(run)
        refreshing.insert(sid); defer { if generation == run { refreshing.remove(sid) } }
        let revision = revisions[sid, default: 0]
        var newlyDiscovered = Set<String>()
        var queue = [sid], descendants: [[String: Any]] = [], seen: Set<String> = [sid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let children = try await list("/session/\(component(next))/children", cwd: cwd)
            for child in children {
                guard let id = child["id"] as? String, child["parentID"] as? String == next,
                      let childCwd = child["directory"] as? String, try directory(childCwd) == cwd else { throw AppError("OpenCode reported an invalid child identity or workspace.") }
                guard seen.insert(id).inserted, seen.count <= 256 else { throw AppError("OpenCode returned cyclic or excessive delegated sessions.") }
                descendants.append(child); queue.append(id)
                if parent[id] == nil { parent[id] = sid; newlyDiscovered.insert(id) }
            }
        }
        let permissions = try await list("/permission", cwd: cwd)
        let questions = try await list("/question", cwd: cwd)
        let interactions = (permissions.map { ("permission", $0) } + questions.map { ("question", $0) }).filter { seen.contains($0.1["sessionID"] as? String ?? "") }
        guard let statuses = try await get("/session/status", cwd: cwd) as? [String: [String: Any]] else { throw AppError("OpenCode returned invalid native session status; idle state cannot be established.") }
        var histories: [String: [[String: Any]]] = [:]
        let ids = [sid] + descendants.compactMap { $0["id"] as? String }
        for id in ids {
            let rows = try await list("/session/\(component(id))/message", cwd: cwd)
            guard rows.allSatisfy({ ($0["info"] as? [String: Any])?["sessionID"] as? String == id }) else { throw AppError("OpenCode history contained a different session identity.") }
            histories[id] = rows
        }
        // HTTP discovery can precede child creation while SSE trails the later
        // status/history reads. Recheck every discovered parent's child set
        // before allowing this snapshot to declare the whole tree idle.
        var topologyUnchanged = true
        if revisions[sid, default: 0] == revision {
            for id in ids {
                let children = try await list("/session/\(component(id))/children", cwd: cwd)
                let currentIDs = try children.map { child -> String in
                    guard let childID = child["id"] as? String, child["parentID"] as? String == id,
                          let childCwd = child["directory"] as? String, try directory(childCwd) == cwd else {
                        throw AppError("OpenCode reported an invalid child identity or workspace.")
                    }
                    return childID
                }
                let expectedIDs = Set(descendants.filter { $0["parentID"] as? String == id }.compactMap { $0["id"] as? String })
                if Set(currentIDs) != expectedIDs || currentIDs.count != expectedIDs.count {
                    topologyUnchanged = false
                    break
                }
            }
        }
        guard generation == run else { throw AppError("The OpenCode connection changed during native activity reconciliation.") }
        let stable = topologyUnchanged && revisions[sid, default: 0] == revision
        if !topologyUnchanged { busy.insert(sid) }
        if !stable { refreshAgain.insert(sid); scheduleRefresh(sid) }
        if !restoring {
            for child in descendants where newlyDiscovered.contains(child["id"] as? String ?? "") {
                if let id = child["id"] as? String { awaitingChildStart.insert(id); event("subagent.start", sid: id, ["name": child["title"] as? String ?? "OpenCode agent"]) }
            }
        }
        var snapshots: [[String: Any]] = [], contextInfo: [String: Any] = [:]
        for id in ids {
            let rows = histories[id] ?? []
            messages[id] = rows
            if let lastUser = rows.last(where: { ($0["info"] as? [String: Any])?["role"] as? String == "user" }),
               let agent = (lastUser["info"] as? [String: Any])?["agent"] as? String, nativeAgents[id] == nil { nativeAgents[id] = agent }
            let observedPrompt = promptIDs[id].map { wanted in rows.contains { ($0["info"] as? [String: Any])?["id"] as? String == wanted } } ?? true
            let currentText = observedPrompt ? Self.currentText(rows) : ""
            let nativeBusy = statuses[id].map { $0["type"] as? String != "idle" } ?? false
            let waiting = interactions.contains { $0.1["sessionID"] as? String == id }
            let last = rows.last?["info"] as? [String: Any] ?? [:]
            let settled = last["role"] as? String == "assistant" && (last["time"] as? [String: Any])?["completed"] != nil
            // A just-accepted prompt can precede its first native message. Keep
            // it busy until history includes a new user input and settles.
            let active = nativeBusy || waiting || (!stable && busy.contains(id))
                || (awaitingChildStart.contains(id) && !settled)
                || (pendingPrompts.contains(id) && !cancelled.contains(id) && (!observedPrompt || !settled) && failures[id] == nil)
            if active { busy.insert(id); if !restoring { start(id) } }
            else { busy.remove(id) }
            if restoring {
                delivered[id] = currentText
                for row in rows { for part in row["parts"] as? [[String: Any]] ?? [] where part["type"] as? String == "tool" {
                    if let toolID = part["id"] as? String { tools.insert(id + ":" + toolID) }
                } }
            }
            else {
                let deliver = { (text: String) in
                    let previous = self.delivered[id] ?? ""
                    guard text.hasPrefix(previous), text.count > previous.count else { return }
                    self.event(id == sid ? "message.delta" : "subagent.text", sid: id, ["text": String(text.dropFirst(previous.count))])
                    self.delivered[id] = text
                }
                // Text written before a call first seen in this poll goes out ahead
                // of it; text after the call then starts a new segment.
                if observedPrompt {
                    if let head = textBeforeNewTool(rows, sid: id) { deliver(head) }
                    projectTools(rows, sid: id)
                }
                deliver(currentText)
                delivered[id] = currentText
            }
            if id != sid {
                let status = active ? (waiting ? "waiting" : "working") : Self.terminal(last, cancelled: cancelled.contains(id))
                snapshots.append(["id": id, "name": descendants.first(where: { $0["id"] as? String == id })?["title"] as? String ?? "OpenCode agent", "text": currentText, "status": status])
                if !restoring, stable, !active, finished.insert(id).inserted { event("subagent.complete", sid: id, ["text": currentText, "status": status]) }
            }
            let latestUsage = rows.last(where: { ($0["info"] as? [String: Any])?["tokens"] is [String: Any] })?["info"] as? [String: Any] ?? [:]
            if let tokens = latestUsage["tokens"] as? [String: Any], id == sid,
               let input = tokens["input"] as? Int, let cache = tokens["cache"] as? [String: Any],
               let read = cache["read"] as? Int, let write = cache["write"] as? Int,
               input >= 0, read >= 0, write >= 0, !input.addingReportingOverflow(read).overflow, !(input + read).addingReportingOverflow(write).overflow {
                var usage: [String: Any] = ["context_used": input + read + write, "context_estimated": true]
                if let provider = latestUsage["providerID"] as? String, let model = latestUsage["modelID"] as? String,
                   let limit = limits[cwd]?[provider + "/" + model] { usage["context_max"] = limit }
                contextInfo = ["usage": usage, "model": latestUsage["modelID"] ?? "", "provider": latestUsage["providerID"] ?? ""]
                event("session.info", sid: sid, contextInfo)
            }
        }
        let currentIDs = Set(interactions.compactMap { $0.1["id"] as? String })
        for (key, request) in requests where stable && root(request["sessionID"] as? String ?? "") == sid && !currentIDs.contains(key) {
            event("clarify.expire", sid: request["sessionID"] as? String ?? sid, ["request_id": key]); requests.removeValue(forKey: key); answers.removeValue(forKey: key)
        }
        for (kind, request) in interactions { publishRequest(kind, request) }
        let allIdle = stable && !seen.contains(where: { busy.contains($0) }) && !parent.contains(where: { $0.value == sid && busy.contains($0.key) }) && interactions.isEmpty
        if !restoring, allIdle, (started.contains(sid) || pendingPrompts.contains(sid)), finished.insert(sid).inserted {
            let confirmed = promptIDs[sid].map { expected in (messages[sid] ?? []).contains { ($0["info"] as? [String: Any])?["id"] as? String == expected } } ?? true
            if confirmed {
                pendingPrompts.remove(sid)
                let last = messages[sid]?.last?["info"] as? [String: Any] ?? [:]
                event("message.complete", sid: sid, ["text": delivered[sid] ?? "", "status": failures[sid] != nil ? "error" : Self.terminal(last, cancelled: cancelled.remove(sid) != nil), "error": failures[sid] ?? ""])
            }
        }
        return ["messages": Self.history(messages[sid] ?? []), "history_complete": true, "running": !allIdle, "parent_complete": stable && !busy.contains(sid), "subagents": snapshots, "activity_verified": stable, "info": contextInfo]
    }

    private func projectTools(_ rows: [[String: Any]], sid: String) {
        // Native child calls use the same parent tool history with stable IDs;
        // child text/status still has its own detail view and lifecycle.
        for row in rows {
            for part in row["parts"] as? [[String: Any]] ?? [] where part["type"] as? String == "tool" {
                guard let id = part["id"] as? String else { continue }
                let key = sid + ":" + id, state = part["state"] as? [String: Any] ?? [:]
                if tools.insert(key).inserted { event("tool.start", sid: sid, ["tool_id": key, "name": part["tool"] as? String ?? "Tool", "context": CodexProtocolState.describe(state["input"])]) }
                if ["completed", "error"].contains(state["status"] as? String ?? "") { event("tool.complete", sid: sid, ["tool_id": key, "is_error": state["status"] as? String == "error", "result": state["output"] ?? state["error"] ?? ""]) }
            }
        }
    }
    /// The current turn's text up to the first tool part not projected yet.
    private func textBeforeNewTool(_ rows: [[String: Any]], sid: String) -> String? {
        let lastUser = rows.lastIndex { ($0["info"] as? [String: Any])?["role"] as? String == "user" } ?? -1
        for index in rows.indices.dropFirst(lastUser + 1) {
            let parts = rows[index]["parts"] as? [[String: Any]] ?? []
            guard let cut = parts.firstIndex(where: { part in
                part["type"] as? String == "tool" && (part["id"] as? String).map { !tools.contains(sid + ":" + $0) } == true
            }) else { continue }
            var row = rows[index]; row["parts"] = Array(parts[..<cut])
            return Self.currentText(Array(rows[..<index]) + [row])
        }
        return nil
    }
    private func list(_ path: String, cwd: String) async throws -> [[String: Any]] {
        guard let value = try await get(path, cwd: cwd) as? [[String: Any]] else { throw AppError("OpenCode returned an invalid native list. Saved history and work were preserved.") }
        return value
    }
    private func publishRequest(_ kind: String, _ value: [String: Any]) {
        guard let id = value["id"] as? String, requests[id] == nil, let sid = value["sessionID"] as? String else { return }
        var stored = value; stored["kind"] = kind; requests[id] = stored
        if parent[sid] != nil { event("subagent.thinking", sid: sid, ["status": "waiting"]) }
        if kind == "permission" {
            event("approval.request", sid: sid, ["request_id": id, "choices": ["once", "deny"], "command": [value["permission"] as? String ?? "Permission", CodexProtocolState.describe(value["patterns"]), CodexProtocolState.describe(value["metadata"])].joined(separator: "\n")])
        } else {
            let questions = value["questions"] as? [[String: Any]] ?? []
            guard !questions.isEmpty, questions.count <= 16, questions.allSatisfy({ $0["question"] is String && $0["options"] is [[String: Any]] && $0["isSecret"] as? Bool != true }) else {
                let run = generation
                Task { @MainActor [weak self] in
                    guard let self, let owner = self.root(sid), let cwd = self.roots[owner], self.generation == run else { return }
                    do {
                        _ = try await self.call("POST", "/question/\(self.component(id))/reject", cwd: cwd)
                        self.requests.removeValue(forKey: id)
                        self.event("runtime.notice", sid: sid, ["message": "OpenCode requested a question this interface cannot safely render. It was declined; use the native interface for that interaction."])
                    } catch { if self.generation == run { self.fail(error) } }
                }
                return
            }
            event("clarify.request", sid: sid, ["request_id": id, "questions": questions.enumerated().map { index, q in
                ["qid": String(index), "header": q["header"] as? String ?? "", "question": q["question"] as? String ?? "Question", "choices": (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }, "choice_details": Dictionary((q["options"] as? [[String: Any]] ?? []).compactMap { option -> (String, String)? in
                    guard let label = option["label"] as? String, let detail = option["description"] as? String else { return nil }; return (label, detail)
                }, uniquingKeysWith: { _, new in new }), "multi_select": q["multiple"] as? Bool ?? false, "allows_free_text": q["custom"] as? Bool ?? true] as [String: Any]
            }])
        }
    }
    private func answer(_ params: [String: Any], approval: Bool, sid: String, cwd: String) async throws -> [String: Any] {
        let run = generation
        let id = params["request_id"] as? String ?? ""
        guard let value = requests[id], let native = value["sessionID"] as? String, root(native) == sid else { throw AppError("That native OpenCode request expired or belongs to another session.") }
        if approval {
            guard value["kind"] as? String == "permission", let choice = params["choice"] as? String, ["once", "deny"].contains(choice) else { throw AppError("Choose only a native one-shot permission decision.") }
            _ = try await call("POST", "/permission/\(component(id))/reply", cwd: cwd, body: ["reply": choice == "once" ? "once" : "reject"])
        } else {
            guard value["kind"] as? String == "question", let index = Int(params["question_id"] as? String ?? "0") else { throw AppError("This is not a native question.") }
            let questions = value["questions"] as? [[String: Any]] ?? []
            guard questions.indices.contains(index) else { throw AppError("That native question has expired.") }
            let q = questions[index], options = (questions[index]["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            let values = q["multiple"] as? Bool == true ? (params["answers"] as? [String] ?? [params["answer"] as? String ?? ""]) : [params["answer"] as? String ?? ""]
            guard q["custom"] as? Bool != false || values.allSatisfy(options.contains) else { throw AppError("Choose an answer offered by native OpenCode.") }
            answers[id, default: [:]][index] = values
            guard answers[id]?.count == questions.count else { return ["resolved": false] }
            _ = try await call("POST", "/question/\(component(id))/reply", cwd: cwd, body: ["answers": questions.indices.map { answers[id]?[$0] ?? [] }])
        }
        try requireGeneration(run)
        requests.removeValue(forKey: id); answers.removeValue(forKey: id); scheduleRefresh(sid)
        return ["resolved": true]
    }
    /// One row per native message.
    nonisolated static func messageRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.compactMap { row in
            guard let info = row["info"] as? [String: Any], let role = info["role"] as? String, let id = info["id"] as? String else { return nil }
            let text = (row["parts"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" && $0["synthetic"] as? Bool != true }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            var result: [String: Any] = ["role": role, "text": text, "row_id": id]
            if role == "user", id.hasPrefix("msg_") { result["client_id"] = String(id.dropFirst(4)) }
            return result
        }
    }
    /// Replies split where they streamed: consecutive assistant messages join, and a
    /// tool call starts a new reply.
    nonisolated static func history(_ rows: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var open = false // the last row is a reply that later text continues
        for row in rows {
            guard let info = row["info"] as? [String: Any], let id = info["id"] as? String else { continue }
            guard info["role"] as? String == "assistant" else { result += messageRows([row]); open = false; continue }
            for (offset, part) in (row["parts"] as? [[String: Any]] ?? []).enumerated() {
                if part["type"] as? String == "tool" { open = false; continue }
                guard part["type"] as? String == "text", part["synthetic"] as? Bool != true,
                      let text = part["text"] as? String, !text.isEmpty else { continue }
                if open, let last = result.indices.last {
                    result[last]["text"] = (result[last]["text"] as? String ?? "") + "\n\n" + text
                } else {
                    // A message's first reply keeps the message's ID.
                    let rowID = result.contains { $0["row_id"] as? String == id } ? id + ":" + String(offset) : id
                    result.append(["role": "assistant", "text": text, "row_id": rowID]); open = true
                }
            }
        }
        return result
    }
    nonisolated static func currentText(_ rows: [[String: Any]]) -> String {
        let lastUser = rows.lastIndex { ($0["info"] as? [String: Any])?["role"] as? String == "user" } ?? -1
        return messageRows(Array(rows.dropFirst(lastUser + 1))).filter { $0["role"] as? String == "assistant" }.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    nonisolated static func terminal(_ info: [String: Any], cancelled: Bool) -> String {
        if cancelled { return "interrupted" }
        if let error = info["error"] as? [String: Any] { return error["name"] as? String == "MessageAbortedError" ? "interrupted" : "error" }
        return (info["time"] as? [String: Any])?["completed"] != nil ? "complete" : "interrupted"
    }
    private static func mime(_ url: URL) -> String? { ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()] }
    private func requireGeneration(_ run: UUID) throws {
        guard generation == run else { throw AppError("The OpenCode connection changed; no stale response was applied.") }
    }
    func disconnect() { cleanup(AppError("OpenCode disconnected.")); onConnectionChange?(false, nil) }
    private func fail(_ error: Error) { cleanup(error); onConnectionChange?(false, error.localizedDescription) }
    private func cleanup(_ error: Error) {
        generation = UUID(); ready = false; deadline?.cancel(); deadline = nil
        opening?.resume(throwing: error); opening = nil
        for waiter in streamWaiters.values { waiter.resume(throwing: error) }; streamWaiters.removeAll()
        for task in streams.values { task.cancel() }; streams.removeAll(); streamReady.removeAll()
        for task in polling.values { task.cancel() }; polling.removeAll(); refreshing.removeAll(); refreshAgain.removeAll()
        stdout?.readabilityHandler = nil; stderr?.readabilityHandler = nil; stdout = nil; stderr = nil
        try? parentInput?.close(); parentInput = nil
        if let child = process, child.isRunning {
            // EOF drives the same-app supervisor's bounded native shutdown,
            // including when the original companion process died unexpectedly.
            child.terminationHandler = nil; Self.retiring.append(child)
        }
        process = nil; address = nil; launchBuffer.removeAll(); password = ""; isV2 = false; hostsMCP = false
        delegations.removeAll(); roots.removeAll(); parent.removeAll(); busy.removeAll(); started.removeAll(); finished.removeAll(); pendingPrompts.removeAll()
        promptIDs.removeAll(); failures.removeAll()
        revisions.removeAll(); awaitingChildStart.removeAll()
        delivered.removeAll(); messages.removeAll(); requests.removeAll(); answers.removeAll(); models.removeAll(); images.removeAll(); tools.removeAll()
        nativeAgents.removeAll()
    }
}

extension OpenCodeClient {
    private func v2Data(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        let response = try await rawCall(method, path, body: body)
        guard let envelope = response as? [String: Any], let data = envelope["data"] else {
            throw AppError("OpenCode V2 returned an invalid native response envelope.")
        }
        return data
    }

    private func v2List(_ path: String, paginated: Bool = false) async throws -> [[String: Any]] {
        var result: [[String: Any]] = [], next = path, cursors = Set<String>()
        repeat {
            guard let response = try await rawCall("GET", next) as? [String: Any], let rows = response["data"] as? [[String: Any]] else {
                throw AppError("OpenCode V2 returned an invalid native list; saved history was preserved.")
            }
            result += rows
            guard result.count <= 100_000 else { throw AppError("OpenCode's native history exceeds the supported snapshot size.") }
            guard paginated else { return result }
            guard let page = response["cursor"] as? [String: Any], let value = page["next"] else { throw AppError("OpenCode omitted its native history pagination boundary.") }
            if value is NSNull { return result }
            guard let cursor = value as? String, !cursor.isEmpty else { throw AppError("OpenCode returned an invalid history cursor.") }
            guard cursors.insert(cursor).inserted, cursors.count <= 1000 else { throw AppError("OpenCode returned repeating or excessive history pages.") }
            var url = URLComponents(string: path)!
            url.queryItems = (url.queryItems ?? []).filter { $0.name != "order" && $0.name != "cursor" } + [URLQueryItem(name: "cursor", value: cursor)]
            next = url.string!
        } while true
    }

    private func callV2(_ method: String, _ path: String, cwd: String?, body: [String: Any]?) async throws -> Any {
        if path == "/global/health" {
            var info = try await rawCall("GET", "/api/info") as? [String: Any] ?? [:]
            info["healthy"] = true; return info
        }
        if path == "/doc" { return try await rawCall("GET", "/openapi.json") }
        if path == "/session", method == "POST" {
            let value = try await v2Data(method, "/api/session", body: ["title": body?["title"] ?? "Companion session", "location": ["directory": cwd ?? ""], "metadata": ["notch_companion_transport": "http-v2"]])
            guard let info = value as? [String: Any] else { throw AppError("OpenCode did not return its created session.") }
            return OpenCodeV2.session(info)
        }
        let owned = Array(roots.keys) + Array(parent.keys)
        if path == "/session/status" {
            guard var statuses = try await v2Data("GET", "/api/session/active") as? [String: [String: Any]] else { throw AppError("OpenCode returned an invalid activity snapshot.") }
            for id in owned where roots[root(id) ?? ""] == cwd {
                if !(try await v2List("/api/session/\(component(id))/inbox")).isEmpty { statuses[id] = ["type": "running"] }
            }
            return statuses
        }
        if path == "/permission" || path == "/question" {
            var result: [[String: Any]] = []
            for id in owned where roots[root(id) ?? ""] == cwd {
                let rows = try await v2List("/api/session/\(component(id))/" + (path == "/permission" ? "permission" : "form"))
                guard rows.allSatisfy({ $0["sessionID"] as? String == id }) else { throw AppError("OpenCode returned an interaction for a different native session.") }
                result += rows.map { row in
                    if path == "/question" { return OpenCodeV2.question(row) }
                    var value = row; value["permission"] = row["action"]; value["patterns"] = row["resources"]; return value
                }
            }
            return result
        }
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if parts.count == 3, ["permission", "question"].contains(parts[0]) {
            guard let request = requests[parts[1]], let id = request["sessionID"] as? String else { throw AppError("That native request expired.") }
            let endpoint = "/api/session/\(component(id))/" + (parts[0] == "permission" ? "permission" : "form") + "/\(component(parts[1]))"
            if parts[0] == "permission" { return try await rawCall("POST", endpoint + "/reply", body: ["decision": body?["reply"] ?? "reject"]) }
            if parts[2] == "reject" { return try await rawCall("DELETE", endpoint) }
            return try await rawCall("POST", endpoint + "/reply", body: OpenCodeV2.formAnswer(request, answers: body?["answers"] as? [[String]] ?? []))
        }
        guard parts.first == "session", parts.count >= 2 else { throw AppError("This OpenCode V2 operation is unsupported.") }
        let id = parts[1], endpoint = "/api/session/\(component(id))"
        if parts.count == 2 {
            if method == "GET" {
                guard let info = try await v2Data(method, endpoint) as? [String: Any] else { throw AppError("OpenCode returned invalid session metadata.") }
                return OpenCodeV2.session(info)
            }
            return try await rawCall(method, endpoint, body: body)
        }
        switch parts[2] {
        case "children":
            return try await v2List("/api/session?parentID=\(component(id))&order=asc", paginated: true).map(OpenCodeV2.session)
        case "message":
            let history = try await v2List(endpoint + "/message?order=asc", paginated: true)
            let queued = try await v2List(endpoint + "/inbox")
            var rows = history.compactMap { OpenCodeV2.message($0, sessionID: id) }
            let seen = Set(history.compactMap { $0["id"] as? String })
            for item in queued where item["type"] as? String == "user" && !seen.contains(item["id"] as? String ?? "") {
                guard item["sessionID"] as? String == id else { throw AppError("OpenCode returned an input receipt for another session.") }
                var value = item; value["text"] = (item["payload"] as? [String: Any])?["text"]
                if let row = OpenCodeV2.message(value, sessionID: id) { rows.append(row) }
            }
            return rows
        case "prompt_async":
            let parts = body?["parts"] as? [[String: Any]] ?? []
            let input: [String: Any] = ["id": body?["messageID"] ?? "", "text": parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                "files": parts.filter { $0["type"] as? String == "file" }.map { ["uri": $0["url"] ?? "", "name": $0["filename"] ?? ""] }, "delivery": "steer"]
            let receipt = try await v2Data("POST", endpoint + "/prompt", body: input) as? [String: Any] ?? [:]
            guard receipt["id"] as? String == body?["messageID"] as? String, receipt["sessionID"] as? String == id else { throw AppError("OpenCode did not confirm this exact native input ID. Check the saved send before retrying.") }
            return receipt
        case "abort":
            _ = try await rawCall("POST", endpoint + "/interrupt")
            for item in try await v2List(endpoint + "/inbox") {
                guard item["sessionID"] as? String == id, let input = item["id"] as? String else { throw AppError("OpenCode returned an invalid queued input identity.") }
                _ = try await rawCall("DELETE", endpoint + "/inbox/" + component(input))
            }
            return [:]
        default: throw AppError("This OpenCode V2 session operation is unsupported.")
        }
    }
}

/// Delegation on OpenCode 2, as T3 Code's adapter hosts it: a runtime MCP server
/// per session at its folder (gone when the owned server stops), session rules
/// that deny every companion server but the session's own, and a session
/// instruction entry. Nothing is written to OpenCode's configuration.
extension OpenCodeClient {
    nonisolated static let delegationPaths = ["/api/experimental/mcp/{server}", "/api/experimental/session/{sessionID}/instructions/entries",
                                              "/api/experimental/session/{sessionID}/instructions/entries/{key}"]
    nonisolated static let delegationNotice = "OpenCode did not add Notch Companion's delegation tools to this session."

    /// Short and per session: OpenCode hides tools whose names pass 64 characters.
    nonisolated static func delegationServerName(_ sid: String) -> String {
        DelegationServer.name + "-" + SHA256.hash(data: Data(sid.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The session's own rules, then the companion's (last match wins): every
    /// session's server denied, then this session's allowed.
    nonisolated static func delegationRules(_ existing: [[String: Any]], server: String?) -> [[String: Any]] {
        // `?` matches one character, so the deny covers only `notch-<16 hex>` servers, not a user's
        // `notch-…` server; the old `notch-*` deny is still stripped from saved sessions.
        existing.filter { ($0["action"] as? String)?.wholeMatch(of: #/notch-(\*|\?{16}_\*|[0-9a-f]{16}_\*)/#) == nil }
            + [["action": "notch-????????????????_*", "resource": "*", "effect": "deny"]]
            + (server.map { [["action": $0 + "_*", "resource": "*", "effect": "allow"]] } ?? [])
    }

    /// Runtime-only, at the session's folder; the token goes only in the header.
    nonisolated static func delegationRegistration(_ launch: [String: Any], server: String, location: String) -> (path: String, body: [String: Any])? {
        guard let url = launch["url"] as? String, let token = launch["token"] as? String else { return nil }
        return ("/api/experimental/mcp/\(server)?location%5Bdirectory%5D=" + (location.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""),
                ["config": ["type": "remote", "url": url, "headers": ["Authorization": "Bearer " + token], "oauth": false]])
    }

    /// Rules for every session; the server and instructions for a hosting one.
    /// A failure leaves the session usable with a notice.
    private func openDelegation(_ sid: String, permissions: [[String: Any]]) async {
        let launch = delegations[sid]?.launch
        let entry = "/api/experimental/session/\(component(sid))/instructions/entries"
        do {
            let rules = Self.delegationRules(permissions, server: launch.map { _ in Self.delegationServerName(sid) })
            if !(rules as NSArray).isEqual(to: permissions) { _ = try await rawCall("PATCH", "/api/session/\(component(sid))", body: ["permissions": rules]) }
            if let launch {
                _ = try await rawCall("PUT", entry + "/notch", body: ["value": launch["instructions"] as? String ?? Delegation.instructions])
                try await registerDelegation(sid)
            } else if try await v2List(entry).contains(where: { $0["key"] as? String == "notch" }) {
                // Delegation was turned off since; the entry would point at missing tools.
                _ = try await rawCall("DELETE", entry + "/notch")
            }
        } catch {
            if launch != nil { event("runtime.notice", sid: sid, ["message": Self.delegationNotice]) }
        }
    }

    private func registerDelegation(_ sid: String) async throws {
        guard let delegation = delegations[sid], let request = Self.delegationRegistration(
            delegation.launch, server: Self.delegationServerName(sid), location: delegation.location) else { return }
        _ = try await rawCall("PUT", request.path, body: request.body)
    }
}

private final class OpenCodeNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct OpenCodeSSEDecoder {
    private var line = Data()
    private var payload = Data()
    mutating func append(_ byte: UInt8) throws -> [String: Any]? {
        guard line.count + payload.count < 2 * 1024 * 1024 else { throw AppError("OpenCode sent an oversized event frame.") }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !payload.isEmpty else { return nil }
            defer { payload.removeAll(keepingCapacity: true) }
            guard let frame = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw AppError("OpenCode sent invalid event JSON.") }
            return frame
        }
        let prefix = Data("data:".utf8)
        if line.starts(with: prefix) {
            var content = line.dropFirst(prefix.count)
            if content.first == 32 { content = content.dropFirst() }
            if !payload.isEmpty { payload.append(10) }; payload.append(contentsOf: content)
        }
        return nil
    }
}
