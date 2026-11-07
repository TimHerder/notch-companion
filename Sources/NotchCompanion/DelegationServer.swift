import Foundation
import Network
import CryptoKit

/// Who called a companion tool: the token's companion session, its harness and
/// whether that session is an app-owned child.
struct DelegationCaller: Equatable {
    var sessionID: String
    var runtime: RuntimeKind
    var subagent: Bool
}

/// A tool failure the agent reads, with T3 Code's error codes.
struct DelegationFailure: LocalizedError, Equatable {
    var code: String
    var message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

/// The loopback MCP endpoint (Streamable HTTP, JSON responses, no SSE) that
/// gives companion sessions their delegation tools, as T3 Code's orchestrator
/// server does. Each native session gets its own random bearer token; only its
/// SHA-256 hash is kept, in memory.
@MainActor
final class DelegationServer {
    nonisolated static let name = "notch"
    static let idleExpiry: TimeInterval = 24 * 60 * 60
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    struct Response: Equatable {
        var status: Int
        var body: Data = Data()
        var headers: [String: String] = [:]
    }

    /// Runs a tool for its caller. Throw `DelegationFailure` for an agent-facing error.
    var call: ((DelegationCaller, String, [String: Any]) async throws -> [String: Any])?
    var tools: ((DelegationCaller) -> [[String: Any]])?
    var instructions = ""
    /// A session with a running turn keeps its token fresh.
    var isActive: ((String) -> Bool)?
    /// Whether a native session ID the harness names on a call is the caller's own (or its native child's).
    var ownsNative: ((DelegationCaller, String) -> Bool)?
    var now: () -> Date = Date.init

    private struct Grant { var caller: DelegationCaller; var lastUsed: Date }
    private var grants: [Data: Grant] = [:]
    private var listener: NWListener?
    private var starting: Task<URL, Error>?
    private var connections: [ObjectIdentifier: (NWConnection, Task<Void, Never>?)] = [:]
    private(set) var url: URL?

