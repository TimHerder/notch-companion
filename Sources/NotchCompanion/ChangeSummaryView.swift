import SwiftUI

struct ChangeSummaryView: View {
    var summary: TurnChanges
    var editorName: String
    var open: (URL) -> Void
    var chooseEditor: (URL) -> Void
    var onInspect: () -> Void
    /// The user's choice for this turn, else open for the latest finished turn.
    var showsFiles: Bool
    var toggle: () -> Void
    /// An open card lists this many files, then "N more files". The notch passes
    /// fewer, so an open card leaves its header and the answer above it in view.
    var fileLimit = 6
    @State var showsAllFiles = false
    @State var selectedPath: String?

    private var project: URL { URL(fileURLWithPath: summary.workspace, isDirectory: true) }
    /// Instrument: monochrome diff, additions read white, removals grey.
    static var added: Color { PanelTheme.pick(Color(red: 0.57, green: 0.85, blue: 0.64), CompanionStyle.green, CompanionStyle.text) }
    static var removed: Color { PanelTheme.pick(Color(red: 1, green: 0.64, blue: 0.62), CompanionStyle.error, Color(white: 0.5)) }
    private var theme: PanelTheme { PanelTheme.current }

    /// A turn whose own snapshot never ran can still show its children's groups.
    private var hasOwnSnapshot: Bool { !summary.files.isEmpty || summary.notice != nil }
    private var title: String { summary.source == .agent || !hasOwnSnapshot ? "Changes" : "Workspace changes" }
    private var groups: [TurnChanges] { (summary.delegated ?? []).filter(\.isVisible) }

