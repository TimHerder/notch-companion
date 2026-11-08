import SwiftUI
import AppKit

struct ComposerView: View {
    @ObservedObject var model: AppModel
    var focused: FocusState<Bool>.Binding
    var isCompact = true
    /// Secondary pages name the session the message goes to, in the field's bar.
    var showsTitle = false
    @State private var editorHeight: CGFloat = ComposerTextView.minimumHeight
    @State private var submissionNotice: String?
    @Environment(\.notchBodyStyle) private var bodyStyle

    private var busy: Bool { model.current?.isBusy == true }
    private var runtimeTitle: String { (model.current?.runtime ?? model.defaultRuntime).title }
    private var checksLastSend: Bool { model.current?.pendingSubmission != nil }
    private var canSend: Bool {
        (checksLastSend || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.dictatingSessionID == model.currentID)
            && !model.submitting && model.canAttemptSend && !busy
            && !model.currentDraftNeedsSetup
    }
    private var hint: String? {
        submissionNotice ?? (checksLastSend ? "Check the last send before sending another message." : nil)
    }
    private var busyHint: String { model.current?.busyInputHint ?? "⌘↩ to queue for later" }
    /// While working, a typed draft gets a key of its own (steer or queue) and Stop steps aside.
    private var takesDraftWhileBusy: Bool {
        busy && !checksLastSend && model.current?.nativeActivityUnverified == nil
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var queued: [QueuedSend] { model.current?.queuedSends.filter(\.isUserMessage) ?? [] }
    private var draftBinding: Binding<String> {
        let sessionID = model.currentID
        return Binding(get: { model.sessions.first { $0.id == sessionID }?.draft ?? "" },
                       set: { value in
            // A late native edit from the previous session must not change the
            // newly selected session's draft.
            guard model.currentID == sessionID else { return }
            model.draft = value
            submissionNotice = nil
        })
    }

    var body: some View {
        let refined = PanelTheme.current == .refined
        VStack(alignment: .leading, spacing: refined ? 6 : 5) {
            if let session = model.current, !queued.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(queued, id: \.id) { send in
                            HStack(spacing: 6) {
                                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                Text("\(send.paused == true ? "Paused" : "Queued"): \(send.text)")
                                    .lineLimit(1).help(send.text + (send.attachments?.isEmpty == false ? "\nFiles: " + send.attachments!.map(\.name).joined(separator: ", ") : ""))
                                Spacer(minLength: 0)
                                queueActions(send, session: session)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(min(queued.count, 3)) * 33)
                .font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                if queued.contains(where: { $0.paused == true }) {
                    Button("Resume queued messages") { model.resumeQueuedSends() }.buttonStyle(NotchPillButtonStyle(small: true))
                }
            }
            if let reason = model.current?.nativeActivityUnverified {
                Text(reason).font(.system(size: 11)).foregroundStyle(CompanionStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
                if let nativeID = model.current?.storedID {
                    Button("Copy native session ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(nativeID, forType: .string)
                    }.buttonStyle(NotchPillButtonStyle(small: true))
                }
            }
            if let session = model.current, [.pi, .deepseek, .antigravity, .cursor].contains(session.runtime), session.messages.isEmpty {
                Text(session.runtimeInfo?.capabilityNote ?? session.runtime.capabilityNote)
                    .font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(refined ? .horizontal : .bottom, refined ? 4 : 3)
            }
            if model.snapShotNeedsPermission && isCompact {
                let notice = HStack(spacing: 8) {
                    Text("Allow Screen Recording for Notch Companion to attach windows.")
                        .font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Settings") { model.openExternally(SnapShot.privacySettings) }.buttonStyle(NotchPillButtonStyle(small: true))
                }
                if refined {
                    notice.foregroundStyle(CompanionStyle.secondary).panelNotice(CompanionStyle.secondary).padding(.bottom, -6)
                } else {
                    notice
                }
            }
            field
            DictationStatus(model: model, dictation: model.dictation)
            // Session settings sit in their own row under the field: permissions at
            // the left, the model and context gauge at the right.
            if (!isCompact || model.page == .session) && (model.showModelPicker || model.showContextUsage || model.showPermissionModes) {
                ModelControlsView(model: model).padding(.horizontal, PanelTheme.pick(6, 8, 2)).padding(.top, -2)
            }
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                    // On the editor's inset, now that every design shares the field.
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14)
            }
        }
        .onChange(of: model.currentID) { _, _ in submissionNotice = nil }
        .onChange(of: busy) { _, _ in submissionNotice = nil }
    }

