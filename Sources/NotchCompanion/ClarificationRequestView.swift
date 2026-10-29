import SwiftUI

struct RequestView: View {
    @ObservedObject var model: AppModel
    var request: PendingRequest
    var compact = false
    @State private var questionBatches: [String: [String]] = [:]

    private var batchKey: String { "\(request.sessionID):\(request.requestID ?? request.id)" }
    private var pendingQuestionIDs: [String] {
        model.requests.filter {
            $0.kind == .clarification && $0.sessionID == request.sessionID
                && ($0.requestID ?? $0.id) == (request.requestID ?? request.id)
        }.map(\.id)
    }
    private var progress: String? {
        let ids = questionBatches[batchKey] ?? pendingQuestionIDs
        guard request.kind == .clarification, ids.count > 1, let index = ids.firstIndex(of: request.id) else { return nil }
        return "Question \(index + 1) of \(ids.count)"
    }

    var body: some View {
        RequestAnswerForm(model: model, request: request, progress: progress, detailsCap: compact ? 132 : 150)
            // A new question or another session gets a distinct answer state.
            .id("\(request.sessionID):\(request.id)")
            .onAppear(perform: rememberQuestionBatch)
            .onChange(of: request.id) { _, _ in rememberQuestionBatch() }
            .onChange(of: pendingQuestionIDs) { _, _ in rememberQuestionBatch() }
    }

    private func rememberQuestionBatch() {
        var known = questionBatches[batchKey] ?? []
        for id in pendingQuestionIDs where !known.contains(id) { known.append(id) }
        questionBatches[batchKey] = known
    }
}

struct ClarificationAnswerState: Equatable {
    var selectedChoices: Set<String> = []
    var freeText = ""
    var usesFreeText = false

    mutating func choose(_ choice: String, multiple: Bool) {
        if multiple {
            if selectedChoices.contains(choice) { selectedChoices.remove(choice) }
            else { selectedChoices.insert(choice) }
        } else {
            selectedChoices = [choice]
            usesFreeText = false
        }
    }

    func answer(choices: [String], multiple: Bool) -> String {
        answers(choices: choices, multiple: multiple).joined(separator: ", ")
    }

    func answers(choices: [String], multiple: Bool) -> [String] {
        let custom = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if choices.isEmpty || (!multiple && usesFreeText) { return custom.isEmpty ? [] : [custom] }
        var selected = choices.filter { selectedChoices.contains($0) }
        if multiple, usesFreeText, !custom.isEmpty { selected.append(custom) }
        return selected
    }
}

/// Display only approval scopes offered by the runtime. Unknown/persistent
/// scopes never turn into an accidental one-time approval.
enum ApprovalAction: String, Identifiable, CaseIterable {
    case once, session, deny, cancel
    var id: Self { self }
    var title: String {
        switch self {
        case .once: return "Allow once"
        case .session: return "Allow this session"
        case .deny: return "Deny"
        case .cancel: return "Cancel turn"
        }
    }
    static func offered(in choices: [String]) -> [Self] {
        let actions = allCases.filter { choices.contains($0.rawValue) }
        return actions.isEmpty ? [.deny] : actions
    }
}

private struct RequestAnswerForm: View {
    @ObservedObject var model: AppModel
    var request: PendingRequest
    var progress: String?
    /// Tahoe: the most the details may take before they scroll; the card hugs anything shorter.
    var detailsCap: CGFloat
    @State private var draft = ClarificationAnswerState()
    @State private var submitting = false
    /// Refined and Tahoe measure the details so the card hugs short ones.
    @State private var detailsHeight = CGFloat.infinity

    /// Refined: the question scrolls past this height; shorter ones hug their content.
    private static let bodyCap: CGFloat = 132

    private var isSubmitting: Bool { submitting || model.isAnswering(request) }
    private var answer: String {
        answers.joined(separator: ", ")
    }
    private var answers: [String] {
        var permitted = draft
        if !request.allowsFreeText { permitted.usesFreeText = false; permitted.freeText = "" }
        return permitted.answers(choices: request.choices, multiple: request.multiSelect)
    }

