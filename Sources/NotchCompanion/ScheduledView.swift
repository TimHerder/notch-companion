import SwiftUI

/// Scheduled tasks with their next run, and the inline form that adds or edits one.
struct ScheduledView: View {
    @ObservedObject var model: AppModel
    /// Why Run now could not start, by task.
    @State private var refusals: [String: String] = [:]

    private var theme: PanelTheme { PanelTheme.current }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                if theme == .instrument {
                    RuleLabel(title: "Scheduled tasks") { newButton }.accessibilityAddTraits(.isHeader)
                } else {
                    HStack {
                        heading("Scheduled tasks")
                        Spacer(minLength: 0)
                        newButton
                    }
                }
                if let editing = model.scheduledEditing, !model.scheduledTasks.contains(where: { $0.id == editing.id }) {
                    SettingsGroup { ScheduledTaskForm(model: model) }
                }
                if model.scheduledTasks.isEmpty && model.scheduledEditing == nil {
                    note("Nothing scheduled. A task sends its prompt to a harness at the times you choose.")
                } else if !model.scheduledTasks.isEmpty {
                    SettingsGroup {
                        ForEach(Array(model.scheduledTasks.enumerated()), id: \.element.id) { index, task in
                            if index > 0 {
                                Rectangle().fill(PanelTheme.pick(Color.white.opacity(0.06), CompanionStyle.separator, Color.white.opacity(0.08)))
                                    .frame(height: 0.5).padding(.leading, PanelTheme.pick(14, 12, 0))
                            }
                            if model.scheduledEditing?.id == task.id { ScheduledTaskForm(model: model) } else { row(task) }
                        }
                    }
                }
                if model.scheduledTasksUnreadable {
                    note("The saved tasks could not be read, so they are left untouched and nothing new is saved.").foregroundStyle(CompanionStyle.amber)
                }
                note("Tasks run only while Notch Companion is open. Runs missed while it was closed or the Mac slept run once when it is back, marked as late, unless a task skips them.")
            }
            .padding(.top, PanelTheme.pick(8, 10, 8)).padding(.bottom, PanelTheme.pick(12, 10, 8))
        }
        .modifier(UsageScrollEdge())
    }

    private var newButton: some View {
        QuietIconButton(symbol: "plus", label: "New scheduled task", size: 22) {
            model.scheduledEditing = ScheduledTask(runtime: model.readyRuntimes.first ?? .codex, folder: model.workspacePath)
            model.scheduledDeleting = nil
        }.disabled(model.scheduledEditing != nil)
    }

    private func row(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(status(task)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(CompanionStyle.secondary).lineLimit(1)
            }
            caption([task.summary(), task.runtime.title, URL(fileURLWithPath: task.folder).lastPathComponent,
                     task.continuesSession ? "One session" : "New session each run"].joined(separator: " · "))
            if let late = lateNote(task) { caption(late) }
            if let error = refusals[task.id] ?? model.scheduledRunError(task) {
                Text(error).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
            }
            if model.scheduledDeleting == task.id {
                HStack(spacing: 8) {
                    caption("Delete \(task.name)? Its sessions stay.")
                    Spacer(minLength: 0)
                    Button("Cancel") { model.scheduledDeleting = nil }.buttonStyle(NotchPillButtonStyle(small: true))
                    Button("Delete") { model.scheduledDeleting = nil; model.deleteScheduledTask(task.id) }
                        .buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
                }
            } else {
                HStack(spacing: PanelTheme.pick(14, 14, 12)) {
                    action(task.paused ? "Resume" : "Pause", symbol: task.paused ? "play" : "pause") {
                        model.setScheduledTaskPaused(task.id, !task.paused)
                    }.disabled(task.repeats == .once && task.nextRun == nil)
                    action("Run now", symbol: "arrow.forward.circle") {
                        refusals[task.id] = model.runScheduledTaskNow(task.id)
                    }.disabled(model.scheduledRunActive(task))
                    action("Edit", symbol: "pencil") { model.scheduledEditing = task; model.scheduledDeleting = nil }
                        .disabled(model.scheduledEditing != nil)
                    action("Delete", symbol: "trash") { model.scheduledDeleting = task.id }
                    Spacer(minLength: 0)
                }.padding(.top, 2)
            }
        }
        .padding(.horizontal, theme == .refined ? 14 : 12).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.name), \(task.summary()), \(status(task))")
    }

    /// "Next 9:00", "Next Tue, Nov 18, 9:00", "Paused", "Running", "Done".
    private func status(_ task: ScheduledTask) -> String {
        if model.scheduledRunActive(task) { return "Running" }
        if task.paused { return "Paused" }
        guard let next = task.nextRun else { return "Done" }
        return next <= Date() ? "Due now" : "Next " + SnoozeChoice.time(next)
    }

    private func lateNote(_ task: ScheduledTask) -> String? {
        if let skipped = task.lastSkipped, skipped >= (task.lastRunAt ?? .distantPast) {
            return "Skipped the run missed at \(SnoozeChoice.time(skipped))."
        }
        guard task.lastRunLate, let ran = task.lastRunAt else { return nil }
        return "Ran late at \(SnoozeChoice.time(ran)), catching up a missed run."
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            let label = Label(title, systemImage: symbol).lineLimit(1)
            if theme == .instrument { label.foregroundStyle(CompanionStyle.secondary) } else { label }
        }.buttonStyle(NotchTextButtonStyle())
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11), .system(size: 10.5)))
            .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func heading(_ text: String) -> some View {
        if theme == .tahoe {
            Text(text).font(.system(size: 13, weight: .semibold)).padding(.leading, 4).accessibilityAddTraits(.isHeader)
        } else {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary).padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(PanelTheme.pick(CompanionStyle.caption, .system(size: 11.5), .system(size: 11.5)))
            .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.secondary))
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, theme == .instrument ? 0 : 4)
    }
}