    /// Plan ready is the field's own first row, above a hairline: the plan's
    /// name, Keep planning as quiet text (hidden for this turn) and Implement
    /// (leaves Plan and asks for the work). Refined keeps its sage for Send, so
    /// Implement is the neutral pill there and the accent key elsewhere
    /// (Instrument's lit white key, like Send).
    private func planHeader(_ session: CompanionSession) -> some View {
        let theme = PanelTheme.current
        let refined = theme == .refined
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                planName(session.planReadyTitle)
                Spacer(minLength: 8)
                Button("Keep planning") { model.keepPlanning(session.id) }
                    .buttonStyle(NotchToolbarButtonStyle(height: theme == .instrument ? 22 : 24))
                    .fixedSize() // A long plan name truncates first.
                    .help("Stay in Plan; this returns with the next plan")
                Button("Implement") { Task { await model.implementPlan(session.id) } }
                    .buttonStyle(NotchPillButtonStyle(prominent: !refined, small: !refined, height: refined ? 24 : nil))
                    .fixedSize()
                    .disabled(model.submitting || !model.canAttemptSend)
                    .help("Switch to \(session.prePlanPermissionMode?.title ?? "Default permissions") and send “\(AppModel.implementPlanMessage)”")
            }
            // Six points in: the 24-point capsule is concentric with the field's corner.
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            Rectangle().fill(PanelTheme.pick(CompanionStyle.hairline, CompanionStyle.separator, CompanionStyle.rule))
                .frame(height: 0.5).padding(.horizontal, theme == .instrument ? 0 : 14)
        }
    }

    /// `Plan · Ready for review`, from the answer's first heading; Instrument
    /// puts a lamp before it.
    private func planName(_ title: String?) -> some View {
        HStack(spacing: 5) {
            if PanelTheme.current == .instrument { LED(color: CompanionStyle.text, size: 5).padding(.trailing, 1) }
            Text(title == nil ? "Plan ready" : "Plan").fontWeight(title == nil ? .medium : .regular)
                .foregroundStyle(title == nil ? CompanionStyle.text : CompanionStyle.secondary)
            if let title {
                Text("·").foregroundStyle(CompanionStyle.faint)
                Text(title).foregroundStyle(CompanionStyle.text)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "Plan ready: \($0)" } ?? "Plan ready")
    }

    /// Steer now (when the running turn can take it), Edit (into an empty
    /// composer) and Cancel.
    @ViewBuilder private func queueActions(_ send: QueuedSend, session: CompanionSession) -> some View {
        let sending = model.isSubmitting(session.id)
        if session.canSteer(send.attachments ?? []) {
            QuietIconButton(symbol: "arrow.turn.up.right", label: "Steer now") { Task { await model.steerQueuedSend(send.id) } }
                .disabled(sending || model.submitting)
        }
        let free = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.attachments.isEmpty
        Button { model.editQueuedSend(send.id) } label: { Image(systemName: "pencil") }
            .buttonStyle(NotchIconButtonStyle(size: 28))
            .disabled(!free || sending)
            .help(free ? "Edit queued message" : "Send or clear your draft first")
            .accessibilityLabel("Edit queued message")
            .accessibilityHint(free ? "" : "Send or clear your draft first")
        QuietIconButton(symbol: "xmark", label: "Cancel queued message") { model.cancelQueuedSend(send.id) }
            .disabled(sending)
    }

    /// One field in every design: a ready plan's row, files and the editor on
    /// top, one bar along its bottom edge with attach, SnapShot, where the
    /// message goes and Send.
    private var field: some View {
        let theme = PanelTheme.current
        let lit = focused.wrappedValue
        return VStack(alignment: .leading, spacing: 0) {
            if let session = model.current, session.planReadyTurnID != nil { planHeader(session) }
            if model.current?.attachments.isEmpty == false {
                AttachmentStrip(model: model).padding(.horizontal, 10).padding(.top, 10)
                    .transition(model.reducedMotion ? .opacity : .scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
            }
            Group {
                if theme == .instrument {
                    HStack(alignment: .top, spacing: 8) {
                        // The prompt glyph sits on the first line: it is yours to write.
                        Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(lit ? CompanionStyle.signal : CompanionStyle.secondary)
                            .frame(width: 10, height: ComposerTextView.minimumHeight).accessibilityHidden(true)
                        editor
                    }
                } else {
                    editor
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
            .textCursor()
            bar.padding(.horizontal, 7).padding(.bottom, 7)
        }
        .background { fieldSurface(lit: lit) }
        .animation(.easeOut(duration: 0.15), value: lit)
    }

    /// `[+] [SnapShot] [harness, folder, session] … [Send]`. When it is tight the
    /// session name truncates first, then the harness label and folder; Send keeps its size.
    private var bar: some View {
        HStack(spacing: 2) {
            QuietIconButton(symbol: "plus", label: "Attach files") { model.pickFiles(showPanel: isCompact) }
                // A file dropped on the notch glides into this button, as laid out on the session page.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(UnifiedNotchView.coordinateSpace)) } action: { frame in
                    if isCompact, model.page == .session, let geometry = model.geometry { model.attachButtonFrame = (frame, geometry) }
                }
            // The notch remembers the window in front when it opened; the full window is in front itself.
            if isCompact && model.showSnapShot && model.current?.capabilities.images == true {
                QuietIconButton(symbol: "camera.viewfinder",
                                label: model.snapShotSource.map { "Attach a picture of \($0.name)" } ?? "Open the notch from a window to attach it") {
                    Task { await model.attachSnapShot() }
                }
                .disabled(model.snapShotSource == nil)
            }
            if model.showDictation && Dictation.isAvailable {
                DictationButton(model: model, dictation: model.dictation, fromNotch: isCompact)
            }
            ComposerDestinationView(model: model, showsTitle: showsTitle).layoutPriority(1)
            Spacer(minLength: 8)
            if takesDraftWhileBusy {
                Button { Task { await model.interrupt() } } label: { Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(NotchIconButtonStyle(size: 28))
                    .help("Stop this session; keep your draft").accessibilityLabel("Stop this session")
            }
            sendButton
        }
    }

    /// Refined: a solid white-6% field. Tahoe: Apple's gray fill under Liquid
    /// Glass (on Black) with an accent ring when focused. Instrument: a dark
    /// square-cornered inset readout on a hairline.
    @ViewBuilder private func fieldSurface(lit: Bool) -> some View {
        switch PanelTheme.current {
        case .refined:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.Radius.field, style: .continuous)
            shape.fill(bodyStyle == nil ? CompanionStyle.surface.opacity(0.8) : Color.white.opacity(0.06))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(lit ? 0.24 : 0.13), Color.white.opacity(lit ? 0.14 : 0.06)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        case .tahoe:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.Radius.field, style: .continuous)
            // Glass over the black body reads as a hole; a gray fill makes it a field.
            shape.fill(bodyStyle == .black ? CompanionStyle.fill : .clear)
                .notchControlBackground(shape, fallback: CompanionStyle.surface)
                // A focused field wears the accent ring, as native text fields do.
                .overlay(shape.strokeBorder(lit ? AnyShapeStyle(CompanionStyle.accent.opacity(0.7)) : AnyShapeStyle(GlassEdge.gradient(0.16)),
                                            lineWidth: lit ? 1.5 : 0.5))
        case .instrument:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.cardRadius, style: .continuous)
            shape.fill(CompanionStyle.inset)
                .overlay(shape.strokeBorder(lit ? Color.white.opacity(0.34) : CompanionStyle.ruleStrong, lineWidth: 0.75))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 3) {
          ZStack(alignment: .topLeading) {
            if model.draft.isEmpty {
                Text(busy ? busyHint : model.currentDraftNeedsSetup ? "Write a message…" : "Ask \(runtimeTitle)…")
                    .font(.system(size: 13))
                    .foregroundStyle(CompanionStyle.secondary)
                    .padding(.top, 3).allowsHitTesting(false).accessibilityHidden(true)
            }
            NativeComposerEditor(text: draftBinding, focused: focused, height: $editorHeight,
                                 accessibilityLabel: "Message \(runtimeTitle)",
                                 accessibilityHint: busy ? busyHint : hint ?? "", onSubmit: { submit() }, onQueue: { submit(queue: true) },
                                 onEditQueued: { queued.last.map { model.editQueuedSend($0.id) } ?? false },
                                 onSteerQueued: {
                                     guard let first = queued.first, model.current?.canSteer(first.attachments ?? []) == true else { return false }
                                     Task { await model.steerQueuedSend(first.id) }
                                     return true
                                 },
                                 onComposingChanged: { [id = model.currentID] in if let id { model.setComposing($0, in: id) } })
                .id(model.currentID)
                .frame(height: editorHeight)
          }
          if busy && !model.draft.isEmpty {
              Text(busyHint).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                  .fixedSize(horizontal: false, vertical: true)
          }
        }
    }

    /// Send turns into Stop in place while the session works (Instrument lights
    /// both as a white key). A draft typed meanwhile turns it into the key for
    /// what Return does: Steer message or Queue message.
    private var sendButton: some View {
        let draftKey = takesDraftWhileBusy
        let stops = busy && !draftKey
        let steers = model.current?.canSteer == true
        let queues = draftKey && !steers
        let symbol = stops ? "stop.fill" : draftKey ? (steers ? "arrow.turn.up.right" : "text.append")
            : checksLastSend ? "magnifyingglass" : "arrow.up"
        return Button {
            if stops { Task { await model.interrupt() } } else { submit(queue: queues) }
        } label: {
            if model.submitting && !busy { ProgressView().controlSize(.mini) }
            else {
                Image(systemName: symbol)
                    .font(.system(size: stops ? 10 : queues ? 11.5 : PanelTheme.pick(13, 13.5, 13), weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(model.reducedMotion ? nil : .smooth(duration: 0.25), value: symbol)
            }
        }
        .buttonStyle(NotchIconButtonStyle(size: 28, prominent: true))
        .disabled(!busy && !canSend)
        .help(stops ? "Stop this session; keep your draft"
              : draftKey ? (steers ? "Steer message · Return" : "Queue message · Command-Return")
              : checksLastSend ? "Check the last send in \(runtimeTitle) history" : "Send · Return or Command-Return")
        .accessibilityLabel(stops ? "Stop this session" : draftKey ? (model.current?.busySendLabel ?? "Queue message")
                            : checksLastSend ? "Check last send" : "Send message")
    }

    private func submit(queue: Bool = false) {
        if model.submitting { submissionNotice = "Sending your message…"; return }
        if model.currentDraftNeedsSetup { submissionNotice = "Connect a harness in Settings before sending."; return }
        let id = model.currentID
        if model.dictation.isActive, model.dictation.sessionID == id {
            // Parakeet writes only when it stops, macOS at each pause: stop, then send the last words too.
            submissionNotice = "Adding your last words…"
            model.dictation.stop()
            Task {
                await model.dictation.finished()
                guard model.currentID == id else { return }
                submissionNotice = nil
                // A run that ended in a failure may have lost words; leave the draft to review.
                guard model.dictation.failure == nil else { return }
                submit(queue: queue)
            }
            return
        }
        if !checksLastSend && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submissionNotice = "Add a message before sending."; return
        }
        if !model.canAttemptSend { submissionNotice = "Reconnect to \(runtimeTitle) before sending."; return }
        if busy && !queue && model.current?.canSteer != true { submissionNotice = "Use Command–Return to queue this message."; return }
        submissionNotice = nil
        Task { guard model.currentID == id else { return }; await model.send(queue: queue) }
    }
}

