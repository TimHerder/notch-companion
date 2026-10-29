import SwiftUI

/// Shared discovery and management controls keep the notch and full window consistent.
struct SessionBrowserView: View {
    @ObservedObject var model: AppModel
    var compact = true
    @State private var renamingID: String?
    @State private var titleDraft = ""
    @FocusState private var renameFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.pick(12, 10, 10)) {
            // The filter chips ride inside the search capsule where it is wide
            // enough and move below it in the full-session sidebar.
            ViewThatFits(in: .horizontal) {
                searchField { filterChips }
                VStack(alignment: .leading, spacing: 8) {
                    searchField { EmptyView() }
                    filterChips
                }
            }

            switch PanelTheme.current {
            case .refined:
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visibleProjects) { project in
                            projectHeader(project)
                            ForEach(project.sessions) { session in row(session) }
                        }
                        if model.visibleSessions.isEmpty { emptyState }
                    }
                    .padding(.bottom, 12)
                }
                .scrollEdgeFade(top: 4)
                .accessibilityLabel("Sessions")
            case .tahoe:
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.visibleProjects) { project in
                            projectHeader(project)
                            // Each project is a grouped section with inset separators.
                            VStack(spacing: 0) {
                                ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                                    if index > 0 { Rectangle().fill(CompanionStyle.separator).frame(height: 0.5).padding(.horizontal, 14) }
                                    row(session).padding(4)
                                }
                            }
                            .notchGroup()
                        }
                        if model.visibleSessions.isEmpty { emptyState }
                    }.padding(.bottom, 6)
                }.softTopEdge(8, bottom: compact ? 14 : 0).accessibilityLabel("Sessions")
            case .instrument:
                ScrollView {
                    // Rows are numbered through the whole list, like channels on a device.
                    let order = model.visibleProjects.flatMap(\.sessions).map(\.id)
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleProjects) { project in
                            projectHeader(project)
                            ForEach(project.sessions) { session in
                                row(session, index: (order.firstIndex(of: session.id) ?? 0) + 1)
                            }
                        }
                        if model.visibleSessions.isEmpty { emptyState }
                    }
                }.accessibilityLabel("Sessions")
            }
        }.padding(.top, compact ? 6 : 0)
    }

    @ViewBuilder private var emptyState: some View {
        switch PanelTheme.current {
        case .refined:
            VStack(alignment: .leading, spacing: 5) {
                Text(emptyTitle).font(.system(size: 13, weight: .semibold))
                Text(emptyDetail).font(CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary)
            }.padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
        case .tahoe:
            VStack(spacing: 6) {
                Image(systemName: model.sessionSearch.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(CompanionStyle.secondary)
                    .padding(.bottom, 6).accessibilityHidden(true)
                Text(emptyTitle).font(.system(size: 15, weight: .semibold))
                Text(emptyDetail).font(.system(size: 12.5)).foregroundStyle(CompanionStyle.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.vertical, 40).padding(.horizontal, 24).frame(maxWidth: .infinity)
        case .instrument:
            VStack(alignment: .leading, spacing: 6) {
                Text("00 sessions").microLabel(9.5).foregroundStyle(CompanionStyle.faint)
                Text(emptyTitle).font(.system(size: 15, weight: .semibold))
                Text(emptyDetail).font(.system(size: 12.5)).foregroundStyle(CompanionStyle.secondary)
            }.padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func searchField<Trailing: View>(@ViewBuilder trailing: () -> Trailing) -> some View {
        searchChrome(HStack(spacing: 7) {
            switch PanelTheme.current {
            case .refined: Image(systemName: "magnifyingglass").foregroundStyle(CompanionStyle.tertiary)
            case .tahoe: Image(systemName: "magnifyingglass").foregroundStyle(CompanionStyle.secondary)
            case .instrument: Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
            }
            TextField("Search sessions", text: $model.sessionSearch)
                .textFieldStyle(.plain).focused($searchFocused).focusEffectDisabled()
                // A fixed ideal width keeps the chip layout from jumping as you type.
                .frame(minWidth: 110, idealWidth: 110, maxWidth: .infinity)
                .accessibilityLabel("Search session titles and conversations")
                .textCursor()
            if !model.sessionSearch.isEmpty {
                QuietIconButton(symbol: "xmark", label: "Clear search", size: 20) { model.sessionSearch = "" }
            }
            trailing()
        })
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    @ViewBuilder private func searchChrome(_ field: some View) -> some View {
        switch PanelTheme.current {
        case .refined:
            // 22-point chips sit 5 points inside the 32-point capsule, like the composer.
            field.font(CompanionStyle.body).padding(.leading, 12).padding(.trailing, 5).frame(height: 32)
                .background(Color.white.opacity(searchFocused ? 0.08 : 0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(searchFocused ? 0.2 : 0.08), lineWidth: 0.5))
        case .tahoe:
            // 24-point chips sit 4 points inside the 32-point capsule, like the composer.
            field.font(.system(size: 13)).padding(.leading, 12).padding(.trailing, 4).frame(height: 32)
                .background(CompanionStyle.fill, in: Capsule())
                // Focus wears the accent ring, as a native search field does.
                .overlay(Capsule().strokeBorder(searchFocused ? AnyShapeStyle(CompanionStyle.accent.opacity(0.7)) : AnyShapeStyle(Color.white.opacity(0.06)),
                                                lineWidth: searchFocused ? 1.5 : 0.5))
        case .instrument:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.cardRadius, style: .continuous)
            // 22-point keys sit 5 points inside the 32-point field, like the composer.
            field.font(.system(size: 12.5)).padding(.leading, 11).padding(.trailing, 5).frame(height: 32)
                .background(CompanionStyle.inset, in: shape)
                .overlay(shape.strokeBorder(searchFocused ? Color.white.opacity(0.34) : CompanionStyle.ruleStrong, lineWidth: 0.75))
        }
    }

    /// Toggle chips: choosing the lit one again shows all sessions.
    private var filterChips: some View {
        HStack(spacing: 4) {
            ForEach([SessionFilter.needsYou, .unread, .archived]) { filter in
                let on = model.sessionFilter == filter
                Button(filter.title) { model.sessionFilter = on ? .all : filter }
                    .buttonStyle(NotchPillButtonStyle(small: true, selected: on))
                    .help(on ? "Show all sessions" : filter == .needsYou ? "Show sessions that need you"
                          : "Show only \(filter.title.lowercased()) sessions")
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter sessions")
    }

    /// A project's folder name, with a way to start another session there.
    @ViewBuilder private func projectHeader(_ project: SessionProject) -> some View {
        let newSession = QuietIconButton(symbol: "plus", label: "New session in \(project.name)", size: 22) {
            Task { await model.newSession(showPanel: compact, workspace: project.path) }
        }
        switch PanelTheme.current {
        case .refined:
            HStack(spacing: 6) {
                projectLabel(project, Label(project.name, systemImage: "folder")
                    .labelStyle(ProjectLabelStyle())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary))
                Spacer(minLength: 6)
                newSession
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 10).padding(.bottom, 2)
        case .tahoe:
            HStack(spacing: 6) {
                projectLabel(project, Label { Text(project.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(CompanionStyle.secondary) }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(CompanionStyle.text))
                Spacer(minLength: 6)
                newSession
            }
            .padding(.leading, 4).padding(.trailing, 2).padding(.top, 8)
        case .instrument:
            HStack(spacing: 8) {
                projectLabel(project, Label(project.name, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .microLabel(10, weight: .semibold).foregroundStyle(CompanionStyle.secondary))
                    .layoutPriority(1)
                Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
                newSession
            }
            .padding(.leading, 2).padding(.top, 12).padding(.bottom, 4)
        }
    }

    private func projectLabel(_ project: SessionProject, _ label: some View) -> some View {
        label
            .lineLimit(1).truncationMode(.middle)
            .help(project.path)
            .accessibilityLabel("Project \(project.name)")
            .accessibilityAddTraits(.isHeader)
    }

    /// `index` numbers the row in Instrument.
    @ViewBuilder private func row(_ session: CompanionSession, index: Int = 0) -> some View {
        let theme = PanelTheme.current
        let selected = model.currentID == session.id
        let open = model.sessionActionsID == session.id
        Group {
            if renamingID == session.id {
                let field = RoundedRectangle(cornerRadius: PanelTheme.pick(8, 8, CompanionStyle.radius), style: .continuous)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Session name", text: $titleDraft)
                        .textFieldStyle(.plain).focused($renameFocused).focusEffectDisabled()
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10).frame(height: PanelTheme.pick(30, 28, 28))
                        .background(PanelTheme.pick(Color.black.opacity(0.25), Color.black.opacity(0.28), CompanionStyle.inset), in: field)
                        .overlay(field.strokeBorder(PanelTheme.pick(Color.white.opacity(renameFocused ? 0.24 : 0.08),
                                                                    renameFocused ? CompanionStyle.accent.opacity(0.7) : Color.white.opacity(0.12),
                                                                    renameFocused ? Color.white.opacity(0.34) : CompanionStyle.ruleStrong),
                                                    lineWidth: PanelTheme.pick(0.75, renameFocused ? 1.5 : 0.5, 0.75)))
                        .textCursor()
                        .onSubmit { finishRename(session.id) }
                        .onExitCommand { renamingID = nil }
                    HStack(spacing: 6) {
                        Button("Save") { finishRename(session.id) }
                            .buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
                            .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { renamingID = nil }
                            .buttonStyle(NotchPillButtonStyle(small: true))
                    }
                }.padding(10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Button { model.sessionActionsID = nil; model.selectSession(session.id) } label: {
                        Group {
                            if theme == .instrument {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(String(format: "%02d", index)).font(CompanionStyle.mono(10.5).monospacedDigit())
                                        .foregroundStyle(selected ? CompanionStyle.text : CompanionStyle.faint)
                                        .accessibilityHidden(true)
                                    rowSummary(session)
                                }
                            } else {
                                rowSummary(session)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PanelTheme.pick(12, 10, 10)).padding(.vertical, PanelTheme.pick(10, 8, 10))
                    }
                    .buttonStyle(NotchRowButtonStyle(selected: selected && !open, cornerRadius: PanelTheme.pick(10, 9, CompanionStyle.radius),
                                                     highlightsHover: !open))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityValue(selected ? "Selected session" : "")
                    .contextMenu { actions(session) }
                    if open {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { actions(session) }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) { manageActions(session) }
                                if session.isLegacyPrivate { ContinueLegacySessionButton(model: model, session: session) }
                            }
                        }
                        .buttonStyle(NotchPillButtonStyle(small: true))
                        .padding(.leading, PanelTheme.pick(12, 10, 36)).padding(.trailing, PanelTheme.pick(12, 10, 10)).padding(.bottom, 10)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                // While open, the row and its actions highlight as one.
                .background(Color.white.opacity(open ? (selected ? PanelTheme.pick(0.09, 0.1, 0.08) : PanelTheme.pick(0.06, 0.06, 0.05)) : 0),
                            in: RoundedRectangle(cornerRadius: PanelTheme.pick(10, 9, CompanionStyle.radius), style: .continuous))
                .overlay(alignment: .topTrailing) { actionsToggle(session, open: open) }
                .overlay(alignment: .bottom) {
                    if theme == .instrument { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 36) }
                }
            }
        }
    }

    /// Title, preview, then state, runtime and age.
    private func rowSummary(_ session: CompanionSession) -> some View {
        VStack(alignment: .leading, spacing: PanelTheme.pick(4, 4, 5)) {
            HStack(spacing: PanelTheme.pick(6, 5, 5)) {
                if session.isArchived {
                    Image(systemName: "archivebox").font(.system(size: PanelTheme.pick(11, 11, 10)))
                        .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                }
                Text(session.title).font(.system(size: 13, weight: PanelTheme.pick(.medium, .semibold, .medium))).lineLimit(compact ? 1 : 2)
            }
            .padding(.trailing, 22) // clear of the row's actions button
            if !preview(session).isEmpty {
                Text(preview(session)).font(.system(size: PanelTheme.pick(12, 12, 11.5))).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
            }
            HStack(spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        SessionStateLabel(session: session)
                        runtimeLabel(session)
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        SessionStateLabel(session: session)
                        runtimeLabel(session)
                    }
                }
                if compact {
                    Spacer(minLength: 6)
                    Text(session.updatedAt, style: .relative)
                        .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), CompanionStyle.mono(10).monospacedDigit()))
                        .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.faint))
                }
            }
            .padding(.top, PanelTheme.pick(2, 0, 1))
        }
    }

    /// The ellipsis opens this row's actions in place instead of a menu.
    private func actionsToggle(_ session: CompanionSession, open: Bool) -> some View {
        let tahoe = PanelTheme.current == .tahoe
        return Button {
            withAnimation(model.reducedMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                model.sessionActionsID = open ? nil : session.id
            }
        } label: { Image(systemName: "ellipsis") }
        .buttonStyle(NotchIconButtonStyle(size: 24, filled: tahoe && open, selected: !tahoe && open))
        .padding(.top, PanelTheme.pick(7, 4, 6)).padding(.trailing, PanelTheme.pick(6, 4, 5))
        .help(open ? "Hide actions" : "Manage \(session.title)")
        .accessibilityLabel("Manage \(session.title)")
        .accessibilityValue(open ? "Actions shown" : "Actions hidden")
    }

    @ViewBuilder private func runtimeLabel(_ session: CompanionSession) -> some View {
        let text = Text(session.isLegacyPrivate ? "Legacy Hermes" : session.runtime.title)
        switch PanelTheme.current {
        case .refined: text.font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).lineLimit(1)
        case .tahoe: text.font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
        case .instrument: text.microLabel(9.5, weight: .regular, tracking: 0.6).foregroundStyle(CompanionStyle.faint).lineLimit(1)
        }
    }

    /// Shared by the inline actions and the right-click menu.
    @ViewBuilder private func actions(_ session: CompanionSession) -> some View {
        manageActions(session)
        if session.isLegacyPrivate {
            ContinueLegacySessionButton(model: model, session: session)
        }
    }

    @ViewBuilder private func manageActions(_ session: CompanionSession) -> some View {
        Button("Rename", systemImage: "pencil") {
            model.sessionActionsID = nil
            titleDraft = session.title
            renamingID = session.id
            renameFocused = true
        }
        if session.isArchived {
            Button("Restore to sessions", systemImage: "tray.and.arrow.up") {
                model.sessionActionsID = nil
                model.restoreSession(session.id)
            }
        } else {
            Button("Archive", systemImage: "archivebox") {
                model.sessionActionsID = nil
                model.archiveSession(session.id)
            }
            .disabled(!model.canArchiveSession(session.id))
        }
    }

    private func finishRename(_ id: String) {
        guard !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.renameSession(id, title: titleDraft)
        renamingID = nil
    }

    private func preview(_ session: CompanionSession) -> String { SessionDigest.preview(session) }

    private var emptyTitle: String {
        if !model.sessionSearch.isEmpty { return "No matching sessions" }
        switch model.sessionFilter {
        case .all: return "A fresh start"
        case .needsYou: return "Nothing needs your attention"
        case .unread: return "You’re all caught up"
        case .archived: return "No archived sessions"
        }
    }

    private var emptyDetail: String {
        if !model.sessionSearch.isEmpty { return "Try a different name or phrase, or change the filter." }
        switch model.sessionFilter {
        case .all: return "Start a new session with the plus button, or add a project folder."
        case .needsYou: return "Questions and failed tasks will appear here."
        case .unread: return "Responses and errors you haven’t read will appear here."
        case .archived: return "Archive a quiet session from its menu. You can restore it here later."
        }
    }
}

/// Refined: a quiet folder glyph ahead of the project name.
private struct ProjectLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 11)).foregroundStyle(CompanionStyle.tertiary)
            configuration.title
        }
    }
}
