import SwiftUI
import AppKit

struct ComposerView: View {
    @ObservedObject var model: AppModel
    var focused: FocusState<Bool>.Binding
    var isCompact = true
    /// Refined: secondary pages name the session the message goes to. The
    /// other designs render the destination row outside the composer.
    var showsTitle = false
    @State private var editorHeight: CGFloat = ComposerTextView.minimumHeight
    @State private var submissionNotice: String?
    @Environment(\.notchBodyStyle) private var bodyStyle

    private var busy: Bool { model.current?.isBusy == true }
    private var runtimeTitle: String { (model.current?.runtime ?? model.defaultRuntime).title }
    private var checksLastSend: Bool { model.current?.pendingSubmission != nil }
    private var canSend: Bool {
        (checksLastSend || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !model.submitting && model.canAttemptSend && !busy
            && !model.currentDraftNeedsSetup
    }
    private var hint: String? {
        submissionNotice ?? (checksLastSend ? "Check the last send before sending another message." : nil)
    }
    private var busyHint: String { model.current?.busyInputHint ?? "⌘↩ to queue for later" }
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
            if let session = model.current, session.queuedSends.contains(where: \.isUserMessage) {
                let queued = session.queuedSends.filter(\.isUserMessage)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(queued, id: \.id) { send in
                            HStack(spacing: 6) {
                                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                Text("\(send.paused == true ? "Paused" : "Queued"): \(send.text)")
                                    .lineLimit(1).help(send.text + (send.attachments?.isEmpty == false ? "\nFiles: " + send.attachments!.map(\.name).joined(separator: ", ") : ""))
                                Spacer(minLength: 0)
                                QuietIconButton(symbol: "xmark", label: "Cancel queued message") { model.cancelQueuedSend(send.id) }
                                    .disabled(model.isSubmitting(session.id))
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
            switch PanelTheme.current {
            case .refined: refinedField
            case .tahoe, .instrument: inlineField
            }
            // Session settings sit in their own row under the field, as in other agent harnesses.
            if (!isCompact || model.page == .session) && (model.showModelPicker || model.showContextUsage || model.showPermissionModes) {
                switch PanelTheme.current {
                case .refined: ModelControlsView(model: model).padding(.leading, 6).padding(.trailing, 10)
                case .tahoe: ModelControlsView(model: model).padding(.horizontal, 10)
                case .instrument: ModelControlsView(model: model).padding(.horizontal, 4)
                }
            }
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, refined ? 14 : 5)
            }
        }
        .onChange(of: model.currentID) { _, _ in submissionNotice = nil }
        .onChange(of: busy) { _, _ in submissionNotice = nil }
    }

