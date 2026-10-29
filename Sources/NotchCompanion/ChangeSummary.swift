import Foundation
import CryptoKit

/// Display snapshots only; the runtime's history and Git remain authoritative.
struct TurnChanges: Codable, Equatable, Identifiable {
    enum Source: String, Codable { case agent, workspace }
    var id: String
    var workspace: String
    var baseRevision: String?
    var source: Source = .workspace
    var files: [ChangedFile] = []
    var notice: String?
    var capturedAt: Date?
    /// A delegated child's group: its title and harness.
    var label: String?
    /// App-owned children's own changes, in the parent turn that delegated them.
    var delegated: [TurnChanges]?
    /// A delegated child's dirty files at its turn start, so only its own edits count.
    var preexisting: [String: String]?
    var isVisible: Bool { !files.isEmpty || notice != nil || delegated?.contains(where: \.isVisible) == true }
    var additions: Int { files.compactMap(\.additions).reduce(0, +) }
    var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }

    /// This turn's files less those a child in the same checkout made, which
    /// a workspace capture also contains; each is listed once, under its child.
    var ownFiles: [ChangedFile] {
        let claimed = Set((delegated ?? []).filter { $0.workspace == workspace }.flatMap { $0.files.map(\.path) })
        return files.filter { !claimed.contains($0.path) }
    }
    var allFiles: [ChangedFile] { ownFiles + (delegated ?? []).flatMap(\.files) }

    /// A child's captured turns as one labelled group: each turn's files less
    /// those already dirty when it began, the latest turn winning per path.
    static func group(_ turns: [TurnChanges], id: String, label: String) -> TurnChanges? {
        let captured = turns.filter { $0.capturedAt != nil }
        guard let last = captured.last else { return nil }
        var files: [String: ChangedFile] = [:]
        for turn in captured {
            // An agent-reported diff is already the turn's own.
            for file in turn.files where turn.source == .agent || turn.preexisting?[file.path] != file.fingerprint { files[file.path] = file }
        }
        return TurnChanges(id: id, workspace: last.workspace, baseRevision: last.baseRevision, source: last.source,
                           files: files.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                           notice: last.notice, capturedAt: last.capturedAt, label: label)
    }
}

struct ChangedFile: Codable, Equatable, Identifiable {
    var path: String
    var oldPath: String?
    var kind: String = "Modified"
    var additions: Int? = 0
    var deletions: Int? = 0
    var patch: String = ""
    var previewTruncated = false
    var id: String { path }
    /// Stable across launches, unlike `hashValue`.
    var fingerprint: String {
        SHA256.hash(data: Data("\(additions ?? -1) \(deletions ?? -1)\n\(patch)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func url(in workspace: String) -> URL? {
        guard !path.isEmpty, !path.utf8.contains(0), path != "/dev/null" else { return nil }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workspace, isDirectory: true)).standardizedFileURL
    }
}

enum UnifiedDiff {
    static let maximumBytes = 4 * 1024 * 1024
    static let maximumFiles = 200
    static let previewBytes = 64 * 1024

