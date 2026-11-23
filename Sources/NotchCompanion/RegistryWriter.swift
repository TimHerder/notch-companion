import Foundation

/// Writes the session registry: the bytes of encoding every session together, while encoding
/// again only the sessions that changed since the write before. One serial queue keeps the
/// writes in the order they were asked for, so the debounced save can leave the main thread
/// and a save that must be on disk first still is. A session equal to the one last encoded
/// keeps those bytes: text replaced by a canonically equivalent form is saved as it was.
final class RegistryWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "NotchCompanion.registry", qos: .userInitiated)
    /// Each session as last encoded. Only touched on `queue`.
    private var encoded: [String: (session: CompanionSession, data: Data)] = [:]

    init(url: URL) { self.url = url }

    /// Returns once these sessions, and every write asked for before them, are on disk.
    func write(_ sessions: [CompanionSession]) throws {
        try queue.sync { try store(sessions) }
    }

    /// Writes off the calling thread; a failure is reported on the main queue.
    func writeLater(_ sessions: [CompanionSession], failed: @escaping @MainActor (Error) -> Void) {
        queue.async {
            do { try self.store(sessions) } catch { DispatchQueue.main.async { MainActor.assumeIsolated { failed(error) } } }
        }
    }

    /// Encodes the sessions ahead of their first write, which would otherwise encode them all at once.
    func prepare(_ sessions: [CompanionSession]) {
        queue.async { _ = try? self.encodings(of: sessions) }
    }

    private func store(_ sessions: [CompanionSession]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // What `JSONEncoder` writes for the whole array: its elements, joined by commas.
        let parts = try encodings(of: sessions)
        var registry = Data(capacity: parts.reduce(2) { $0 + $1.count + 1 })
        registry.append(UInt8(ascii: "["))
        for (index, part) in parts.enumerated() {
            if index > 0 { registry.append(UInt8(ascii: ",")) }
            registry.append(part)
        }
        registry.append(UInt8(ascii: "]"))
        try registry.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func encodings(of sessions: [CompanionSession]) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var kept: [String: (session: CompanionSession, data: Data)] = [:]
        let parts = try sessions.map { session in
            var entry = encoded[session.id]
            if entry?.session != session { entry = (session, try encoder.encode(session)) }
            kept[session.id] = entry
            return entry!.data
        }
        encoded = kept
        return parts
    }
}
