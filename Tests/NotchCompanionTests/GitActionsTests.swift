import XCTest
@testable import NotchCompanion

@MainActor private final class IdleTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws {}
    func disconnect() {}
    var calls: [(String, [String: Any])] = []
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        guard method == "session.draft_title" else { throw AppError("Not connected.") }
        return ["title": "Tidy the readme"]
    }
}

/// Git runs only in temporary repositories, pushing to a local bare repository; `gh` is a fake script.
@MainActor final class GitActionsTests: XCTestCase {
    private var folders: [URL] = []
    private var models: [AppModel] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        for model in models { model.shutdown() }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        models = []; suites = []; folders = []
    }

    private func temporary(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-git-\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
        folders.append(url)
        return url
    }

    @discardableResult
    private func git(_ arguments: [String], at folder: URL) throws -> String {
        try WorkspaceChanges.run(arguments, at: folder.path, reportingErrors: true)
    }

    /// A repository on `branch` with one commit, its own identity and no hooks or signing, pushing to a bare `origin`.
    private func makeRepository(branch: String = "notch/fix-1a2b3c4d") throws -> (URL, URL) {
        let remote = temporary("remote"), repository = temporary("repo"), hooks = temporary("hooks")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "-b", "main", remote.path], at: FileManager.default.temporaryDirectory)
        try git(["init", "-q", "-b", "main"], at: repository)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", hooks.path)] {
            try git(["config", key, value], at: repository)
        }
        try Data("one\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try git(["add", "."], at: repository); try git(["commit", "-q", "-m", "Initial"], at: repository)
        try git(["remote", "add", "origin", remote.path], at: repository)
        try git(["push", "-q", "origin", "main"], at: repository)
        try git(["remote", "set-head", "origin", "main"], at: repository)
        if branch != "main" { try git(["checkout", "-q", "-b", branch], at: repository) }
        return (repository, remote)
    }

    func testParsesStatusIncludingRenamesUntrackedAndSpaces() {
        let files = GitActions.parseStatus(" M a.swift\0R  new name.txt\0old name.txt\0?? docs/new file.md\0 D gone.txt\0A  added.txt\0UU both.txt\0")
        XCTAssertEqual(files, [GitStatusFile(path: "a.swift", kind: "Modified"),
                               GitStatusFile(path: "new name.txt", oldPath: "old name.txt", kind: "Renamed"),
                               GitStatusFile(path: "docs/new file.md", kind: "Untracked"),
                               GitStatusFile(path: "gone.txt", kind: "Deleted"),
                               GitStatusFile(path: "added.txt", kind: "Added"),
                               GitStatusFile(path: "both.txt", kind: "Conflicted")])
    }

    func testRecognizesOnlyGitHubRemotes() {
        for url in ["https://github.com/owner/repo.git", "git@github.com:owner/repo.git", "ssh://git@github.com/owner/repo",
                    "https://user@github.com/owner/repo/", "https://GitHub.com/owner/repo"] {
            XCTAssertEqual(GitActions.githubRepository(url)?.lowercased(), "owner/repo", url)
        }
        for url in ["https://gitlab.com/owner/repo.git", "git@github.com.evil.com:owner/repo", "https://github.com/owner",
                    "https://github.com/owner/repo/extra", "/tmp/repo.git", "https://github.com/../x", nil] {
            XCTAssertNil(GitActions.githubRepository(url), url ?? "nil")
        }
    }

    func testConfirmsPushesOutsideTheSessionsOwnWorktreeBranch() {
        XCTAssertFalse(GitActions.needsPushConfirmation(branch: "notch/fix-1", defaultBranch: "main", worktreeBranch: "notch/fix-1"))
        XCTAssertTrue(GitActions.needsPushConfirmation(branch: "main", defaultBranch: "main", worktreeBranch: "main"))
        XCTAssertTrue(GitActions.needsPushConfirmation(branch: "master", defaultBranch: nil, worktreeBranch: nil))
        XCTAssertTrue(GitActions.needsPushConfirmation(branch: "trunk", defaultBranch: "trunk", worktreeBranch: "trunk"))
        XCTAssertTrue(GitActions.needsPushConfirmation(branch: "feature/x", defaultBranch: "main", worktreeBranch: nil))
        XCTAssertTrue(GitActions.needsPushConfirmation(branch: "notch/other", defaultBranch: "main", worktreeBranch: "notch/fix-1"))
    }

    func testCompareURLEncodesBranchesAndDraft() {
        let url = GitActions.compareURL(repository: "owner/repo", base: "main", head: "notch/fix #1", title: "Fix & test", body: "- a\n- b")
        XCTAssertEqual(url.absoluteString, "https://github.com/owner/repo/compare/main...notch/fix%20%231?expand=1&title=Fix%20%26%20test&body=-%20a%0A-%20b")
    }

    func testDraftMessageUsesTitleAndFiles() {
        XCTAssertEqual(GitActions.draftMessage(subject: "Fix the login form\nmore", files: [GitStatusFile(path: "a.swift", kind: "Modified")]),
                       "Fix the login form\n\n- Modified a.swift")
        XCTAssertEqual(GitActions.draftMessage(subject: " ", files: [GitStatusFile(path: "a", kind: "Added"), GitStatusFile(path: "b", kind: "Deleted")]),
                       "Update 2 files\n\n- Added a\n- Deleted b")
    }

    func testCommitsOnlyIncludedPathsThenPushesWithUpstream() throws {
        let (repository, remote) = try makeRepository()
        try Data("two\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try Data("new".utf8).write(to: repository.appendingPathComponent("*.txt"))
        try Data("keep".utf8).write(to: repository.appendingPathComponent("keep.txt"))
        try Data("staged".utf8).write(to: repository.appendingPathComponent("staged.txt"))
        try git(["add", "staged.txt"], at: repository)
        try git(["mv", "README.md", "Read me.md"], at: repository)

        var state = try XCTUnwrap(GitActions.read(repository.path))
        XCTAssertEqual(state.branch, "notch/fix-1a2b3c4d")
        XCTAssertEqual(state.remote, "origin")
        XCTAssertEqual(state.defaultBranch, "main")
        XCTAssertFalse(state.pushed)
        XCTAssertEqual(Set(state.files.map(\.path)), ["*.txt", "keep.txt", "staged.txt", "Read me.md"])
        let included = state.files.filter { $0.path == "*.txt" || $0.path == "Read me.md" }
        let hash = try GitActions.commit(included, message: "Add a file\n\nBody", at: state.root)
        XCTAssertFalse(hash.isEmpty)
        // Exactly the included paths (a literal `*`, the rename's both sides); the excluded staged file stays staged.
        XCTAssertEqual(try git(["show", "--name-status", "--format=%an %s", "HEAD"], at: repository),
                       "Fixture Add a file\n\nA\t*.txt\nD\tREADME.md\nA\tRead me.md\n")
        XCTAssertEqual(try git(["status", "--porcelain"], at: repository), "A  staged.txt\n?? keep.txt\n")

        try GitActions.push(remote: "origin", branch: "notch/fix-1a2b3c4d", at: state.root)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: repository), try git(["rev-parse", "notch/fix-1a2b3c4d"], at: remote))
        XCTAssertEqual(try git(["config", "branch.notch/fix-1a2b3c4d.remote"], at: repository), "origin\n")
        state = try XCTUnwrap(GitActions.read(repository.path))
        XCTAssertTrue(state.pushed)
        XCTAssertFalse(state.unpushed)
        XCTAssertEqual(state.subject, "Add a file")
        XCTAssertEqual(GitActions.draftBody(base: "main", remote: "origin", at: state.root), "- Add a file")
    }

    func testFailedHookShowsItsOutputAndCommitsNothing() throws {
        let (repository, _) = try makeRepository()
        let hooks = URL(fileURLWithPath: try git(["config", "core.hooksPath"], at: repository).trimmingCharacters(in: .newlines))
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\necho 'lint failed: trailing space' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try Data("two\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        let state = try XCTUnwrap(GitActions.read(repository.path))
        XCTAssertThrowsError(try GitActions.commit(state.files, message: "Change", at: state.root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("lint failed: trailing space"), error.localizedDescription)
        }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], at: repository), "1\n")
        XCTAssertThrowsError(try GitActions.commit([], message: "Change", at: state.root)) { XCTAssertEqual($0.localizedDescription, "Nothing to commit.") }
    }

    func testPushWithoutRemoteShowsGitsError() throws {
        let (repository, _) = try makeRepository()
        try git(["remote", "remove", "origin"], at: repository)
        XCTAssertNil(GitActions.read(repository.path)?.remote)
        XCTAssertThrowsError(try GitActions.push(remote: "origin", branch: "notch/fix-1a2b3c4d", at: repository.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("origin"), error.localizedDescription)
        }
        XCTAssertNil(GitActions.read("/nonexistent-\(UUID())"))
    }

    /// A fake `gh` that logs its arguments, one per line, and answers like the real one.
    private func fakeGH(authenticated: Bool = true, output: String = "https://github.com/owner/repo/pull/7", fails: Bool = false) throws -> (URL, URL) {
        let folder = temporary("gh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("log"), script = folder.appendingPathComponent("gh")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" >> '\(log.path)'
        if [ "$1" = auth ]; then exit \(authenticated ? 0 : 1); fi
        \(fails ? "echo '\(output)' >&2; exit 1" : "echo '\(output)'")
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }

    func testPullRequestUsesGHLoginElseCompareURL() throws {
        let (repository, _) = try makeRepository()
        let (gh, log) = try fakeGH()
        let result = try GitActions.pullRequest(repository: "owner/repo", base: "main", head: "notch/fix-1a2b3c4d", title: "Fix; rm -rf $HOME",
                                                body: "Body `x`", at: repository.path, gh: gh)
        XCTAssertEqual(result, .created(URL(string: "https://github.com/owner/repo/pull/7")!))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), """
        auth\nstatus\n--hostname\ngithub.com\npr\ncreate\n--repo\nowner/repo\n--base\nmain\n--head\nnotch/fix-1a2b3c4d\n--title\nFix; rm -rf $HOME\n--body\nBody `x`\n
        """)

        let (signedOut, _) = try fakeGH(authenticated: false)
        for gh in [signedOut, nil] {
            guard case .compare(let url) = try GitActions.pullRequest(repository: "owner/repo", base: "main", head: "b", title: "T", body: "", at: repository.path, gh: gh)
            else { return XCTFail("Expected the compare page") }
            XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/owner/repo/compare/main...b?"))
        }

        let (existing, _) = try fakeGH(output: "a pull request for branch \"b\" into branch \"main\" already exists:\nhttps://github.com/owner/repo/pull/3", fails: true)
        XCTAssertEqual(try GitActions.pullRequest(repository: "owner/repo", base: "main", head: "b", title: "T", body: "", at: repository.path, gh: existing),
                       .created(URL(string: "https://github.com/owner/repo/pull/3")!))
        let (failing, _) = try fakeGH(output: "GraphQL: No commits between main and b", fails: true)
        XCTAssertThrowsError(try GitActions.pullRequest(repository: "owner/repo", base: "main", head: "b", title: "T", body: "", at: repository.path, gh: failing)) {
            XCTAssertTrue($0.localizedDescription.contains("No commits between"), $0.localizedDescription)
        }
    }

    private func makeModel(session: CompanionSession) -> AppModel {
        let suite = "notch-git-\(UUID().uuidString)"
        suites.append(suite)
        let model = AppModel(storageURL: temporary("store").appendingPathComponent("sessions.json"), playsSounds: false,
                             client: IdleTransport(), preferences: UserDefaults(suiteName: suite)!)
        models.append(model)
        model.sessions = [session]
        model.currentID = session.id
        return model
    }

    func testControllerWaitsForIdleThenCommitsPushesAndRecordsPullRequest() async throws {
        let (repository, remote) = try makeRepository()
        try git(["remote", "set-url", "origin", "https://github.com/owner/repo.git"], at: repository)
        try git(["remote", "set-url", "--push", "origin", remote.path], at: repository)
        try Data("two\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        var session = CompanionSession(id: "s", title: "Fix the readme", state: .working, workspacePath: repository.path)
        session.worktree = SessionWorktree(repository: repository.path, project: repository.path, branch: "notch/fix-1a2b3c4d", path: repository.path, base: "main")
        let model = makeModel(session: session)
        let controller = model.gitActions(for: "s")
        XCTAssertTrue(controller === model.gitActions(for: "s"))
        await controller.refresh()
        XCTAssertEqual(controller.repository?.github, "owner/repo")
        await controller.writeMessage()
        XCTAssertEqual(controller.message, "Fix the readme\n\n- Modified README.md")

        // Busy: nothing happens.
        await controller.commit(thenPush: true)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], at: repository), "1\n")

        model.update("s") { $0.state = .finished }
        await controller.commit(thenPush: true)
        XCTAssertNil(controller.error)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: repository), try git(["rev-parse", "notch/fix-1a2b3c4d"], at: remote))
        XCTAssertEqual(controller.notice, "Pushed notch/fix-1a2b3c4d to origin.")
        XCTAssertTrue(controller.repository?.pushed == true)

        controller.toggle(.pullRequest)
        for _ in 0..<200 where controller.form != .pullRequest { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.title, "Fix the readme")
        XCTAssertEqual(controller.base, "main")
        XCTAssertEqual(controller.body, "- Fix the readme")
        let (gh, _) = try fakeGH()
        controller.gh = { gh }
        await controller.createPullRequest()
        XCTAssertEqual(model.sessions[0].pullRequest, "https://github.com/owner/repo/pull/7")
        XCTAssertNil(controller.form)
    }

    func testClaudeDraftsTheSubjectOtherHarnessesFillIt() async throws {
        let (repository, _) = try makeRepository()
        try Data("two\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        var session = CompanionSession(id: "s", runtimeID: "rt-s", title: "Fix the readme", state: .finished, workspacePath: repository.path)
        session.runtime = .claude
        let model = makeModel(session: session)
        let controller = model.gitActions(for: "s")
        await controller.refresh()
        XCTAssertTrue(controller.harnessDrafts)
        await controller.writeMessage()
        XCTAssertEqual(controller.message, "Tidy the readme\n\n- Modified README.md")
        let transport = try XCTUnwrap(model.client as? IdleTransport)
        XCTAssertEqual(transport.calls.map(\.0), ["session.draft_title"])
        XCTAssertEqual(transport.calls.first?.1["session_id"] as? String, "rt-s")
        model.update("s") { $0.runtime = .codex }
        controller.message = ""
        XCTAssertFalse(controller.harnessDrafts)
        await controller.writeMessage()
        XCTAssertEqual(controller.message, "Fix the readme\n\n- Modified README.md")
        XCTAssertEqual(transport.calls.count, 1)
    }

    func testPushToADefaultBranchAsksFirst() async throws {
        let (repository, remote) = try makeRepository(branch: "main")
        try Data("two\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try git(["commit", "-qam", "Two"], at: repository)
        let model = makeModel(session: CompanionSession(id: "s", title: "T", state: .finished, workspacePath: repository.path))
        let controller = model.gitActions(for: "s")
        await controller.push()
        XCTAssertEqual(controller.form, .confirmPush)
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"], at: repository), try git(["rev-parse", "main"], at: remote))
        await controller.push(confirmed: true)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: repository), try git(["rev-parse", "main"], at: remote))
    }

    func testWorktreeRecordsItsBaseAndOldRecordsDecode() throws {
        let (repository, _) = try makeRepository(branch: "main")
        try git(["update-ref", "refs/remotes/origin/release/1", "main"], at: repository)
        let root = temporary("worktrees")
        for (base, expected) in [("main", "main"), ("origin/release/1", "release/1"), ("HEAD", "main")] {
            let (_, record) = try Delegation.makeWorktree(from: repository.path, name: "w", root: root, base: base)
            XCTAssertEqual(record.base, expected, base)
        }
        let old = try JSONDecoder().decode(SessionWorktree.self, from: Data(#"{"repository":"/r","project":"/r","branch":"notch/x","path":"/w"}"#.utf8))
        XCTAssertNil(old.base)
        let session = try JSONDecoder().decode(CompanionSession.self, from: Data(#"{"id":"s","runtime":"codex"}"#.utf8))
        XCTAssertNil(session.pullRequest)
    }
}