/// The bar's microphone: listens into this session's draft, and stops any
/// dictation that is running.
private struct DictationButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: Dictation
    var fromNotch: Bool

    var body: some View {
        let here = dictation.sessionID == model.currentID
        // Dictation into another session still shows here, so it can be stopped from any composer.
        let listening = dictation.phase == .listening || (dictation.isActive && !here)
        Button { model.toggleDictation(fromNotch: fromNotch) } label: {
            if case .preparing = dictation.phase, here { ProgressView().controlSize(.mini) }
            else {
                Image(systemName: listening ? "waveform" : "mic")
                    .foregroundStyle(listening ? CompanionStyle.error : CompanionStyle.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: listening && !model.reducedMotion)
            }
        }
        .buttonStyle(NotchIconButtonStyle(size: 28))
        .disabled(dictation.phase == .finishing || model.current == nil)
        .help(dictation.isActive ? "Stop dictation" : "Dictate" + (model.dictateShortcut.map { " · \($0.spoken) starts a new session" } ?? ""))
        .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate")
    }
}

/// Under the field while dictating here: what is happening and the words not yet final.
private struct DictationStatus: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: Dictation

    var body: some View {
        if dictation.sessionID == model.currentID, dictation.isActive {
            HStack(spacing: 6) {
                Circle().fill(dictation.phase == .listening ? CompanionStyle.error : CompanionStyle.faint).frame(width: 6, height: 6)
                Text(status).foregroundStyle(CompanionStyle.secondary)
                if !dictation.volatileText.isEmpty {
                    Text(dictation.volatileText).foregroundStyle(CompanionStyle.text.opacity(0.75))
                        .truncationMode(.head)
                }
            }
            .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 14)
            .accessibilityElement(children: .combine)
        } else if let failure = dictation.failure {
            HStack(spacing: 8) {
                Text(failure).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if dictation.needsMicrophonePermission {
                    Button("Open Settings") { model.openExternally(Dictation.microphoneSettings) }.buttonStyle(NotchPillButtonStyle(small: true))
                }
                QuietIconButton(symbol: "xmark", label: "Dismiss", size: 22) { dictation.failure = nil }
            }
            .padding(.horizontal, 14)
        }
    }

    private var status: String {
        switch dictation.phase {
        case .preparing(let step): step
        case .listening: dictation.volatileText.isEmpty ? "Listening…" : "Listening:"
        case .finishing: "Finishing…"
        case .idle: ""
        }
    }
}

