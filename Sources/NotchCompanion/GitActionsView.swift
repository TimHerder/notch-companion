import SwiftUI

/// The latest finished turn's change card ends with Commit, Push and Open pull
/// request for the session's folder, as quiet text buttons with inline forms.
struct GitActionsView: View {
    @ObservedObject var controller: GitActionsController
    /// Why the actions wait (the session, a child or an unconfirmed send is busy), else nil.
    var blocked: String?
    /// The session's pull request, once opened.
    var pullRequest: String?
    /// A worktree session shows its actions before the first read (its removed worktree comes back on use).
    var isWorktree = false
    /// The pull request is being watched; the last poll's error, shown only in the tooltip.
    var watching = false
    var watchError: String?
    var harness: String
    var openURL: (URL) -> Void

    private var theme: PanelTheme { PanelTheme.current }
    private var enabled: Bool { blocked == nil && controller.working == nil }

    var body: some View {
        let repository = controller.repository
        Group {
            if repository != nil || isWorktree {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: PanelTheme.pick(14, 14, 12)) {
                        action("Commit…", symbol: "checkmark.circle", help: "Choose files and commit them with your Git identity and hooks") {
                            controller.toggle(.commit)
                        }
                        action("Push", symbol: "arrow.up.circle", help: "Push \(repository?.branch ?? "this branch") to \(repository?.remote ?? "origin"). Never forced.") {
                            Task { await controller.push() }
                        }
                        if let repository, repository.github != nil, repository.pushed, repository.branch != nil, pullRequest == nil {
                            action("Open pull request", symbol: "arrow.triangle.pull", help: "Create a pull request on GitHub for \(repository.branch ?? "")") {
                                controller.toggle(.pullRequest)
                            }
                        }
                        Spacer(minLength: 0)
                        if let pullRequest, let url = URL(string: pullRequest) {
                            watchControl(url)
                            Button { openURL(url) } label: { Label("Pull request #\(url.lastPathComponent)", systemImage: "arrow.up.right").lineLimit(1) }
                                .buttonStyle(NotchTextButtonStyle()).foregroundStyle(CompanionStyle.secondary)
                                .help("Open \(pullRequest) in your browser")
                        }
                    }
                    if let blocked { caption(blocked) }
                    else if let working = controller.working {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); caption(working) }
                    }
                    if let error = controller.error {
                        ScrollView { Text(error).font(CompanionStyle.mono(10.5)).foregroundStyle(CompanionStyle.error).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true) }
                            .frame(maxHeight: 90).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Git error: \(error)")
                    } else if let notice = controller.notice { caption(notice) }
                    switch controller.form {
                    case .commit: commitForm
                    case .confirmPush: pushConfirmation
                    case .pullRequest: pullRequestForm
                    case nil: EmptyView()
                    }
                }
                .padding(.top, 2)
            }
        }
        .task { await controller.refresh() }
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            let files = controller.repository?.files ?? []
            if files.isEmpty {
                caption("Nothing to commit.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            Toggle(isOn: Binding(get: { !controller.excluded.contains(file.path) },
                                                 set: { if $0 { controller.excluded.remove(file.path) } else { controller.excluded.insert(file.path) } })) {
                                HStack(spacing: 6) {
                                    Text(file.path).font(CompanionStyle.mono(11)).lineLimit(1).truncationMode(.middle)
                                    Text(file.kind).font(.system(size: 10.5)).foregroundStyle(CompanionStyle.secondary)
                                }
                            }
                            .toggleStyle(NotchCheckboxStyle())
                            .accessibilityLabel("Include \(file.path), \(file.kind)")
                        }
                    }
                }
                .frame(maxHeight: 112).fixedSize(horizontal: false, vertical: true)
                TextField("Commit message", text: $controller.message, axis: .vertical)
                    .gitField(lines: 1...5)
                    .accessibilityLabel("Commit message")
                HStack(spacing: 8) {
                    if controller.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Write message") { Task { await controller.writeMessage() } }
                            .buttonStyle(NotchPillButtonStyle(small: true)).disabled(!enabled || controller.included.isEmpty)
                            .help(controller.harnessDrafts
                                  ? "\(harness) drafts a subject without adding a turn to this conversation; the changed files follow"
                                  : "Fills in a draft from the session title and changed files. \(harness) can’t write one without adding a turn to this conversation.")
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { controller.form = nil; controller.error = nil }.buttonStyle(NotchPillButtonStyle(small: true))
                    let ready = enabled && !controller.included.isEmpty && !controller.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button("Commit & push") { Task { await controller.commit(thenPush: true) } }
                        .buttonStyle(NotchPillButtonStyle(small: true)).disabled(!ready)
                    Button("Commit \(controller.included.count) \(controller.included.count == 1 ? "file" : "files")") { Task { await controller.commit(thenPush: false) } }
                        .buttonStyle(NotchPillButtonStyle(prominent: true, small: true)).disabled(!ready)
                }
            }
        }
    }

    private var pushConfirmation: some View {
        let repository = controller.repository
        let branch = repository?.branch ?? ""
        let reason = branch == repository?.defaultBranch || ["main", "master"].contains(branch)
            ? "It is the repository’s default branch." : "It is not this session’s own worktree branch."
        return VStack(alignment: .leading, spacing: 8) {
            Text("Push \(branch) to \(repository?.remote ?? "origin")? \(reason)").fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { controller.form = nil }.buttonStyle(NotchPillButtonStyle(small: true))
                Button("Push") { Task { await controller.push(confirmed: true) } }
                    .buttonStyle(NotchPillButtonStyle(prominent: true, small: true)).disabled(!enabled)
            }
        }
    }

    private var pullRequestForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                caption("\(controller.repository?.branch ?? "") into")
                TextField("Base branch", text: $controller.base).gitField(lines: 1...1).frame(maxWidth: 160)
                    .accessibilityLabel("Base branch")
            }
            TextField("Title", text: $controller.title).gitField(lines: 1...1).accessibilityLabel("Pull request title")
            TextField("Description", text: $controller.body, axis: .vertical).gitField(lines: 2...6).accessibilityLabel("Pull request description")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { controller.form = nil; controller.error = nil }.buttonStyle(NotchPillButtonStyle(small: true))
                Button("Create pull request") { Task { await controller.createPullRequest() } }
                    .buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
                    .disabled(!enabled || controller.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Uses your GitHub CLI login; without one, GitHub’s compare page opens in your browser")
            }
        }
    }

    /// Watch beside a github.com link; while watching, its eye stops the watch.
    @ViewBuilder private func watchControl(_ url: URL) -> some View {
        if watching {
            Button { controller.model?.stopWatchingPullRequest(controller.sessionID) } label: { Image(systemName: "eye.fill") }
                .buttonStyle(NotchTextButtonStyle()).foregroundStyle(watchError == nil ? CompanionStyle.secondary : CompanionStyle.amber)
                .help("Watching pull request #\(url.lastPathComponent) for failed checks, reviews, comments, conflicts and merging. Click to stop."
                      + (watchError.map { "\nThe last check failed: \($0) Trying again later." } ?? ""))
                .accessibilityLabel("Stop watching pull request #\(url.lastPathComponent)")
        } else if url.host?.lowercased() == "github.com" {
            Button {
                Task {
                    controller.error = nil
                    controller.working = "Checking GitHub CLI…"
                    let problem = await controller.model?.watchPullRequest(controller.sessionID)
                    controller.working = nil
                    controller.error = problem
                }
            } label: { Label("Watch", systemImage: "eye").lineLimit(1) }
                .buttonStyle(NotchTextButtonStyle()).foregroundStyle(CompanionStyle.secondary).disabled(controller.working != nil)
                .help("Message this session when checks fail or recover, reviews or comments arrive, conflicts appear, or the pull request merges or closes. Uses your signed-in GitHub CLI; polls every 2 minutes while the app is open.")
        }
    }

    private func action(_ title: String, symbol: String, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            let label = Label(title, systemImage: symbol).lineLimit(1)
            if theme == .instrument { label.foregroundStyle(CompanionStyle.secondary) } else { label }
        }
        .buttonStyle(NotchTextButtonStyle()).disabled(!enabled).help(blocked ?? help)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11), .system(size: 10)))
            .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A recessed field in each design, like a written answer.
    func gitField(lines: ClosedRange<Int>) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.small, 8, CompanionStyle.radius), style: .continuous)
        return lineLimit(lines).textFieldStyle(.plain).focusEffectDisabled()
            .font(PanelTheme.current == .instrument ? CompanionStyle.mono(11) : .system(size: 12.5))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(PanelTheme.pick(Color.black.opacity(0.25), Color.black.opacity(0.28), CompanionStyle.inset), in: shape)
            .overlay(shape.strokeBorder(PanelTheme.pick(CompanionStyle.hairline, Color.white.opacity(0.12), CompanionStyle.ruleStrong),
                                        lineWidth: PanelTheme.pick(0.75, 0.5, 0.75)))
            .textCursor()
    }
}
