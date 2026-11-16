import Foundation

/// A Git worktree the app created under its own Worktrees folder, for a
/// session started in New worktree or an isolated delegated child.
struct SessionWorktree: Codable, Equatable, Sendable {
    /// The repository's main checkout, where Git commands run.
    var repository: String
    /// The folder the user chose; the session stays grouped under it.
    var project: String
    /// `notch/<name>`, kept after removal so the worktree can come back.
    var branch: String
    /// The worktree's top folder.
    var path: String
    /// Cleanup removed it; the next restore or send recreates it from `branch`.
    var removed: Bool? = nil
    /// Why the last removal kept it, such as uncommitted changes.
    var kept: String? = nil

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// `git worktree remove` without `--force`, so uncommitted work keeps it, and
    /// only for a folder under `root`; then `git branch -d`, which keeps an unmerged
    /// branch. Returns nil once removed, else why it was kept.
    nonisolated func remove(under root: URL) -> String? {
        let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard folder.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            return "It is outside Notch Companion’s Worktrees folder."
        }
        // Only the checkout the app made, still on its branch: a detached HEAD's commits or a
        // worktree someone else put at this path would be lost or taken.
        guard let list = try? WorkspaceChanges.run(["worktree", "list", "--porcelain"], at: repository) else {
            return "Git could not list the repository’s worktrees."
        }
        let entry = list.components(separatedBy: "\n\n").first { block in
            block.split(separator: "\n").first.map { URL(fileURLWithPath: String($0.dropFirst(9))).standardizedFileURL.resolvingSymlinksInPath().path } == folder
        }
        guard let entry else {
            return FileManager.default.fileExists(atPath: path) ? "It is no longer one of this repository’s worktrees." : nil
        }
        guard entry.split(separator: "\n").contains("branch refs/heads/" + branch) else {
            return "It is no longer on \(branch), so removing it could lose commits."
        }
        do { _ = try WorkspaceChanges.run(["worktree", "remove", path], at: repository, timeout: 60, reportingErrors: true) }
        catch {
            let message = error.localizedDescription
            return message.contains("modified or untracked") ? "It has uncommitted changes." : message
        }
        _ = try? WorkspaceChanges.run(["branch", "-d", branch], at: repository)
        return nil
    }

    /// `git worktree add <path> <branch>` for a removed (or deleted) worktree.
    nonisolated func restore() throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A folder deleted by hand leaves Git's record of it, which would keep the branch checked out;
        // removing a missing worktree drops only that record.
        if !FileManager.default.fileExists(atPath: path) { _ = try? WorkspaceChanges.run(["worktree", "remove", path], at: repository) }
        do { _ = try WorkspaceChanges.run(["worktree", "add", path, branch], at: repository, timeout: 120, reportingErrors: true) }
        catch { throw AppError("Git could not recreate this session’s worktree from \(branch): \(error.localizedDescription)") }
    }
}

/// When the app removes the worktrees it created (Settings → Remove worktrees).
enum WorktreeCleanup: String, CaseIterable, Identifiable {
    case archived, inactive, never
    static let key = "sessions.removeWorktrees"
    static let inactiveInterval: TimeInterval = 7 * 86_400
    var id: Self { self }
    var label: String {
        switch self {
        case .archived: return "When the session is archived"
        case .inactive: return "After 7 days inactive"
        case .never: return "Never"
        }
    }
    var shortLabel: String {
        switch self {
        case .archived: return "Archived"
        case .inactive: return "7 days"
        case .never: return "Never"
        }
    }
}

/// A draft folder's repository: what New worktree can branch from.
struct GitBranches: Equatable, Sendable {
    /// The checked-out branch, or `HEAD` when detached.
    var current: String
    /// Local, then remote-tracking branches, the current one first.
    var names: [String]

