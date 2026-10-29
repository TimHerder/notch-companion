import Foundation
import Darwin

/// The native HTTP server ignores stdin. A separate instance of this signed
/// executable holds its lifetime to the companion's ownership pipe. It contains
/// no agent loop, profile copy, shell evaluation or arbitrary argument protocol.
enum OpenCodeSupervisor {
    static let flag = "--supervise-opencode"
    static let serverArguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3, arguments[1] == flag,
              arguments[2].hasPrefix("/"), !arguments[2].contains("\0"),
              FileManager.default.isExecutableFile(atPath: arguments[2]) else { return 64 }
        var input = stat()
        guard fstat(STDIN_FILENO, &input) == 0, input.st_mode & S_IFMT == S_IFIFO else { return 64 }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: arguments[2])
        child.arguments = serverArguments
        child.environment = ProcessInfo.processInfo.environment
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        do { try child.run() } catch { return 69 }

        let stopping = SupervisorStop(child: child)
        // Direct termination of the helper also asks its exact child to exit.
        // SIGKILL is inherently uncatchable; the companion never uses it on the
        // helper, and it never identifies another process by executable name.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: stopping.queue)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: stopping.queue)
        interrupt.setEventHandler { stopping.stop() }
        terminate.setEventHandler { stopping.stop() }
        interrupt.resume(); terminate.resume()
        DispatchQueue.global(qos: .utility).async {
            var byte: UInt8 = 0
            var count: Int
            repeat { count = Darwin.read(STDIN_FILENO, &byte, 1) } while count < 0 && errno == EINTR
            // EOF is the ordinary parent-death signal. Unexpected input also
            // closes this deliberately one-way ownership protocol.
            stopping.queue.async { stopping.stop() }
        }
        child.waitUntilExit()
        withExtendedLifetime((interrupt, terminate, stopping)) {}
        return child.terminationStatus
    }
}

private final class SupervisorStop: @unchecked Sendable {
    let queue = DispatchQueue(label: "NotchCompanion.OpenCodeSupervisor.stop")
    let child: Process
    private var stopping = false
    init(child: Process) { self.child = child }

    /// Only called on queue. The main thread waits on this exact unreaped child,
    /// so these signals cannot select a Gateway, another frontend, or a PID file.
    func stop() {
        guard !stopping, child.isRunning else { return }
        stopping = true
        child.interrupt()
        for _ in 0..<40 { if !child.isRunning { return }; usleep(100_000) }
        child.terminate()
        for _ in 0..<20 { if !child.isRunning { return }; usleep(100_000) }
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
    }
}
