import SwiftUI
import AppKit

/// A command or skill the session's harness reports and runs when it arrives
/// as `/name` in an ordinary message.
struct RuntimeCommand: Equatable {
    var name: String
    var description = ""
    /// The harness's own argument hint, such as `<file>`.
    var hint: String? = nil

    /// Adapters report `[{name, description, hint}]`; a leading slash is dropped.
    static func list(_ value: Any?) -> [RuntimeCommand] {
        var seen = Set<String>()
        return (value as? [[String: Any]] ?? []).compactMap { row in
            guard var name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if name.hasPrefix("/") { name.removeFirst() }
            guard !name.isEmpty, !name.contains(where: \.isWhitespace), seen.insert(name).inserted else { return nil }
            let hint = (row["hint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RuntimeCommand(name: name, description: (row["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  hint: hint?.isEmpty == false ? hint : nil)
        }
    }
}

/// One row of the composer's completion list.
struct ComposerCompletionItem: Equatable, Identifiable {
    var name: String
    var detail: String
    /// What choosing it writes over the typed token.
    var insertion: String
    /// A trailing part of `insertion` left selected, so typing replaces it (an argument hint).
    var selectedSuffix = 0
    var id: String { insertion }
}

/// `/` as the draft's first character, or `@` starting a word, up to the caret.
struct ComposerCompletionTrigger: Equatable {
    enum Kind { case command, file }
    var kind: Kind
    var query: String
    /// The whole token, trigger included, that a choice replaces.
    var range: NSRange

    static func find(in text: String, caret: Int) -> ComposerCompletionTrigger? {
        let string = text as NSString
        guard caret > 0, caret <= string.length else { return nil }
        // A surrogate half is part of an emoji, never a space.
        func isSpace(_ index: Int) -> Bool {
            UnicodeScalar(string.character(at: index)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        func isWordStart(_ index: Int) -> Bool { index == 0 || isSpace(index - 1) }
        // Inside an open quoted mention, spaces included: `@"My Notes/pl|`.
        let line = string.lineRange(for: NSRange(location: caret, length: 0))
        let before = string.range(of: "@\"", options: .backwards, range: NSRange(location: line.location, length: caret - line.location))
        if before.location != NSNotFound, isWordStart(before.location) {
            let typed = string.substring(with: NSRange(location: before.location + 2, length: caret - before.location - 2))
            if !typed.contains("\"") {
                let rest = NSRange(location: caret, length: NSMaxRange(line) - caret)
                let close = string.range(of: "\"", range: rest)
                var end = close.location == NSNotFound ? caret : NSMaxRange(close)
                if close.location == NSNotFound { while end < string.length, !isSpace(end) { end += 1 } }
                return Self(kind: .file, query: typed, range: NSRange(location: before.location, length: end - before.location))
            }
        }
        var start = caret
        while start > 0, !isSpace(start - 1) { start -= 1 }
        guard start < caret else { return nil }
        var end = caret
        while end < string.length, !isSpace(end) { end += 1 }
        let typed = string.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        let range = NSRange(location: start, length: end - start)
        switch string.character(at: start) {
        case 0x2F where start == 0: return Self(kind: .command, query: typed, range: range)
        case 0x40: return Self(kind: .file, query: typed, range: range)
        default: return nil
        }
    }
}

enum ComposerCompletionRanking {
    static let fileRows = 50

    /// Name prefix first, then a match inside the name, then the letters in order.
    static func commands(_ commands: [RuntimeCommand], matching query: String) -> [ComposerCompletionItem] {
        let query = query.lowercased()
        return commands.compactMap { command -> (Int, RuntimeCommand)? in
            let name = command.name.lowercased()
            if query.isEmpty || name.hasPrefix(query) { return (0, command) }
            if name.contains(query) { return (1, command) }
            return isSubsequence(query, of: name) ? (2, command) : nil
        }
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name.localizedStandardCompare($1.1.name) == .orderedAscending }
        .map { _, command in
            let hint = command.hint ?? ""
            return ComposerCompletionItem(name: "/" + command.name, detail: command.description,
                                          insertion: "/\(command.name) \(hint)", selectedSuffix: (hint as NSString).length)
        }
    }

    /// Fuzzy on the relative path; a match in the file's own name ranks first,
    /// then shorter paths.
    static func files(_ paths: [String], matching query: String, limit: Int = fileRows) -> [ComposerCompletionItem] {
        let query = query.lowercased()
        var ranked: [(Int, String)] = []
        for path in paths {
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            let tier: Int
            if query.isEmpty || name.hasPrefix(query) { tier = 0 }
            else if name.contains(query) { tier = 1 }
            else if lower.contains(query) { tier = 2 }
            else if isSubsequence(query, of: lower) { tier = 3 }
            else { continue }
            ranked.append((tier, path))
        }
        ranked.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.count != b.1.count { return a.1.count < b.1.count }
            return a.1 < b.1
        }
        return ranked.prefix(limit).map { _, path in
            let folder = (path as NSString).deletingLastPathComponent
            return ComposerCompletionItem(name: (path as NSString).lastPathComponent, detail: folder.isEmpty ? "" : folder + "/",
                                          insertion: mention(path))
        }
    }

