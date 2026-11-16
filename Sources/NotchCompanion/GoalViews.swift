import SwiftUI

/// The Goal control's label in the row under the composer: “Goal”, “Goal · 3/10”, or paused.
struct GoalButtonLabel: View {
    var goal: SessionGoal?

    var body: some View {
        let glyph = Image(systemName: "scope").font(.system(size: PanelTheme.pick(10.5, 11, 10)))
        let title = goal.map { "Goal · \($0.progress)" + ($0.isActive ? "" : " · Paused") } ?? "Goal"
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PanelTheme.pick(5, 5, 6)) { glyph; Text(title).lineLimit(1).monospacedDigit() }
            glyph
        }
        .foregroundStyle(CompanionStyle.secondary)
    }
}

/// The bounded Goal overlay: a definition of done and a turn cap, then Pause, Resume, Edit and Clear.
struct GoalPanel: View {
    @ObservedObject var model: AppModel
    var session: CompanionSession
    var close: () -> Void
    @State private var editing: Bool
    @State private var objective: String
    @State private var cap: Int

    init(model: AppModel, session: CompanionSession, close: @escaping () -> Void) {
        self.model = model
        self.session = session
        self.close = close
        _editing = State(initialValue: session.goal == nil)
        _objective = State(initialValue: session.goal?.objective ?? "")
        _cap = State(initialValue: session.goal?.cap ?? SessionGoal.defaultCap)
    }

    static let help = "Goal (Notch Companion): after each turn the companion asks the agent to continue until its answer ends with GOAL COMPLETE, the turn cap is reached, or you stop it."

    var body: some View {
        let theme = PanelTheme.current
        VStack(alignment: .leading, spacing: 10) {
            header
            if editing || session.goal == nil { form } else if let goal = session.goal { status(goal) }
        }
        .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), .system(size: 11)))
        .foregroundStyle(CompanionStyle.secondary)
        .padding(theme == .instrument ? 10 : 12)
        .onChange(of: session.goal == nil) { _, cleared in if cleared { editing = true; objective = ""; cap = SessionGoal.defaultCap } }
    }

    @ViewBuilder private var header: some View {
        let close = QuietIconButton(symbol: "xmark", label: "Close goal", size: 18, action: self.close)
        if PanelTheme.current == .instrument {
            RuleLabel(title: "Goal") { close }.accessibilityAddTraits(.isHeader)
        } else {
            HStack(spacing: 6) {
                Text("Goal").font(.system(size: PanelTheme.pick(11, 12, 11), weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Notch Companion").foregroundStyle(CompanionStyle.tertiary)
                Spacer(minLength: 0)
                close
            }
            .help(Self.help)
        }
    }

    private var form: some View {
        let ready = !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Definition of done", text: $objective, axis: .vertical)
                .gitField(lines: 3...6)
                .foregroundStyle(CompanionStyle.text)
                .accessibilityLabel("Definition of done")
            HStack(spacing: 8) {
                Text("Turn cap")
                Spacer(minLength: 0)
                Text("\(cap)").monospacedDigit().foregroundStyle(CompanionStyle.text)
                Stepper("Turn cap", value: $cap, in: SessionGoal.caps).labelsHidden().controlSize(.small)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if session.goal != nil {
                    Button("Cancel") { editing = false; objective = session.goal?.objective ?? ""; cap = session.goal?.cap ?? cap }
                        .buttonStyle(NotchPillButtonStyle(small: true))
                }
                Button(session.goal == nil ? "Start goal" : "Save") {
                    if session.goal == nil {
                        model.startGoal(session.id, objective: objective, cap: cap)
                        close()
                    } else {
                        model.editGoal(session.id, objective: objective, cap: cap)
                        editing = false
                    }
                }
                .buttonStyle(NotchPillButtonStyle(prominent: true, small: true)).disabled(!ready)
                .help(session.goal == nil ? Self.help : "The next follow-up states the new definition")
            }
        }
    }

    private func status(_ goal: SessionGoal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(goal.objective).foregroundStyle(CompanionStyle.text).lineLimit(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(goal.pauseText ?? "Turn \(goal.turns) of \(goal.limit)").monospacedDigit()
                .foregroundStyle(goal.pause == .cap || goal.pause == .limit ? CompanionStyle.amber : CompanionStyle.secondary)
            HStack(spacing: 6) {
                if goal.isActive {
                    Button("Pause") { model.pauseGoal(session.id) }.buttonStyle(NotchPillButtonStyle(small: true))
                } else {
                    Button(goal.turns >= goal.limit ? "Continue for \(goal.cap) more" : "Resume") { model.resumeGoal(session.id) }
                        .buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
                }
                Button("Edit") { editing = true; objective = goal.objective; cap = goal.cap }.buttonStyle(NotchPillButtonStyle(small: true))
                Spacer(minLength: 0)
                Button("Clear") { model.clearGoal(session.id) }.buttonStyle(NotchTextButtonStyle())
                    .help("Ends the goal; the conversation stays")
            }
        }
    }
}
