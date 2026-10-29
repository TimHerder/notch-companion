import Foundation
import CoreFoundation
import Darwin

/// LaunchServices cannot start Hermes's private CuaDriver from a Seatbelt
/// process, even with an allow-all profile. This relay accepts only that exact
/// signed application's private-daemon launch; Hermes keeps its normal policy,
/// socket readiness checks and session teardown inside the protected frontend.
@MainActor
final class ComputerUseLaunchRelay {
    struct Request: Equatable, Sendable {
        let app: URL
        let executable: URL
        let arguments: [String]
        let socket: URL
        let expiresAt: TimeInterval
    }

    struct RelayError: LocalizedError {
        let errorDescription: String?
        init(_ message: String = "The protected Hermes computer-use launch could not be completed.") {
            errorDescription = message
        }
    }

    private struct LeaseIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    let directory: URL
    private let leaseIdentity: LeaseIdentity
    private var stopped = false
    private var reserved = Set<String>()
    private var owned: [String: Request] = [:]
    private var pending: [UUID: Task<Void, Error>] = [:]
    private var cleanup: Task<Void, Never>?

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("notch-cua-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        leaseIdentity = try Self.identity(of: directory)
    }

    /// Parse a deliberately closed protocol before executing any process. The
    /// lease is unique to this frontend; existing/global sockets are never used.
    nonisolated static func validate(_ payload: [String: Any], directory: URL,
                                     now: TimeInterval = Date().timeIntervalSince1970) throws -> Request {
        _ = try identity(of: directory)
        guard Set(payload.keys) == Set(["app", "arguments", "expires_at"]),
              let appPath = payload["app"] as? String, appPath.hasPrefix("/"), appPath.count < 4096,
              !appPath.contains("\0"), appPath.hasSuffix(".app"),
              let arguments = payload["arguments"] as? [String], arguments.count >= 7, arguments.count <= 12,
              arguments.allSatisfy({ !$0.contains("\0") && $0.count < 4096 }),
              let expiry = payload["expires_at"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > now, expiry.doubleValue <= now + 20,
              Array(arguments.prefix(3)) == ["serve", "--embedded", "--socket"],
              arguments[4] == "--no-permissions-gate", arguments[5] == "--permission-mode",
              ["bounded", "unrestricted"].contains(arguments[6]) else { throw RelayError() }

        guard let realAppPath = canonicalPath(appPath), let leasePath = canonicalPath(directory.path) else { throw RelayError() }
        let app = URL(fileURLWithPath: realAppPath)
        let executable = app.appendingPathComponent("Contents/MacOS/cua-driver")
        guard app.pathExtension == "app", FileManager.default.isExecutableFile(atPath: executable.path),
              canonicalPath(executable.path) == executable.path else { throw RelayError() }

        // Foundation shortens existing /private/tmp paths to /tmp. Compare
        // POSIX paths, matching Python Path.resolve() and the actual socket.
        let socket = URL(fileURLWithPath: arguments[3])
        guard arguments[3] == leasePath + "/" + socket.lastPathComponent,
              socket.lastPathComponent.range(of: #"^hc-[0-9a-f]{12}\.sock$"#, options: .regularExpression) != nil,
              !FileManager.default.fileExists(atPath: socket.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: socket.path)) == nil else { throw RelayError() }

        var flags = Set<String>()
        var manifest: String?
        var index = 7
        while index < arguments.count {
            let flag = arguments[index]
            guard flags.insert(flag).inserted else { throw RelayError() }
            switch flag {
            case "--dangerously-bypass-approvals", "--approve-capability-manifest", "--no-overlay":
                index += 1
            case "--capability-manifest":
                guard index + 1 < arguments.count else { throw RelayError() }
                let path = arguments[index + 1]
                guard path.hasPrefix("/"),
                      (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw RelayError()
                }
                manifest = path
                index += 2
            default: throw RelayError()
            }
        }
        guard flags.contains("--dangerously-bypass-approvals") == (arguments[6] == "unrestricted"),
              flags.contains("--approve-capability-manifest") == (manifest != nil),
              arguments[6] != "bounded" || manifest != nil else { throw RelayError() }
        return Request(app: app, executable: executable, arguments: arguments,
                       socket: socket, expiresAt: expiry.doubleValue)
    }

    nonisolated static func hasExpectedIdentity(_ output: String) -> Bool {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["Identifier", "TeamIdentifier"].contains(parts[0]) else { continue }
            guard fields[parts[0]] == nil else { return false }
            fields[parts[0]] = parts[1]
        }
        return fields["Identifier"] == "com.trycua.driver"
            && ["4YEC26S9KF", "YCK386LBJ7"].contains(fields["TeamIdentifier"] ?? "")
    }

