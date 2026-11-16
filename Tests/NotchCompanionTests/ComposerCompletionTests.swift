import XCTest
import AppKit
@testable import NotchCompanion

final class ComposerCompletionTests: XCTestCase {
    func testTriggersAreASlashFirstOrAnAtStartingAWord() {
        let command = ComposerCompletionTrigger.find(in: "/rev more", caret: 4)
        XCTAssertEqual(command, ComposerCompletionTrigger(kind: .command, query: "rev", range: NSRange(location: 0, length: 4)))
        XCTAssertNil(ComposerCompletionTrigger.find(in: " /rev", caret: 5), "A slash later in the draft is text")
        XCTAssertNil(ComposerCompletionTrigger.find(in: "Run /rev", caret: 8))
        XCTAssertNil(ComposerCompletionTrigger.find(in: "/review ", caret: 8), "After the space the command is written")
        let file = ComposerCompletionTrigger.find(in: "Read @src/Ap and", caret: 12)
        XCTAssertEqual(file, ComposerCompletionTrigger(kind: .file, query: "src/Ap", range: NSRange(location: 5, length: 7)))
        XCTAssertEqual(ComposerCompletionTrigger.find(in: "@src/App.swift", caret: 2)?.range, NSRange(location: 0, length: 14),
                       "A choice replaces the whole word around the caret")
        XCTAssertNil(ComposerCompletionTrigger.find(in: "me@example", caret: 10), "An @ inside a word is not a mention")
        XCTAssertEqual(ComposerCompletionTrigger.find(in: "@\"My", caret: 4)?.query, "My")
        XCTAssertNil(ComposerCompletionTrigger.find(in: "", caret: 0))
    }

    func testCommandsFilterByNameAndInsertTheirHint() {
        let commands = RuntimeCommand.list([
            ["name": "/review", "description": "Review a pull request", "hint": "<pr>"],
            ["name": "pr-comments", "description": "Show comments"],
            ["name": "skill:release-notes", "description": "Draft notes", "hint": ""],
            ["name": "review", "description": "Duplicate"], ["name": "two words"], ["description": "nameless"]])
        XCTAssertEqual(commands.map(\.name), ["review", "pr-comments", "skill:release-notes"])
        XCTAssertNil(commands[2].hint)
        XCTAssertEqual(ComposerCompletionRanking.commands(commands, matching: "").map(\.name), ["/pr-comments", "/review", "/skill:release-notes"])
        XCTAssertEqual(ComposerCompletionRanking.commands(commands, matching: "re").map(\.name), ["/review", "/skill:release-notes", "/pr-comments"],
                       "Prefix, then inside the name, then the letters in order")
        let review = ComposerCompletionRanking.commands(commands, matching: "rev")[0]
        XCTAssertEqual(review.insertion, "/review <pr>")
        XCTAssertEqual(review.selectedSuffix, 4)
        XCTAssertEqual(review.detail, "Review a pull request")
        XCTAssertEqual(ComposerCompletionRanking.commands(commands, matching: "pr-c")[0].insertion, "/pr-comments ")
        XCTAssertTrue(ComposerCompletionRanking.commands(commands, matching: "zzz").isEmpty)
    }

    func testFilesRankFileNameMatchesFirstAndQuotePathsWithSpaces() {
        let paths = ["Sources/AppModel.swift", "docs/app-notes.md", "Sources/Views/Composer.swift", "Tests/AppTests.swift", "a/p/p/x.txt", "My Notes/plan one.md"]
        let names = ComposerCompletionRanking.files(paths, matching: "app").map(\.insertion)
        XCTAssertEqual(names, ["@docs/app-notes.md ", "@Tests/AppTests.swift ", "@Sources/AppModel.swift ", "@a/p/p/x.txt "])
        let composer = ComposerCompletionRanking.files(paths, matching: "svc")
        XCTAssertEqual(composer.map(\.name), ["Composer.swift"], "Fuzzy on the whole relative path")
        XCTAssertEqual(composer.first?.detail, "Sources/Views/")
        XCTAssertEqual(ComposerCompletionRanking.files(paths, matching: "plan").first?.insertion, "@\"My Notes/plan one.md\" ")
        XCTAssertEqual(ComposerCompletionRanking.files(paths, matching: "", limit: 2).count, 2)
    }

