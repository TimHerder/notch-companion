import Foundation

enum HermesClientError: LocalizedError {
    case unavailable(String)
    case rpc(Int, String)
    case disconnected
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .rpc(_, let message): return message
        case .disconnected: return "Hermes disconnected. Reconnect to continue your saved sessions."
        case .timedOut(let method): return "Hermes did not respond to \(method). Reconnect if this continues."
        }
    }
}

/// One app-owned stdio backend. Never connects to, stops, or restarts a user's
/// messaging gateway. All callbacks and request completion run on MainActor.
@MainActor
final class HermesClient {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var requestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var ready = false
    private var generation = UUID()
    private let writeQueue = DispatchQueue(label: "NotchCompanion.Hermes.write")

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchCompanion", isDirectory: true)
    }

    func connect() async throws {
        if ready { return }
        if process != nil { throw HermesClientError.unavailable("Hermes is already connecting.") }
        let files = FileManager.default
        let userHome = files.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let sourceHome = URL(fileURLWithPath: environment["NOTCH_HERMES_SOURCE_HOME"] ?? userHome.appendingPathComponent(".hermes").path)
        let source = URL(fileURLWithPath: environment["NOTCH_HERMES_SOURCE"] ?? sourceHome.appendingPathComponent("hermes-agent").path)
        let appHome = URL(fileURLWithPath: environment["NOTCH_HERMES_HOME"] ?? Self.supportDirectory.appendingPathComponent("hermes").path)
        let candidates = [source.appendingPathComponent("venv/bin/python"), source.appendingPathComponent(".venv/bin/python")]
        guard let python = candidates.first(where: { files.isExecutableFile(atPath: $0.path) }) else {
            throw HermesClientError.unavailable("Hermes was not found at \(source.path). Install Hermes with its Python environment, then reconnect.")
        }
        guard let bridge = CompanionResources.bundle.url(forResource: "hermes_bridge", withExtension: "py")
                ?? CompanionResources.bundle.url(forResource: "hermes_bridge", withExtension: "py", subdirectory: "Resources") else {
            throw HermesClientError.unavailable("The Hermes bridge is missing from this app. Rebuild the application.")
        }
        guard files.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw HermesClientError.unavailable("The macOS isolation helper is unavailable. Hermes was not started.")
        }
        // OS-enforced protection also covers any child tools spawned by this
        // backend. The app and its agents cannot modify the existing Hermes home.
        func sandboxString(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let protectedPaths = Set([sourceHome.resolvingSymlinksInPath().path, source.resolvingSymlinksInPath().path])
        let denials = protectedPaths.sorted().map { "(deny file-write* (subpath \(sandboxString($0))))" }.joined()
        let profile = "(version 1)(allow default)" + denials
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", profile, python.path, "-B", "-u", bridge.path,
                           "--source", source.path, "--source-home", sourceHome.path,
                           "--app-home", appHome.path]
        var childEnvironment = environment
        childEnvironment.removeValue(forKey: "PYTHONHOME")
        childEnvironment.removeValue(forKey: "PYTHONPATH")
        childEnvironment["PYTHONDONTWRITEBYTECODE"] = "1"
        childEnvironment["PYTHONUNBUFFERED"] = "1"
        childEnvironment["HERMES_HOME"] = appHome.path
        // Finder launches have a minimal PATH; preserve the user's path while
        // making standard installed Hermes tools discoverable.
        childEnvironment["PATH"] = [source.appendingPathComponent("venv/bin").path,
                                    userHome.appendingPathComponent(".local/bin").path,
                                    "/opt/homebrew/bin", "/usr/local/bin",
                                    environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        child.environment = childEnvironment
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        let runID = UUID()
        generation = runID
        process = child
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        errorOutput = stderrPipe.fileHandleForReading
        buffer.removeAll(keepingCapacity: true)
        // Pipe readability callbacks retain their handles until cleanup. Only
        // bytes cross into MainActor, so framing/state have a single owner.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                Task { @MainActor [weak self] in self?.receive(data, generation: runID) }
            } else {
                handle.readabilityHandler = nil
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            // Drain so an import/tool log cannot deadlock the child. Raw stderr
            // may contain tokens or prompt text, so never display or persist it.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self, self.generation == runID else { return }
                let message = "Hermes stopped (exit \(terminated.terminationStatus)). Your companion sessions are saved; reconnect to continue."
                self.failConnection(HermesClientError.unavailable(message))
            }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyWaiter = continuation
                startupTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard let self, self.generation == runID, !self.ready else { return }
                    self.failConnection(HermesClientError.timedOut("startup"))
                }
                do { try child.run() }
                catch { failConnection(HermesClientError.unavailable("Hermes could not be launched: \(error.localizedDescription)")) }
            }
        } catch { throw error }
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard ready, let handle = input, process?.isRunning == true else { throw HermesClientError.disconnected }
        requestID += 1
        let identifier = requestID
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": identifier, "method": method, "params": params]
        var data = try JSONSerialization.data(withJSONObject: frame)
        data.append(0x0A)
        let runID = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[identifier] = continuation
            timeouts[identifier] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                guard let self, self.generation == runID else { return }
                self.timeouts.removeValue(forKey: identifier)
                self.pending.removeValue(forKey: identifier)?.resume(throwing: HermesClientError.timedOut(method))
            }
            writeQueue.async { [weak self] in
                do { try handle.write(contentsOf: data) }
                catch {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == runID else { return }
                        self.failConnection(HermesClientError.disconnected)
                    }
                }
            }
        }
    }

    func disconnect() {
        cleanup(error: HermesClientError.disconnected)
        onConnectionChange?(false, nil)
    }

    private func receive(_ data: Data, generation runID: UUID) {
        guard generation == runID else { return }
        buffer.append(data)
        // Tool results can be large; a bounded frame buffer prevents malformed
        // output from consuming memory indefinitely.
        guard buffer.count <= 32 * 1024 * 1024 else {
            failConnection(HermesClientError.unavailable("Hermes sent an oversized response. Reconnect to continue."))
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                // Some installed optional plugins print to stdout at import. A
                // non-protocol line must not corrupt the next valid frame.
                continue
            }
            if frame["method"] as? String == "event", let params = frame["params"] as? [String: Any], let type = params["type"] as? String {
                var payload = params["payload"] as? [String: Any] ?? [:]
                payload["session_id"] = params["session_id"] as? String ?? ""
                if type == "gateway.ready" {
                    ready = true
                    startupTimeout?.cancel()
                    startupTimeout = nil
                    readyWaiter?.resume()
                    readyWaiter = nil
                    onConnectionChange?(true, nil)
                } else if type == "bridge.error" {
                    failConnection(HermesClientError.unavailable(payload["message"] as? String ?? "Hermes could not start."))
                }
                onEvent?(type, payload)
            } else if let identifier = frame["id"] as? Int, let continuation = pending.removeValue(forKey: identifier) {
                timeouts.removeValue(forKey: identifier)?.cancel()
                if let error = frame["error"] as? [String: Any] {
                    continuation.resume(throwing: HermesClientError.rpc(error["code"] as? Int ?? -1, error["message"] as? String ?? "Hermes request failed."))
                } else {
                    continuation.resume(returning: frame["result"] as? [String: Any] ?? [:])
                }
            }
        }
    }

    private func failConnection(_ error: Error) {
        cleanup(error: error)
        onConnectionChange?(false, error.localizedDescription)
    }

    private func cleanup(error: Error) {
        generation = UUID()
        ready = false
        startupTimeout?.cancel()
        startupTimeout = nil
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close()
        input = nil
        output = nil
        errorOutput = nil
        buffer.removeAll()
        if let child = process {
            child.terminationHandler = nil
            if child.isRunning {
                // Hermes handles SIGTERM by flushing its own session database.
                child.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
    }
}
