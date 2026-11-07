import XCTest
@testable import NotchCompanion

final class ChangeSummaryTests: XCTestCase {
    private let patch = """
    diff --git a/Sources/My File.swift b/Sources/My File.swift
    index 1111111..2222222 100644
    --- a/Sources/My File.swift
    +++ b/Sources/My File.swift
    @@ -1,2 +1,3 @@
    --- old text
    +++ new text
    +one more
     unchanged
    """

    func testCountsHunkLinesAndPreservesSpacedPath() throws {
        let file = try XCTUnwrap(UnifiedDiff.files(patch).first)
        XCTAssertEqual(file.path, "Sources/My File.swift")
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertEqual(file.url(in: "/tmp/project")?.path, "/tmp/project/Sources/My File.swift")
        XCTAssertEqual(ChangedFile(path: "/tmp/outside.swift").url(in: "/project")?.path, "/tmp/outside.swift")
        XCTAssertNil(ChangedFile(path: "bad\0path").url(in: "/project"))
    }

    func testRenameDeletionBinaryAndQuotedNames() {
        let files = UnifiedDiff.files("""
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        diff --git "a/a\\t\\303\\251.txt" "b/a\\t\\303\\251.txt"
        deleted file mode 100644
        --- "a/a\\t\\303\\251.txt"
        +++ /dev/null
        @@ -1 +0,0 @@
        -removed
        diff --git a/picture.png b/picture.png
        Binary files a/picture.png and b/picture.png differ
        """)
        XCTAssertEqual(files.map(\.kind), ["Renamed", "Deleted", "Modified"])
        XCTAssertEqual(files.map(\.path), ["new.txt", "a\té.txt", "picture.png"])
        XCTAssertEqual(files.first?.oldPath, "old.txt")
        XCTAssertEqual(files[1].deletions, 1)
        XCTAssertNil(files[2].additions)
        XCTAssertNil(files[2].deletions)
        let binary = UnifiedDiff.files("diff --git a/folder b/image.png b/folder b/image.png\nBinary files differ\n")
        XCTAssertEqual(binary.first?.path, "folder b/image.png")
    }

    func testLargePreviewKeepsExactCounts() throws {
        let diff = "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -0,0 +1,4000 @@\n" + String(repeating: "+abcdefghijklmnopqrstuvwxyz\n", count: 4000)
        let file = try XCTUnwrap(UnifiedDiff.files(diff).first)
        XCTAssertEqual(file.additions, 4000)
        XCTAssertTrue(file.previewTruncated)
        XCTAssertLessThanOrEqual(file.patch.utf8.count, UnifiedDiff.previewBytes)
    }

    func testCodexRoutesOnlyCurrentOwnedParentDiffs() throws {
        var state = CodexProtocolState()
        _ = try state.register(["id": "parent", "turns": []])
        _ = state.notifications("turn/started", ["threadId": "parent", "turn": ["id": "turn"]])
        let payload: [String: Any] = ["threadId": "parent", "turnId": "turn", "diff": patch]
        XCTAssertEqual(state.notifications("turn/diff/updated", payload).first?.name, "turn.changes")
        XCTAssertTrue(state.notifications("turn/diff/updated", ["threadId": "other", "turnId": "turn", "diff": patch]).isEmpty)
        XCTAssertTrue(state.notifications("turn/diff/updated", ["threadId": "parent", "turnId": "old", "diff": patch]).isEmpty)
        state.parents["child"] = "parent"
        XCTAssertTrue(state.notifications("turn/diff/updated", ["threadId": "child", "turnId": "child-turn", "diff": patch]).isEmpty)
        _ = state.notifications("turn/completed", ["threadId": "parent", "turn": ["id": "turn", "status": "completed"]])
        XCTAssertTrue(state.notifications("turn/diff/updated", payload).isEmpty)
    }

