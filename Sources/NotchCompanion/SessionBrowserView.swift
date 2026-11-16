import SwiftUI

/// Shared discovery and management controls keep the notch and full window consistent.
struct SessionBrowserView: View {
    @ObservedObject var model: AppModel
    var compact = true
    @State private var renamingID: String?
    @State private var titleDraft = ""
    /// The row under the pointer trades its age for the actions button.
    @State private var hoveredID: String?
    @FocusState private var renameFocused: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var actionsFocusID: String?
    /// Custom snooze's chosen time; nil starts from the default.
    @State private var customSnoozeDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.pick(12, 10, 10)) {
            // The Archived chip stays inside the search capsule, typing or not.
            searchField
            // Re-read each minute so ages stay current and quiet sessions move to Archived.
            TimelineView(.everyMinute) { _ in list }
                .overlay(alignment: .bottom) {
                    if let undo = model.sessionUndo {
                        SessionUndoToast(undo: undo) { model.undoSessionChange() }
                            .padding(.bottom, 8)
                            .transition(model.reducedMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(model.reducedMotion ? nil : .easeOut(duration: 0.2), value: model.sessionUndo?.id)
        }.padding(.top, compact ? 6 : 0)
        // In the notch this page has no composer; opening it focuses search (a non-key panel ignores this).
        .onAppear { if compact { searchFocused = true } }
    }

    @ViewBuilder private var list: some View {
        let projects = model.visibleProjects
        switch PanelTheme.current {
        case .refined:
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(projects) { project in
                        projectHeader(project)
                        ForEach(project.sessions) { session in row(session) }
                    }
                    if projects.isEmpty { emptyState }
                    if showsFooters { footers.padding(.top, projects.isEmpty ? 0 : 10) }
                }
                .padding(.bottom, 12)
            }
            .scrollEdgeFade(top: 4)
            .accessibilityLabel("Sessions")
        case .tahoe:
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(projects) { project in
                        projectHeader(project)
                        // Each project is a grouped section with separators inset to the titles.
                        VStack(spacing: 0) {
                            ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Rectangle().fill(CompanionStyle.separator).frame(height: 0.5).padding(.leading, 38).padding(.trailing, 14) }
                                row(session).padding(3)
                            }
                        }
                        .notchGroup()
                    }
                    if projects.isEmpty { emptyState }
                    if showsFooters { footers.notchGroup().padding(.top, projects.isEmpty ? 0 : 8) }
                }.padding(.bottom, 6)
            }.softTopEdge(8, bottom: compact ? 14 : 0).accessibilityLabel("Sessions")
        case .instrument:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(projects) { project in
                        projectHeader(project)
                        ForEach(project.sessions) { session in row(session) }
                    }
                    if projects.isEmpty { emptyState }
                    if showsFooters { footers.padding(.top, projects.isEmpty ? 0 : 12) }
                }
            }.accessibilityLabel("Sessions")
        }
    }

    private var query: String { model.sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showsFooters: Bool { model.sessionFilter == .all && query.isEmpty && model.archivedCount + model.snoozedCount > 0 }

    /// Ends the default list: quiet ways into Snoozed and Archived, also when nothing is active.
    private var footers: some View {
        VStack(spacing: PanelTheme.pick(2, 0, 0)) {
            if model.snoozedCount > 0 {
                footer(.snoozed, symbol: "moon.zzz", count: model.snoozedCount, help: "Show snoozed sessions")
            }
            if PanelTheme.current == .tahoe && model.snoozedCount > 0 && model.archivedCount > 0 {
                Rectangle().fill(CompanionStyle.separator).frame(height: 0.5).padding(.leading, 38).padding(.trailing, 14)
            }
            if model.archivedCount > 0 {
                footer(.archived, symbol: "archivebox", count: model.archivedCount, help: "Show read and archived sessions")
            }
        }
    }

    private func footer(_ filter: SessionFilter, symbol: String, count: Int, help: String) -> some View {
        Button { model.sessionFilter = filter } label: {
            HStack(spacing: PanelTheme.pick(9, 8, 9)) {
                switch PanelTheme.current {
                case .refined, .tahoe:
                    Image(systemName: symbol).font(.system(size: 11)).frame(width: 16)
                    Text(filter.title).font(.system(size: PanelTheme.pick(12, 13, 12)))
                    Text("\(count)").font(.system(size: PanelTheme.pick(11, 12, 11)).monospacedDigit())
                        .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.faint))
                case .instrument:
                    Text(filter.title).font(.system(size: 12))
                    Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(CompanionStyle.faint)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.faint, CompanionStyle.faint))
            }
            .foregroundStyle(CompanionStyle.secondary)
            .padding(.horizontal, PanelTheme.pick(12, 10, 2))
            .frame(height: PanelTheme.pick(30, 28, 30))
        }
        .buttonStyle(NotchRowButtonStyle(cornerRadius: PanelTheme.pick(10, 9, CompanionStyle.radius)))
        .padding(PanelTheme.pick(0, 3, 0))
        .help(help)
        .accessibilityLabel("\(filter.title), \(count) \(count == 1 ? "session" : "sessions")")
    }

    @ViewBuilder private var emptyState: some View {
        switch PanelTheme.current {
        case .refined:
            VStack(alignment: .leading, spacing: 5) {
                Text(emptyTitle).font(.system(size: 13, weight: .semibold))
                Text(emptyDetail).font(CompanionStyle.callout).foregroundStyle(CompanionStyle.secondary)
            }
            // Starts where the rows' status glyphs and the Archived row's icon do.
            .padding(.vertical, 18).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
        case .tahoe:
            VStack(spacing: 6) {
                Image(systemName: !query.isEmpty ? "magnifyingglass" : model.sessionFilter == .archived ? "archivebox"
                      : model.sessionFilter == .snoozed ? "moon.zzz" : "tray")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(CompanionStyle.secondary)
                    .padding(.bottom, 6).accessibilityHidden(true)
                Text(emptyTitle).font(.system(size: 15, weight: .semibold))
                Text(emptyDetail).font(.system(size: 12.5)).foregroundStyle(CompanionStyle.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.vertical, 40).padding(.horizontal, 24).frame(maxWidth: .infinity)
        case .instrument:
            VStack(alignment: .leading, spacing: 6) {
                Text(emptyTitle).font(.system(size: 15, weight: .semibold))
                Text(emptyDetail).font(.system(size: 12.5)).foregroundStyle(CompanionStyle.secondary)
            }
            // Shares the project headers' and Archived row's two-point inset.
            .padding(.vertical, 18).padding(.horizontal, 2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var searchField: some View {
        searchChrome(HStack(spacing: 7) {
            switch PanelTheme.current {
            case .refined: Image(systemName: "magnifyingglass").foregroundStyle(CompanionStyle.tertiary)
            case .tahoe: Image(systemName: "magnifyingglass").foregroundStyle(CompanionStyle.secondary)
            case .instrument: Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
            }
            TextField("Search sessions", text: $model.sessionSearch)
                .textFieldStyle(.plain).focused($searchFocused).focusEffectDisabled()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Search session titles and conversations")
                .textCursor()
            if !model.sessionSearch.isEmpty {
                QuietIconButton(symbol: "xmark", label: "Clear search", size: 20) { model.sessionSearch = "" }
            }
            archivedChip
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

    /// Toggles Archived; choosing it again returns to the active list.
    private var archivedChip: some View {
        let on = model.sessionFilter == .archived
        return Button(SessionFilter.archived.title) { model.sessionFilter = on ? .all : .archived }
            .buttonStyle(NotchPillButtonStyle(small: true, selected: on))
            .help(on ? "Show active sessions" : "Show read and archived sessions")
            .accessibilityAddTraits(on ? .isSelected : [])
            .fixedSize()
    }

    /// A project's folder name and row count, with a way to start another session there.
    @ViewBuilder private func projectHeader(_ project: SessionProject) -> some View {
        // Pinned sessions keep their own folders, so the Pinned group starts none.
        let newSession = QuietIconButton(symbol: "plus", label: "New session in \(project.name)", size: 22) {
            Task { await model.newSession(showPanel: compact, workspace: project.path) }
        }.opacity(project.pinned ? 0 : 1).disabled(project.pinned).accessibilityHidden(project.pinned)
        let count = project.sessions.count
        let name = project.pinned ? "Pinned" : project.name
        switch PanelTheme.current {
        case .refined:
            HStack(spacing: 6) {
                projectLabel(project, Label(name, systemImage: project.pinned ? "pin" : "folder")
                    .labelStyle(ProjectLabelStyle())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary))
                Text("\(count)").font(CompanionStyle.caption.monospacedDigit()).foregroundStyle(CompanionStyle.tertiary)
                Spacer(minLength: 6)
                newSession
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 10).padding(.bottom, 2)
        case .tahoe:
            HStack(spacing: 6) {
                projectLabel(project, Label { Text(name) } icon: { Image(systemName: project.pinned ? "pin.fill" : "folder.fill").foregroundStyle(CompanionStyle.secondary) }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(CompanionStyle.text))
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(CompanionStyle.secondary)
                Spacer(minLength: 6)
                newSession
            }
            .padding(.leading, 4).padding(.trailing, 2).padding(.top, 8)
        case .instrument:
            HStack(spacing: 8) {
                projectLabel(project, Label(name, systemImage: project.pinned ? "pin" : "folder")
                    .labelStyle(.titleAndIcon)
                    .microLabel(10, weight: .semibold).foregroundStyle(CompanionStyle.secondary))
                    .layoutPriority(1)
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(CompanionStyle.faint)
                Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
                newSession
            }
            .padding(.leading, 2).padding(.top, 12).padding(.bottom, 4)
        }
    }

    private func projectLabel(_ project: SessionProject, _ label: some View) -> some View {
        label
            .lineLimit(1).truncationMode(.middle)
            .help(project.pinned ? "Pinned sessions" : project.path)
            .accessibilityLabel("\(project.pinned ? "Pinned" : "Project \(project.name)"), \(project.sessions.count) \(project.sessions.count == 1 ? "session" : "sessions")")
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func row(_ session: CompanionSession) -> some View {
        if renamingID == session.id {
            renameEditor(session)
        } else {
            let theme = PanelTheme.current
            let selected = model.currentID == session.id
            let open = model.sessionActionsID == session.id
            let showsActions = open || hoveredID == session.id || actionsFocusID == session.id
            let entry = SessionDigest.entry(session, requests: model.requests)
            VStack(alignment: .leading, spacing: 0) {
                Button { model.sessionActionsID = nil; model.selectSession(session.id) } label: {
                    rowLine(session, entry: entry, selected: selected, hidesTrailing: showsActions)
                        .padding(.horizontal, PanelTheme.pick(12, 10, 10))
                        // A two-line sidebar title keeps the single-line rows' first-line position.
                        .padding(.vertical, compact ? 0 : 9)
                        .frame(minHeight: Self.rowHeight)
                }
                .buttonStyle(NotchRowButtonStyle(selected: selected && !open, cornerRadius: PanelTheme.pick(10, 8, CompanionStyle.radius),
                                                 highlightsHover: !open))
                .help(entry.detail.isEmpty ? session.title : "\(session.title)\n\(entry.detail)")
                .accessibilityLabel(accessibilityLabel(session, entry: entry))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityValue(selected ? "Selected session" : "")
                .contextMenu { actions(session, menu: true) }
                if open {
                    Group {
                        if model.snoozeChoicesShown { snoozeChoices(session) } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) { actions(session) }
                                // The sidebar fits two short pills a row at most, and Mark as unread alone.
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) { renameAction(session); pinAction(session) }
                                    HStack(spacing: 6) { snoozeOrWakeAction(session); archiveOrRestoreAction(session) }
                                    markUnreadAction(session)
                                    if session.isLegacyPrivate { ContinueLegacySessionButton(model: model, session: session) }
                                }
                                VStack(alignment: .leading, spacing: 6) { actions(session) }
                            }
                        }
                    }
                    .buttonStyle(NotchPillButtonStyle(small: true))
                    .padding(.leading, PanelTheme.pick(37, 34, instrumentTitleX)).padding(.trailing, PanelTheme.pick(12, 10, 10)).padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            // While open, the row and its actions highlight as one.
            .background(Color.white.opacity(open ? (selected ? PanelTheme.pick(0.09, 0.1, 0.08) : PanelTheme.pick(0.06, 0.06, 0.05)) : 0),
                        in: RoundedRectangle(cornerRadius: PanelTheme.pick(10, 8, CompanionStyle.radius), style: .continuous))
            .overlay(alignment: .topTrailing) {
                // Hidden but focusable, so the keyboard can still reach it.
                actionsToggle(session, open: open)
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
            }
            .onHover { inside in
                if inside { hoveredID = session.id } else if hoveredID == session.id { hoveredID = nil }
            }
            .overlay(alignment: .bottom) {
                if theme == .instrument { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, instrumentTitleX) }
            }
        }
    }

    static var rowHeight: CGFloat { PanelTheme.pick(34, 32, 34) }
    /// Where Instrument titles start: past the lamp.
    private let instrumentTitleX: CGFloat = 27

    /// Status, title, then runtime and age (a live timer while working). Every
    /// row keeps one line so rows share a height; the tooltip has the full title.
    private func rowLine(_ session: CompanionSession, entry: GlanceEntry, selected: Bool, hidesTrailing: Bool) -> some View {
        // Read rows recede; what is new or needs you keeps full contrast.
        let quiet = !entry.unread && !selected
        let archived = model.sessionFilter != .archived && (session.isArchived || model.isAutoArchived(session))
        let snoozed = model.sessionFilter != .snoozed && session.snoozedUntil != nil
        let alignment: VerticalAlignment = compact ? .center : .firstTextBaseline, spacing: CGFloat = PanelTheme.pick(9, 8, 9)
        let label = HStack(alignment: alignment, spacing: spacing) {
            Text(session.title)
                .font(.system(size: 13, weight: PanelTheme.pick(.medium, .regular, .medium)))
                .foregroundStyle(quiet ? CompanionStyle.secondary : CompanionStyle.text)
                .lineLimit(1)
            // Search results mark sessions that live under Archived.
            if archived {
                Image(systemName: "archivebox").font(.system(size: PanelTheme.pick(10.5, 11, 10)))
                    .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.faint, CompanionStyle.faint))
                    .help("Archived")
            }
            if snoozed {
                Image(systemName: "moon.zzz").font(.system(size: PanelTheme.pick(10.5, 11, 10)))
                    .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.faint, CompanionStyle.faint))
                    .help("Snoozed")
            }
        }
        return HStack(alignment: alignment, spacing: spacing) {
            statusMark(session, entry: entry)
            if compact {
                label
                Spacer(minLength: 8)
            } else {
                // The sidebar gives the title every point but one gap before the age.
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
            // The actions button takes the age's place on hover.
            trailing(session, entry: entry).opacity(hidesTrailing ? 0 : 1)
        }
    }

    /// Working, needs-you and unread rows get a glyph; a read failure keeps a
    /// quiet mark; other read rows leave the column empty.
    private func statusMark(_ session: CompanionSession, entry: GlanceEntry) -> some View {
        // The column keeps its width when empty so titles stay aligned.
        Color.clear.frame(width: PanelTheme.pick(16, 16, 8), height: 16).overlay {
            if PanelTheme.current == .instrument {
                if entry.unread {
                    LED(color: CompanionStyle.indicatorColor(CollapsedStatus.resolve(session: session)),
                        pulsing: entry.status == .working, size: 6)
                } else if entry.status == .failed {
                    LED(color: CompanionStyle.faint, lit: false, size: 6)
                }
            } else if entry.unread || entry.status == .failed {
                GlanceStatusGlyph(status: entry.status, unread: entry.unread, reducedMotion: model.reducedMotion, size: 16)
            }
        }
        // On baseline-aligned rows, centred on the title's first line (13-point text's middle sits ~4.5 points above it).
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }

    @ViewBuilder private func trailing(_ session: CompanionSession, entry: GlanceEntry) -> some View {
        let theme = PanelTheme.current
        HStack(spacing: 6) {
            // The 252-point sidebar keeps only the time.
            if compact { runtimeLabel(session) }
            if entry.status == .working {
                TimelineView(.periodic(from: entry.since, by: 1)) { context in
                    Text(SessionDigest.elapsed(context.date.timeIntervalSince(entry.since)))
                        .foregroundStyle(theme == .instrument ? CompanionStyle.signal : IslandStyle.indicatorColor(.running))
                }
            } else if let until = session.snoozedUntil {
                // A snoozed row counts down to its wake instead of up from its last activity.
                Text(SessionDigest.wakeLabel(until.timeIntervalSinceNow))
                    .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.faint))
            } else {
                Text(SessionDigest.compactAge(Date().timeIntervalSince(entry.since)))
                    .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.faint))
            }
        }
        .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), .system(size: 11)).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    private func accessibilityLabel(_ session: CompanionSession, entry: GlanceEntry) -> String {
        let archived = session.isArchived || model.isAutoArchived(session) ? " Archived." : ""
        let snoozed = session.snoozedUntil.map { " Snoozed until \(SnoozeChoice.time($0))." } ?? ""
        let runtime = session.isLegacyPrivate ? "Legacy Hermes" : session.runtime.title
        let plan = Self.showsPlanReady(session) ? " Plan ready." : ""
        return "\(entry.accessibilityLabel) \(runtime).\(plan)\(archived)\(snoozed)"
    }

    private func renameEditor(_ session: CompanionSession) -> some View {
        let field = RoundedRectangle(cornerRadius: PanelTheme.pick(8, 8, CompanionStyle.radius), style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
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
        .focused($actionsFocusID, equals: session.id)
        .padding(.top, (Self.rowHeight - 24) / 2).padding(.trailing, PanelTheme.pick(6, 4, 5))
        .help(open ? "Hide actions" : "Manage \(session.title)")
        .accessibilityLabel("Manage \(session.title)")
        .accessibilityValue(open ? "Actions shown" : "Actions hidden")
    }

    /// An unread plan waiting for Implement or Keep planning.
    static func showsPlanReady(_ session: CompanionSession) -> Bool { session.planReadyTurnID != nil && session.hasUnreadCompletion }

    @ViewBuilder private func runtimeLabel(_ session: CompanionSession) -> some View {
        let text = Text(Self.showsPlanReady(session) ? "Plan ready" : session.isLegacyPrivate ? "Legacy Hermes" : session.runtime.title)
        switch PanelTheme.current {
        case .refined: text.foregroundStyle(CompanionStyle.faint)
        case .tahoe: text.foregroundStyle(CompanionStyle.faint)
        case .instrument: text.foregroundStyle(CompanionStyle.faint)
        }
    }

    /// Shared by the inline actions and the right-click menu.
    @ViewBuilder private func actions(_ session: CompanionSession, menu: Bool = false) -> some View {
        renameAction(session)
        pinAction(session)
        markUnreadAction(session)
        snoozeOrWakeAction(session, menu: menu)
        archiveOrRestoreAction(session)
        if session.isLegacyPrivate {
            ContinueLegacySessionButton(model: model, session: session)
        }
    }

    private func renameAction(_ session: CompanionSession) -> some View {
        Button("Rename", systemImage: "pencil") {
            model.sessionActionsID = nil
            titleDraft = session.title
            renamingID = session.id
            renameFocused = true
        }
    }

    @ViewBuilder private func pinAction(_ session: CompanionSession) -> some View {
        if session.isPinned {
            Button("Unpin", systemImage: "pin.slash") {
                model.sessionActionsID = nil
                model.undoable(.unpinned, session.id) { model.setPinned(session.id, false) }
            }
        } else if model.canPinSession(session.id) {
            Button("Pin", systemImage: "pin") {
                model.sessionActionsID = nil
                model.setPinned(session.id, true)
            }
            .help("Keep it above your projects; it never archives on its own")
        }
    }

    @ViewBuilder private func markUnreadAction(_ session: CompanionSession) -> some View {
        if model.canMarkUnread(session.id) {
            Button("Mark as unread", systemImage: "circle.inset.filled") {
                model.sessionActionsID = nil
                model.markUnread(session.id)
            }
            .help("Show its result as new until you open it")
        }
    }

    @ViewBuilder private func snoozeOrWakeAction(_ session: CompanionSession, menu: Bool = false) -> some View {
        if let until = session.snoozedUntil {
            Button("Wake now", systemImage: "sun.max") {
                model.sessionActionsID = nil
                model.wakeSession(session.id)
            }
            .help("Snoozed until \(SnoozeChoice.time(until)). Bring it back now")
        } else if !(session.isArchived || model.isAutoArchived(session)) {
            if menu {
                Menu("Snooze", systemImage: "moon.zzz") {
                    ForEach(SnoozeChoice.allCases) { choice in
                        Button(choice.title) { snooze(session, until: choice.until()) }
                    }
                    if let reset = model.limitResetDate(for: session.id) {
                        Button(Self.limitResetTitle) { snooze(session, until: reset) }
                    }
                    // The menu cannot hold a picker, so Custom… opens the row's own.
                    Button(Self.customTitle) {
                        model.sessionActionsID = session.id
                        model.snoozeChoicesShown = true
                        model.customSnoozeShown = true
                    }
                }
                .disabled(!model.canSnoozeSession(session.id))
            } else {
                Button("Snooze", systemImage: "moon.zzz") { model.snoozeChoicesShown = true }
                    .disabled(!model.canSnoozeSession(session.id))
                    .help(model.canSnoozeSession(session.id) ? "Hide it until later; a question or failure brings it back sooner"
                          : "Answer its question first")
            }
        }
    }

    @ViewBuilder private func archiveOrRestoreAction(_ session: CompanionSession) -> some View {
        if session.isArchived || model.isAutoArchived(session) {
            Button("Restore to sessions", systemImage: "tray.and.arrow.up") {
                model.sessionActionsID = nil
                model.restoreSession(session.id)
            }
        } else {
            Button("Archive", systemImage: "archivebox") {
                model.sessionActionsID = nil
                model.undoable(.archived, session.id) { model.archiveSession(session.id) }
            }
            .disabled(!model.canArchiveSession(session.id))
        }
    }

    static let limitResetTitle = "Until limit resets"
    static let customTitle = "Custom…"

    private func snooze(_ session: CompanionSession, until: Date) {
        model.sessionActionsID = nil
        model.undoable(.snoozed, session.id) { model.snoozeSession(session.id, until: until) }
    }

    /// The open row's snooze choices; they wrap in the narrow sidebar.
    @ViewBuilder private func snoozeChoices(_ session: CompanionSession) -> some View {
        if model.customSnoozeShown {
            customSnooze(session)
        } else {
            let choices = SnoozeChoice.allCases.map { choice in
                Button(choice.title) { snooze(session, until: choice.until()) }.help(choice.help())
            }
            let reset = model.limitResetDate(for: session.id)
            let others = HStack(spacing: 6) {
                if let reset {
                    Button(Self.limitResetTitle) { snooze(session, until: reset) }
                        .help("Snooze until \(session.runtime.title)’s usage limit resets, \(SnoozeChoice.time(reset))")
                }
                Button(Self.customTitle) { customSnoozeDate = Self.defaultCustomDate(); model.customSnoozeShown = true }
                    .help("Choose a day and time")
            }
            let cancel = Button("Cancel") { model.snoozeChoicesShown = false }.help("Keep \(session.title) in your sessions")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { ForEach(0..<4) { choices[$0] }; others; cancel }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { ForEach(0..<4) { choices[$0] } }
                    HStack(spacing: 6) { others; cancel }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { ForEach(0..<2) { choices[$0] } }
                    HStack(spacing: 6) { ForEach(2..<4) { choices[$0] } }
                    others
                    cancel
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Snooze \(session.title)")
        }
    }

    /// The next whole hour at least an hour away: a round, future starting point.
    static func defaultCustomDate(now: Date = Date(), calendar: Calendar = .app) -> Date {
        let later = now.addingTimeInterval(3_600)
        return calendar.nextDate(after: later, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? later
    }

    /// Custom…: a date and time on the user's calendar, future times only.
    private func customSnooze(_ session: CompanionSession) -> some View {
        // A choice left over from an earlier, now past, visit starts over.
        let date = customSnoozeDate.flatMap { $0 > Date() ? $0 : nil } ?? Self.defaultCustomDate()
        let picker = DatePicker("Wake at", selection: Binding(get: { date }, set: { customSnoozeDate = $0 }),
                                in: Date()..., displayedComponents: [.date, .hourAndMinute])
            .labelsHidden().datePickerStyle(.field)
            .environment(\.locale, .app).environment(\.calendar, .app)
            .fixedSize()
            .accessibilityLabel("Snooze until")
        let confirm = Button("Snooze") { snooze(session, until: date) }
            .disabled(date <= Date())
            .help("Snooze until \(SnoozeChoice.time(date))")
        let cancel = Button("Cancel") { model.customSnoozeShown = false }.help("Back to the snooze choices")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { picker; confirm; cancel }
            VStack(alignment: .leading, spacing: 6) { picker; HStack(spacing: 6) { confirm; cancel } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Snooze \(session.title) until a chosen time")
    }

    private func finishRename(_ id: String) {
        guard !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.renameSession(id, title: titleDraft)
        renamingID = nil
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "No matching sessions" }
        switch model.sessionFilter {
        case .all: return model.archivedCount + model.snoozedCount > 0 ? "All caught up" : "A fresh start"
        case .needsYou: return "Nothing needs your attention"
        case .unread: return "You’re all caught up"
        case .archived: return "No archived sessions"
        case .snoozed: return "No snoozed sessions"
        }
    }

    private var emptyDetail: String {
        if !query.isEmpty { return "Try a different name or phrase." }
        switch model.sessionFilter {
        case .all: return model.archivedCount > 0 ? "Nothing is working or waiting. Read sessions rest in Archived."
            : model.snoozedCount > 0 ? "Nothing is working or waiting. Snoozed sessions come back when it’s time."
            : "Start a new session with the plus button, or add a project folder."
        case .needsYou: return "Questions and failed tasks will appear here."
        case .unread: return "Responses and errors you haven’t read will appear here."
        case .archived:
            guard model.autoArchiveAfter != .never else { return "Archive a quiet session from its menu. You can restore it here later." }
            return "Read sessions move here after \(model.autoArchiveAfter.label) without activity. You can also archive one from its menu."
        case .snoozed: return "Snooze a session from its menu. It comes back on time, or sooner if it needs you."
        }
    }
}

/// Refined: a quiet folder glyph in the status column, so project names align with row titles.
private struct ProjectLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon.font(.system(size: 11)).foregroundStyle(CompanionStyle.tertiary).frame(width: 16)
            configuration.title
        }
    }
}

/// The list's quiet confirmation of an archive, snooze or unpin, with its Undo.
struct SessionUndoToast: View {
    var undo: SessionUndo
    var action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The verb stays whole; a long title truncates.
            HStack(spacing: 4) {
                Text(undo.kind.rawValue).fixedSize()
                Text(undo.title).lineLimit(1).truncationMode(.tail)
            }.font(.system(size: 12)).foregroundStyle(CompanionStyle.secondary)
            Text("·").font(.system(size: 12)).foregroundStyle(CompanionStyle.tertiary).accessibilityHidden(true)
            Button("Undo", action: action)
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.text)
                .keyboardShortcut("z", modifiers: .command)
                .pressableCursor()
                .help("Undo (⌘Z)")
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Color(white: 0.11), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(undo.message)
        .accessibilityAction(named: "Undo", action)
    }
}