    /// Nil outside Git or before the first commit, when there is nothing to branch from.
    nonisolated static func read(_ folder: String) -> GitBranches? {
        guard let refs = try? WorkspaceChanges.run(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], at: folder) else { return nil }
        var names: [String] = refs.split(separator: "\n").compactMap { ref in
            if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst(11)) }
            guard ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") else { return nil }
            return String(ref.dropFirst(13))
        }
        guard !names.isEmpty else { return nil }
        let branch = (try? WorkspaceChanges.run(["symbolic-ref", "--short", "-q", "HEAD"], at: folder))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = branch?.isEmpty == false ? branch! : "HEAD"
        names.removeAll { $0 == current }
        return GitBranches(current: current, names: [current] + names)
    }

    func matching(_ search: String) -> [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension AppModel {
    /// Whether the current draft can offer Local or New worktree: a Git folder, not OpenClaw's agent workspace.
    func worktreeBranches(for session: CompanionSession) -> GitBranches? {
        guard canChangeRuntime(session.id), session.runtime != .openclaw else { return nil }
        return gitBranches[session.workspacePath ?? workspacePath]
    }

    func loadBranches(for folder: String) async {
        let branches = await Task.detached(priority: .utility) { GitBranches.read(folder) }.value
        gitBranches[folder] = branches
    }

    /// Nil is Local; a branch makes the first send create a worktree from it.
    func setWorktreeBase(_ base: String?, for id: String) {
        guard canChangeRuntime(id), sessions.first(where: { $0.id == id })?.runtime != .openclaw else { return }
        update(id) { $0.worktreeBase = base }
        scheduleSave()
    }

    /// Before a send: a New worktree draft gets its worktree, and a removed one
    /// comes back from its branch. A failure throws before anything is sent.
    func prepareWorktree(_ id: String) async throws {
        await worktreeCleanupTask?.value
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard let base = session.worktreeBase, session.worktree == nil, session.storedID == nil else {
            try await recreateWorktree(id)
            return
        }
        let folder = session.workspacePath ?? workspacePath
        let name = Delegation.worktreeName(title: session.title, taskID: session.id.lowercased())
        let root = worktreesDirectory
        let (worktree, record) = try await Task.detached { try Delegation.makeWorktree(from: folder, name: name, root: root, base: base) }.value
        update(id) {
            $0.workspacePath = worktree
            $0.worktree = record
            $0.worktreeBase = nil
            // A worktree checks out the same project, so the folder's trust carries over.
            if $0.trustedProjectPath != nil { $0.trustedProjectPath = URL(fileURLWithPath: worktree).standardizedFileURL.resolvingSymlinksInPath().path }
        }
        save()
    }

    /// Recreates a worktree cleanup removed (or one deleted by hand) from its kept branch.
    /// A restore and a send at once share one attempt.
    func recreateWorktree(_ id: String) async throws {
        // A removal in progress finishes first, so it cannot take the recreated checkout.
        await worktreeCleanupTask?.value
        // A shared child works in an ancestor's worktree, which comes back for it.
        var owner = sessions.first { $0.id == id }
        while let current = owner, current.worktree == nil, let parent = current.parentSessionID {
            owner = sessions.first { $0.id == parent }
        }
        guard let id = owner?.id else { return }
        if let running = worktreeRestores[id] { return try await running.value }
        guard let worktree = sessions.first(where: { $0.id == id })?.worktree,
              !FileManager.default.fileExists(atPath: worktree.path) else { return }
        let task = Task.detached { try worktree.restore() }
        worktreeRestores[id] = task
        defer { worktreeRestores[id] = nil }
        try await task.value
        update(id) { $0.worktree?.removed = nil; $0.worktree?.kept = nil }
        save()
    }

    /// Restore brings a session's (and its children's) worktrees back with it.
    func recreateWorktrees(restoring id: String) async {
        do { for target in [id] + delegatedDescendants(of: id) { try await recreateWorktree(target) } }
        catch { errorMessage = error.localizedDescription }
    }

    /// Settings' rule for a top-level session, whose children's worktrees follow it.
    /// The whole tree must be idle: nothing running, sending, queued or being delegated.
    func worktreeCleanupDue(_ session: CompanionSession, now: Date = Date()) -> Bool {
        let tree = [session.id] + delegatedDescendants(of: session.id)
        let idle = tree.allSatisfy { id in
            guard let member = sessions.first(where: { $0.id == id }) else { return true }
            return !member.isBusy && member.pendingSubmission == nil && member.queuedSends.isEmpty && !isSubmitting(id)
                && !unfinishedParents.contains(id) && (unfinishedChildren[id]?.isEmpty ?? true)
        }
        guard idle, !delegationCreations.values.contains(where: { tree.contains($0.parentID) }) else { return false }
        switch removeWorktrees {
        case .archived: return session.isArchived || isAutoArchived(session, now: now)
        case .inactive:
            return session.id != currentID && max(session.updatedAt, session.lastSeenAt ?? .distantPast) < now.addingTimeInterval(-WorktreeCleanup.inactiveInterval)
        case .never: return false
        }
    }

    /// Removes due worktrees; a kept one is retried an hour later. Sends wait for a run in progress.
    func cleanUpWorktrees(now: Date = Date()) async {
        if let running = worktreeCleanupTask { await running.value; return }
        let task = Task { await removeDueWorktrees(now: now) }
        worktreeCleanupTask = task
        await task.value
        worktreeCleanupTask = nil
    }

    private func removeDueWorktrees(now: Date) async {
        let root = worktreesDirectory
        var changed = false
        for session in topLevelSessions where session.worktree != nil || !delegatedDescendants(of: session.id).isEmpty {
            // Children first: a child's worktree may branch from this session's.
            for id in delegatedDescendants(of: session.id).reversed() + [session.id] {
                // Re-checked after every removal, which awaits Git.
                guard let top = sessions.first(where: { $0.id == session.id }), worktreeCleanupDue(top, now: now),
                      let worktree = sessions.first(where: { $0.id == id })?.worktree, worktree.removed != true,
                      worktreeAttempts[id].map({ now.timeIntervalSince($0) >= 3_600 }) ?? true else { continue }
                worktreeAttempts[id] = now
                // Another session working in it (`create_sessions` inherits the folder) keeps it.
                let folder = URL(fileURLWithPath: worktree.path).standardizedFileURL.resolvingSymlinksInPath().path
                let tree = Set(delegatedDescendants(of: session.id) + [session.id])
                if sessions.contains(where: { !tree.contains($0.id) && $0.workspacePath.map {
                    let path = URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                    return path == folder || path.hasPrefix(folder + "/")
                } == true }) {
                    update(id) { $0.worktree?.kept = "Another session works in it." }
                    changed = true
                    continue
                }
                let kept = await Task.detached(priority: .utility) { worktree.remove(under: root) }.value
                update(id) { $0.worktree?.removed = kept == nil ? true : nil; $0.worktree?.kept = kept }
                changed = true
            }
        }
        if changed { save() }
    }

    /// Shortly after launch, then every ten minutes.
    func startWorktreeCleanup() {
        worktreeTimer = Task { [weak self] in
            var delay = Duration.seconds(30)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                delay = .seconds(600)
                guard !Task.isCancelled, let self else { return }
                await self.cleanUpWorktrees()
            }
        }
    }
}