    /// `@path`, or `@"path"` when it has spaces, the quoted form Claude Code reads.
    static func mention(_ path: String) -> String {
        (path.contains(where: \.isWhitespace) ? "@\"\(path)\"" : "@" + path) + " "
    }

    private static func isSubsequence(_ query: String, of text: String) -> Bool {
        var rest = Substring(text)
        for character in query {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}

/// Files under a session's folder for `@` mentions: `git ls-files` (tracked
/// and untracked, not ignored) in a repository, else a bounded walk. Listed
/// off the main thread, cached per folder and refreshed in the background.
@MainActor final class FileMentionIndex {
    static let shared = FileMentionIndex()
    nonisolated static let limit = 20_000
    static let freshFor: TimeInterval = 30
    private var cache: [String: (paths: [String], at: Date)] = [:]
    private var waiting: [String: [() -> Void]] = [:]

    /// The cached list (nil until the first listing ends); `updated` runs once a newer one arrives.
    func paths(in folder: String, updated: @escaping () -> Void) -> [String]? {
        let cached = cache[folder]
        if cached.map({ Date().timeIntervalSince($0.at) > Self.freshFor }) ?? true {
            if waiting[folder] == nil {
                waiting[folder] = []
                Task.detached(priority: .utility) {
                    let paths = Self.list(folder)
                    await MainActor.run { self.store(paths, for: folder) }
                }
            }
            waiting[folder]?.append(updated)
        }
        return cached?.paths
    }

    func store(_ paths: [String], for folder: String) {
        cache[folder] = (paths, Date())
        waiting.removeValue(forKey: folder)?.forEach { $0() }
    }

    nonisolated static func list(_ folder: String) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: folder) else { return [] }
        if (try? WorkspaceChanges.run(["rev-parse", "--is-inside-work-tree"], at: folder)) == "true\n" {
            // Git decides what is ignored: a failed listing shows nothing rather than a walk that ignores `.gitignore`.
            guard var listed = try? WorkspaceChanges.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], at: folder, truncating: true)
            else { return [] }
            // A cut-off listing ends inside a path.
            if !listed.hasSuffix("\0"), let last = listed.lastIndex(of: "\0") { listed = String(listed[...last]) }
            var seen = Set<String>()
            // Merge conflicts list a path once per stage.
            return Array(listed.split(separator: "\0").map(String.init).filter { seen.insert($0).inserted }.prefix(limit))
        }
        return walk(folder)
    }

    nonisolated static let skippedFolders: Set<String> = ["node_modules", "build", "dist", "target", "DerivedData", "Pods", "__pycache__", "venv", "out"]
    /// In the home folder, the ones macOS guards with a privacy prompt (and Library).
    nonisolated static let privateHomeFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]

    /// Hidden and common build folders are skipped; depth and size are bounded.
    nonisolated static func walk(_ folder: String, limit: Int = limit) -> [String] {
        let root = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        var visited = 0
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        while let url = walker.nextObject() as? URL, paths.count < limit, visited < limit * 5 {
            visited += 1
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skippedFolders.contains(name) || walker.level > 12
                    || (root.path == home && walker.level == 1 && privateHomeFolders.contains(name)) { walker.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
        }
        return paths
    }
}

/// The composer's one completion list: what the editor's caret is in, the
/// matching rows and the selection. The editor asks it before handling keys.
@MainActor final class ComposerCompletion: ObservableObject {
    @Published private(set) var trigger: ComposerCompletionTrigger?
    @Published private(set) var items: [ComposerCompletionItem] = []
    @Published private(set) var selection = 0
    /// A new editor is another session's: an earlier Escape no longer applies.
    weak var editor: ComposerTextView? { didSet { if editor !== oldValue { dismissed = nil; trigger = nil; items = [] } } }
    /// Escape closes the list for that token until it is gone.
    private var dismissed: NSRange?
    private var commands: [RuntimeCommand] = []
    private var folder: String?

    var isOpen: Bool { !items.isEmpty }

    func setSources(commands: [RuntimeCommand], folder: String?) {
        guard commands != self.commands || folder != self.folder else { return }
        self.commands = commands
        self.folder = folder
        refilter()
    }