    var body: some View {
        card {
            header
            details.disabled(isSubmitting)
            actions.controlSize(.small).disabled(isSubmitting)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.map { "\($0), \(request.title)" } ?? request.title)
    }

    @ViewBuilder private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch PanelTheme.current {
        case .refined:
            let shape = RoundedRectangle(cornerRadius: CompanionStyle.Radius.field, style: .continuous)
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(CompanionStyle.well, in: shape)
                .overlay(shape.strokeBorder(CompanionStyle.amber.opacity(0.28), lineWidth: 0.75))
        case .tahoe:
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
                .background(CompanionStyle.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(GlassEdge.gradient(0.14), lineWidth: 0.5))
        case .instrument:
            VStack(alignment: .leading, spacing: 9, content: content)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: request.kind == .approval ? nil : .infinity, alignment: .topLeading)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(CompanionStyle.signal).frame(width: 2) }
        }
    }

    @ViewBuilder private var header: some View {
        switch PanelTheme.current {
        case .refined:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: request.kind == .approval ? "hand.raised.fill" : "bubble.left.fill")
                    .font(.system(size: 12)).foregroundStyle(CompanionStyle.amber)
                    .accessibilityHidden(true)
                Text(request.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).layoutPriority(1)
                Spacer(minLength: 8)
                if let progress {
                    Text(progress).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).fixedSize()
                }
            }
        case .tahoe:
            HStack(alignment: .center, spacing: 10) {
                SettingsIcon(symbol: request.kind == .approval ? "hand.raised.fill" : "questionmark.bubble.fill", tint: .orange)
                Text(request.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).layoutPriority(1)
                Spacer(minLength: 6)
                if let progress {
                    Text(progress).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary).fixedSize()
                }
            }
        case .instrument:
            // Needs you: the signal lamp, the request in tracked capitals, a rule to the progress count.
            HStack(alignment: .center, spacing: 8) {
                LED(color: CompanionStyle.signal, pulsing: true, size: 6)
                Label(request.title, systemImage: request.kind == .approval ? "hand.raised" : "bubble.left")
                    .labelStyle(.titleOnly)
                    .microLabel(10.5, weight: .semibold, tracking: 0.9).foregroundStyle(CompanionStyle.signal)
                    .lineLimit(2).layoutPriority(1)
                Rectangle().fill(CompanionStyle.signal.opacity(0.35)).frame(height: 0.5)
                if let progress {
                    Text(progress).microLabel(9.5, tracking: 0.6).foregroundStyle(CompanionStyle.secondary).fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var details: some View {
        switch PanelTheme.current {
        case .refined:
            ScrollView {
                requestBody.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { detailsHeight = $0 }
            }
            .frame(height: min(detailsHeight, Self.bodyCap))
        case .tahoe:
            ScrollView {
                requestBody.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: min(detailsHeight, detailsCap), alignment: .topLeading)
        case .instrument:
            // An approval hugs its request, so its keys sit right under it; a long one scrolls
            // within the height the card used to have. Questions always scroll in their fixed
            // area, so a growing answer field never swaps views while you type.
            if request.kind == .approval {
                ViewThatFits(in: .vertical) {
                    requestBody.fixedSize(horizontal: false, vertical: true)
                    ScrollView { requestBody }.frame(maxWidth: .infinity, maxHeight: 112, alignment: .topLeading)
                }
            } else {
                ScrollView { requestBody }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var requestBody: some View {
        VStack(alignment: .leading, spacing: PanelTheme.pick(8, 9, 9)) {
            if !request.detail.isEmpty {
                Text(request.detail).font(.system(size: 13)).lineSpacing(PanelTheme.pick(3, 2, 3)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if request.kind == .clarification {
                if !request.choices.isEmpty {
                    chooseHint(request.multiSelect ? "Choose all that apply" : "Choose one answer")
                    ForEach(request.choices, id: \.self) { choice in choiceControl(choice) }
                    if request.allowsFreeText {
                        Toggle(request.multiSelect ? "Add another answer" : "Write another answer", isOn: $draft.usesFreeText)
                            .toggleStyle(NotchCheckboxStyle()).font(.system(size: 13))
                    }
                }
                if request.allowsFreeText && (request.choices.isEmpty || draft.usesFreeText) {
                    TextField("Your answer…", text: $draft.freeText, axis: .vertical)
                        .answerField(vertical: 7)
                        .accessibilityLabel("Your answer to \(request.title)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, PanelTheme.pick(4, 3, 3))
    }

    @ViewBuilder private func chooseHint(_ text: String) -> some View {
        switch PanelTheme.current {
        case .refined: Text(text).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).padding(.top, 2)
        case .tahoe: Text(text).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
        case .instrument: Text(text).microLabel(9.5, tracking: 0.7).foregroundStyle(CompanionStyle.faint)
        }
    }

    @ViewBuilder private var actions: some View {
        switch PanelTheme.current {
        case .refined:
            // The safe way out stays quiet at the left; the primary answer sits at
            // the right, where macOS puts a default button.
            HStack(spacing: 8) {
                if request.kind == .approval {
                    let offered = ApprovalAction.offered(in: request.choices)
                    if offered.contains(.cancel) {
                        Button(ApprovalAction.cancel.title) { respond(ApprovalAction.cancel.rawValue) }
                            .buttonStyle(NotchToolbarButtonStyle(height: 26)).padding(.leading, -8)
                    }
                    if isSubmitting { ProgressView().controlSize(.mini).accessibilityLabel("Sending response") }
                    Spacer(minLength: 0)
                    ForEach(offered.filter { $0 != .cancel }.reversed()) { action in
                        Button(action.title) { respond(action.rawValue) }
                            .buttonStyle(NotchPillButtonStyle(prominent: action == .once))
                    }
                } else {
                    Text("Your choice is sent when you reply.").font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary)
                    Spacer(minLength: 0)
                    if isSubmitting { ProgressView().controlSize(.mini).accessibilityLabel("Sending response") }
                    Button(isSubmitting ? "Sending reply…" : "Reply") { respond(answer) }
                        .buttonStyle(NotchPillButtonStyle(prominent: true))
                        .disabled(answer.isEmpty)
                }
            }
        case .tahoe:
            HStack(spacing: 8) {
                if request.kind == .approval {
                    // Equal-width actions, as on a system alert or Live Activity.
                    ForEach(ApprovalAction.offered(in: request.choices)) { action in
                        // Each keeps its full title; spare width is shared out evenly.
                        Button { respond(action.rawValue) } label: { Text(action.title).fixedSize().frame(maxWidth: .infinity) }
                            .buttonStyle(NotchPillButtonStyle(prominent: action == .once))
                    }
                } else {
                    Button(isSubmitting ? "Sending reply…" : "Reply") { respond(answer) }
                        .buttonStyle(NotchPillButtonStyle(prominent: true))
                        .disabled(answer.isEmpty)
                    Text("Your choice is sent when you reply.").font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
                }
                if isSubmitting { ProgressView().controlSize(.mini).accessibilityLabel("Sending response") }
                if request.kind != .approval { Spacer(minLength: 0) }
            }
        case .instrument:
            HStack(spacing: 10) {
                if request.kind == .approval {
                    ForEach(ApprovalAction.offered(in: request.choices)) { action in
                        Button(action.title) { respond(action.rawValue) }
                            .buttonStyle(NotchPillButtonStyle(prominent: action == .once))
                    }
                } else {
                    Button(isSubmitting ? "Sending reply…" : "Reply") { respond(answer) }
                        .buttonStyle(NotchPillButtonStyle(prominent: true))
                        .disabled(answer.isEmpty)
                    Text("Your choice is sent when you reply.").font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary)
                }
                if isSubmitting { ProgressView().controlSize(.mini).accessibilityLabel("Sending response") }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func choiceControl(_ choice: String) -> some View {
        let detail = request.choiceDetails[choice]
        if request.multiSelect {
            Toggle(isOn: Binding(get: { draft.selectedChoices.contains(choice) },
                                 set: { selected in
                if selected { draft.selectedChoices.insert(choice) }
                else { draft.selectedChoices.remove(choice) }
            })) { choiceLabel(choice, detail: detail) }
                .toggleStyle(NotchCheckboxStyle()).font(.system(size: 13))
                .accessibilityHint(detail ?? "")
        } else {
            Button { draft.choose(choice, multiple: false) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ChoiceMark(selected: draft.selectedChoices.contains(choice) && !draft.usesFreeText, round: true)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    choiceLabel(choice, detail: detail).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 13)).padding(.vertical, 3).contentShape(Rectangle())
            }.buttonStyle(.plain).pressableCursor()
                .accessibilityLabel(choice)
                .accessibilityHint(detail ?? "")
                .accessibilityValue(draft.selectedChoices.contains(choice) && !draft.usesFreeText ? "Selected" : "Not selected")
        }
    }

    /// The option and, beneath it, the runtime's description of it.
    private func choiceLabel(_ choice: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(choice).multilineTextAlignment(.leading)
            if let detail {
                Text(detail).font(.system(size: PanelTheme.pick(11, 11.5, 11.5)))
                    .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func respond(_ value: String) {
        guard !isSubmitting else { return }
        submitting = true
        Task {
            await model.answer(request, choice: value, answers: request.multiSelect ? answers : nil)
            // Failed requests retain this form and every local answer field.
            submitting = false
        }
    }
}

/// Questions an agent asked without pausing its turn (Codex's asynchronous
/// question tool). Options are suggestions; a written answer is always
/// allowed. Reply sends one ordinary next message, so the composer stays.
struct AsyncQuestionCard: View {
    enum Status: Equatable {
        /// The latest message: answerable now, or once the turn finishes.
        case open(canReply: Bool, hint: String)
        /// A later message has been sent.
        case answered
    }

    var questions: [AsyncQuestion]
    var asker: String
    var status: Status
    var reply: ([String]) async -> Bool
    @State private var drafts: [ClarificationAnswerState] = []
    @State private var sending = false

    private var answers: [String] {
        questions.indices.map { index in
            let draft = index < drafts.count ? drafts[index] : ClarificationAnswerState()
            return draft.answers(choices: questions[index].options, multiple: false).first ?? ""
        }
    }

    var body: some View {
        let answered = status == .answered
        let shape = RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.card, 14, CompanionStyle.cardRadius), style: .continuous)
        let fill: Color = PanelTheme.pick(answered ? Color.white.opacity(0.03) : CompanionStyle.well,
                                          answered ? Color.white.opacity(0.035) : CompanionStyle.fill,
                                          Color.black.opacity(0.3))
        let edge: Color = PanelTheme.pick(answered ? Color.white.opacity(0.06) : CompanionStyle.amber.opacity(0.28),
                                          answered ? Color.white.opacity(0.06) : CompanionStyle.amber.opacity(0.35),
                                          answered ? CompanionStyle.rule : CompanionStyle.amber.opacity(0.45))
        let label = "\(asker) \(answered ? "asked" : "asks") \(questions.count == 1 ? "a question" : "\(questions.count) questions")"
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if answered {
                        if !question.options.isEmpty {
                            Text(question.options.joined(separator: " · "))
                                .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), CompanionStyle.mono(10.5)))
                                .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
                                .lineLimit(2)
                        }
                    } else {
                        form(index, question)
                    }
                }
            }
            if case .open(let canReply, let hint) = status {
                replyRow(canReply: canReply, hint: hint).controlSize(.small)
            }
        }
        .padding(PanelTheme.pick(14, 14, 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: shape)
        .overlay(shape.strokeBorder(edge, lineWidth: PanelTheme.pick(0.75, 0.5, 0.5)))
        .disabled(sending)
        .onAppear { if drafts.count != questions.count { drafts = Array(repeating: ClarificationAnswerState(), count: questions.count) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var header: some View {
        let answered = status == .answered
        let title = answered ? "\(asker) asked" : "\(asker) asks"
        switch PanelTheme.current {
        case .refined:
            Label(title, systemImage: answered ? "checkmark.bubble" : "bubble.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(answered ? CompanionStyle.tertiary : CompanionStyle.amber)
        case .tahoe:
            Label(title, systemImage: answered ? "checkmark.bubble.fill" : "questionmark.bubble.fill")
                .font(.system(size: 12, weight: .semibold)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(answered ? CompanionStyle.secondary : CompanionStyle.amber)
        case .instrument:
            HStack(spacing: 8) {
                LED(color: answered ? CompanionStyle.faint : CompanionStyle.signal, lit: !answered, size: 6)
                Label(title, systemImage: answered ? "checkmark.bubble" : "bubble.left")
                    .labelStyle(.titleOnly)
                    .microLabel(10, weight: .semibold)
                    .foregroundStyle(answered ? CompanionStyle.secondary : CompanionStyle.amber)
                Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
            }
        }
    }

    @ViewBuilder private func replyRow(canReply: Bool, hint: String) -> some View {
        let button = Button(sending ? "Sending reply…" : "Reply") { send() }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
            .disabled(!canReply || sending || answers.allSatisfy(\.isEmpty))
        if PanelTheme.current == .refined {
            HStack(spacing: 8) {
                Text(hint).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).lineLimit(2)
                Spacer(minLength: 0)
                if sending { ProgressView().controlSize(.mini).accessibilityLabel("Sending reply") }
                button
            }
        } else {
            HStack(spacing: 10) {
                button
                Text(hint).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary).lineLimit(2)
                if sending { ProgressView().controlSize(.mini).accessibilityLabel("Sending reply") }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func form(_ index: Int, _ question: AsyncQuestion) -> some View {
        let draft = Binding(get: { index < drafts.count ? drafts[index] : ClarificationAnswerState() },
                            set: { if index < drafts.count { drafts[index] = $0 } })
        ForEach(question.options, id: \.self) { option in
            let selected = draft.wrappedValue.selectedChoices.contains(option) && !draft.wrappedValue.usesFreeText
            Button { draft.wrappedValue.choose(option, multiple: false) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ChoiceMark(selected: selected, round: true).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(option).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 13)).padding(.vertical, 2).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pressableCursor()
            .accessibilityLabel(option).accessibilityValue(selected ? "Selected" : "Not selected")
        }
        TextField(question.options.isEmpty ? "Your answer…" : "Or write an answer…", text: Binding(
            get: { draft.wrappedValue.freeText },
            set: { value in
                draft.wrappedValue.freeText = value
                draft.wrappedValue.usesFreeText = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }), axis: .vertical)
            .answerField(vertical: PanelTheme.pick(7, 6, 6))
            .accessibilityLabel("Your answer to \(question.title)")
    }

    private func send() {
        guard !sending else { return }
        sending = true
        let values = answers
        Task {
            // A failed send keeps every answer for another try.
            if await reply(values) { drafts = Array(repeating: ClarificationAnswerState(), count: questions.count) }
            sending = false
        }
    }
}

private extension View {
    /// A written answer: a recessed field in each design (Instrument's dark readout).
    func answerField(vertical: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.row, 9, CompanionStyle.radius), style: .continuous)
        return lineLimit(1...3).textFieldStyle(.plain).focusEffectDisabled().font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, vertical)
            .background(PanelTheme.pick(Color.black.opacity(0.25), Color.black.opacity(0.28), CompanionStyle.inset), in: shape)
            .overlay(shape.strokeBorder(PanelTheme.pick(CompanionStyle.hairline, Color.white.opacity(0.12), CompanionStyle.ruleStrong),
                                        lineWidth: PanelTheme.pick(0.75, 0.5, 0.75)))
            .textCursor()
    }
}
