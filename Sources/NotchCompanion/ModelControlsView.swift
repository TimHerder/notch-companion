import SwiftUI

struct ModelControlsView: View {
    @ObservedObject var model: AppModel
    @State private var choosingModel = false
    @State private var showingContext = false
    @State private var choosingPermissions = false
    @State private var search = ""
    @StateObject private var popupDismissal = PopupDismissalMonitor()

    init(model: AppModel, choosingModel: Bool = false, showingContext: Bool = false, choosingPermissions: Bool = false, search: String = "") {
        self.model = model
        _choosingModel = State(initialValue: choosingModel)
        _showingContext = State(initialValue: showingContext)
        _choosingPermissions = State(initialValue: choosingPermissions)
        _search = State(initialValue: search)
    }

    var body: some View {
        if let session = model.current {
            let key = model.modelCatalogKey(for: session)
            let catalog = model.modelCatalogs[key]
            let shown = session.modelOverride ?? session.runtimeInfo?.model.map {
                RuntimeModelChoice(model: $0, provider: session.runtimeInfo?.provider)
            } ?? catalog?.defaultModel
            let modelTitle = shown.map { catalog?.title(for: $0) ?? $0.model }
            let shownOption = shown.flatMap { catalog?.option(for: $0) }
            let effort = shownOption?.reasoningEfforts.isEmpty == false ? shown?.reasoningEffort ?? shownOption?.defaultReasoningEffort : nil
            let permissionTitle = session.permissionMode?.title ?? "Default permissions"
            let context = session.runtimeInfo?.context
            // Unclamped, so an over-limit report reads as more than 100 %.
            let percentage = context?.ratio.map { "\(context?.estimated == true ? "≈" : "")\(Int(($0 * 100).rounded()))%" }
            let contextCounts = context.map { "\($0.estimated ? "≈" : "")\($0.used?.formatted() ?? "—") / \($0.limit?.formatted() ?? "—")" }
            let contextDetail = context.map { usage in
                [percentage, usage.detail].compactMap { $0 }.joined(separator: " · ")
            } ?? "The runtime has not reported context usage yet. Send a message to receive a report."
            let modes = session.capabilities.supportedPermissionModes
            let theme = PanelTheme.current
            HStack(spacing: 4) {
                if model.showPermissionModes && !modes.isEmpty {
                    Button {
                        choosingPermissions.toggle()
                        choosingModel = false; showingContext = false
                    } label: {
                        Group {
                            switch theme {
                            case .refined:
                                HStack(spacing: 5) {
                                    Image(systemName: session.permissionMode?.symbol ?? "shield")
                                    Text(permissionTitle).lineLimit(1)
                                }
                            case .tahoe:
                                HStack(spacing: 5) {
                                    // The glyph takes the label's color explicitly; inherited, Full access drew it white.
                                    Image(systemName: session.permissionMode?.symbol ?? "shield").symbolRenderingMode(.monochrome)
                                        .foregroundStyle(session.permissionMode == .fullAccess ? CompanionStyle.amber : CompanionStyle.secondary)
                                    Text(permissionTitle).lineLimit(1)
                                }
                            case .instrument:
                                HStack(spacing: 6) {
                                    Image(systemName: session.permissionMode?.symbol ?? "shield").font(.system(size: 10))
                                    Text(permissionTitle).microLabel(10, tracking: 0.6).lineLimit(1)
                                }
                            }
                        }
                        .foregroundStyle(session.permissionMode == .fullAccess ? CompanionStyle.amber : CompanionStyle.secondary)
                    }
                    .sessionControlStyle()
                    .disabled(!model.canChangePermissionMode(session.id))
                    .help(model.canChangePermissionMode(session.id)
                          ? "Permissions for your next message: \(permissionTitle)"
                          : "Wait for this session and its delegated work to finish.")
                    .accessibilityLabel("Permission mode")
                    .accessibilityValue(permissionTitle)
                    .background(PopupDismissalRegion(monitor: popupDismissal))
                }
                Spacer(minLength: 8)
                if model.showModelPicker {
                    Button {
                        choosingModel.toggle()
                        showingContext = false; choosingPermissions = false
                    } label: {
                        switch theme {
                        case .refined:
                            HStack(spacing: 5) {
                                Text(modelTitle ?? "Runtime default")
                                    .lineLimit(1).truncationMode(.middle)
                                if let effort {
                                    Text(RuntimeModelOption.effortTitle(effort)).foregroundStyle(CompanionStyle.tertiary)
                                        .lineLimit(1).fixedSize()
                                }
                            }
                        case .tahoe, .instrument:
                            HStack(spacing: theme == .instrument ? 7 : 5) {
                                Text(modelTitle ?? "Runtime default").foregroundStyle(CompanionStyle.text)
                                    .lineLimit(1).truncationMode(.middle)
                                if let effort { Text(RuntimeModelOption.effortTitle(effort)).lineLimit(1).fixedSize() }
                            }
                            .modifier(InstrumentMicroLabel(active: theme == .instrument))
                        }
                    }
                    .sessionControlStyle()
                    .disabled(!model.canChangeModel(session.id))
                    .accessibilityLabel("Choose \(session.runtime.title) model and reasoning effort")
                    .accessibilityValue([modelTitle, effort.map(RuntimeModelOption.effortTitle)].compactMap { $0 }.joined(separator: ", "))
                    .background(PopupDismissalRegion(monitor: popupDismissal))
                    .help(session.isLegacyPrivate ? "Model selection is unavailable for Legacy Hermes."
                          : session.isBusy ? "Wait for this session and its delegated work to finish."
                          : "Choose the model for your next message in this conversation")
                }
                if model.showContextUsage {
                    let toggle = {
                        showingContext.toggle()
                        choosingModel = false; choosingPermissions = false
                    }
                    Group {
                        if theme == .instrument {
                            Button(action: toggle) {
                                // A level meter: ten segments, the signal near the limit.
                                HStack(spacing: 6) {
                                    SegmentMeter(fraction: context?.fraction)
                                    Text(percentage ?? "—%").font(CompanionStyle.mono(10).monospacedDigit())
                                        .foregroundStyle(context?.fraction == nil ? CompanionStyle.faint : CompanionStyle.secondary)
                                }
                                .padding(.horizontal, 2)
                            }
                            .buttonStyle(NotchTextButtonStyle())
                        } else {
                            // Refined draws a finer, quieter ring.
                            let line: CGFloat = theme == .refined ? 1.75 : 2
                            Button(action: toggle) {
                                ZStack {
                                    Circle().stroke(style: StrokeStyle(lineWidth: line, dash: context?.fraction == nil ? [2, 2] : []))
                                        .opacity(theme == .refined ? 0.35 : 0.6)
                                    if let fraction = context?.fraction {
                                        Circle().trim(from: 0, to: fraction)
                                            .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                    }
                                }
                                .frame(width: theme == .refined ? 13 : 14, height: theme == .refined ? 13 : 14)
                            }
                            .buttonStyle(NotchIconButtonStyle(size: 22))
                        }
                    }
                    .help(contextCounts.map { [$0, percentage].compactMap { $0 }.joined(separator: " · ") } ?? contextDetail)
                    .accessibilityLabel("Context usage")
                    .accessibilityValue(contextDetail)
                    .accessibilityHint("Show or hide context details")
                    .background(PopupDismissalRegion(monitor: popupDismissal))
                }
            }
            .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), CompanionStyle.mono(10.5))).foregroundStyle(CompanionStyle.secondary)
            .frame(height: 22)
            .overlay(alignment: .bottomTrailing) {
                if showingContext && model.showContextUsage {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionHeader("Context") {
                                QuietIconButton(symbol: "xmark", label: "Close context details", size: 18) {
                                    showingContext = false
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(percentage ?? "—")
                                        .font(theme == .instrument ? CompanionStyle.mono(14, .semibold) : .system(size: 15, weight: .semibold))
                                        .monospacedDigit().foregroundStyle(CompanionStyle.text)
                                    Spacer(minLength: 0)
                                    if let context {
                                        Text(context.label).monospacedDigit().lineLimit(1)
                                            .fontDesign(theme == .instrument ? .monospaced : nil)
                                    }
                                }
                                UsageBar(fraction: context?.fraction)
                                Text(context.map { UsageView.contextCaption($0) } ?? "No report yet")
                                    .font(UsageLimitRow.captionFont).foregroundStyle(UsageLimitRow.captionColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if model.showUsage && session.runtime.capabilities.rateLimits == true {
                            accountLimits(session.runtime)
                        }
                    }
                    .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), .system(size: 11)))
                    .foregroundStyle(CompanionStyle.secondary).padding(PanelTheme.pick(12, 12, 10))
                    // A fixed width, so the bubble never jumps between states.
                    .frame(width: 264)
                    .fixedSize(horizontal: false, vertical: true)
                    .popupSurface(cornerRadius: 12)
                    .background(PopupDismissalRegion(monitor: popupDismissal))
                    // Eight points above the 22-point control row.
                    .offset(y: -30)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if choosingModel && model.showModelPicker {
                    modelChoices(session: session, key: key, catalog: catalog)
                        .frame(width: 350)
                        .fixedSize(horizontal: false, vertical: true)
                        .popupSurface()
                        .background(PopupDismissalRegion(monitor: popupDismissal))
                        .offset(y: -30)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if choosingPermissions && model.showPermissionModes {
                    permissionChoices(session: session, modes: modes)
                        .frame(width: PanelTheme.pick(320, 320, 364))
                        .fixedSize(horizontal: false, vertical: true)
                        .popupSurface()
                        .background(PopupDismissalRegion(monitor: popupDismissal))
                        .offset(y: -30)
                }
            }
            .task(id: key) {
                if model.showModelPicker { await model.loadModels(for: key) }
            }
            .onChange(of: model.showModelPicker) { _, visible in
                if visible { Task { await model.loadModels(for: key) } }
            }
            .onChange(of: model.currentID) { _, _ in choosingModel = false; showingContext = false; choosingPermissions = false; search = "" }
            .onChange(of: session.runtime) { _, _ in choosingModel = false; showingContext = false; choosingPermissions = false; search = "" }
            .onChange(of: model.expanded) { _, expanded in if !expanded { showingContext = false; choosingModel = false; choosingPermissions = false } }
            .onChange(of: session.isBusy) { _, busy in if busy { choosingModel = false; choosingPermissions = false } }
            .onChange(of: (choosingModel && model.showModelPicker) || (showingContext && model.showContextUsage)
                        || (choosingPermissions && model.showPermissionModes), initial: true) { _, presented in
                if presented {
                    popupDismissal.start { choosingModel = false; showingContext = false; choosingPermissions = false }
                } else { popupDismissal.stop() }
            }
            .onDisappear { popupDismissal.stop() }
        }
    }

    /// The Usage page's account limits for this session's harness, asked again on open.
    private func accountLimits(_ runtime: RuntimeKind) -> some View {
        let limits = RuntimeRateLimit.sorted(model.rateLimits[runtime.rawValue] ?? [])
        let rows = VStack(alignment: .leading, spacing: 10) { ForEach(limits) { UsageLimitRow(limit: $0) } }
        return VStack(alignment: .leading, spacing: 8) {
            if PanelTheme.current != .instrument {
                Rectangle().fill(PanelTheme.pick(CompanionStyle.hairline, CompanionStyle.separator, .clear)).frame(height: 0.5)
                    .padding(.bottom, 2)
            }
            sectionHeader("\(runtime.title) usage") {
                if let reported = limits.map(\.reportedAt).max() {
                    // Instrument's rule label leaves room for the bare timestamp only.
                    Text(PanelTheme.current == .instrument ? UsageView.reportedTime(reported) : UsageView.reportedText(reported))
                        .font(UsageLimitRow.captionFont).foregroundStyle(UsageLimitRow.captionColor).lineLimit(1).fixedSize()
                        .accessibilityLabel(UsageView.reportedText(reported))
                }
                if model.refreshingRateLimits { ProgressView().controlSize(.mini).frame(width: 18, height: 18) }
                else {
                    QuietIconButton(symbol: "arrow.clockwise", label: "Refresh \(runtime.title) usage", size: 18) {
                        Task { await model.refreshRateLimits(runtime) }
                    }
                }
            }
            if let error = model.rateLimitErrors[runtime.rawValue] {
                Text(error).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
            } else if limits.isEmpty {
                Text(runtime == .claude ? "Claude Code reports its limits during a turn." : "Not reported yet.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Claude can report six windows; past four the list scrolls inside the bubble.
            if limits.count > 4 { ScrollView { rows }.frame(height: 200) } else { rows }
        }
        .task { await model.refreshRateLimits(runtime) }
    }

    /// A bubble section's label with trailing controls: Instrument's rule label,
    /// a quiet secondary label elsewhere (like the picker's Reasoning effort).
    @ViewBuilder
    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        if PanelTheme.current == .instrument {
            RuleLabel(title: title, trailing: trailing).accessibilityAddTraits(.isHeader)
        } else {
            HStack(spacing: 6) {
                Text(title).font(.system(size: PanelTheme.pick(11, 12, 11), weight: .semibold)).foregroundStyle(CompanionStyle.secondary)
                    .lineLimit(1).layoutPriority(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                trailing()
            }
        }
    }

    @ViewBuilder
    private func permissionChoices(session: CompanionSession, modes: [PermissionMode]) -> some View {
        let options = [PermissionMode?.none] + modes.map(Optional.some)
        switch PanelTheme.current {
        case .refined:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Permissions for your next message").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    QuietIconButton(symbol: "xmark", label: "Close permission modes", size: 22) { choosingPermissions = false }
                }
                .padding(.leading, 10)
                ForEach(options, id: \.self) { mode in
                    Button {
                        model.setPermissionMode(mode, for: session.id)
                        choosingPermissions = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode?.symbol ?? "shield").font(.system(size: 13)).frame(width: 18)
                                .foregroundStyle(mode == .fullAccess ? CompanionStyle.amber : CompanionStyle.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode?.title ?? "Default permissions").font(.system(size: 12, weight: .medium))
                                Text(mode?.detail ?? "Uses \(session.runtime.title)'s own settings")
                                    .font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                            }
                            Spacer(minLength: 0)
                            if session.permissionMode == mode { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NotchRowButtonStyle(selected: session.permissionMode == mode, cornerRadius: 8))
                    .accessibilityLabel(mode?.title ?? "Default permissions")
                    .accessibilityAddTraits(session.permissionMode == mode ? .isSelected : [])
                }
            }
            .padding(8)
            .disabled(!model.canChangePermissionMode(session.id))
        case .tahoe:
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Permissions for your next message").font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary)
                    Spacer(minLength: 0)
                    QuietIconButton(symbol: "xmark", label: "Close permission modes", size: 22) { choosingPermissions = false }
                }.padding(.leading, 8).padding(.bottom, 2)
                ForEach(options, id: \.self) { mode in
                    Button {
                        model.setPermissionMode(mode, for: session.id)
                        choosingPermissions = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode?.symbol ?? "shield").font(.system(size: 14)).symbolRenderingMode(.hierarchical)
                                .frame(width: 20)
                                .foregroundStyle(mode == .fullAccess ? CompanionStyle.amber : CompanionStyle.text)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode?.title ?? "Default permissions").font(.system(size: 13))
                                    .foregroundStyle(mode == .fullAccess ? CompanionStyle.amber : CompanionStyle.text)
                                Text(mode?.detail ?? "Uses \(session.runtime.title)'s own settings")
                                    .font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                            }
                            Spacer(minLength: 0)
                            if session.permissionMode == mode { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.accent) }
                        }
                        .padding(.horizontal, 8).frame(height: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NotchRowButtonStyle(cornerRadius: 8))
                    .accessibilityLabel(mode?.title ?? "Default permissions")
                    .accessibilityAddTraits(session.permissionMode == mode ? .isSelected : [])
                }
            }
            .padding(6)
            .disabled(!model.canChangePermissionMode(session.id))
        case .instrument:
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Permissions · next message").microLabel(9.5, weight: .semibold).foregroundStyle(CompanionStyle.secondary)
                    Spacer(minLength: 0)
                    QuietIconButton(symbol: "xmark", label: "Close permission modes", size: 22) { choosingPermissions = false }
                }
                .padding(.bottom, 4)
                ForEach(Array(options.enumerated()), id: \.element) { index, mode in
                    let chosen = session.permissionMode == mode
                    Button {
                        model.setPermissionMode(mode, for: session.id)
                        choosingPermissions = false
                    } label: {
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1)).font(CompanionStyle.mono(10)).foregroundStyle(CompanionStyle.faint)
                            Image(systemName: mode?.symbol ?? "shield").frame(width: 14)
                                .foregroundStyle(mode == .fullAccess ? CompanionStyle.amber : CompanionStyle.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode?.title ?? "Default permissions").font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(mode == .fullAccess ? CompanionStyle.amber : CompanionStyle.text)
                                Text(mode?.detail ?? "Uses \(session.runtime.title)'s own settings")
                                    .font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if chosen { LED(color: CompanionStyle.text, size: 6) }
                        }
                        .padding(.horizontal, 8).frame(height: 42)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NotchRowButtonStyle(selected: chosen))
                    .accessibilityLabel(mode?.title ?? "Default permissions")
                    .accessibilityAddTraits(session.permissionMode == mode ? .isSelected : [])
                }
            }
            .font(.system(size: 11)).padding(8)
            .disabled(!model.canChangePermissionMode(session.id))
        }
    }

    private func modelChoices(session: CompanionSession, key: ModelCatalogKey, catalog: RuntimeModelCatalog?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                searchField(session: session)
                if model.loadingModelCatalogs.contains(key) { ProgressView().controlSize(.mini) }
                QuietIconButton(symbol: "arrow.clockwise", label: "Refresh available models", size: 22) {
                    Task { await model.loadModels(for: key, refresh: true) }
                }.disabled(model.loadingModelCatalogs.contains(key))
                QuietIconButton(symbol: "xmark", label: "Close model picker", size: 22) { choosingModel = false }
            }
            if let error = model.modelCatalogErrors[key] {
                Text(error).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PanelTheme.pick(2, 0, 2)) {
                    let listsDefault = catalog?.defaultModel != nil && search.isEmpty
                    if let defaultModel = catalog?.defaultModel, listsDefault {
                        choiceRow(index: 1, title: "Use runtime default", detail: catalog?.title(for: defaultModel),
                                  selected: session.modelOverride == nil && session.runtimeInfo?.model == nil) {
                            model.setModel(session.storedID == nil ? nil : defaultModel, for: session.id)
                            choosingModel = false
                        }
                    }
                    let options = catalog?.matchingModels(search) ?? []
                    ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                        choiceRow(index: offset + (listsDefault ? 2 : 1), title: option.title, detail: option.choice.provider,
                                  selected: session.modelOverride?.id == option.choice.id || (session.modelOverride == nil && session.runtimeInfo?.model == option.choice.model)) {
                            var choice = option.choice
                            if let effort = session.modelOverride?.reasoningEffort, option.reasoningEfforts.contains(effort) {
                                choice.reasoningEffort = effort
                            } else { choice.reasoningEffort = option.defaultReasoningEffort }
                            model.setModel(choice, for: session.id)
                            if option.reasoningEfforts.isEmpty { choosingModel = false }
                        }
                    }
                    if options.isEmpty && !model.loadingModelCatalogs.contains(key) {
                        Text(search.isEmpty ? "No selectable models reported." : "No matching models.")
                            .foregroundStyle(CompanionStyle.secondary).padding(.vertical, 6)
                    }
                }
            }
            .frame(height: 116)
            reasoningChoices(session: session, catalog: catalog)
        }
        .font(PanelTheme.pick(CompanionStyle.callout, .system(size: 11.5), .system(size: 11))).padding(10)
        .disabled(!model.canChangeModel(session.id))
    }

    @ViewBuilder
    private func searchField(session: CompanionSession) -> some View {
        switch PanelTheme.current {
        case .refined:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(CompanionStyle.tertiary)
                    .accessibilityHidden(true)
                TextField("Search models…", text: $search).textFieldStyle(.plain).textCursor()
                    .accessibilityLabel("Find a \(session.runtime.title) model")
            }
            .font(CompanionStyle.callout)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CompanionStyle.hairline, lineWidth: 0.75))
        case .tahoe:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(CompanionStyle.secondary)
                    .accessibilityHidden(true)
                TextField("Search models…", text: $search).textFieldStyle(.plain).textCursor()
                    .font(.system(size: 13))
                    .accessibilityLabel("Find a \(session.runtime.title) model")
            }
            .padding(.horizontal, 9).frame(height: 28)
            // The inset well of a native search field.
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        case .instrument:
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(CompanionStyle.secondary)
                    .accessibilityHidden(true)
                TextField("Search models…", text: $search).textFieldStyle(.plain).font(CompanionStyle.mono(11)).textCursor()
                    .accessibilityLabel("Find a \(session.runtime.title) model")
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(CompanionStyle.inset, in: RoundedRectangle(cornerRadius: CompanionStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: CompanionStyle.radius).strokeBorder(CompanionStyle.ruleStrong, lineWidth: 0.75))
        }
    }

    @ViewBuilder
    private func reasoningChoices(session: CompanionSession, catalog: RuntimeModelCatalog?) -> some View {
        let choice = session.modelOverride ?? session.runtimeInfo?.model.map {
            RuntimeModelChoice(model: $0, provider: session.runtimeInfo?.provider ?? catalog?.defaultModel?.provider)
        } ?? catalog?.defaultModel
        let option = choice.flatMap { catalog?.option(for: $0) }
        if let choice, let option, !option.reasoningEfforts.isEmpty {
            let spacing: CGFloat = PanelTheme.pick(4, 5, 4)
            switch PanelTheme.current {
            case .refined:
                Rectangle().fill(CompanionStyle.hairline).frame(height: 0.5).padding(.vertical, 2)
                // On the rows' text inset, not the chips' edge.
                Text("Reasoning effort").font(.system(size: 11, weight: .semibold)).foregroundStyle(CompanionStyle.secondary)
                    .padding(.leading, 10)
            case .tahoe:
                Rectangle().fill(CompanionStyle.separator).frame(height: 0.5).padding(.vertical, 2)
                Text("Reasoning effort").font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary)
            case .instrument:
                RuleLabel("Reasoning effort").padding(.top, 4)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: spacing)], alignment: .leading, spacing: spacing) {
                ForEach(option.reasoningEfforts, id: \.self) { effort in
                    let selected = (choice.reasoningEffort ?? option.defaultReasoningEffort) == effort
                    Button {
                        var selection = choice
                        selection.reasoningEffort = effort
                        model.setModel(selection, for: session.id)
                    } label: {
                        if PanelTheme.current == .instrument {
                            Text(RuntimeModelOption.effortTitle(effort)).tracking(0.1).frame(maxWidth: .infinity)
                        } else {
                            Text(RuntimeModelOption.effortTitle(effort)).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(NotchPillButtonStyle(small: true, selected: selected))
                    .accessibilityLabel("Reasoning effort: \(effort)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    /// `index` numbers the row in Instrument's chooser.
    private func choiceRow(index: Int, title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                switch PanelTheme.current {
                case .refined:
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if let detail { Text(detail).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).lineLimit(1).truncationMode(.middle) }
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                case .tahoe:
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.accent) }
                    }
                    .padding(.horizontal, 9).frame(height: 30)
                case .instrument:
                    HStack(spacing: 9) {
                        Text(String(format: "%02d", index)).font(CompanionStyle.mono(10)).foregroundStyle(CompanionStyle.faint)
                            .accessibilityHidden(true)
                        Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(CompanionStyle.text)
                            .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if let detail { Text(detail).font(CompanionStyle.mono(10)).foregroundStyle(CompanionStyle.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer(minLength: 0)
                        if selected { LED(color: CompanionStyle.text, size: 6) }
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(NotchRowButtonStyle(selected: selected, cornerRadius: PanelTheme.pick(8, 7, CompanionStyle.radius)))
        .help([title, detail].compactMap { $0 }.joined(separator: " · "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RuntimeDefaultModelView: View {
    @ObservedObject var model: AppModel
    var runtime: RuntimeKind

    var body: some View {
        let key = ModelCatalogKey(route: RuntimeRoute(runtime: runtime), cwd: model.workspacePath)
        let catalog = model.modelCatalogs[key]
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    switch PanelTheme.current {
                    case .refined: Text("Default model").font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                    case .tahoe: Text("Default model").font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                    case .instrument: Text("Default model").microLabel(9.5).foregroundStyle(CompanionStyle.faint)
                    }
                    let value = Text(catalog.flatMap { $0.defaultModel.map($0.title(for:)) } ?? (model.loadingModelCatalogs.contains(key) ? "Loading…" : "Not reported"))
                        .font(.system(size: 12, weight: .medium))
                    Group {
                        if PanelTheme.current == .refined { value.foregroundStyle(CompanionStyle.text) } else { value }
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                QuietIconButton(symbol: "arrow.clockwise", label: "Refresh \(runtime.title) models", size: 22) {
                    Task { await model.loadModels(for: key, refresh: true) }
                }.disabled(model.loadingModelCatalogs.contains(key))
            }
            if let provider = catalog?.defaultModel?.provider { Text("Provider · \(provider)") }
            if let limit = catalog?.configuredContextWindow { Text("Configured context limit · \(limit.formatted()) tokens") }
            if let error = model.modelCatalogErrors[key] {
                Text(error).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
            }
            Text(runtime == .codex ? "Inherited for new sessions in your default folder. Project settings can change this."
                 : "Inherited from your existing \(runtime.title) profile.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 10.5), .system(size: 11)))
        .foregroundStyle(PanelTheme.current == .refined ? CompanionStyle.tertiary : CompanionStyle.secondary)
        .padding(.horizontal, PanelTheme.pick(14, 12, 12)).padding(.bottom, 12)
        .task(id: key) { if model.connectionStatus(for: runtime).connected { await model.loadModels(for: key) } }
    }
}

/// Instrument's model label: tracked SF Mono capitals.
private struct InstrumentMicroLabel: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.microLabel(10, tracking: 0.6) } else { content }
    }
}

private extension View {
    /// Refined's quiet toolbar control under the field; a text button elsewhere.
    @ViewBuilder func sessionControlStyle() -> some View {
        if PanelTheme.current == .refined { buttonStyle(NotchToolbarButtonStyle(height: 22, weight: .regular)) }
        else { buttonStyle(NotchTextButtonStyle()) }
    }

    /// The chooser's floating surface; `cornerRadius` applies to Tahoe only.
    @ViewBuilder func popupSurface(cornerRadius: CGFloat = 14) -> some View {
        if PanelTheme.current == .instrument { instrumentPopup() }
        else { notchPopover(cornerRadius: cornerRadius) }
    }
}

extension View {
    /// Instrument: the floating chooser chrome, an opaque black plate on a hairline, cast above the panel.
    func instrumentPopup() -> some View {
        let shape = RoundedRectangle(cornerRadius: CompanionStyle.cardRadius, style: .continuous)
        return background(Color(white: 0.045), in: shape)
            .overlay(shape.strokeBorder(CompanionStyle.ruleStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.6), radius: 14, x: 0, y: 6)
    }
}