    /// The editor's text or caret changed. Marked input-method text never opens it.
    func update(text: String, selection range: NSRange, composing: Bool) {
        let found = composing || range.length > 0 ? nil : ComposerCompletionTrigger.find(in: text, caret: range.location)
        if let dismissed, found?.range.location != dismissed.location { self.dismissed = nil }
        guard found != trigger else { return }
        let sameToken = found?.kind == trigger?.kind && found?.range.location == trigger?.range.location
        trigger = found
        refilter(keepingSelection: sameToken)
    }

    private func refilter(keepingSelection: Bool = false) {
        let previous = items.indices.contains(selection) ? items[selection].id : nil
        var rows: [ComposerCompletionItem] = []
        if let trigger, dismissed == nil {
            switch trigger.kind {
            case .command: rows = ComposerCompletionRanking.commands(commands, matching: trigger.query)
            case .file:
                if let folder, let paths = FileMentionIndex.shared.paths(in: folder, updated: { [weak self] in self?.refilter(keepingSelection: true) }) {
                    rows = ComposerCompletionRanking.files(paths, matching: trigger.query)
                }
            }
        }
        let wasOpen = isOpen
        items = rows
        selection = keepingSelection ? rows.firstIndex { $0.id == previous } ?? 0 : 0
        if isOpen && (!wasOpen || !keepingSelection) { announce(opening: !wasOpen) }
    }

    func move(_ delta: Int) {
        guard isOpen else { return }
        selection = (selection + delta + items.count) % items.count
        announce(opening: false)
    }

    func dismiss() {
        dismissed = trigger?.range
        items = []
    }

    /// Writes the row over the typed token, then the caret follows it (or its hint is selected).
    func choose(_ index: Int? = nil) {
        let index = index ?? selection
        guard let editor, let trigger, items.indices.contains(index) else { return }
        let item = items[index]
        editor.insertText(item.insertion, replacementRange: trigger.range)
        let end = trigger.range.location + (item.insertion as NSString).length
        editor.setSelectedRange(NSRange(location: end - item.selectedSuffix, length: item.selectedSuffix))
        editor.window?.makeFirstResponder(editor)
    }

    /// VoiceOver hears the list open and each row the arrows select.
    private func announce(opening: Bool) {
        guard items.indices.contains(selection), let kind = trigger?.kind else { return }
        let item = items[selection]
        var words = [item.name, item.detail].filter { !$0.isEmpty }.joined(separator: ", ")
        if opening {
            let noun = kind == .command ? (items.count == 1 ? "command" : "commands") : (items.count == 1 ? "file" : "files")
            words = "\(items.count) \(noun). \(words)"
        }
        guard let target = editor ?? NSApp?.keyWindow else { return }
        NSAccessibility.post(element: target, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// The list over the transcript, its bottom on the field's top edge, so the
/// panel never grows. Rows show a name and a one-line description.
struct ComposerCompletionList: View {
    @ObservedObject var completion: ComposerCompletion
    static let rowHeight: CGFloat = PanelTheme.pick(28, 28, 26)
    static let visibleRows = 6

    var body: some View {
        if completion.isOpen, let kind = completion.trigger?.kind {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(completion.items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == completion.selection) { completion.choose(index) }.id(item.id)
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.automatic)
                .frame(height: CGFloat(min(completion.items.count, Self.visibleRows)) * Self.rowHeight + 8)
                .onChange(of: completion.selection) { _, value in
                    if completion.items.indices.contains(value) { proxy.scrollTo(completion.items[value].id) }
                }
            }
            .completionSurface()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(kind == .command ? "Commands and skills" : "Files")
        }
    }

    private func row(_ item: ComposerCompletionItem, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(item.name).foregroundStyle(CompanionStyle.text).lineLimit(1).layoutPriority(1)
                    .font(PanelTheme.current == .instrument ? CompanionStyle.mono(11.5) : .system(size: 12.5, weight: .medium))
                Text(item.detail).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                    .truncationMode(completion.trigger?.kind == .file ? .head : .tail)
                    .font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PanelTheme.pick(9, 9, 8)).frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Tahoe marks the keyboard selection with the accent, as a native menu does.
                if selected && PanelTheme.current == .tahoe {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CompanionStyle.accent.opacity(0.85))
                }
            }
        }
        .buttonStyle(NotchRowButtonStyle(selected: selected && PanelTheme.current != .tahoe, cornerRadius: PanelTheme.pick(8, 7, CompanionStyle.radius)))
        .help(item.detail.isEmpty ? item.name : "\(item.name) — \(item.detail)")
        .accessibilityLabel([item.name, item.detail].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    @ViewBuilder func completionSurface() -> some View {
        switch PanelTheme.current {
        case .refined: notchPopover()
        case .tahoe: notchPopover(cornerRadius: 12)
        case .instrument: instrumentPopup()
        }
    }
}
