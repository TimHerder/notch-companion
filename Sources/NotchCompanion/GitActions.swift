import Foundation
import Combine

/// One `git status` entry the commit form offers: staged, unstaged or untracked.
struct GitStatusFile: Equatable, Identifiable, Sendable {
    var path: String
    /// A rename's source, committed with it.
    var oldPath: String?
    var kind: String
    var id: String { path }
}

/// A session folder's repository, as Commit, Push and Open pull request need it.
struct GitRepository: Equatable, Sendable {
    var root: String
    /// Nil when detached: there is nothing to push.
    var branch: String?
    var files: [GitStatusFile]
    /// The branch's upstream remote, else `origin` when it exists.
    var remote: String?
    var remoteURL: String?
    /// `<remote>/<branch>` exists, so a pull request can be opened from it.
    var pushed = false
    /// The remote's default branch, from its `HEAD`.
    var defaultBranch: String?
    /// HEAD's subject: a pull request's title.
    var subject: String?
    /// HEAD is ahead of `<remote>/<branch>`, or that does not exist yet.
    var unpushed = false
    var github: String? { GitActions.githubRepository(remoteURL) }
}

/// Commit, push and pull requests for a session's folder. Every command is an
/// argument array (no shell) run in the folder's repository; callers run these off the main actor.
enum GitActions {
    enum PullRequestResult: Equatable { case created(URL), compare(URL) }

    /// The user's own environment, so hooks, signing and credential helpers work; Git and `gh` never prompt.
    nonisolated static var environment: [String: String] {
        var result = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        result["PATH"] = [result["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin", "/usr/local/bin",
                          home.appendingPathComponent(".local/bin").path].joined(separator: ":")
        result["GIT_TERMINAL_PROMPT"] = "0"
        result["GH_PROMPT_DISABLED"] = "1"
        return result
    }

    /// Nil outside Git.
    nonisolated static func read(_ folder: String) -> GitRepository? {
        func git(_ arguments: [String], at path: String) -> String? {
            (try? WorkspaceChanges.run(arguments, at: path))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard FileManager.default.fileExists(atPath: folder), let root = git(["rev-parse", "--show-toplevel"], at: folder), !root.isEmpty,
              let status = try? WorkspaceChanges.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root) else { return nil }
        let branch = git(["symbolic-ref", "--short", "-q", "HEAD"], at: root).flatMap { $0.isEmpty ? nil : $0 }
        let remotes = (git(["remote"], at: root) ?? "").split(separator: "\n").map(String.init)
        let upstream = branch.flatMap { git(["config", "--get", "branch.\($0).remote"], at: root) }
        let remote = upstream.flatMap { remotes.contains($0) ? $0 : nil } ?? (remotes.contains("origin") ? "origin" : nil)
        var repository = GitRepository(root: root, branch: branch, files: parseStatus(status), remote: remote)
        repository.subject = git(["log", "-1", "--format=%s"], at: root)
        if let remote {
            repository.remoteURL = git(["remote", "get-url", remote], at: root)
            repository.defaultBranch = git(["symbolic-ref", "--short", "-q", "refs/remotes/\(remote)/HEAD"], at: root)
                .flatMap { $0.hasPrefix(remote + "/") ? String($0.dropFirst(remote.count + 1)) : nil }
            if let branch {
                let tracking = "refs/remotes/\(remote)/\(branch)"
                repository.pushed = git(["rev-parse", "--verify", "--quiet", tracking], at: root) != nil
                repository.unpushed = !repository.pushed || git(["rev-list", "--count", tracking + "..HEAD"], at: root) != "0"
            }
        }
        return repository
    }

    /// `git status --porcelain=v1 -z`: `XY path`, a rename followed by its source.
    nonisolated static func parseStatus(_ output: String) -> [GitStatusFile] {
        var fields = output.components(separatedBy: "\0").makeIterator()
        var files: [GitStatusFile] = []
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            var file = GitStatusFile(path: String(field.dropFirst(3)), kind: "Modified")
            if code.contains("R") || code.contains("C") { file.oldPath = fields.next() }
            if code == "??" { file.kind = "Untracked" }
            else if code.contains("U") || code == "AA" || code == "DD" { file.kind = "Conflicted" }
            else if code.contains("D") { file.kind = "Deleted" }
            else if code.contains("R") { file.kind = "Renamed" }
            else if code.contains("A") || code.contains("C") { file.kind = "Added" }
            files.append(file)
        }
        return files
    }

