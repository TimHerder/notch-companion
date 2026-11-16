import XCTest
@testable import NotchCompanion

/// Each companion session gets runtime ID `rt-<companion id>`; every call is recorded.
@MainActor private final class WorktreeTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        guard method == "session.create" || method == "session.resume" else { return [:] }
        let owner = params["companion_id"] as? String ?? UUID().uuidString
        return ["session_id": "rt-" + owner, "stored_session_id": "native-" + owner]
    }
}

/// Git runs only in temporary repositories created here.
@MainActor final class WorktreeSessionTests: XCTestCase {
    private var folders: [URL] = []
    private var suites: [String] = []
    private var models: [AppModel] = []

    override func tearDown() async throws {
        for model in models { model.shutdown() }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        models = []; suites = []; folders = []
    }

    private func makeModel() -> (AppModel, WorktreeTransport) {
        let suite = "notch-worktree-\(UUID().uuidString)"
        suites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set([RuntimeKind.codex.rawValue: RuntimeRoute.defaultProfile(.codex, defaults: preferences)], forKey: "runtime.configuredProfiles")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-worktree-store-\(UUID().uuidString)")
        folders.append(folder)
        let transport = WorktreeTransport()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport, preferences: preferences)
        models.append(model)
        return (model, transport)
    }

    @discardableResult
    private func git(_ arguments: [String], at folder: URL) throws -> String {
        try WorkspaceChanges.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                                  "-c", "core.hooksPath=/dev/null"] + arguments, at: folder.path, reportingErrors: true)
    }

    /// `main` with app/README.md, a `feature` branch adding feature.txt, and `origin/main`.
    private func makeRepository() throws -> URL {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("notch-worktree-repo-\(UUID().uuidString)")
        folders.append(repository)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("app"), withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: repository)
        try Data("committed".utf8).write(to: repository.appendingPathComponent("app/README.md"))
        try git(["add", "."], at: repository); try git(["commit", "-q", "-m", "Initial"], at: repository)
        try git(["checkout", "-q", "-b", "feature"], at: repository)
        try Data("feature".utf8).write(to: repository.appendingPathComponent("feature.txt"))
        try git(["add", "."], at: repository); try git(["commit", "-q", "-m", "Feature"], at: repository)
        try git(["checkout", "-q", "main"], at: repository)
        try git(["update-ref", "refs/remotes/origin/main", "main"], at: repository)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: repository)
        return repository
    }

    private func finish(_ model: AppModel, _ id: String) {
        model.receive("message.start", payload: ["session_id": "rt-" + id])
        model.receive("message.complete", payload: ["session_id": "rt-" + id, "text": "Done.", "status": "complete"])
    }

    /// A Codex draft in `folder` that chose New worktree from `base`.
    private func worktreeDraft(_ model: AppModel, folder: String, base: String?) async throws -> String {
        await model.newSession(showPanel: false, runtime: .codex, workspace: folder)
        let id = try XCTUnwrap(model.currentID)
        await model.loadBranches(for: folder)
        if let base { model.setWorktreeBase(base, for: id) }
        return id
    }

    func testBranchesListLocalAndRemoteTrackingWithTheCurrentFirst() throws {
        let repository = try makeRepository()
        let branches = try XCTUnwrap(GitBranches.read(repository.appendingPathComponent("app").path))
        XCTAssertEqual(branches.current, "main")
        XCTAssertEqual(branches.names, ["main", "feature", "origin/main"], "origin/HEAD is an alias, not a branch")
        XCTAssertEqual(branches.matching("FEAT"), ["feature"])
        XCTAssertNil(GitBranches.read(FileManager.default.temporaryDirectory.path), "Outside Git")
    }

    func testNewWorktreeSessionBranchesFromItsBaseOnTheFirstSend() async throws {
        let (model, transport) = makeModel()
        let repository = try makeRepository()
        let folder = repository.appendingPathComponent("app").path
        await model.connect()
        let id = try await worktreeDraft(model, folder: folder, base: "feature")
        XCTAssertNotNil(model.worktreeBranches(for: model.current!), "A Git draft offers the choice")
        model.draft = "Fix the login page"
        await model.send()
        let session = try XCTUnwrap(model.sessions.first { $0.id == id })
        let worktree = try XCTUnwrap(session.worktree)
        let workspace = try XCTUnwrap(session.workspacePath)
        XCTAssertTrue(workspace.hasPrefix(model.worktreesDirectory.path + "/"), workspace)
        XCTAssertTrue(workspace.hasSuffix("/app"), "The chosen subfolder inside the worktree")
        XCTAssertEqual(worktree.branch, "notch/fix-the-login-page-" + id.lowercased().prefix(8))
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], at: URL(fileURLWithPath: workspace)).trimmingCharacters(in: .newlines), worktree.branch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path + "/feature.txt"), "Checked out from the base branch")
        XCTAssertNil(try? git(["config", "--get", "branch.\(worktree.branch).merge"], at: repository), "No upstream")
        XCTAssertNil(session.worktreeBase)
        XCTAssertEqual(model.projectPath(of: session), URL(fileURLWithPath: folder).standardizedFileURL.path, "Grouped under its project")
        XCTAssertEqual(transport.calls.first { $0.0 == "session.create" }?.1["cwd"] as? String, workspace)
        XCTAssertEqual(transport.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        XCTAssertNil(model.worktreeBranches(for: session), "A started session no longer chooses")

        // A taken name gets the next suffix rather than failing.
        let again = try Delegation.makeWorktree(from: folder, name: worktree.name, root: model.worktreesDirectory)
        XCTAssertEqual(again.worktree.branch, worktree.branch + "-2")
    }

    func testAFailedWorktreeKeepsTheDraftAndSendsNothing() async throws {
        let (model, transport) = makeModel()
        let repository = try makeRepository()
        await model.connect()
        let id = try await worktreeDraft(model, folder: repository.path, base: "no-such-branch")
        model.draft = "Try it"
        await model.send()
        let session = try XCTUnwrap(model.sessions.first { $0.id == id })
        XCTAssertEqual(session.draft, "Try it")
        XCTAssertNil(session.worktree)
        XCTAssertEqual(session.worktreeBase, "no-such-branch", "The choice stays for a retry")
        XCTAssertEqual(session.workspacePath, repository.path)
        XCTAssertTrue(model.errorMessage?.contains("no-such-branch") == true, model.errorMessage ?? "")
        XCTAssertFalse(transport.calls.contains { $0.0 == "session.create" || $0.0 == "prompt.submit" })
        XCTAssertTrue(model.canChangeRuntime(id), "Still a draft")
    }

    func testCleanupKeepsUncommittedWorkAndRestoreRecreatesFromTheBranch() async throws {
        let (model, _) = makeModel()
        let repository = try makeRepository()
        await model.connect()
        let id = try await worktreeDraft(model, folder: repository.path, base: "main")
        model.draft = "Add a note"
        await model.send()
        let worktree = try XCTUnwrap(model.sessions.first { $0.id == id }?.worktree)
        let checkout = URL(fileURLWithPath: worktree.path)

        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), "Running and not archived")
        finish(model, id)
        model.archiveSession(id)
        model.removeWorktrees = .never
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), "Never")

        model.removeWorktrees = .archived
        try Data("draft".utf8).write(to: checkout.appendingPathComponent("note.txt"))
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path + "/note.txt"), "Uncommitted work keeps it")
        XCTAssertEqual(model.sessions.first { $0.id == id }?.worktree?.kept, "It has uncommitted changes.")
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), "Retried only after an hour")

        try git(["add", "."], at: checkout); try git(["commit", "-q", "-m", "Note"], at: checkout)
        await model.cleanUpWorktrees(now: Date().addingTimeInterval(3_700))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertEqual(model.sessions.first { $0.id == id }?.worktree?.removed, true)
        XCTAssertNil(model.sessions.first { $0.id == id }?.worktree?.kept)
        XCTAssertFalse(try git(["branch", "--list", worktree.branch], at: repository).isEmpty, "An unmerged branch stays")

        model.restoreSession(id)
        await model.recreateWorktrees(restoring: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path + "/note.txt"), model.errorMessage ?? "Recreated from its branch")
        XCTAssertNil(model.sessions.first { $0.id == id }?.worktree?.removed)
    }

    func testAMergedBranchIsDeletedAndSendingThenShowsWhyItCannotReturn() async throws {
        let (model, transport) = makeModel()
        let repository = try makeRepository()
        await model.connect()
        let id = try await worktreeDraft(model, folder: repository.path, base: "main")
        model.draft = "Look around"
        await model.send()
        finish(model, id)
        let worktree = try XCTUnwrap(model.sessions.first { $0.id == id }?.worktree)
        model.archiveSession(id)
        await model.cleanUpWorktrees()
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertTrue(try git(["branch", "--list", worktree.branch], at: repository).isEmpty, "Merged, so deleted")

        model.selectSession(id)
        model.draft = "One more thing"
        let submits = transport.calls.filter { $0.0 == "prompt.submit" }.count
        await model.send()
        XCTAssertEqual(model.sessions.first { $0.id == id }?.draft, "One more thing")
        XCTAssertTrue(model.errorMessage?.contains(worktree.branch) == true, model.errorMessage ?? "")
        XCTAssertEqual(transport.calls.filter { $0.0 == "prompt.submit" }.count, submits, "Nothing sent")
    }

    func testAChildsWorktreeFollowsItsParentAndOnlyTheAppsOwnAreRemoved() async throws {
        let (model, _) = makeModel()
        let repository = try makeRepository()
        await model.connect()
        await model.newSession(showPanel: false, runtime: .codex, workspace: repository.path)
        let parentID = try XCTUnwrap(model.currentID)
        model.draft = "Delegate"
        await model.send()
        finish(model, parentID)
        let made = try Delegation.makeWorktree(from: repository.path, name: "child-task", root: model.worktreesDirectory)
        var child = CompanionSession(id: "child", title: "Child", workspacePath: made.folder)
        child.parentSessionID = parentID
        child.worktree = made.worktree
        model.sessions.append(child)

        model.update("child") { $0.state = .working }
        model.update(parentID) { $0.isArchived = true }
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.worktree.path), "A busy child keeps the tree")
        model.update("child") { $0.state = .finished }
        await model.cleanUpWorktrees()
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.worktree.path), "Removed with its archived parent")

        // A worktree the user made outside the app's folder is never touched.
        let own = repository.deletingLastPathComponent().appendingPathComponent("own-\(UUID().uuidString)")
        folders.append(own)
        try git(["worktree", "add", "-q", "-b", "mine", own.path], at: repository)
        let foreign = SessionWorktree(repository: repository.path, project: repository.path, branch: "mine", path: own.path)
        XCTAssertNotNil(foreign.remove(under: model.worktreesDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
    }

    /// An archived worktree session with nothing uncommitted.
    private func archivedWorktreeSession(_ model: AppModel, repository: URL) async throws -> (String, SessionWorktree) {
        await model.connect()
        let id = try await worktreeDraft(model, folder: repository.path, base: "main")
        model.draft = "Work"
        await model.send()
        finish(model, id)
        model.archiveSession(id)
        return (id, try XCTUnwrap(model.sessions.first { $0.id == id }?.worktree))
    }

    func testADetachedOrReplacedCheckoutIsKept() async throws {
        let (model, _) = makeModel()
        let repository = try makeRepository()
        let (id, worktree) = try await archivedWorktreeSession(model, repository: repository)
        let checkout = URL(fileURLWithPath: worktree.path)
        try git(["checkout", "-q", "--detach"], at: checkout)
        try Data("x".utf8).write(to: checkout.appendingPathComponent("detached.txt"))
        try git(["add", "."], at: checkout); try git(["commit", "-q", "-m", "Detached"], at: checkout)
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path + "/detached.txt"), "A detached commit would lose its only reference")
        XCTAssertTrue(model.sessions.first { $0.id == id }?.worktree?.kept?.contains(worktree.branch) == true)

        // Someone else's worktree now at that path: not the app's checkout.
        try git(["worktree", "remove", "--force", worktree.path], at: repository)
        try git(["worktree", "add", "-q", "-b", "theirs", worktree.path], at: repository)
        model.worktreeAttempts = [:]
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertFalse(try git(["branch", "--list", "theirs"], at: repository).isEmpty)
    }

    func testAnotherSessionInTheWorktreeKeepsIt() async throws {
        let (model, _) = makeModel()
        let repository = try makeRepository()
        let (id, worktree) = try await archivedWorktreeSession(model, repository: repository)
        // As `create_sessions` makes one: a top-level session in the caller's folder.
        model.sessions.append(CompanionSession(id: "sibling", title: "Sibling", state: .working, workspacePath: worktree.path))
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertEqual(model.sessions.first { $0.id == id }?.worktree?.kept, "Another session works in it.")
    }

    func testASymlinkIntoTheWorktreeStillKeepsIt() async throws {
        let (model, _) = makeModel()
        let repository = try makeRepository()
        let (_, worktree) = try await archivedWorktreeSession(model, repository: repository)
        let alias = repository.deletingLastPathComponent().appendingPathComponent("alias-\(UUID().uuidString)")
        folders.append(alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: worktree.path)
        model.sessions.append(CompanionSession(id: "aliased", title: "Aliased", state: .working, workspacePath: alias.path))
        await model.cleanUpWorktrees()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
    }

    func testASharedChildsSendRecreatesItsParentsWorktree() async throws {
        let (model, transport) = makeModel()
        let repository = try makeRepository()
        let (parentID, worktree) = try await archivedWorktreeSession(model, repository: repository)
        let checkout = URL(fileURLWithPath: worktree.path)
        try Data("x".utf8).write(to: checkout.appendingPathComponent("kept.txt"))
        try git(["add", "."], at: checkout); try git(["commit", "-q", "-m", "Unmerged"], at: checkout)
        var child = CompanionSession(id: "shared-child", title: "Shared child", workspacePath: worktree.path)
        child.runtime = .codex
        child.parentSessionID = parentID
        model.sessions.append(child)
        await model.cleanUpWorktrees()
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        let sent = await model.submit(reply: "Carry on", target: "shared-child")
        XCTAssertTrue(sent, model.backgroundSendErrors["shared-child"] ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path + "/kept.txt"), "The parent's worktree came back first")
        XCTAssertEqual(transport.calls.last { $0.0 == "session.create" }?.1["cwd"] as? String, worktree.path)
    }

    func testRestoreWaitsForARemovalInProgress() async throws {
        let (model, _) = makeModel()
        let repository = try makeRepository()
        let (id, worktree) = try await archivedWorktreeSession(model, repository: repository)
        let checkout = URL(fileURLWithPath: worktree.path)
        try Data("x".utf8).write(to: checkout.appendingPathComponent("kept.txt"))
        try git(["add", "."], at: checkout); try git(["commit", "-q", "-m", "Unmerged"], at: checkout)
        let cleanup = Task { await model.cleanUpWorktrees() }
        await Task.yield()
        model.restoreSession(id)
        await model.recreateWorktrees(restoring: id)
        await cleanup.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path + "/kept.txt"), model.errorMessage ?? "Recreated after the removal")
    }

    func testNoisyGitStderrDoesNotStallTheCommand() throws {
        let repository = try makeRepository()
        let hooks = repository.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("post-checkout")
        try Data("#!/bin/sh\nhead -c 262144 /dev/zero | tr '\\0' x >&2\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try WorkspaceChanges.run(["-c", "core.hooksPath=" + hooks.path, "checkout", "-q", "feature"], at: repository.path,
                                     timeout: 10, reportingErrors: true)
    }

    func testOlderRegistriesDecodeWithoutWorktreeFields() throws {
        let old = try JSONDecoder().decode(CompanionSession.self, from: Data(#"{"id":"old","runtime":"codex"}"#.utf8))
        XCTAssertNil(old.worktree)
        XCTAssertNil(old.worktreeBase)
        var session = CompanionSession(id: "new")
        session.worktreeBase = "main"
        session.worktree = SessionWorktree(repository: "/r", project: "/r", branch: "notch/x", path: "/w/x", removed: true)
        let decoded = try JSONDecoder().decode(CompanionSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.worktree, session.worktree)
        XCTAssertEqual(decoded.worktreeBase, "main")
    }
}