    var body: some View {
        let all = summary.allFiles
        let added = all.compactMap(\.additions).reduce(0, +), removed = all.compactMap(\.deletions).reduce(0, +)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if !showsFiles { onInspect() }
                toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showsFiles ? 90 : 0))
                        .font(PanelTheme.pick(.system(size: 10, weight: .semibold), .system(size: 10, weight: .bold), .system(size: 8, weight: .bold)))
                        .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                        .frame(width: PanelTheme.pick(16, 10, nil))
                    if theme == .tahoe {
                        Image(systemName: "doc.text.fill").symbolRenderingMode(.hierarchical).foregroundStyle(CompanionStyle.secondary)
                    }
                    if theme == .instrument {
                        Text(title).microLabel(10, weight: .semibold)
                    } else {
                        Text(title).fontWeight(PanelTheme.pick(.medium, .semibold, .medium))
                    }
                    if !all.isEmpty {
                        Text("\(all.count) \(all.count == 1 ? "file" : "files")").foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                        Spacer(minLength: 4)
                        counts(added, removed)
                        if theme == .instrument { DiffStat(added: added, removed: removed) }
                    } else {
                        Spacer()
                        Image(systemName: "exclamationmark.circle").foregroundStyle(CompanionStyle.secondary)
                    }
                }.frame(minHeight: theme == .refined ? 22 : nil).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pressableCursor()
            .help(showsFiles ? "Hide the changed files" : "Show the changed files")
            .accessibilityLabel("\(showsFiles ? "Collapse" : "Expand") \(title.lowercased()), \(all.count) files, \(added) lines added, \(removed) lines removed")

            if showsFiles {
                let shown = Self.shownCounts([summary.ownFiles.count] + groups.map(\.files.count), limit: fileLimit, showsAll: showsAllFiles)
                let hidden = all.count - shown.compactMap { $0 }.reduce(0, +)
                if let notice = summary.notice { Text(notice).foregroundStyle(CompanionStyle.secondary).fixedSize(horizontal: false, vertical: true) }
                fileRows(Array(summary.ownFiles.prefix(shown[0] ?? 0)), workspace: summary.workspace, key: "")
                ForEach(zip(groups, shown.dropFirst()).compactMap { group, count in count.map { (group, $0) } }, id: \.0.id) { group, count in
                    HStack(spacing: PanelTheme.pick(8, 7, 7)) {
                        let label = Label(group.label ?? "Delegated", systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.tail)
                        switch theme {
                        case .refined: label.foregroundStyle(CompanionStyle.secondary).fontWeight(.medium)
                        case .tahoe: label.foregroundStyle(CompanionStyle.secondary).fontWeight(.semibold)
                        case .instrument: label.foregroundStyle(CompanionStyle.secondary).fontWeight(.semibold)
                        }
                        Spacer(minLength: 4)
                        if !group.files.isEmpty { counts(group.additions, group.deletions) }
                    }
                    .padding(.top, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Delegated to \(group.label ?? "a child"), \(group.files.count) files")
                    if let notice = group.notice { Text(notice).foregroundStyle(CompanionStyle.secondary).fixedSize(horizontal: false, vertical: true) }
                    fileRows(Array(group.files.prefix(count)), workspace: group.workspace, key: group.id + "\u{0}")
                }
                if hidden > 0 {
                    Button {
                        showsAllFiles = true
                        onInspect()
                    } label: {
                        // Laid out like a file row: the chevron in the icons' column, the label under the paths.
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: PanelTheme.pick(10, 10, 8), weight: .bold))
                                .frame(width: PanelTheme.pick(16, 15, 14))
                            Text("\(hidden) more \(hidden == 1 ? "file" : "files")")
                        }
                        .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                        .frame(minHeight: 20).padding(.horizontal, PanelTheme.pick(0, 7, 7)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pressableCursor()
                    .help("Show all \(all.count) files")
                    .accessibilityLabel("Show \(hidden) more \(hidden == 1 ? "file" : "files")")
                }
                if hasOwnSnapshot {
                    if summary.source == .workspace {
                        Text("Compared with \(summary.baseRevision.map { String($0.prefix(8)) } ?? "an empty repository") at turn start. Includes pre-existing and concurrent edits.")
                            .font(footnoteFont).foregroundStyle(footnoteColor)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Agent-reported changes for this turn.")
                            .font(footnoteFont).foregroundStyle(footnoteColor)
                    }
                }
                if !groups.isEmpty {
                    Text("Files under a delegated child are its own edits.")
                        .font(footnoteFont).foregroundStyle(footnoteColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                editorButton("Open project in \(editorName)", url: project)
            }
        }
        .font(PanelTheme.pick(CompanionStyle.callout, .system(size: 12.5), .system(size: 11.5))).foregroundStyle(CompanionStyle.text)
        .padding(.horizontal, PanelTheme.pick(10, 12, 11)).padding(.vertical, PanelTheme.pick(6, 10, 10))
        .background(PanelTheme.pick(CompanionStyle.well, CompanionStyle.fill, Color.black.opacity(0.3)), in: cardShape)
        .overlay { if theme == .instrument { cardShape.strokeBorder(CompanionStyle.rule, lineWidth: 0.5) } }
        .onChange(of: rowKeys) { _, keys in
            if let selectedPath, !keys.contains(selectedPath) { self.selectedPath = nil }
        }
    }

    /// Per list (own files, then each child group's): how many files show, or nil
    /// for a group hidden past the limit. Over the limit only the first files show.
    static func shownCounts(_ counts: [Int], limit: Int, showsAll: Bool) -> [Int?] {
        var left = showsAll || counts.reduce(0, +) <= limit ? Int.max : limit
        return counts.map { count in
            guard left > 0 else { return nil }
            let shown = min(count, left)
            left -= shown
            return shown
        }
    }

    /// The change cards of the latest finished turn, which start open; older ones
    /// start collapsed. A running turn (with its steers) and a message still
    /// sending are not finished, so the turn before them stays the latest. Turns
    /// the companion sent for an agent (a delegation result, a relayed message)
    /// continue the user's turn before them, whose cards (its children's) stay open.
    static func latestFinished(in timeline: [ConversationTimelineItem], session: CompanionSession) -> Set<String> {
        var end = timeline.endIndex
        var live: String?
        for index in timeline.indices.reversed() {
            guard case .message(let message) = timeline[index], message.role == "user" else { continue }
            let turn = message.turnID ?? message.id
            // Still sending, even once it shows and the session reads working.
            if message.id == session.stagedSubmission?.message.id { end = index; live = live ?? turn; continue }
            guard session.isBusy, live == nil || live == turn else { break }
            live = turn
            end = index
        }
        var result = Set<String>()
        for item in timeline[..<end].reversed() {
            switch item {
            case .changes(let changes): result.insert(changes.id)
            // Only a user row that starts its own turn ends this one; a steer belongs to the turn it joined.
            case .message(let message) where message.role == "user" && message.kind == nil && (message.turnID ?? message.id) == message.id:
                return result
            default: continue
            }
        }
        return result
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.row, 12, CompanionStyle.cardRadius), style: .continuous)
    }
    private var footnoteFont: Font { PanelTheme.pick(CompanionStyle.caption, .system(size: 11), .system(size: 10)) }
    private var footnoteColor: Color { PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary) }

    /// A row's selection key: its path, prefixed by its child group's ID.
    private var rowKeys: [String] {
        summary.ownFiles.map(\.path) + groups.flatMap { group in group.files.map { group.id + "\u{0}" + $0.path } }
    }

    private func fileRows(_ files: [ChangedFile], workspace: String, key prefix: String) -> some View {
        ForEach(files) { file in
            let key = prefix + file.path
            Button {
                selectedPath = selectedPath == key ? nil : key
                onInspect()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    switch theme {
                    case .refined:
                        Image(systemName: file.kind == "Deleted" ? "doc.badge.minus" : "doc.text")
                            .foregroundStyle(CompanionStyle.tertiary).frame(width: 16)
                    case .tahoe:
                        Image(systemName: file.kind == "Deleted" ? "doc.badge.minus" : "doc.text")
                            .foregroundStyle(CompanionStyle.secondary)
                    case .instrument:
                        Text(String(file.kind.prefix(1))).font(CompanionStyle.mono(10, .semibold))
                            .foregroundStyle(file.kind == "Deleted" ? CompanionStyle.faint : CompanionStyle.secondary)
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(CompanionStyle.ruleStrong, lineWidth: 0.5))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: PanelTheme.pick(2, 2, 3)) {
                        let kind = Text(file.kind + (file.additions == nil ? " · Binary" : ""))
                        switch theme {
                        case .refined:
                            Text(file.path).lineLimit(2).truncationMode(.middle)
                            kind.font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                        case .tahoe:
                            Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                            kind.font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                        case .instrument:
                            Text(file.path).font(CompanionStyle.mono(11)).lineLimit(2).truncationMode(.middle)
                            kind.font(.system(size: 10.5)).foregroundStyle(CompanionStyle.faint)
                        }
                    }
                    Spacer(minLength: 4)
                    if let added = file.additions, let removed = file.deletions { counts(added, removed) }
                }
                .padding(PanelTheme.pick(6, 7, 7)).contentShape(Rectangle())
                .background(key == selectedPath ? PanelTheme.pick(CompanionStyle.raised, Color.white.opacity(0.08), Color.white.opacity(0.06)) : .clear,
                            in: RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.small, 8, CompanionStyle.radius),
                                                 style: theme == .instrument ? .circular : .continuous))
                .overlay(alignment: .leading) { if theme == .instrument && key == selectedPath { Rectangle().fill(CompanionStyle.text).frame(width: 2).padding(.vertical, 5) } }
                .padding(.horizontal, theme == .refined ? -6 : 0)
            }.buttonStyle(.plain).pressableCursor().help(file.path)
            .accessibilityLabel("\(file.path), \(file.kind), \(file.additions.map { "\($0) lines added, \(file.deletions ?? 0) lines removed" } ?? "binary file"). Show diff")
            if key == selectedPath {
                filePreview(file, workspace: workspace)
            }
        }
    }

    private func filePreview(_ selected: ChangedFile, workspace: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView([.horizontal, .vertical]) {
                ChangePatchText(patch: selected.patch).equatable()
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(9)
            }
            .frame(height: 190)
            .background(PanelTheme.pick(Color.black.opacity(0.3), Color.black.opacity(0.3), CompanionStyle.inset),
                        in: RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.small, 8, CompanionStyle.radius),
                                             style: theme == .instrument ? .circular : .continuous))
            .overlay { if theme == .instrument { RoundedRectangle(cornerRadius: CompanionStyle.radius).strokeBorder(CompanionStyle.rule, lineWidth: 0.5) } }
            .accessibilityLabel("Diff for \(selected.path)")
            if selected.previewTruncated {
                if theme == .refined {
                    Text("Preview shortened; line counts include the full diff.").font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                } else {
                    Text("Preview shortened; line counts include the full diff.").foregroundStyle(CompanionStyle.secondary)
                }
            }
            if selected.kind != "Deleted", let url = selected.url(in: workspace) {
                editorButton("Open file in \(editorName)", url: url)
            }
        }
    }

    @ViewBuilder private func counts(_ added: Int, _ removed: Int) -> some View {
        let row = HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(Self.added)
            Text("−\(removed)").foregroundStyle(Self.removed)
        }
        switch theme {
        case .refined: row.monospacedDigit().fixedSize()
        case .tahoe: row.font(.system(size: 12, weight: .semibold)).monospacedDigit().fixedSize()
        case .instrument: row.font(CompanionStyle.mono(10.5, .medium)).monospacedDigit().fixedSize()
        }
    }

    private func editorButton(_ title: String, url: URL) -> some View {
        Button { open(url) } label: {
            let label = Label(title, systemImage: "arrow.up.right")
            if theme == .instrument { label.foregroundStyle(CompanionStyle.secondary) } else { label }
        }
            .buttonStyle(NotchTextButtonStyle())
            .contextMenu { Button("Choose editor…") { chooseEditor(url) } }
            .help("Open in your code editor. Right-click to choose another editor.")
    }

}

/// Pointer updates must not recolor an unchanged, potentially large patch.
private struct ChangePatchText: View, Equatable {
    var patch: String
    var body: some View { Text(coloredPatch) }

    private var coloredPatch: AttributedString {
        var result = AttributedString()
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            var part = AttributedString(String(line) + "\n")
            part.foregroundColor = line.hasPrefix("+") ? ChangeSummaryView.added : line.hasPrefix("-") ? ChangeSummaryView.removed
                : PanelTheme.pick(CompanionStyle.secondary, CompanionStyle.secondary, CompanionStyle.faint)
            if PanelTheme.current == .instrument && line.hasPrefix("+") && !line.hasPrefix("+++") { part.backgroundColor = Color.white.opacity(0.07) }
            result.append(part)
        }
        return result
    }
}

/// Instrument: five blocks, as a diffstat: lit for additions, dim for removals.
private struct DiffStat: View {
    var added: Int
    var removed: Int

    var body: some View {
        let total = max(1, added + removed)
        let lit = added == 0 ? 0 : max(1, min(5, Int((Double(added) / Double(total) * 5).rounded())))
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                Rectangle().fill(index < lit ? CompanionStyle.text : Color(white: 0.32)).frame(width: 5, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