    /// Refined: one field, files and the editor on top, a toolbar along its
    /// bottom edge (attach, where the message goes, Send), all on one inset.
    private var refinedField: some View {
        let shape = RoundedRectangle(cornerRadius: CompanionStyle.Radius.field, style: .continuous)
        let lit = focused.wrappedValue
        return VStack(alignment: .leading, spacing: 0) {
            if model.current?.attachments.isEmpty == false {
                AttachmentStrip(model: model).padding(.horizontal, 10).padding(.top, 10)
            }
            editor
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                .textCursor()
            HStack(spacing: 2) {
                QuietIconButton(symbol: "plus", label: "Attach files") { model.pickFiles(showPanel: isCompact) }
                // The notch remembers the window in front when it opened; the full window is in front itself.
                if isCompact && model.showSnapShot && model.current?.capabilities.images == true {
                    QuietIconButton(symbol: "camera.viewfinder",
                                    label: model.snapShotSource.map { "Attach a picture of \($0.name)" } ?? "Open the notch from a window to attach it") {
                        Task { await model.attachSnapShot() }
                    }
                    .disabled(model.snapShotSource == nil)
                }
                ComposerDestinationView(model: model, showsTitle: showsTitle)
                Spacer(minLength: 8)
                sendButton
            }
            .padding(.horizontal, 7).padding(.bottom, 7)
        }
        .background(bodyStyle == nil ? CompanionStyle.surface.opacity(0.8) : Color.white.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(lit ? 0.24 : 0.13), Color.white.opacity(lit ? 0.14 : 0.06)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        .animation(.easeOut(duration: 0.15), value: lit)
    }

    /// Tahoe and Instrument: attach keys, the editor and Send on one row.
    private var inlineField: some View {
        let instrument = PanelTheme.current == .instrument
        // Tahoe: a single line is a capsule, the 28-point buttons 5 points inside
        // a 38-point field so their circles share its corner centers.
        // Instrument: a square-cornered inset readout; the 28-point keys sit 5 points inside it.
        let shape = RoundedRectangle(cornerRadius: instrument ? CompanionStyle.cardRadius : 19, style: .continuous)
        // Instrument: attach keys stay on the first line with the prompt glyph; Send stays at the last.
        let firstLine = instrument ? max(0, editorHeight - ComposerTextView.minimumHeight) : 0
        let row = HStack(alignment: .bottom, spacing: 6) {
            QuietIconButton(symbol: "plus", label: "Attach files") { model.pickFiles(showPanel: isCompact) }
                .padding(.bottom, 5)
                .alignmentGuide(.bottom) { $0[.bottom] + firstLine }
            // The notch remembers the window in front when it opened; the full window is in front itself.
            if isCompact && model.showSnapShot && model.current?.capabilities.images == true {
                QuietIconButton(symbol: "camera.viewfinder",
                                label: model.snapShotSource.map { "Attach a picture of \($0.name)" } ?? "Open the notch from a window to attach it") {
                    Task { await model.attachSnapShot() }
                }
                .disabled(model.snapShotSource == nil)
                .padding(.bottom, 5).padding(.leading, -6)
                .alignmentGuide(.bottom) { $0[.bottom] + firstLine }
            }
            if instrument {
                HStack(alignment: .top, spacing: 8) {
                    // The prompt glyph sits on the first line: it is yours to write.
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .heavy))
                        .foregroundStyle(focused.wrappedValue ? CompanionStyle.signal : CompanionStyle.secondary)
                        .frame(width: 10, height: ComposerTextView.minimumHeight).accessibilityHidden(true)
                    editor.textCursor()
                }
                .padding(.vertical, 8)
            } else {
                editor
                    .padding(.vertical, 8)
                    .textCursor()
            }
            sendButton
                .padding(.bottom, 5)
        }
        .padding(.horizontal, 5)
        return Group {
            if instrument {
                row
                    .background(CompanionStyle.inset, in: shape)
                    .overlay(shape.strokeBorder(focused.wrappedValue ? Color.white.opacity(0.34) : CompanionStyle.ruleStrong, lineWidth: 0.75))
            } else {
                row
                    // Glass over the black body reads as a hole; a gray fill makes it a field.
                    .background(bodyStyle == .black ? CompanionStyle.fill : .clear, in: shape)
                    .notchControlBackground(shape, fallback: CompanionStyle.surface)
                    // A focused field wears the accent ring, as native text fields do.
                    .overlay(shape.strokeBorder(focused.wrappedValue ? AnyShapeStyle(CompanionStyle.accent.opacity(0.7)) : AnyShapeStyle(GlassEdge.gradient(0.16)),
                                                lineWidth: focused.wrappedValue ? 1.5 : 0.5))
            }
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
                                 accessibilityHint: busy ? busyHint : hint ?? "", onSubmit: { submit() }, onQueue: { submit(queue: true) })
                .id(model.currentID)
                .frame(height: editorHeight)
          }
          if busy && !model.draft.isEmpty {
              Text(busyHint).font(.system(size: 11)).foregroundStyle(CompanionStyle.secondary)
                  .fixedSize(horizontal: false, vertical: true)
          }
        }
    }

    /// Send turns into Stop in place while the session works; Instrument lights
    /// Stop as a white key instead of the signal.
    private var sendButton: some View {
        let stopKey = PanelTheme.current == .instrument && busy
        return Button {
            if busy { Task { await model.interrupt() } } else { submit() }
        } label: {
            if model.submitting && !busy { ProgressView().controlSize(.mini) }
            else {
                Image(systemName: busy ? "stop.fill" : checksLastSend ? "magnifyingglass" : "arrow.up")
                    .font(.system(size: busy ? 10 : PanelTheme.pick(13, 13.5, 13), weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(model.reducedMotion ? nil : .smooth(duration: 0.25), value: busy)
            }
        }
        .buttonStyle(NotchIconButtonStyle(size: 28, selected: stopKey, prominent: !stopKey))
        .disabled(!busy && !canSend)
        .help(busy ? "Stop this session; keep your draft"
              : checksLastSend ? "Check the last send in \(runtimeTitle) history" : "Send · Return or Command-Return")
        .accessibilityLabel(busy ? "Stop this session" : checksLastSend ? "Check last send" : "Send message")
    }

    private func submit(queue: Bool = false) {
        if model.submitting { submissionNotice = "Sending your message…"; return }
        if model.currentDraftNeedsSetup { submissionNotice = "Connect a harness in Settings before sending."; return }
        if !checksLastSend && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submissionNotice = "Add a message before sending."; return
        }
        if !model.canAttemptSend { submissionNotice = "Reconnect to \(runtimeTitle) before sending."; return }
        if busy && !queue && model.current?.canSteer != true { submissionNotice = "Use Command–Return to queue this message."; return }
        submissionNotice = nil
        let id = model.currentID
        Task { guard model.currentID == id else { return }; await model.send(queue: queue) }
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        editor.onFocusChanged = { [weak coordinator = context.coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused.wrappedValue = value }
        }
        editor.onLayoutChanged = { [weak coordinator = context.coordinator] in coordinator?.updateHeight() }
        context.coordinator.editor = editor
        scroll.documentView = editor
        editor.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityHelp(accessibilityHint)
        // Do not destroy marked text while an input method is composing.
        if !editor.hasMarkedText(), editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
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
        init(_ parent: NativeComposerEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            parent.text = editor.string
            updateHeight()
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
    var onFocusChanged: ((Bool) -> Void)?
    var onLayoutChanged: (() -> Void)?

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