/// TextKit supplies normal selection, undo, input methods and internal scrolling.
/// Only Return handling and the bounded height differ from a native editor.
struct NativeComposerEditor: NSViewRepresentable {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    @Binding var height: CGFloat
    var accessibilityLabel: String
    var accessibilityHint: String
    var onSubmit: () -> Void
    var onQueue: (() -> Void)? = nil
    /// In an empty composer: Option–Up edits the newest queued message, Command–Shift–Return
    /// steers the oldest. Each returns whether it acted.
    var onEditQueued: (() -> Bool)? = nil
    var onSteerQueued: (() -> Bool)? = nil
    /// An input method's composition began or ended; dictation waits for it.
    var onComposingChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if coordinator.composing { coordinator.parent.onComposingChanged?(false) }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = ComposerTextView(frame: .zero)
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = NSColor(CompanionStyle.text)
        switch PanelTheme.current {
        case .refined:
            editor.insertionPointColor = NSColor(CompanionStyle.accent)
            editor.selectedTextAttributes = [.backgroundColor: NSColor(CompanionStyle.accent).withAlphaComponent(0.3)]
        case .tahoe:
            editor.insertionPointColor = .controlAccentColor
            editor.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        case .instrument:
            editor.insertionPointColor = NSColor(CompanionStyle.signal)
            editor.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.24)]
        }
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 0, height: 3)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.delegate = context.coordinator
        editor.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        editor.onQueue = { [weak coordinator = context.coordinator] in
            guard let parent = coordinator?.parent else { return }
            (parent.onQueue ?? parent.onSubmit)()
        }
        editor.onEditQueued = { [weak coordinator = context.coordinator] in coordinator?.parent.onEditQueued?() ?? false }
        editor.onSteerQueued = { [weak coordinator = context.coordinator] in coordinator?.parent.onSteerQueued?() ?? false }
        editor.onFocusChanged = { [weak coordinator = context.coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused.wrappedValue = value }
        }
        editor.onLayoutChanged = { [weak coordinator = context.coordinator] in coordinator?.updateHeight() }
        editor.onMarkedTextChanged = { [weak coordinator = context.coordinator] in coordinator?.reportComposing() }
        context.coordinator.editor = editor
        context.coordinator.synced = text
        scroll.documentView = editor
        editor.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityHelp(accessibilityHint)
        context.coordinator.sync(to: text)
        context.coordinator.updateHeight()
        if focused.wrappedValue, editor.window?.firstResponder !== editor {
            DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                guard let editor, coordinator?.parent.focused.wrappedValue == true else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerEditor
        weak var editor: ComposerTextView?
        private var heightUpdatePending = false
        /// The draft as the editor last wrote or took it. A draft that differs
        /// from it was changed on purpose elsewhere (Send, a queued Edit).
        var synced = ""
        private(set) var composing = false
        /// Applying the draft; the editor's own change notifications are echoes.
        private var applying = false
        init(_ parent: NativeComposerEditor) { self.parent = parent }

        /// Takes a changed draft into the editor. While an input method composes,
        /// only a deliberate change (not a stale echo of the editor's own text)
        /// replaces it, and the composition is dropped. Dictation never arrives
        /// meanwhile: it waits for `onComposingChanged(false)`.
        func sync(to text: String) {
            guard let editor, editor.string != text else { return }
            let discarding = editor.hasMarkedText()
            if discarding { guard text != synced else { return } }
            applying = true
            defer { applying = false }
            if discarding {
                editor.inputContext?.discardMarkedText()
                editor.unmarkText()
            }
            // Text restored into an empty composer (a queued message's Edit), or over a
            // dropped composition, keeps typing after it.
            let location = editor.string.isEmpty || discarding ? (text as NSString).length
                : min(editor.selectedRange().location, (text as NSString).length)
            editor.string = text
            editor.setSelectedRange(NSRange(location: location, length: 0))
            synced = text
            reportComposing()
        }

        func textDidChange(_ notification: Notification) {
            guard let editor, !applying else { return }
            synced = editor.string
            parent.text = editor.string
            reportComposing()
            updateHeight()
        }

        func reportComposing() {
            let now = editor?.hasMarkedText() ?? false
            guard now != composing else { return }
            composing = now
            parent.onComposingChanged?(now)
        }

        func updateHeight() {
            guard !heightUpdatePending else { return }
            heightUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightUpdatePending = false
                guard let editor = self.editor else { return }
                let measured = editor.boundedHeight
                if abs(self.parent.height - measured) > 0.5 { self.parent.height = measured }
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    static let minimumHeight: CGFloat = 22
    static let maximumLines = 4
    var onSubmit: (() -> Void)?
    var onQueue: (() -> Void)?
    var onEditQueued: (() -> Bool)?
    var onSteerQueued: (() -> Bool)?
    var onFocusChanged: ((Bool) -> Void)?
    var onLayoutChanged: (() -> Void)?
    /// Marked text changes post no text-change notification of their own.
    var onMarkedTextChanged: (() -> Void)?

    var boundedHeight: CGFloat {
        guard let layoutManager, let textContainer else { return Self.minimumHeight }
        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 13))
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let lastLineHeight = string.hasSuffix("\n") ? lineHeight : 0
        let natural = max(lineHeight, usedHeight + lastLineHeight) + 2 * textContainerInset.height
        return ceil(min(max(Self.minimumHeight, natural), lineHeight * CGFloat(Self.maximumLines) + 2 * textContainerInset.height))
    }

    override func layout() { super.layout(); onLayoutChanged?() }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChanged?()
    }
    override func unmarkText() { super.unmarkText(); onMarkedTextChanged?() }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onMarkedTextChanged?()
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChanged?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChanged?(false) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Only an empty composer reaches the queue; otherwise these keys keep their usual meaning.
        if string.isEmpty, !hasMarkedText(),
           (event.keyCode == 126 && modifiers == .option && onEditQueued?() == true)
            || ([UInt16(36), UInt16(76)].contains(event.keyCode) && modifiers == [.command, .shift] && onSteerQueued?() == true) { return }
        if [UInt16(36), UInt16(76)].contains(event.keyCode), !hasMarkedText() {
            if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
                insertNewline(nil)
            } else if event.modifierFlags.contains(.command) {
                (onQueue ?? onSubmit)?()
            } else {
                onSubmit?()
            }
            return
        }
        // Escape stays in the responder chain for the host's existing dismissal.
        super.keyDown(with: event)
    }
}
