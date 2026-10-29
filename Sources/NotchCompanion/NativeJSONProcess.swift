import Foundation

/// A bounded JSON-lines decoder. Malformed protocol output is a connection
/// failure, never silently ignored (which could strand an approval or send).
struct NativeJSONLines {
    var buffer = Data()
    let limit: Int
    init(limit: Int = 16 * 1024 * 1024) { self.limit = limit }

    mutating func append(_ data: Data) throws -> [[String: Any]] {
        var frames: [[String: Any]] = []
        let parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for part in parts.enumerated() {
            guard buffer.count + part.element.count <= limit else { throw AppError("The native runtime sent an oversized protocol frame.") }
            buffer.append(contentsOf: part.element)
            // The final part belongs to the next read unless input ends in LF.
            guard part.offset < parts.count - 1 else { break }
            if buffer.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) { buffer.removeAll(keepingCapacity: true); continue }
            guard let frame = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
                throw AppError("The native runtime sent invalid JSON protocol output. Check its version and stdout logging configuration.")
            }
            frames.append(frame)
            buffer.removeAll(keepingCapacity: true)
        }
        return frames
    }
}

/// One owned native frontend, with no shell or independent agent home. Adapters
/// own protocol correlation; this helper only owns process and JSONL framing.
@MainActor
final class NativeJSONProcess {
    private static var retiring: [Process] = []
    var onFrame: (([String: Any]) -> Void)?
    var onFailure: ((Error) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var generation = UUID()
    private var decoder = NativeJSONLines()
    private let writes = DispatchQueue(label: "NotchCompanion.NativeJSON.write")
    var isRunning: Bool { process?.isRunning == true }

    /// Reopening an exact native session must wait for its previous frontend to
    /// flush and release storage. Only owned, already-stopping children wait.
    static func awaitPendingStops() async throws {
        let deadline = Date().addingTimeInterval(6)
        while true {
            retiring.removeAll { !$0.isRunning }
            if retiring.isEmpty { return }
            guard Date() < deadline else { throw AppError("The previous native frontend has not exited yet. Wait before reconnecting to its saved sessions.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func start(executable: URL, arguments: [String], environment: [String: String], cwd: URL) throws {
        guard process == nil else { throw AppError("The native runtime is already connected.") }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = environment; child.currentDirectoryURL = cwd
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = stderrPipe
        let run = UUID(); generation = run
        process = child; input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading; diagnostics = stderrPipe.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            // A single FileHandle delivers reads serially. Dispatch directly
            // to the main queue so the final frame precedes the EOF callback;
            // unstructured Tasks do not promise that ordering.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == run else { return }
                do {
                    if data.isEmpty { throw AppError("The native runtime closed its output. Reconnect to check the saved session before sending again.") }
                    for frame in try self.decoder.append(data) {
                        guard self.generation == run else { return }
                        self.onFrame?(frame)
                    }
                } catch { self.fail(error) }
            }
        }
        diagnostics?.readabilityHandler = { handle in
            // Provider/tool stderr can contain secrets and conversation text.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] child in
            // EOF owns normal completion. Process termination can arrive before
            // stdout's final read, so only use it as a bounded fallback when a
            // descendant retained the output pipe and prevented EOF.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.generation == run else { return }
                self.fail(AppError("The native runtime exited (\(child.terminationStatus)). Reconnect to check the saved session before sending again."))
            }
        }
        do { try child.run() } catch { stop(); throw error }
    }

    func send(_ frame: [String: Any]) throws {
        guard let input, isRunning else { throw AppError("The native runtime is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: frame)
        guard data.count <= 16 * 1024 * 1024 else { throw AppError("This native request is too large. Remove large attachments before sending.") }
        data.append(0x0A)
        let run = generation
        writes.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch { Task { @MainActor [weak self] in
                guard let self, self.generation == run else { return }
                self.fail(AppError("The native runtime disconnected while writing. Check its saved session before retrying."))
            } }
        }
    }

    private func fail(_ error: Error) { stop(); onFailure?(error) }

    func interrupt() throws {
        guard let process, process.isRunning else { throw AppError("The native runtime is disconnected.") }
        process.interrupt()
    }

    func stop() {
        generation = UUID()
        output?.readabilityHandler = nil; diagnostics?.readabilityHandler = nil
        let handle = input
        writes.async { try? handle?.close() }
        input = nil; output = nil; diagnostics = nil; decoder = NativeJSONLines()
        if let child = process {
            child.terminationHandler = nil
            if child.isRunning { Self.retiring.append(child) }
            // EOF requests native persistence flush. Only the frontend we own
            // may be terminated if it does not settle; never a shared gateway.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if child.isRunning { child.terminate() } }
        }
        process = nil
    }
}