    func testSnapshotPersistsAndStaysAfterItsOwnAnswer() throws {
        var session = CompanionSession()
        session.messages = [ChatMessage(id: "user", role: "user", text: "Edit", turnID: "turn"),
                            ChatMessage(id: "answer", role: "assistant", text: "Done", turnID: "turn"),
                            ChatMessage(id: "next", role: "user", text: "Next")]
        session.changes = [TurnChanges(id: "turn", workspace: "/project", source: .agent, files: UnifiedDiff.files(patch))]
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(CompanionSession.self, from: data)
        XCTAssertEqual(restored.changes, session.changes)
        XCTAssertEqual(ConversationTimeline.build(session: restored).map(\.id), ["message:user", "message:answer", "changes:turn", "message:next"])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "changes")
        XCTAssertTrue(try JSONDecoder().decode(CompanionSession.self, from: JSONSerialization.data(withJSONObject: legacy)).changes.isEmpty)
    }

    @MainActor func testOnlyTheLatestFinishedTurnsCardsStartOpen() {
        let edit = [ChangedFile(path: "a.txt", additions: 1, deletions: 0)]
        func turn(_ id: String, answer: Bool = true) -> [ChatMessage] {
            [ChatMessage(id: id, role: "user", text: id, turnID: id)] + (answer ? [ChatMessage(role: "assistant", text: "Done", turnID: id)] : [])
        }
        var session = CompanionSession()
        session.messages = turn("u1") + turn("u2")
        session.changes = ["u1", "u2"].map { TurnChanges(id: $0, workspace: "/p", source: .agent, files: edit) }
        func open() -> Set<String> { ChangeSummaryView.latestFinished(in: ConversationTimeline.build(session: session), session: session) }
        XCTAssertEqual(open(), ["u2"], "Older turns start collapsed")
        // A running turn, its steer and its live aggregate are not finished: the turn before stays open.
        session.messages += turn("u3", answer: false) + [ChatMessage(id: "steer", role: "user", text: "Also", turnID: "u3")]
        session.changes.append(TurnChanges(id: "u3", workspace: "/p", source: .agent, files: edit))
        session.state = .working
        XCTAssertEqual(open(), ["u2"])
        session.state = .finished
        XCTAssertEqual(open(), ["u3"])
        session.stagedSubmission = StagedSubmission(message: turn("u4")[0], draft: nil, attachments: [])
        XCTAssertEqual(open(), ["u3"], "A message still sending does not close it")
        session.stagedSubmission = nil
        session.messages += turn("u4")
        XCTAssertEqual(open(), [], "The latest finished turn changed nothing")
    }

    @MainActor func testAnOpenCardListsSixFilesThenTheRest() {
        XCTAssertEqual(ChangeSummaryView.shownCounts([3, 0, 5, 2], showsAll: false), [3, 0, 3, nil])
        XCTAssertEqual(ChangeSummaryView.shownCounts([3, 0, 5, 2], showsAll: true), [3, 0, 5, 2])
        XCTAssertEqual(ChangeSummaryView.shownCounts([6, 0], showsAll: false), [6, 0], "At the limit nothing hides")
        XCTAssertEqual(ChangeSummaryView.shownCounts([6, 0, 1], showsAll: false), [6, nil, nil])
    }

    func testDelegatedGroupsListEachFileOnceUnderItsChildAndRoundTrip() throws {
        let files = { (paths: [String]) in paths.map { ChangedFile(path: $0, additions: 1, deletions: 0) } }
        let now = Date()
        // Turn 1 began with the user's draft dirty; turn 2 began after its own notes; turn 3 never settled.
        let first = TurnChanges(id: "t1", workspace: "/project", files: files(["draft.txt", "notes.txt"]), capturedAt: now,
                                preexisting: ["draft.txt": files(["draft.txt"])[0].fingerprint])
        var second = TurnChanges(id: "t2", workspace: "/project", files: files(["draft.txt", "notes.txt", "more.txt"]), capturedAt: now,
                                 preexisting: ["draft.txt": files(["draft.txt"])[0].fingerprint, "notes.txt": files(["notes.txt"])[0].fingerprint])
        second.files[1].additions = 2
        let pending = TurnChanges(id: "t3", workspace: "/project", files: files(["late.txt"]))
        let shared = try XCTUnwrap(TurnChanges.group([first, second, pending], id: "child", label: "Notes · Claude Code"))
        XCTAssertEqual(shared.files.map(\.path), ["more.txt", "notes.txt"], "The user's draft is not the child's")
        XCTAssertEqual(shared.files.last?.additions, 2, "The latest turn wins")
        XCTAssertNil(TurnChanges.group([pending], id: "child", label: "x"), "Nothing settled yet")
        let agent = TurnChanges(id: "a", workspace: "/project", source: .agent, files: files(["draft.txt"]), capturedAt: now, preexisting: first.preexisting)
        XCTAssertEqual(TurnChanges.group([agent], id: "c", label: "x")?.files.map(\.path), ["draft.txt"], "An agent's diff is already its own")

        let worktree = TurnChanges(id: "other", workspace: "/worktrees/project-1", files: files(["notes.txt", "app.txt"]), capturedAt: now, label: "Risky · Codex · worktree")
        var parent = TurnChanges(id: "turn", workspace: "/project", files: files(["draft.txt", "notes.txt"]), capturedAt: now)
        parent.delegated = [shared, worktree]
        XCTAssertEqual(parent.ownFiles.map(\.path), ["draft.txt"], "A shared child's file is not counted twice")
        XCTAssertEqual(parent.allFiles.map(\.path), ["draft.txt", "more.txt", "notes.txt", "notes.txt", "app.txt"], "A worktree's same path is another file")
        XCTAssertTrue(TurnChanges(id: "turn", workspace: "/project", delegated: [worktree]).isVisible, "A delegating turn shows its children alone")
        XCTAssertEqual(try JSONDecoder().decode(TurnChanges.self, from: JSONEncoder().encode(parent)), parent)
        let legacy = #"{"id":"turn","workspace":"/project","source":"workspace","files":[]}"#
        XCTAssertNil(try JSONDecoder().decode(TurnChanges.self, from: Data(legacy.utf8)).delegated)
    }

    func testAChildBaselineRecordsWhatWasAlreadyDirty() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("old\n", to: "draft.txt", in: root)
        try commit(root)
        try write("user\n", to: "draft.txt", in: root)
        try write("untracked\n", to: "scratch.txt", in: root)
        let baseline = WorkspaceChanges.baseline(workspace: root.path, turnID: "child", recordingDirtyFiles: true)
        XCTAssertEqual(baseline.preexisting?.keys.sorted(), ["draft.txt", "scratch.txt"])
        XCTAssertNil(WorkspaceChanges.baseline(workspace: root.path, turnID: "parent").preexisting)
        try write("child\n", to: "child.txt", in: root)
        try write("untracked\nand the child\n", to: "scratch.txt", in: root)
        let group = TurnChanges.group([WorkspaceChanges.capture(baseline)], id: "child", label: "Child · Pi")
        XCTAssertEqual(group?.files.map(\.path), ["child.txt", "scratch.txt"], "A dirty file the child edits again is its own")
    }

    func testGitSnapshotIncludesStagedUnstagedUntrackedAndCommittedWorkWithoutMutation() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("old\n", to: "edit.txt", in: root)
        try write("remove\n", to: "delete.txt", in: root)
        try commit(root)
        let baseline = WorkspaceChanges.baseline(workspace: root.path, turnID: "turn")
        try write("new\nadded\n", to: "edit.txt", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        try write("staged\n", to: "staged.txt", in: root)
        _ = try git(["add", "staged.txt"], root)
        try write("space\n", to: "new file.txt", in: root)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.dat"))
        try write("ignored.txt\n", to: ".gitignore", in: root)
        try write("ignored\n", to: "ignored.txt", in: root)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside-link").path, withDestinationPath: "/etc/passwd")
        let before = try git(["status", "--porcelain=v1", "-z"], root)
        let snapshot = WorkspaceChanges.capture(baseline)
        XCTAssertNil(snapshot.notice)
        XCTAssertEqual(snapshot.files.map(\.path), [".gitignore", "binary.dat", "delete.txt", "edit.txt", "new file.txt", "staged.txt"])
        XCTAssertEqual(snapshot.files.first(where: { $0.path == "edit.txt" })?.additions, 2)
        XCTAssertEqual(snapshot.files.first(where: { $0.path == "delete.txt" })?.kind, "Deleted")
        XCTAssertNil(snapshot.files.first(where: { $0.path == "binary.dat" })?.additions)
        XCTAssertEqual(try git(["status", "--porcelain=v1", "-z"], root), before)
        try FileManager.default.removeItem(at: root.appendingPathComponent("outside-link"))
        try commit(root)
        let committed = WorkspaceChanges.capture(baseline)
        XCTAssertEqual(committed.files.map(\.path), snapshot.files.map(\.path), "Committing during a turn does not erase the summary")
        XCTAssertEqual(committed.additions, snapshot.additions)
        XCTAssertEqual(committed.deletions, snapshot.deletions)
    }

    func testGitUnbornRepositoryAndFailureLimits() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = WorkspaceChanges.baseline(workspace: root.path, turnID: "first")
        try write("one\ntwo\n", to: "new.txt", in: root)
        _ = try git(["add", "new.txt"], root)
        try write("one\ntwo\nthree\n", to: "new.txt", in: root)
        let snapshot = WorkspaceChanges.capture(baseline)
        XCTAssertEqual(snapshot.files.first?.additions, 3)
        XCTAssertEqual(snapshot.files.first?.kind, "Added")
        try commit(root)
        try Data(repeating: 97, count: UnifiedDiff.maximumBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        let limited = WorkspaceChanges.capture(WorkspaceChanges.baseline(workspace: root.path, turnID: "second"))
        XCTAssertTrue(limited.files.isEmpty)
        XCTAssertTrue(limited.notice?.contains("too large") == true)
        let missing = TurnChanges(id: "missing", workspace: root.appendingPathComponent("missing").path)
        XCTAssertFalse(WorkspaceChanges.capture(missing).isVisible)
    }

    @MainActor func testNativeUpdatesReplaceRatherThanAccumulateAndRestore() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("registry.json")
        let model = AppModel(storageURL: storage, playsSounds: false, client: ChangesTransport())
        defer { model.shutdown() }
        model.sessions[0].runtimeID = "live"
        model.sessions[0].workspacePath = root.path
        model.sessions[0].messages = [ChatMessage(id: "u", role: "user", text: "Edit", turnID: "u")]
        model.receive("turn.changes", payload: ["session_id": "live", "diff": patch])
        try await waitUntil { model.current?.changes.first?.files.count == 1 }
        XCTAssertEqual(model.current?.changes.first?.source, .agent)
        model.receive("turn.changes", payload: ["session_id": "live", "diff": ""])
        try await waitUntil { model.current?.changes.first?.files.isEmpty == true }
        XCTAssertEqual(model.current?.changes.count, 1)
        model.receive("turn.changes", payload: ["session_id": "live", "diff": patch])
        try await waitUntil { model.current?.changes.first?.files.count == 1 }
        model.shutdown()
        let restored = AppModel(storageURL: storage, playsSounds: false, client: ChangesTransport())
        defer { restored.shutdown() }
        XCTAssertEqual(restored.current?.changes.first?.additions, 2)
    }

    @MainActor func testFallbackWaitsForChildrenAndKeepsTheSubmittedBaseline() async throws {
        let root = try repository()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        try write("before\n", to: "file.txt", in: root)
        try commit(root)
        let model = AppModel(storageURL: storage, playsSounds: false, client: ChangesTransport())
        defer { model.shutdown() }
        model.sessions[0].workspacePath = root.path
        await model.connect()
        model.draft = "Edit"
        await model.send()
        XCTAssertEqual(model.current?.changes.count, 1)
        XCTAssertNotNil(model.current?.changes.first?.baseRevision)
        model.receive("message.start", payload: ["session_id": "live"])
        model.receive("subagent.start", payload: ["session_id": "live", "subagent_id": "child", "name": "Helper"])
        model.receive("message.complete", payload: ["session_id": "live", "text": "Working", "status": "complete"])
        XCTAssertNil(model.current?.changes.first?.capturedAt)
        try write("after\nchild\n", to: "file.txt", in: root)
        try commit(root)
        model.receive("subagent.complete", payload: ["session_id": "live", "subagent_id": "child", "status": "complete"])
        model.draft = "Next turn"
        await model.send()
        XCTAssertEqual(model.current?.changes.count, 2)
        try await waitUntil { model.current?.changes.first?.capturedAt != nil }
        XCTAssertEqual(model.current?.changes.first?.files.map(\.path), ["file.txt"])
        XCTAssertEqual(model.current?.changes.first?.additions, 2)
        XCTAssertEqual(model.current?.changes.first?.source, .workspace)
    }

    @MainActor func testEveryHarnessCapturesItsOwnWorkspaceThroughTheRouterAndRestores() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.json")
        var adapters: [RuntimeRoute: ChangesTransport] = [:]
        var roots: [URL] = []
        let router = RuntimeRouter { route in
            let adapter = ChangesTransport()
            adapters[route] = adapter
            return adapter
        }
        let model = AppModel(storageURL: storage, playsSounds: false, client: router)
        defer {
            model.shutdown()
            for root in roots { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.removeItem(at: storage.deletingLastPathComponent())
        }
        model.sessions = []
        let routes = RuntimeKind.allCases.map { RuntimeRoute(runtime: $0) }
            + [RuntimeRoute(runtime: .hermes, legacy: true)]
        for route in routes {
            let root = try repository()
            roots.append(root)
            let project = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try write("before\n", to: "nested/file.txt", in: root)
            try commit(root)
            let session = CompanionSession(runtime: route.runtime, profileID: route.profileID,
                isLegacyPrivate: route.legacy,
                trustedProjectPath: project.standardizedFileURL.resolvingSymlinksInPath().path, workspacePath: project.path)
            model.sessions.append(session)
            model.currentID = session.id
            model.draft = "Edit"
            await model.send()
            XCTAssertNil(model.errorMessage, route.title)
            let baseline = try XCTUnwrap(model.current?.changes.first, route.title)
            XCTAssertEqual(URL(fileURLWithPath: baseline.workspace).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
            let adapter = try XCTUnwrap(adapters[route])
            // All routes deliberately reuse the same native ID.
            adapter.onEvent?("message.complete", ["session_id": "external", "status": "complete"])
            XCTAssertNil(model.current?.changes.first?.capturedAt, route.title)
            adapter.onEvent?("message.start", ["session_id": "live"])
            adapter.onEvent?("message.interim", ["session_id": "live", "text": "Still working"])
            XCTAssertNil(model.current?.changes.first?.capturedAt, route.title)
            try write("after\nextra\n", to: "nested/file.txt", in: root)
            adapter.onEvent?("message.complete", ["session_id": "live", "text": "Done", "status": "complete"])
            try await waitUntil { model.current?.changes.first?.capturedAt != nil }
            let summary = try XCTUnwrap(model.current?.changes.first, route.title)
            XCTAssertNil(summary.notice, route.title)
            XCTAssertEqual(summary.source, .workspace, route.title)
            XCTAssertEqual(summary.files.map(\.path), ["nested/file.txt"], route.title)
            XCTAssertEqual(summary.additions, 2, route.title)
            XCTAssertEqual(summary.deletions, 1, route.title)
            XCTAssertEqual(summary.files.first?.url(in: summary.workspace)?.resolvingSymlinksInPath(), project.appendingPathComponent("file.txt").resolvingSymlinksInPath())
        }
        XCTAssertEqual(Set(model.sessions.compactMap(\.runtimeID)).count, routes.count)
        let snapshots = model.sessions.map(\.changes)
        model.shutdown()
        let restored = AppModel(storageURL: storage, playsSounds: false, client: ChangesTransport())
        defer { restored.shutdown() }
        XCTAssertEqual(restored.sessions.map(\.changes), snapshots)
    }

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "--quiet"], root)
        return root
    }
    private func write(_ text: String, to path: String, in root: URL) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func git(_ arguments: [String], _ root: URL) throws -> String { try WorkspaceChanges.run(arguments, at: root.path) }
    private func commit(_ root: URL) throws {
        _ = try git(["add", "."], root)
        _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "Fixture"], root)
    }
    @MainActor private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ready())
    }
}

@MainActor private final class ChangesTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws {}
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.create" { return ["session_id": "live", "stored_session_id": "native"] }
        return [:]
    }
}
