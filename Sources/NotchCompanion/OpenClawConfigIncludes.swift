import Foundation
import Darwin

/// Read-only subset of native configuration loading: JSON5 and $include merge
/// semantics. No evaluation, file creation, environment mutation or secret exec.
struct OpenClawConfigIncludes {
    private struct Root {
        let lexical: URL
        let canonical: URL
    }
    private var roots: [Root]
    private var filesRead = 0
    private var bytesRead = 0
    private var nodesRead = 0

    static func read(_ file: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data {
        let root = file.deletingLastPathComponent().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        let extras = (environment["OPENCLAW_INCLUDE_ROOTS"] ?? "").split(separator: ":").compactMap { value -> URL? in
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.contains("\0") else { return nil }
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL }
            return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL
        }
        var resolver = Self(roots: ([root] + extras).map { Root(lexical: $0, canonical: $0.resolvingSymlinksInPath()) })
        let value = try resolver.load(file.standardizedFileURL, includeDepth: 0, containerDepth: 0, visited: [])
        return try JSONEncoder().encode(value)
    }

    private static func contains(_ root: URL, _ file: URL) -> Bool {
        file.path == root.path || file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }
    private mutating func load(_ file: URL, includeDepth: Int, containerDepth: Int, visited: Set<String>) throws -> Value {
        guard includeDepth <= 10, file.path.utf8.count < 4096, !file.path.contains("\0"),
              roots.contains(where: { Self.contains($0.lexical, file) }) else {
            throw AppError("OpenClaw config include exceeds its native depth/path boundary. Includes must stay within the config directory or explicit OPENCLAW_INCLUDE_ROOTS.")
        }
        guard filesRead < 128 else { throw AppError("OpenClaw config includes exceed this adapter's 128-file read limit.") }
        filesRead += 1
        // O_NONBLOCK prevents an authored FIFO/device path from hanging discovery;
        // fstat immediately requires a plain, singly linked file.
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw AppError("An OpenClaw configuration file could not be opened. Check its existing path and permissions.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        let limit = includeDepth == 0 ? 4 * 1024 * 1024 : 2 * 1024 * 1024
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_size >= 0, metadata.st_size <= limit else {
            throw AppError("OpenClaw configuration includes must be regular files without hardlinks, no larger than 2 MiB (4 MiB for the root config).")
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let resolved = pathBuffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!)) }
        guard resolved == 0 else { throw AppError("The opened OpenClaw configuration path could not be verified.") }
        let openedPath = URL(fileURLWithPath: String(cString: pathBuffer)).standardizedFileURL.resolvingSymlinksInPath()
        guard roots.contains(where: { Self.contains($0.canonical, openedPath) }) else {
            throw AppError("An OpenClaw include resolves outside the permitted config roots. Its contents were not read.")
        }
        guard !visited.contains(openedPath.path) else { throw AppError("The OpenClaw configuration has a circular $include chain.") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        bytesRead += data.count
        guard data.count <= limit, bytesRead <= 16 * 1024 * 1024 else { throw AppError("OpenClaw includes exceed this adapter's 16 MiB total read limit.") }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == metadata.st_size,
              after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
            throw AppError("OpenClaw's configuration changed during discovery. Retry after the native configuration edit finishes.")
        }
        let decoder = JSONDecoder(); decoder.allowsJSON5 = true
        let value: Value
        do { value = try decoder.decode(Value.self, from: data) }
        catch { throw AppError("An OpenClaw config include is not supported JSON/JSON5. Check the native configuration; no files were changed.") }
        return try expand(value, baseFile: file, includeDepth: includeDepth, containerDepth: containerDepth,
                          visited: visited.union([openedPath.path]))
    }

    private mutating func expand(_ value: Value, baseFile: URL, includeDepth: Int, containerDepth: Int, visited: Set<String>) throws -> Value {
        nodesRead += 1
        guard containerDepth <= 128, nodesRead <= 100_000 else { throw AppError("OpenClaw config includes exceed this adapter's bounded nesting or object limit.") }
        switch value {
        case .array(let values):
            return .array(try values.map { try expand($0, baseFile: baseFile, includeDepth: includeDepth, containerDepth: containerDepth + 1, visited: visited) })
        case .object(var fields):
            guard let include = fields.removeValue(forKey: "$include") else {
                return .object(try fields.mapValues { try expand($0, baseFile: baseFile, includeDepth: includeDepth, containerDepth: containerDepth + 1, visited: visited) })
            }
            let paths: [String]
            let multiple: Bool
            switch include {
            case .string(let path): paths = [path]; multiple = false
            case .array(let items):
                paths = try items.map { item in
                    guard case .string(let path) = item else { throw AppError("OpenClaw $include arrays must contain only file paths.") }
                    return path
                }; multiple = true
            default: throw AppError("OpenClaw $include must be a file path or an array of file paths.")
            }
            var included = Value.object([:])
            for path in paths {
                guard !path.contains("\0"), path.utf8.count < 4096 else { throw AppError("An OpenClaw include path is invalid or too long.") }
                let file = URL(fileURLWithPath: path, relativeTo: baseFile.deletingLastPathComponent()).standardizedFileURL
                let next = try load(file, includeDepth: includeDepth + 1, containerDepth: containerDepth + 1, visited: visited)
                included = multiple ? Self.merge(included, next) : next
            }
            if fields.isEmpty { return included }
            guard case .object = included else { throw AppError("OpenClaw include sibling overrides require included object content.") }
            let overrides = try fields.mapValues { try expand($0, baseFile: baseFile, includeDepth: includeDepth, containerDepth: containerDepth + 1, visited: visited) }
            return Self.merge(included, .object(overrides))
        default: return value
        }
    }

    private static func merge(_ target: Value, _ source: Value) -> Value {
        switch (target, source) {
        case (.array(let lhs), .array(let rhs)): return .array(lhs + rhs)
        case (.object(var lhs), .object(let rhs)):
            for (key, value) in rhs { lhs[key] = lhs[key].map { merge($0, value) } ?? value }
            return .object(lhs)
        default: return source
        }
    }
    private indirect enum Value: Codable {
        case object([String: Value]), array([Value]), string(String), number(Decimal), bool(Bool), null
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else if let array = try? value.decode([Value].self) { self = .array(array) }
            else if let object = try? value.decode([String: Value].self) { self = .object(object) }
            else { self = .number(try value.decode(Decimal.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .object(let object): try value.encode(object)
            case .array(let array): try value.encode(array)
            case .string(let string): try value.encode(string)
            case .number(let number): try value.encode(number)
            case .bool(let boolean): try value.encode(boolean)
            case .null: try value.encodeNil()
            }
        }
    }
}