    @MainActor private func editor(_ completion: ComposerCompletion) -> ComposerTextView {
        _ = NSApplication.shared
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        view.isRichText = false
        view.completion = completion
        completion.editor = view
        return view
    }

    private func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @MainActor func testOpenListOwnsArrowsReturnTabAndEscape() {
        let completion = ComposerCompletion()
        completion.setSources(commands: [RuntimeCommand(name: "compact", description: "Free up context", hint: "<instructions>"),
                                         RuntimeCommand(name: "context", description: "Show context")], folder: nil)
        let view = editor(completion)
        var sent = 0
        view.onSubmit = { sent += 1 }
        view.onQueue = { sent += 1 }
        view.recallPrompts = { ["Earlier prompt"] }
        view.insertText("/co", replacementRange: NSRange(location: 0, length: 0))
        view.reportCompletion()
        XCTAssertTrue(completion.isOpen)
        XCTAssertEqual(completion.items.map(\.name), ["/compact", "/context"])
        view.keyDown(with: key(125, "\u{F701}", [.function, .numericPad]))
        XCTAssertEqual(completion.selection, 1)
        view.keyDown(with: key(126, "\u{F700}", [.function, .numericPad]))
        XCTAssertEqual(completion.selection, 0)
        XCTAssertEqual(view.string, "/co", "↑ moves the selection, never recalls a prompt")
        view.keyDown(with: key(36, "\r", .command))
        XCTAssertEqual(sent, 0, "Return never sends while the list is open")
        XCTAssertEqual(view.string, "/compact <instructions>")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 9, length: 14), "The hint is selected, so typing replaces it")
        view.reportCompletion()
        XCTAssertFalse(completion.isOpen)
        view.keyDown(with: key(36, "\r"))
        XCTAssertEqual(sent, 1, "A closed list leaves Return to send")

        view.string = ""
        view.insertText("/con", replacementRange: NSRange(location: 0, length: 0))
        view.reportCompletion()
        view.keyDown(with: key(48, "\t"))
        XCTAssertEqual(view.string, "/context ", "Tab chooses too")

        view.string = ""
        view.insertText("/c", replacementRange: NSRange(location: 0, length: 0))
        view.reportCompletion()
        view.keyDown(with: key(53, "\u{1B}"))
        XCTAssertFalse(completion.isOpen)
        XCTAssertEqual(view.string, "/c", "Escape closes the list and keeps the text")
        view.insertText("o", replacementRange: view.selectedRange())
        view.reportCompletion()
        XCTAssertFalse(completion.isOpen, "It stays closed for that word")
        view.string = ""
        view.reportCompletion()
        view.insertText("/", replacementRange: NSRange(location: 0, length: 0))
        view.reportCompletion()
        XCTAssertTrue(completion.isOpen, "A new word opens it again")
    }

    @MainActor func testMarkedTextNeverOpensOrChooses() {
        let completion = ComposerCompletion()
        completion.setSources(commands: [RuntimeCommand(name: "compact")], folder: nil)
        let view = editor(completion)
        view.setMarkedText("/", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        view.reportCompletion()
        XCTAssertFalse(completion.isOpen)
        completion.update(text: "/", selection: NSRange(location: 1, length: 0), composing: false)
        XCTAssertTrue(completion.isOpen)
        var sent = 0
        view.onSubmit = { sent += 1 }
        view.keyDown(with: key(36, "\r"))
        XCTAssertFalse(view.string.contains("compact"), "Return during a composition goes to the input method, not the list")
        XCTAssertEqual(sent, 0)
    }

    @MainActor func testFileListLoadsOffTheMainThreadAndFilters() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mentions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for path in ["Sources/App.swift", "README.md", ".hidden/secret.txt", "node_modules/pkg/index.js", "build/out.o", "Docs/Guide Book.md"] {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        XCTAssertEqual(Set(FileMentionIndex.walk(folder.path)), ["Sources/App.swift", "README.md", "Docs/Guide Book.md"],
                       "Hidden and build folders are skipped")
        XCTAssertEqual(FileMentionIndex.walk(folder.path, limit: 1).count, 1)
        XCTAssertTrue(FileMentionIndex.list(folder.appendingPathComponent("missing").path).isEmpty)

        let completion = ComposerCompletion()
        completion.setSources(commands: [], folder: folder.path)
        completion.update(text: "Read @gui", selection: NSRange(location: 9, length: 0), composing: false)
        XCTAssertFalse(completion.isOpen, "Nothing until the first listing ends")
        for _ in 0..<200 where !completion.isOpen { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(completion.items.map(\.insertion), ["@\"Docs/Guide Book.md\" "])
    }

    func testGitFolderListsTrackedAndUntrackedButNotIgnoredFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mentions-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("build"), withIntermediateDirectories: true)
        _ = try WorkspaceChanges.run(["init", "-q"], at: folder.path)
        try Data("ignored.log\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))
        for name in ["tracked.swift", "ignored.log", "new.txt", "build/kept.o"] { try Data().write(to: folder.appendingPathComponent(name)) }
        _ = try WorkspaceChanges.run(["add", "tracked.swift"], at: folder.path)
        XCTAssertEqual(Set(FileMentionIndex.list(folder.path)), ["tracked.swift", "new.txt", ".gitignore", "build/kept.o"],
                       "Git decides, so a build folder it does not ignore is listed")
    }

    // MARK: Harness catalogs

    func testACPReportsItsAvailableCommands() {
        var state = ACPProtocolState(); state.owned = ["owned"]
        let update: [String: Any] = ["sessionUpdate": "available_commands_update", "availableCommands": [
            ["name": "web", "description": "Search the web", "input": ["hint": "query"]], ["name": "plan", "description": "Plan first", "input": NSNull()]]]
        let events = state.notification("session/update", ["sessionId": "owned", "update": update])
        XCTAssertEqual(events.map(\.name), ["session.commands"])
        let commands = RuntimeCommand.list(events.first?.payload["commands"])
        XCTAssertEqual(commands, [RuntimeCommand(name: "web", description: "Search the web", hint: "query"), RuntimeCommand(name: "plan", description: "Plan first")])
        XCTAssertTrue(state.notification("session/update", ["sessionId": "other", "update": update]).isEmpty)
    }

    @MainActor func testClaudeLeavesOutClearWhichMovesTheSession() {
        let commands = RuntimeCommand.list(ClaudeClient.commands([
            ["name": "compact", "description": "Free up context", "argumentHint": "<optional custom summarization instructions>"],
            ["name": "clear", "description": "Start a new session"], ["name": "deploy", "description": "Ship it", "argumentHint": ""]]))
        XCTAssertEqual(commands.map(\.name), ["compact", "deploy"])
        XCTAssertEqual(commands.first?.hint, "<optional custom summarization instructions>")
    }

    @MainActor func testSessionCatalogIsCachedForItsSessionAndDraftsInTheSameFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: CompletionTransport())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        model.sessions[0].runtime = .claude
        model.sessions[0].profileID = "profile"
        model.sessions[0].workspacePath = "/project"
        model.sessions[0].runtimeID = "live"
        var draft = model.sessions[0]
        draft.id = UUID().uuidString; draft.runtimeID = nil
        var elsewhere = draft
        elsewhere.id = UUID().uuidString; elsewhere.workspacePath = "/other"
        model.sessions += [draft, elsewhere]
        model.receive("session.commands", payload: ["session_id": "live", "commands": [["name": "review", "description": "Review"]]])
        XCTAssertEqual(model.composerCommands(for: model.sessions[0]).map(\.name), ["review"])
        XCTAssertEqual(model.composerCommands(for: model.sessions[1]).map(\.name), ["review"], "A draft in the same profile and folder uses it")
        XCTAssertTrue(model.composerCommands(for: model.sessions[2]).isEmpty, "Another folder may have other commands")
        model.sessions[0].runtime = .codex
        XCTAssertTrue(model.composerCommands(for: model.sessions[0]).isEmpty, "Another harness never inherits them")
        model.sessions[0].runtime = .claude
        model.receive("session.commands", payload: ["session_id": "live", "commands": []])
        XCTAssertTrue(model.composerCommands(for: model.sessions[0]).isEmpty, "A harness that reports none shows no list")
    }
}

@MainActor private final class CompletionTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func disconnect() {}
}