    /// Stages exactly these paths and commits only them, with the user's identity and hooks.
    /// Returns the new commit's short hash.
    nonisolated static func commit(_ files: [GitStatusFile], message: String, at root: String) throws -> String {
        guard !files.isEmpty else { throw AppError("Nothing to commit.") }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("Write a commit message first.") }
        // Literal pathspecs: a file named `*` or `:x` is that file, never a pattern. Only files on disk
        // are added: a deletion (staged or not) and a rename's source are committed by their pathspec alone.
        let onDisk = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: root).appendingPathComponent(path).path)) != nil }
        // A rename's source recreated since would be committed by its pathspec, though it was left out.
        let included = Set(files.map(\.path))
        if let source = files.compactMap(\.oldPath).first(where: { onDisk($0) && !included.contains($0) }) {
            throw AppError("\(source) was renamed and then recreated. Include it too, or commit in your editor.")
        }
        let present = files.map(\.path).filter(onDisk)
        if !present.isEmpty { _ = try user(["--literal-pathspecs", "add", "-A", "--"] + present, at: root) }
        let paths = files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        // A pathspec commits only these paths, leaving anything else already staged as it is.
        _ = try user(["--literal-pathspecs", "commit", "-m", message, "--"] + paths, at: root, timeout: 300)
        return (try? WorkspaceChanges.run(["rev-parse", "--short", "HEAD"], at: root))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// `git push -u <remote> <branch>`, never forced.
    nonisolated static func push(remote: String, branch: String, at root: String) throws {
        _ = try user(["push", "-u", "--", remote, branch], at: root, timeout: 300)
    }

    /// A default branch, `main`/`master`, or a branch other than the session's own `notch/…` worktree branch.
    nonisolated static func needsPushConfirmation(branch: String, defaultBranch: String?, worktreeBranch: String?) -> Bool {
        branch == defaultBranch || ["main", "master"].contains(branch) || !(branch.hasPrefix("notch/") && branch == worktreeBranch)
    }

    /// `gh pr create` with the user's existing `gh` login, else GitHub's compare page for the browser.
    nonisolated static func pullRequest(repository: String, base: String, head: String, title: String, body: String,
                                        at root: String, gh: URL? = ghExecutable()) throws -> PullRequestResult {
        if let gh, (try? user(["auth", "status", "--hostname", "github.com"], at: root, timeout: 30, executable: gh.path)) != nil {
            do {
                let output = try user(["pr", "create", "--repo", repository, "--base", base, "--head", head, "--title", title, "--body", body],
                                      at: root, timeout: 120, executable: gh.path)
                if let url = pullRequestURL(in: output) { return .created(url) }
                throw AppError("GitHub CLI did not report the pull request’s link.")
            } catch {
                // One already open for this branch is the one to show.
                if let url = pullRequestURL(in: error.localizedDescription) { return .created(url) }
                throw error
            }
        }
        return .compare(compareURL(repository: repository, base: base, head: head, title: title, body: body))
    }

    nonisolated static func compareURL(repository: String, base: String, head: String, title: String, body: String) -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        let path = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
        var components = URLComponents(string: "https://github.com/\(repository)/compare/\(path(base))...\(path(head))")!
        components.queryItems = [URLQueryItem(name: "expand", value: "1"), URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components.url!
    }

    nonisolated static func pullRequestURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https://[^\s"']+/pull/[0-9]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    /// `owner/repo` for a github.com remote (HTTPS, SSH or scp-style); nil for other hosts.
    nonisolated static func githubRepository(_ url: String?) -> String? {
        guard var rest = url?.trimmingCharacters(in: .whitespacesAndNewlines), !rest.isEmpty else { return nil }
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let user = rest.firstIndex(of: "@"), rest[..<user].allSatisfy({ $0 != "/" && $0 != ":" }) { rest = String(rest[rest.index(after: user)...]) }
        guard rest.lowercased().hasPrefix("github.com"), let separator = rest.dropFirst(10).first, separator == "/" || separator == ":" else { return nil }
        var path = String(rest.dropFirst(11))
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(valid.contains) }) else { return nil }
        return path
    }

    /// The installed `gh`, from the user's PATH or the usual install folders.
    nonisolated static func ghExecutable() -> URL? {
        environment["PATH"]?.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("gh") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A message to edit: the session title as the subject, then the changed files.
    nonisolated static func draftMessage(subject: String, files: [GitStatusFile]) -> String {
        let line = subject.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = line.count > 72 ? String(line.prefix(71)) + "…" : line
        return ([title.isEmpty ? "Update \(files.count == 1 ? files[0].path : "\(files.count) files")" : title, ""]
                + files.map { "- \($0.kind) \($0.path)" }).joined(separator: "\n")
    }

    /// A pull request body to edit: the branch's commits since its base.
    nonisolated static func draftBody(base: String, remote: String?, at root: String) -> String {
        let range = remote.map { "refs/remotes/\($0)/\(base)" }.flatMap { ref in
            (try? WorkspaceChanges.run(["rev-parse", "--verify", "--quiet", ref], at: root)) != nil ? ref + "..HEAD" : nil
        } ?? "-1"
        let commits = (try? WorkspaceChanges.run(["log", "--format=- %s", "--max-count=50", range], at: root)) ?? ""
        return commits.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func user(_ arguments: [String], at root: String, timeout: TimeInterval = 60,
                                         executable: String = "/usr/bin/git") throws -> String {
        try WorkspaceChanges.run(arguments, at: root, timeout: timeout, reportingErrors: true, executable: executable, environment: environment)
    }
}

/// One session's Git actions: the commit form, push confirmation and pull request form.
@MainActor final class GitActionsController: ObservableObject {
    enum Form: Equatable { case commit, confirmPush, pullRequest }
    /// What the open push confirmation names; a changed branch or remote asks again.
    private var confirming: (branch: String, remote: String)?
    let sessionID: String
    weak var model: AppModel?
    @Published var repository: GitRepository?
    @Published var form: Form?
    @Published var excluded: Set<String> = []
    @Published var message = ""
    @Published var title = ""
    @Published var body = ""
    @Published var base = ""
    /// What is running, such as “Committing…”.
    @Published var working: String?
    @Published var error: String?
    @Published var notice: String?
    /// Tests inject `gh` (or its absence) instead of the installed one.
    var gh: () -> URL? = { GitActions.ghExecutable() }

    init(sessionID: String, model: AppModel) {
        self.sessionID = sessionID
        self.model = model
    }

    private var session: CompanionSession? { model?.sessions.first { $0.id == sessionID } }
    var folder: String { session?.workspacePath ?? model?.workspacePath ?? "" }
    var included: [GitStatusFile] { repository?.files.filter { !excluded.contains($0.path) } ?? [] }
    /// The harness drafts a subject only where it can without a turn in the conversation.
    var harnessDrafts: Bool { session?.runtime == .claude && session?.runtimeID != nil }

    /// `recreating` brings back a worktree cleanup removed, as a send does.
    func refresh(recreating: Bool = false) async {
        if recreating {
            do { try await model?.recreateWorktree(sessionID) } catch { self.error = error.localizedDescription; return }
        }
        let folder = folder
        repository = await Task.detached(priority: .userInitiated) { GitActions.read(folder) }.value
        excluded.formIntersection(repository?.files.map(\.path) ?? [])
    }

    func toggle(_ form: Form) {
        error = nil; notice = nil
        guard self.form != form else { self.form = nil; return }
        Task {
            await refresh(recreating: true)
            guard error == nil, let repository else { return }
            if form == .pullRequest {
                title = repository.subject ?? ""
                base = session?.worktree?.base ?? repository.defaultBranch ?? "main"
                let (root, base, remote) = (repository.root, base, repository.remote)
                body = await Task.detached { GitActions.draftBody(base: base, remote: remote, at: root) }.value
            }
            self.form = form
        }
    }

    func writeMessage() async {
        guard let repository, let session, let model else { return }
        let files = included
        var draft = GitActions.draftMessage(subject: session.title, files: files)
        if harnessDrafts, let runtimeID = session.runtimeID {
            working = "Writing message…"
            let description = "A one-line Git commit subject for these changes in \"\(session.title)\":\n"
                + files.prefix(40).map { "\($0.kind) \($0.path)" }.joined(separator: "\n")
            if let subject = try? await model.client.request("session.draft_title", params: ["session_id": runtimeID, "description": description])["title"] as? String,
               !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = GitActions.draftMessage(subject: subject, files: files)
            }
            working = nil
        }
        // The user may have typed meanwhile; theirs stays.
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.repository?.root == repository.root { message = draft }
    }

    func commit(thenPush: Bool) async {
        guard working == nil, let repository, model?.gitActionsIdle(sessionID) == true else { return }
        let files = included
        guard !files.isEmpty else { error = "Nothing to commit."; return }
        let (message, root) = (message, repository.root)
        working = "Committing…"; error = nil; notice = nil
        do {
            let hash = try await Task.detached(priority: .userInitiated) { try GitActions.commit(files, message: message, at: root) }.value
            self.message = ""
            form = nil
            notice = "Committed \(hash)."
        } catch { self.error = error.localizedDescription }
        working = nil
        await refresh()
        if thenPush, self.error == nil { await push() }
    }

    /// The first call asks first when the branch needs it; `confirmed` pushes what that confirmation named.
    func push(confirmed: Bool = false) async {
        guard working == nil, model?.gitActionsIdle(sessionID) == true else { return }
        // Marked working before any wait, so a send cannot start meanwhile.
        working = "Pushing…"; error = nil; notice = nil
        defer { working = nil }
        await refresh(recreating: true)
        guard error == nil, let repository, model?.gitActionsIdle(sessionID) == true else { return }
        guard let branch = repository.branch else { error = "This checkout is not on a branch, so there is nothing to push."; return }
        let remote = repository.remote ?? "origin"
        let approved = confirmed && confirming.map { $0.branch == branch && $0.remote == remote } == true
        if !approved, GitActions.needsPushConfirmation(branch: branch, defaultBranch: repository.defaultBranch, worktreeBranch: session?.worktree?.branch) {
            confirming = (branch, remote)
            form = .confirmPush
            return
        }
        confirming = nil
        let root = repository.root
        form = nil
        do {
            try await Task.detached(priority: .userInitiated) { try GitActions.push(remote: remote, branch: branch, at: root) }.value
            notice = "Pushed \(branch) to \(remote)."
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func createPullRequest() async {
        guard working == nil, let repository, let github = repository.github, let branch = repository.branch, model?.gitActionsIdle(sessionID) == true else { return }
        let (title, body, base, root, gh) = (title.trimmingCharacters(in: .whitespacesAndNewlines), body, base.trimmingCharacters(in: .whitespaces), repository.root, gh())
        guard !title.isEmpty, !base.isEmpty else { error = "Give the pull request a title and a base branch."; return }
        working = "Opening pull request…"; error = nil; notice = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try GitActions.pullRequest(repository: github, base: base, head: branch, title: title, body: body, at: root, gh: gh)
            }.value
            switch result {
            case .created(let url):
                model?.update(sessionID) { $0.pullRequest = url.absoluteString }
                _ = model?.save()
                form = nil
            case .compare(let url):
                form = nil
                notice = "GitHub CLI isn’t installed or signed in, so GitHub’s compare page opened in your browser."
                model?.openExternally(url)
            }
        } catch { self.error = error.localizedDescription }
        working = nil
    }
}

extension AppModel {
    /// Sessions sharing a checkout (one folder inside the other) share its Git actions' safety.
    func sharesCheckout(_ first: String, _ second: String) -> Bool {
        func folder(_ id: String) -> String? {
            sessions.first { $0.id == id }.map { URL(fileURLWithPath: $0.workspacePath ?? workspacePath).standardizedFileURL.path }
        }
        guard let a = folder(first), let b = folder(second) else { return false }
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// Git actions run only while this session's tree and every session in the same checkout are idle.
    func gitActionsIdle(_ id: String) -> Bool {
        treeIsIdle(id) && sessions.allSatisfy { $0.id == id || !sharesCheckout(id, $0.id) || treeIsIdle($0.id) }
    }

    /// A commit or push running in this session's checkout, which a send must wait for.
    func gitActionRunning(near id: String) -> Bool {
        gitActionControllers.values.contains { $0.working != nil && sharesCheckout(id, $0.sessionID) }
    }

    func gitActions(for id: String) -> GitActionsController {
        if let existing = gitActionControllers[id] { return existing }
        let controller = GitActionsController(sessionID: id, model: self)
        gitActionControllers[id] = controller
        return controller
    }
}