    /// Starts once on an OS-chosen loopback port.
    func start() async throws -> URL {
        if let url { return url }
        if let starting { return try await starting.value }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        let task = Task { @MainActor () throws -> URL in
            final class Once { var done = false }
            let once = Once()
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    MainActor.assumeIsolated {
                        guard !once.done else { return }
                        switch state {
                        case .ready: once.done = true; continuation.resume(returning: listener.port?.rawValue ?? 0)
                        case .failed(let error): once.done = true; continuation.resume(throwing: error)
                        case .cancelled: once.done = true; continuation.resume(throwing: AppError("The delegation server stopped."))
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
            }
            guard port > 0 else { throw AppError("The delegation server has no port.") }
            return URL(string: "http://127.0.0.1:\(port)/mcp")!
        }
        starting = task
        defer { starting = nil }
        do {
            let url = try await task.value
            self.url = url
            return url
        } catch {
            listener.cancel(); self.listener = nil
            throw error
        }
    }

    func stop() {
        listener?.cancel(); listener = nil; url = nil
        for (connection, task) in connections.values { task?.cancel(); connection.cancel() }
        connections.removeAll()
        grants.removeAll()
    }

    /// One token per native session; a new one replaces the session's old token.
    func issueToken(for caller: DelegationCaller) -> String {
        revoke(sessionID: caller.sessionID)
        var random = SystemRandomNumberGenerator() // arc4random: cryptographically secure
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        grants[Self.hash(token)] = Grant(caller: caller, lastUsed: now())
        return token
    }

    func hasGrant(sessionID: String) -> Bool { grants.values.contains { $0.caller.sessionID == sessionID } }

    func revoke(sessionID: String) { grants = grants.filter { $0.value.caller.sessionID != sessionID } }

    func caller(token: String) -> DelegationCaller? {
        let key = Self.hash(token)
        guard var grant = grants[key] else { return nil }
        if now().timeIntervalSince(grant.lastUsed) > Self.idleExpiry, isActive?(grant.caller.sessionID) != true {
            grants.removeValue(forKey: key)
            return nil
        }
        grant.lastUsed = now()
        grants[key] = grant
        return grant.caller
    }

    private static func hash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    // MARK: MCP over HTTP

    func respond(method: String, path: String, headers: [String: String], body: Data) async -> Response {
        guard path.split(separator: "?").first == "/mcp" else { return Response(status: 404) }
        let authorization = headers.first { $0.key.lowercased() == "authorization" }?.value ?? ""
        guard authorization.lowercased().hasPrefix("bearer "),
              let caller = caller(token: String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)) else {
            return Response(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        // No server-initiated stream and no session to end: Streamable HTTP allows 405.
        guard method == "POST" else { return Response(status: 405, headers: ["Allow": "POST"]) }
        guard let message = try? JSONSerialization.jsonObject(with: body) else {
            return json(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = message as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for request in batch { if let reply = await handle(request, caller: caller) { replies.append(reply) } }
            return replies.isEmpty ? Response(status: 202) : json(replies)
        }
        guard let request = message as? [String: Any] else { return json(Self.error(id: NSNull(), code: -32600, message: "Invalid request")) }
        guard let reply = await handle(request, caller: caller) else { return Response(status: 202) }
        return json(reply)
    }

    private func json(_ value: Any) -> Response {
        Response(status: 200, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), headers: ["Content-Type": "application/json"])
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// Nil for notifications and responses, which need no reply.
    private func handle(_ request: [String: Any], caller: DelegationCaller) async -> [String: Any]? {
        guard let id = request["id"], let method = request["method"] as? String else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return result(["protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                           "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": Self.name, "title": "Notch Companion", "version": "0.2.0"],
                           // OpenCode adds every server's instructions at a folder to each prompt; its session entry carries them once.
                           "instructions": caller.runtime == .opencode ? "" : instructions])
        case "ping": return result([:])
        case "tools/list": return result(["tools": tools?(caller) ?? []])
        case "tools/call":
            guard let name = params["name"] as? String, (tools?(caller) ?? []).contains(where: { $0["name"] as? String == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool")
            }
            do {
                // OpenCode names the session running the tool; one session cannot use another's server.
                if let native = (params["_meta"] as? [String: Any])?["ai.opencode/sessionID"] as? String, ownsNative?(caller, native) == false {
                    throw DelegationFailure("capability_denied", "These tools belong to a different session.")
                }
                let value = try await call?(caller, name, params["arguments"] as? [String: Any] ?? [:]) ?? [:]
                let text = String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
                return result(["content": [["type": "text", "text": text]], "structuredContent": value, "isError": false])
            } catch {
                let failure = error as? DelegationFailure ?? DelegationFailure("orchestration_error", error.localizedDescription)
                let text = String(data: (try? JSONSerialization.data(withJSONObject: ["code": failure.code, "message": failure.message], options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? failure.message
                return result(["content": [["type": "text", "text": text]], "isError": true])
            }
        default: return Self.error(id: id, code: -32601, message: "Method not found")
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = (connection, nil)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                MainActor.assumeIsolated {
                    // A closed request ends its tool call, including a blocking wait.
                    self?.connections.removeValue(forKey: key)?.1?.cancel()
                }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    nonisolated private static let headerLimit = 64 * 1024
    nonisolated private static let bodyLimit = 8 * 1024 * 1024

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard error == nil else { connection.cancel(); return }
                switch Self.parse(buffer) {
                case .incomplete:
                    if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                case .invalid(let status): self.send(Response(status: status), on: connection)
                case .request(let method, let path, let headers, let body):
                    let task = Task { @MainActor [weak self] in
                        guard let self else { return }
                        let response = await self.respond(method: method, path: path, headers: headers, body: body)
                        guard !Task.isCancelled else { return }
                        self.send(response, on: connection)
                    }
                    self.connections[ObjectIdentifier(connection)]?.1 = task
                    self.watchClose(connection)
                }
            }
        }
    }

    /// A peer that closes while its tool call waits cancels that call, so a
    /// wait it abandoned never acknowledges a result it did not receive.
    private func watchClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let key = ObjectIdentifier(connection)
                guard complete || error != nil else {
                    if self.connections[key] != nil { self.watchClose(connection) }
                    return
                }
                self.connections.removeValue(forKey: key)?.1?.cancel()
                connection.cancel()
            }
        }
    }

    enum Parsed: Equatable {
        case incomplete
        case invalid(Int)
        case request(method: String, path: String, headers: [String: String], body: Data)
    }

    nonisolated static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > headerLimit ? .invalid(431) : .incomplete
        }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3 else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if headers.contains(where: { $0.key.lowercased() == "transfer-encoding" }) { return .invalid(411) }
        let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? -1
        guard length >= 0, length <= bodyLimit else { return .invalid(413) }
        let available = buffer.count - end.upperBound
        guard available >= length else { return .incomplete }
        return .request(method: String(start[0]), path: String(start[1]), headers: headers,
                        body: buffer.subdata(in: end.upperBound..<(end.upperBound + length)))
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                       405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large", 431: "Request Header Fields Too Large"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// ACP agents get the companion's tools from this stdio MCP server, as T3
/// Code ships one, because some drop injected HTTP servers. The agent starts
/// this executable with `flag`; it relays each JSON-RPC line to the loopback
/// endpoint with that session's token and writes back the answers.
enum DelegationBridge {
    static let flag = "--notch-delegation-bridge"
    static let urlKey = "NOTCH_DELEGATION_URL"
    static let tokenKey = "NOTCH_DELEGATION_TOKEN"

    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard let address = environment[urlKey], let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
              let token = environment[tokenKey], !token.isEmpty else { return 64 }
        let configuration = URLSessionConfiguration.ephemeral
        // A delegation wait may block for an hour.
        configuration.timeoutIntervalForRequest = 65 * 60
        configuration.timeoutIntervalForResource = 65 * 60
        let session = URLSession(configuration: configuration)
        let output = DispatchQueue(label: "NotchCompanion.DelegationBridge.output")
        let pending = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let body = Data(line.utf8)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            pending.enter()
            // Concurrent, so a ping is answered while a tool call waits.
            session.dataTask(with: request) { data, response, _ in
                defer { pending.leave() }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var reply = status == 200 ? data : nil
                if reply?.isEmpty != false, status != 202,
                   let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"] {
                    let message = status == 401 ? "This session's Notch Companion token is no longer valid." : "Notch Companion is not answering."
                    reply = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]])
                }
                guard let reply, !reply.isEmpty else { return }
                output.sync { FileHandle.standardOutput.write(reply + Data([0x0A])) }
            }.resume()
        }
        pending.wait()
        return 0
    }
}