    /// Parse hunk bodies separately so source lines beginning with +++/--- count.
    static func files(_ diff: String) -> [ChangedFile] {
        var result: [ChangedFile] = []
        var file: ChangedFile?
        var inHunk = false
        var previewSize = 0
        func finish() {
            if let file, !file.path.isEmpty, file.path != "/dev/null" { result.append(file) }
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                finish()
                file = ChangedFile(path: headerPath(String(line.dropFirst(11))))
                inHunk = false
                previewSize = 0
            } else if line.hasPrefix("@@ ") { inHunk = true }
            else if !inHunk {
                if line.hasPrefix("--- ") {
                    let path = pathField(String(line.dropFirst(4)))
                    if file == nil { file = ChangedFile(path: path) }
                    if path != "/dev/null" { file?.oldPath = path }
                    else { file?.kind = "Added" }
                } else if line.hasPrefix("+++ ") {
                    let path = pathField(String(line.dropFirst(4)))
                    if path == "/dev/null" { file?.kind = "Deleted" }
                    else { file?.path = path }
                } else if line.hasPrefix("rename from ") {
                    file?.oldPath = unquote(String(line.dropFirst(12)))
                    file?.kind = "Renamed"
                } else if line.hasPrefix("rename to ") { file?.path = unquote(String(line.dropFirst(10))) }
                else if line.hasPrefix("new file mode ") { file?.kind = "Added" }
                else if line.hasPrefix("deleted file mode ") { file?.kind = "Deleted" }
                else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                    file?.additions = nil
                    file?.deletions = nil
                }
            } else if line.hasPrefix("+"), let count = file?.additions { file?.additions = count + 1 }
            else if line.hasPrefix("-"), let count = file?.deletions { file?.deletions = count + 1 }
            if file != nil {
                previewSize += line.utf8.count + 1
                if previewSize <= previewBytes { file?.patch += line + "\n" }
                else { file?.previewTruncated = true }
            }
        }
        finish()
        // A malformed/repeated section must never create duplicate SwiftUI IDs.
        var paths = Set<String>()
        return result.reversed().filter { paths.insert($0.path).inserted }.reversed()
    }

    private static func pathField(_ value: String) -> String {
        let path = unquote(String(value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]))
        return path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    private static func headerPath(_ value: String) -> String {
        // Text patches supply exact ---/+++ paths below. This also covers
        // binary/mode-only patches, including Git's C-quoted filenames.
        if let range = value.range(of: " \"b/", options: .backwards) {
            return pathField(String(value[range.lowerBound...].dropFirst()))
        }
        if value.hasPrefix("a/") {
            var search = value.startIndex
            while let range = value.range(of: " b/", range: search..<value.endIndex) {
                let old = String(value[value.index(value.startIndex, offsetBy: 2)..<range.lowerBound])
                let new = String(value[range.upperBound...])
                if old == new { return new }
                search = range.upperBound
            }
        }
        if let range = value.range(of: " b/", options: .backwards) {
            return String(value[range.upperBound...])
        }
        return ""
    }

    /// Git quotes tabs, quotes, backslashes and non-ASCII bytes with C escapes.
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let bytes = Array(value.dropFirst().dropLast().utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            guard byte == 92, index < bytes.count else { result.append(byte); continue }
            let escaped = bytes[index]
            index += 1
            if (48...55).contains(escaped) {
                var octal = Int(escaped - 48)
                for _ in 0..<2 where index < bytes.count && (48...55).contains(bytes[index]) {
                    octal = octal * 8 + Int(bytes[index] - 48)
                    index += 1
                }
                result.append(UInt8(truncatingIfNeeded: octal))
            } else {
                result.append([UInt8(116): 9, 110: 10, 114: 13, 98: 8, 102: 12, 118: 11, 97: 7][escaped] ?? escaped)
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}

/// Read-only, bounded Git commands; callers run these off the main actor.
enum WorkspaceChanges {
    static func baseline(workspace: String, turnID: String, recordingDirtyFiles: Bool = false) -> TurnChanges {
        let root = try? run(["rev-parse", "--show-toplevel"], at: workspace).trimmingCharacters(in: .newlines)
        let revision = root.flatMap { try? run(["rev-parse", "--verify", "HEAD"], at: $0).trimmingCharacters(in: .newlines) }
        var baseline = TurnChanges(id: turnID, workspace: root ?? workspace, baseRevision: revision)
        if recordingDirtyFiles {
            baseline.preexisting = Dictionary(capture(baseline).files.map { ($0.path, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        }
        return baseline
    }

    static func capture(_ baseline: TurnChanges) -> TurnChanges {
        var snapshot = baseline
        snapshot.source = .workspace
        snapshot.files = []
        snapshot.notice = nil
        snapshot.capturedAt = Date()
        let deadline = Date().addingTimeInterval(15)
        do {
            // An ordinary conversation outside Git should not grow an empty card.
            guard (try? run(["rev-parse", "--is-inside-work-tree"], at: baseline.workspace)) == "true\n" else { return snapshot }
            let paths: [String]
            if let revision = baseline.baseRevision {
                let diff = try run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--find-renames", revision, "--"], at: baseline.workspace)
                snapshot.files = UnifiedDiff.files(diff)
                paths = try run(["ls-files", "--others", "--exclude-standard", "-z"], at: baseline.workspace).components(separatedBy: "\0").filter { !$0.isEmpty }
            } else {
                // Before the first commit, every tracked or untracked file is new.
                paths = Array(Set(try run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], at: baseline.workspace).components(separatedBy: "\0").filter { !$0.isEmpty })).sorted()
            }
            guard snapshot.files.count + paths.count <= UnifiedDiff.maximumFiles else { throw AppError("More than 200 files changed. Open the project in your editor to review them.") }
            var bytes = snapshot.files.reduce(0) { $0 + $1.patch.utf8.count }
            for path in paths {
                guard Date() < deadline else { throw AppError("Reading changes took too long. Open the project in your editor.") }
                let url = URL(fileURLWithPath: baseline.workspace).appendingPathComponent(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                // Do not follow untracked symlinks outside the working tree.
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= UnifiedDiff.maximumBytes else { throw AppError("A changed file is too large to preview. Open the project in your editor.") }
                let diff = try run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", path], at: baseline.workspace, acceptsDifference: true)
                bytes += diff.utf8.count
                guard bytes <= UnifiedDiff.maximumBytes else { throw AppError("The diff is too large to preview. Open the project in your editor.") }
                if var file = UnifiedDiff.files(diff).first {
                    file.path = path
                    snapshot.files.append(file)
                }
            }
            snapshot.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        } catch {
            snapshot.files = []
            snapshot.notice = error.localizedDescription
        }
        return snapshot
    }

    static func run(_ arguments: [String], at workspace: String, acceptsDifference: Bool = false, timeout seconds: TimeInterval = 5) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-c", "core.quotepath=false", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspace, isDirectory: true)
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        try process.run()
        // SIGKILL bounds even a stuck filesystem/Git process; this is our child only.
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        try pipe.fileHandleForWriting.close()
        var data = Data()
        var oversized = false
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            if data.count + chunk.count <= UnifiedDiff.maximumBytes { data.append(chunk) }
            else {
                oversized = true
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process.waitUntilExit()
        guard !oversized else { throw AppError("The diff is too large to preview. Open the project in your editor.") }
        guard process.terminationStatus == 0 || (acceptsDifference && process.terminationStatus == 1) else {
            throw AppError("Could not read workspace changes. Open the project in your editor to review them.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