    private nonisolated static func canonicalPath(_ path: String) -> String? {
        guard let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private nonisolated static func identity(of directory: URL) throws -> LeaseIdentity {
        var info = stat()
        guard directory.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700,
              info.st_uid == geteuid(), canonicalPath(directory.path) == directory.path else { throw RelayError() }
        return LeaseIdentity(device: info.st_dev, inode: info.st_ino)
    }

    func launch(_ payload: [String: Any]) async throws {
        guard !stopped else { throw RelayError() }
        guard try Self.identity(of: directory) == leaseIdentity else { throw RelayError() }
        let request = try Self.validate(payload, directory: directory)
        guard reserved.insert(request.socket.path).inserted else { throw RelayError() }
        let id = UUID()
        defer { pending.removeValue(forKey: id) }
        let verification = Task.detached(priority: .userInitiated) {
            try Self.verify(request)
        }
        pending[id] = verification
        try await verification.value
        guard !stopped, !Task.isCancelled, Date().timeIntervalSince1970 < request.expiresAt,
              try Self.identity(of: directory) == leaseIdentity,
              try Self.validate(payload, directory: directory) == request else { throw RelayError() }
        // Reserve ownership before the launch task runs, so a simultaneous
        // disconnect will clean this lease even if LaunchServices is delayed.
        owned[request.socket.path] = request
        let lease = directory, identity = leaseIdentity
        let launching = Task.detached(priority: .userInitiated) {
            guard try Self.identity(of: lease) == identity,
                  !FileManager.default.fileExists(atPath: request.socket.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: request.socket.path)) == nil else { throw RelayError() }
            _ = try Self.run("/usr/bin/open", ["-n", "-g", "-a", request.app.path, "--args"] + request.arguments,
                             timeout: min(4, request.expiresAt - Date().timeIntervalSince1970))
        }
        pending[id] = launching
        try await launching.value
        guard !stopped, !Task.isCancelled else { throw RelayError() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let tasks = Array(pending.values)
        tasks.forEach { $0.cancel() }
        pending.removeAll()
        let requests = Array(owned.values)
        owned.removeAll()
        let lease = directory
        let identity = leaseIdentity
        cleanup = Task.detached(priority: .utility) {
            // Await any in-progress open before deleting the lease. A queued
            // LaunchServices request cannot bind a socket after its directory
            // has been removed, even when open was cancelled concurrently.
            for task in tasks { _ = try? await task.value }
            for request in requests {
                guard (try? Self.identity(of: lease)) == identity else { continue }
                // Never execute a replaced/modified binary during teardown.
                guard (try? Self.verify(request, checkDeadline: false)) != nil else { continue }
                var socketInfo = stat()
                if request.socket.path.withCString({ lstat($0, &socketInfo) }) == 0,
                   socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_uid == geteuid(),
                   (try? Self.identity(of: lease)) == identity {
                    _ = try? Self.run(request.executable.path, ["stop", "--socket", request.socket.path], timeout: 3)
                }
            }
            // Keep the original lease through the native startup deadline. The
            // frontend's EOF watcher independently stops late LaunchServices
            // arrivals and must still recognize this directory by inode.
            if let lastDeadline = requests.map(\.expiresAt).max() {
                let remaining = lastDeadline + 3 - Date().timeIntervalSince1970
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            }
            // Remove an empty lease only. A live socket is preserved if native
            // stop failed, rather than unlinking it and making cleanup harder.
            if (try? Self.identity(of: lease)) == identity { _ = lease.path.withCString { rmdir($0) } }
        }
    }

    /// Tests and callers that can await shutdown may confirm bounded cleanup;
    /// the frontend also retains its own native daemon teardown on parent EOF.
    func waitForStop() async { await cleanup?.value }

    private nonisolated static func verify(_ request: Request, checkDeadline: Bool = true) throws {
        if checkDeadline && Date().timeIntervalSince1970 >= request.expiresAt { throw RelayError() }
        _ = try run("/usr/bin/codesign", ["--verify", "--strict", request.app.path], timeout: 4)
        let identity = try run("/usr/bin/codesign", ["-dv", request.app.path], timeout: 4, capture: true)
        guard hasExpectedIdentity(identity) else { throw RelayError() }
    }

    /// Fixed executables and arguments only. Work and bounded diagnostics stay
    /// off the UI actor; raw tool output is never forwarded to the conversation.
    private nonisolated static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                                        capture: Bool = false) throws -> String {
        guard timeout > 0, !Task.isCancelled else { throw RelayError() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        // LaunchServices supplies CuaDriver's native identity. Do not propagate
        // the containing app's identity or any Hermes credentials into `open`.
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = capture ? Pipe() : nil
        child.standardOutput = pipe?.fileHandleForWriting ?? FileHandle.nullDevice
        child.standardError = pipe?.fileHandleForWriting ?? FileHandle.nullDevice
        let buffer = BoundedOutput()
        let drained = DispatchGroup()
        defer {
            try? pipe?.fileHandleForWriting.close()
        }
        do { try child.run() } catch { throw RelayError() }
        if let handle = pipe?.fileHandleForReading {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close(); drained.leave() }
                while let bytes = try? handle.read(upToCount: 4096), !bytes.isEmpty { buffer.append(bytes) }
            }
        }
        try? pipe?.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning {
            child.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while child.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            _ = drained.wait(timeout: .now() + 0.5)
            throw RelayError()
        }
        guard drained.wait(timeout: .now() + 0.5) == .success else { throw RelayError() }
        guard child.terminationStatus == 0, !Task.isCancelled else { throw RelayError() }
        return buffer.string
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes.prefix(max(0, 16_384 - data.count)))
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