/// Name, prompt, harness, folder, schedule and destination, edited in place.
private struct ScheduledTaskForm: View {
    @ObservedObject var model: AppModel
    @State private var problem: String?

    private var task: Binding<ScheduledTask> {
        Binding(get: { model.scheduledEditing ?? ScheduledTask() }, set: { model.scheduledEditing = $0 })
    }

    var body: some View {
        let calendar = Calendar.app
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: task.name).gitField(lines: 1...1).accessibilityLabel("Task name")
            TextField("Prompt to send", text: task.prompt, axis: .vertical).gitField(lines: 3...6).accessibilityLabel("Prompt")
            field("Harness") {
                let runtimes = model.readyRuntimes
                if runtimes.isEmpty {
                    label("Set up a harness in Settings first.")
                } else {
                    FlowChips(items: runtimes, title: \.title, selected: { $0 == task.wrappedValue.runtime }) { task.wrappedValue.runtime = $0 }
                }
            }
            field("Folder") {
                Button {
                    if let folder = model.pickFolder("Folder the task's sessions work in", from: task.wrappedValue.folder) { task.wrappedValue.folder = folder }
                } label: { Label(URL(fileURLWithPath: task.wrappedValue.folder).lastPathComponent, systemImage: "folder").lineLimit(1).truncationMode(.middle) }
                    .buttonStyle(NotchPillButtonStyle(small: true)).help(task.wrappedValue.folder)
            }
            field("Repeat") {
                NotchSegmentedControl(label: "Repeat", options: ScheduledTask.Repeat.allCases, title: { repeatTitle($0) },
                                      selection: task.repeats, small: true)
            }
            switch task.wrappedValue.repeats {
            case .once:
                field("On") { picker(components: [.date, .hourAndMinute], calendar: calendar) }
            case .hours:
                field("Every") {
                    HStack(spacing: 6) {
                        QuietIconButton(symbol: "minus", label: "Fewer hours", size: 22) { task.wrappedValue.hours = max(1, task.wrappedValue.hours - 1) }
                            .disabled(task.wrappedValue.hours <= 1)
                        Text(task.wrappedValue.hours == 1 ? "1 hour" : "\(task.wrappedValue.hours) hours").monospacedDigit()
                        QuietIconButton(symbol: "plus", label: "More hours", size: 22) { task.wrappedValue.hours = min(168, task.wrappedValue.hours + 1) }
                        label("from")
                        picker(components: .hourAndMinute, calendar: calendar)
                    }
                }
            case .daily:
                field("At") { picker(components: .hourAndMinute, calendar: calendar) }
            case .weekly:
                field("On") {
                    let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
                    FlowChips(items: order, title: { calendar.veryShortWeekdaySymbols[$0 - 1] },
                              spoken: { calendar.weekdaySymbols[$0 - 1] }, selected: { task.wrappedValue.weekdays.contains($0) }) { day in
                        if let index = task.wrappedValue.weekdays.firstIndex(of: day) { task.wrappedValue.weekdays.remove(at: index) }
                        else { task.wrappedValue.weekdays.append(day) }
                    }
                }
                field("At") { picker(components: .hourAndMinute, calendar: calendar) }
            }
            field("Sends to") {
                NotchSegmentedControl(label: "Sends to", options: [false, true], title: { $0 ? "One session" : "New session each run" },
                                      selection: task.continuesSession, small: true)
            }
            field("Missed") {
                Toggle("Skip missed runs", isOn: task.skipMissed).toggleStyle(NotchSwitchStyle())
                label("Skip missed runs")
            }
            .help("Runs missed while the app was closed or the Mac slept are skipped instead of running once, late")
            if let problem { Text(problem).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.amber) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { model.scheduledEditing = nil }.buttonStyle(NotchPillButtonStyle(small: true))
                Button("Save") {
                    guard let edited = model.scheduledEditing else { return }
                    problem = model.saveScheduledTask(edited)
                    if problem == nil { model.scheduledEditing = nil }
                }
                .buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
                .disabled(model.readyRuntimes.isEmpty)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, PanelTheme.current == .refined ? 14 : 12).padding(.vertical, 10)
    }

    private func repeatTitle(_ repeats: ScheduledTask.Repeat) -> String {
        switch repeats { case .once: "Once"; case .hours: "Hourly"; case .daily: "Daily"; case .weekly: "Weekly" }
    }

    /// The date (once) or time of day, read and written as wall-clock components on the user's calendar.
    private func picker(components: DatePickerComponents, calendar: Calendar) -> some View {
        let once = components.contains(.date)
        let date = Binding<Date>(get: {
            let time = task.wrappedValue.time
            if once, time.year != nil, let date = calendar.date(from: time) { return date }
            return calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: Date()) ?? Date()
        }, set: { date in
            task.wrappedValue.time = calendar.dateComponents(once ? [.year, .month, .day, .hour, .minute] : [.hour, .minute], from: date)
        })
        return DatePicker(once ? "On" : "At", selection: date, displayedComponents: components)
            .labelsHidden().datePickerStyle(.field).fixedSize()
            .environment(\.locale, .app).environment(\.calendar, calendar)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            label(title).frame(width: 62, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(CompanionStyle.secondary)
    }
}

/// Small toggle chips that wrap onto more rows instead of widening the panel.
private struct FlowChips<Item: Hashable>: View {
    var items: [Item]
    var title: (Item) -> String
    var spoken: ((Item) -> String)? = nil
    var selected: (Item) -> Bool
    var choose: (Item) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { chips(items) }
            VStack(alignment: .leading, spacing: 5) {
                let half = (items.count + 1) / 2
                HStack(spacing: 5) { chips(Array(items.prefix(half))) }
                HStack(spacing: 5) { chips(Array(items.dropFirst(half))) }
            }
        }
    }

    private func chips(_ items: [Item]) -> some View {
        ForEach(items, id: \.self) { item in
            Button(title(item)) { choose(item) }
                .buttonStyle(NotchPillButtonStyle(small: true, selected: selected(item)))
                .accessibilityLabel(spoken?(item) ?? title(item))
                .accessibilityAddTraits(selected(item) ? .isSelected : [])
        }
    }
}
