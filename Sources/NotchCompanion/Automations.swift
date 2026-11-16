import Foundation
import AppKit

/// A prompt the app sends on a schedule, only while it is open.
struct ScheduledTask: Codable, Identifiable, Equatable {
    enum Repeat: String, Codable, CaseIterable { case once, hours, daily, weekly }
    var id = UUID().uuidString
    var name = ""
    var prompt = ""
    var runtime: RuntimeKind = .codex
    var folder = ""
    var repeats: Repeat = .daily
    /// Wall-clock hour and minute on the user's calendar; a one-time task adds year, month and day.
    var time = DateComponents(hour: 9, minute: 0)
    /// Every N hours counts from here.
    var anchor = Date()
    var hours = 1
    /// Calendar weekdays, 1 = Sunday.
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    /// Each run continues one session instead of starting a new one.
    var continuesSession = false
    var sessionID: String? = nil
    var skipMissed = false
    var paused = false
    /// The occurrence waiting to run; nil once a one-time task has run.
    var nextRun: Date? = nil
    /// The occurrence the last scheduled run (or skip) was for, so a day never runs twice.
    var lastOccurrence: Date? = nil
    var lastRunAt: Date? = nil
    var lastRunLate = false
    var lastRunID: String? = nil
    var lastSkipped: Date? = nil

    /// A run more than this late is a missed one: caught up with a note, or skipped.
    static let grace: TimeInterval = 300

    /// The next occurrence after `date`. Wall-clock schedules follow the calendar's
    /// time zone and DST, and skip a day that already ran.
    func occurrence(after date: Date, calendar: Calendar = .app) -> Date? {
        switch repeats {
        case .once:
            return calendar.date(from: time)
        case .hours:
            let period = TimeInterval(max(1, hours) * 3_600)
            guard date >= anchor else { return anchor }
            return anchor.addingTimeInterval((floor(date.timeIntervalSince(anchor) / period) + 1) * period)
        case .daily, .weekly:
            let days: [Int?] = repeats == .daily ? [nil] : weekdays.sorted()
            func next(after start: Date) -> Date? {
                days.compactMap { day in
                    calendar.nextDate(after: start, matching: DateComponents(hour: time.hour ?? 9, minute: time.minute ?? 0, weekday: day),
                                      matchingPolicy: .nextTime, repeatedTimePolicy: .first)
                }.min()
            }
            guard let candidate = next(after: date) else { return nil }
            // A time-zone change, a clock set back or DST's repeated hour never runs a day twice.
            if let last = lastOccurrence, calendar.isDate(candidate, inSameDayAs: last) { return next(after: candidate) }
            return candidate
        }
    }

    /// "Daily at 9:00", "Mon, Wed at 18:30", "Every 3 hours", "Once on Tue, Nov 18, 9:00".
    func summary(calendar: Calendar = .app) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
        let clock = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: Date()).map { $0.formatted(style.hour().minute()) } ?? ""
        switch repeats {
        case .once:
            return "Once on " + (calendar.date(from: time).map { $0.formatted(style.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) } ?? "—")
        case .hours: return hours == 1 ? "Every hour" : "Every \(hours) hours"
        case .daily: return "Daily at \(clock)"
        case .weekly:
            let days = weekdays.sorted()
            if days == [2, 3, 4, 5, 6] { return "Weekdays at \(clock)" }
            if days.count == 7 { return "Every day at \(clock)" }
            let names = calendar.shortWeekdaySymbols
            return days.map { names[($0 - 1) % 7] }.joined(separator: ", ") + " at \(clock)"
        }
    }

    /// Why the form cannot be saved, else nil.
    func problem(now: Date = Date(), calendar: Calendar = .app) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the task a name." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write the prompt it sends." }
        if repeats == .weekly && weekdays.isEmpty { return "Choose at least one day." }
        if repeats == .once, (calendar.date(from: time) ?? now) <= now { return "Choose a time in the future." }
        return nil
    }
}

extension ChatMessage {
    /// A scheduled run's kind carries its task's name, so the label survives the task.
    static func scheduledKind(_ name: String, late: Bool) -> String { (late ? "scheduledLate:" : "scheduled:") + name }
    static let pullRequestWatch = "prWatch"
    static func automationLabel(_ kind: String?) -> String? {
        guard let kind else { return nil }
        if kind == pullRequestWatch { return "PR watch" }
        for (prefix, note) in [("scheduled:", ""), ("scheduledLate:", " · ran late")] where kind.hasPrefix(prefix) {
            return "Scheduled · " + kind.dropFirst(prefix.count) + note
        }
        return nil
    }
    /// A scheduled run starts its own turn, as the user's prompt would.
    var isScheduledRun: Bool { kind?.hasPrefix("scheduled") == true }
}

extension QueuedSend {
    /// Scheduled runs and pull request messages keep Quit and Reconnect waiting until they are sent.
    var isAutomation: Bool { ChatMessage.automationLabel(kind) != nil }
}

/// A watched pull request's saved state: what has been reported, so a restart never repeats it.
struct PullRequestWatch: Codable, Equatable {
    var url: String
    /// Check runs, reviews and comments already handled.
    var seen: Set<String> = []
    /// A failure was reported; all checks passing reports the recovery.
    var failing = false
    var conflicting = false
    /// The first poll records existing reviews and comments without reporting them.
    var baselined = false
    /// Messages sent so far: each message's ID derives from it.
    var sent = 0
}

/// A watch's polling, in memory only: polls back off after errors, which show only in the link's tooltip.
struct PullRequestPoll: Equatable {
    var next = Date.distantPast
    var failures = 0
    var error: String?
    static let interval: TimeInterval = 120

    mutating func failed(_ message: String, now: Date = Date()) {
        failures += 1
        error = message
        next = now.addingTimeInterval(min(1_800, Self.interval * pow(2, Double(failures))))
    }
}

enum PullRequestEvents {
    static let fields = "number,url,state,author,mergeable,statusCheckRollup,reviews,comments"
    private static let failedConclusions: Set<String> = ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]
    private static let passedConclusions: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]

    /// One short message for what changed since `watch`, and whether the watch ends (merged or closed).
    /// Comment and review bodies stay out: they are other people's text, and the agent can read them with `gh`.
    static func evaluate(_ pr: [String: Any], watch: inout PullRequestWatch) -> (message: String?, ended: Bool) {
        let number = (pr["number"] as? Int).map { "PR #\($0)" } ?? "the pull request"
        let link = pr["url"] as? String ?? watch.url
        let author = (pr["author"] as? [String: Any])?["login"] as? String
        var lines: [String] = []
        let first = !watch.baselined
        watch.baselined = true

        let checks = (pr["statusCheckRollup"] as? [[String: Any]] ?? []).map { check in
            let name = check["name"] as? String ?? check["context"] as? String ?? "check"
            let url = check["detailsUrl"] as? String ?? check["targetUrl"] as? String
            // A check run's conclusion once completed; a status context's state.
            let status = check["status"] as? String
            let result = (status == nil || status == "COMPLETED") ? (check["conclusion"] as? String ?? check["state"] as? String ?? "") : "PENDING"
            let key = "check:\(name)|\(url ?? "")|\(check["startedAt"] as? String ?? "")"
            return (name: name, url: url, result: result.uppercased(), key: key)
        }
        let failed = checks.filter { failedConclusions.contains($0.result) && !watch.seen.contains($0.key) }
        for check in failed {
            watch.seen.insert(check.key)
            lines.append("Check `\(check.name)` failed on \(number): \(check.url ?? link). Investigate and fix it.")
        }
        if !failed.isEmpty { watch.failing = true }
        else if watch.failing, !checks.isEmpty, checks.allSatisfy({ passedConclusions.contains($0.result) }) {
            watch.failing = false
            lines.append("All checks pass on \(number) now: \(link).")
        }

        for review in pr["reviews"] as? [[String: Any]] ?? [] {
            guard let id = review["id"].map({ "review:" + EventValue.string($0) }), watch.seen.insert(id).inserted, !first else { continue }
            let who = (review["author"] as? [String: Any])?["login"] as? String ?? "A reviewer"
            switch review["state"] as? String {
            case "CHANGES_REQUESTED": lines.append("\(who) requested changes on \(number): \(link). Address the review.")
            case "COMMENTED" where who != author && !(review["body"] as? String ?? "").isEmpty:
                lines.append("\(who) left a review comment on \(number): \(link). Read it and respond if it needs a change.")
            default: break
            }
        }
        for comment in pr["comments"] as? [[String: Any]] ?? [] {
            guard let id = comment["id"].map({ "comment:" + EventValue.string($0) }), watch.seen.insert(id).inserted, !first else { continue }
            let who = (comment["author"] as? [String: Any])?["login"] as? String
            // The PR author's own comments are this session's (or the user's) automation.
            guard who != author else { continue }
            lines.append("\(who ?? "Someone") commented on \(number): \(comment["url"] as? String ?? link). Read it and respond if it needs a change.")
        }

        switch pr["mergeable"] as? String {
        case "CONFLICTING" where !watch.conflicting:
            watch.conflicting = true
            lines.append("\(number) has merge conflicts with its base branch: \(link). Resolve them.")
        case "MERGEABLE": watch.conflicting = false
        default: break
        }

        let state = pr["state"] as? String
        if state == "MERGED" { lines.append("\(number) was merged: \(link).") }
        else if state == "CLOSED" { lines.append("\(number) was closed without merging: \(link).") }
        return (lines.isEmpty ? nil : lines.joined(separator: "\n"), state == "MERGED" || state == "CLOSED")
    }

    /// `gh` with the user's own login, as an argument array; never a shell.
    nonisolated static func gh(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard let gh = GitActions.ghExecutable() else { throw AppError("The GitHub CLI (gh) isn't installed.") }
            return try WorkspaceChanges.run(arguments, at: FileManager.default.homeDirectoryForCurrentUser.path, timeout: 60,
                                            reportingErrors: true, executable: gh.path, environment: GitActions.environment)
        }.value
    }
}

extension AppModel {
    var scheduledTasksURL: URL { storageURL.deletingLastPathComponent().appendingPathComponent("scheduled-tasks.json") }

    /// An unreadable file is left untouched and never overwritten.
    func loadScheduledTasks() {
        guard let data = try? Data(contentsOf: scheduledTasksURL) else { return }
        if let tasks = try? JSONDecoder().decode([ScheduledTask].self, from: data) { scheduledTasks = tasks }
        else { scheduledTasksUnreadable = true }
    }

    @discardableResult
    func saveScheduledTasks() -> Bool {
        guard !scheduledTasksUnreadable else { return false }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: scheduledTasksURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try encoder.encode(scheduledTasks).write(to: scheduledTasksURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scheduledTasksURL.path)
            return true
        } catch { errorMessage = "Could not save scheduled tasks: \(error.localizedDescription)"; return false }
    }

    /// Runs and polls due work now, after waking from sleep and when the clock or time zone changes.
    func startAutomations() {
        let centers: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (.default, .NSSystemClockDidChange), (.default, .NSSystemTimeZoneDidChange)]
        automationObservers = centers.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateAutomations() }
            })
        }
        Task { @MainActor [weak self] in self?.evaluateAutomations() }
    }

    func stopAutomations() {
        automationTimer?.cancel()
        automationTimer = nil
        for (center, observer) in automationObservers { center.removeObserver(observer) }
        automationObservers = []
    }

    /// Starts due runs and polls, then sleeps until the next, at most a minute so a
    /// changed clock is noticed. A run waiting on its previous one is checked every 15 s.
    func evaluateAutomations(now: Date = Date()) {
        runDueScheduledTasks(now: now)
        let watched = sessions.filter { $0.pullRequestWatch != nil }.map(\.id)
        for id in pullRequestPolls.keys where !watched.contains(id) { pullRequestPolls[id] = nil }
        for id in watched where (pullRequestPolls[id]?.next ?? .distantPast) <= now && !pullRequestPolling.contains(id) {
            // Pushed back before the poll starts, so another evaluation never starts a second one.
            pullRequestPolls[id, default: PullRequestPoll()].next = now.addingTimeInterval(PullRequestPoll.interval)
            Task { await self.pollPullRequest(id) }
        }
        automationTimer?.cancel()
        let next = (scheduledTasks.filter { !$0.paused }.compactMap(\.nextRun) + watched.compactMap { pullRequestPolls[$0]?.next }).min()
        guard let next else { automationTimer = nil; return }
        let delay = min(60, next > now ? next.timeIntervalSince(now) : 15)
        automationTimer = Task { [weak self] in
            // A continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluateAutomations()
        }
    }

    // MARK: Scheduled tasks

    func runDueScheduledTasks(now: Date = Date()) {
        var changed = false
        for index in scheduledTasks.indices where !scheduledTasks[index].paused {
            var task = scheduledTasks[index]
            // Wall-clock schedules follow a changed time zone; a missed occurrence stays due.
            if task.repeats != .hours, let pending = task.nextRun, pending > now, let current = task.occurrence(after: now), current != pending {
                task.nextRun = current; scheduledTasks[index] = task; changed = true
            }
            guard let due = task.nextRun, due <= now, !scheduledRunActive(task) else { continue }
            let late = now.timeIntervalSince(due) > ScheduledTask.grace
            // Every missed occurrence collapses into this one run.
            task.lastOccurrence = due
            task.nextRun = task.repeats == .once ? nil : task.occurrence(after: max(now, due))
            scheduledTasks[index] = task
            changed = true
            if late && task.skipMissed { scheduledTasks[index].lastSkipped = due; continue }
            startScheduledRun(index, key: "\(Int(due.timeIntervalSince1970))", late: late, now: now)
        }
        if changed { saveScheduledTasks() }
    }

    /// The previous run is still queued, sending or working; its own session's later turns don't count.
    func scheduledRunActive(_ task: ScheduledTask) -> Bool {
        guard let id = task.lastRunID else { return false }
        for session in sessions {
            if session.queuedSends.contains(where: { $0.id == id }) { return !failedDeliveries.contains(id) }
            if session.pendingSubmission?.id == id || session.stagedSubmission?.message.id == id { return true }
            if session.messages.contains(where: { $0.id == id }) {
                return (session.isBusy || isSubmitting(session.id)) && session.messages.last(where: { $0.role == "user" })?.id == id
            }
        }
        return false
    }

    /// Why the last run could not be sent, else nil.
    func scheduledRunError(_ task: ScheduledTask) -> String? {
        guard let id = task.lastRunID, failedDeliveries.contains(id), let session = sessions.first(where: { $0.queuedSends.contains { $0.id == id } }) else { return nil }
        return backgroundSendErrors[session.id] ?? "The run could not be sent."
    }

    /// Queues the run in its session through the ordinary send path, which waits for the
    /// session to be idle. `key` names the occurrence, so a restart never queues it twice.
    @discardableResult
    func startScheduledRun(_ index: Int, key: String, late: Bool, now: Date = Date()) -> Bool {
        var task = scheduledTasks[index]
        let runID = Delegation.derivedID(caller: task.id, operation: "scheduled.run", clientRequestID: key)
        guard !sessions.contains(where: { $0.wasDelivered(runID) || $0.queuedSends.contains { $0.id == runID } || $0.stagedSubmission?.message.id == runID }) else { return false }
        let before = sessions
        // A previous run that could not be sent gives way to this one.
        if let old = task.lastRunID, failedDeliveries.contains(old) {
            for id in sessions.map(\.id) { update(id) { $0.queuedSends.removeAll { $0.id == old } } }
        }
        let sessionID: String
        if task.continuesSession, let existing = task.sessionID, sessions.contains(where: { $0.id == existing }) {
            sessionID = existing
        } else {
            var session = CompanionSession()
            session.id = Delegation.derivedID(caller: task.id, operation: "scheduled.session", clientRequestID: key)
            session.runtime = task.runtime
            session.profileID = RuntimeRoute.defaultProfile(task.runtime, defaults: preferences)
            session.workspacePath = task.folder.isEmpty ? nil : task.folder
            applyNativeWorkspace(to: &session)
            if task.runtime.requiresProjectTrust, trustsProject(task.runtime, path: session.workspacePath) {
                session.trustedProjectPath = URL(fileURLWithPath: session.workspacePath ?? workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
            }
            let date = now.formatted(Date.FormatStyle(locale: .app, calendar: .app).day().month(.abbreviated).hour().minute())
            session.title = task.continuesSession ? task.name : "\(task.name) · \(date)"
            sessions.insert(session, at: 0)
            sessionID = session.id
        }
        update(sessionID) {
            $0.isArchived = false
            $0.queuedSends.append(QueuedSend(id: runID, text: task.prompt, kind: ChatMessage.scheduledKind(task.name, late: late)))
        }
        guard save() else { sessions = before; return false }
        task.lastRunID = runID; task.lastRunAt = now; task.lastRunLate = late; task.sessionID = sessionID
        scheduledTasks[index] = task
        saveScheduledTasks()
        processDelegationWakes()
        return true
    }

    /// Adds or replaces a task, its next run counted from now.
    func saveScheduledTask(_ edited: ScheduledTask, now: Date = Date()) -> String? {
        if let problem = edited.problem(now: now) { return problem }
        var task = edited
        task.name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.repeats == .hours {
            task.anchor = Calendar.app.date(bySettingHour: task.time.hour ?? 9, minute: task.time.minute ?? 0, second: 0, of: now) ?? now
        }
        // An edit starts the schedule over: a time already past today waits for the next one.
        task.lastOccurrence = nil
        task.nextRun = task.occurrence(after: now)
        // The continued session belongs to the harness and folder it started in.
        if let old = scheduledTasks.first(where: { $0.id == task.id }), old.runtime != task.runtime || old.folder != task.folder || !task.continuesSession {
            task.sessionID = nil
        }
        let before = scheduledTasks
        if let index = scheduledTasks.firstIndex(where: { $0.id == task.id }) { scheduledTasks[index] = task } else { scheduledTasks.append(task) }
        guard saveScheduledTasks() else { scheduledTasks = before; return "Could not save scheduled tasks." }
        evaluateAutomations(now: now)
        return nil
    }

    func setScheduledTaskPaused(_ id: String, _ paused: Bool, now: Date = Date()) {
        guard let index = scheduledTasks.firstIndex(where: { $0.id == id }) else { return }
        scheduledTasks[index].paused = paused
        // Occurrences while paused are skipped, not caught up.
        if !paused, scheduledTasks[index].repeats != .once { scheduledTasks[index].nextRun = scheduledTasks[index].occurrence(after: now) }
        saveScheduledTasks()
        evaluateAutomations(now: now)
    }

    /// Runs once now; the schedule is unchanged. Nil, or why it cannot start.
    @discardableResult
    func runScheduledTaskNow(_ id: String, now: Date = Date()) -> String? {
        guard let index = scheduledTasks.firstIndex(where: { $0.id == id }) else { return nil }
        guard !scheduledRunActive(scheduledTasks[index]) else { return "The previous run is still sending or working." }
        return startScheduledRun(index, key: "now-" + UUID().uuidString, late: false, now: now) ? nil : "The run could not be queued."
    }

    /// A run not sent yet goes with its task; sessions and their history stay.
    func deleteScheduledTask(_ id: String) {
        guard let task = scheduledTasks.first(where: { $0.id == id }) else { return }
        if let run = task.lastRunID { for sessionID in sessions.map(\.id) { update(sessionID) { $0.queuedSends.removeAll { $0.id == run } } } }
        scheduledTasks.removeAll { $0.id == id }
        save()
        saveScheduledTasks()
        evaluateAutomations()
    }

    // MARK: Pull request watch

    /// Starts watching the session's github.com pull request with the user's signed-in `gh`.
    /// Nil, or why it cannot.
    func watchPullRequest(_ id: String) async -> String? {
        guard let link = sessions.first(where: { $0.id == id })?.pullRequest, let url = URL(string: link), url.host?.lowercased() == "github.com",
              GitActions.pullRequestURL(in: link) != nil else { return "Only pull requests on github.com can be watched." }
        do { _ = try await pullRequestRunner(["auth", "status", "--hostname", "github.com"]) }
        catch { return "Watching needs the GitHub CLI installed and signed in. Run gh auth login in Terminal, then try again." }
        guard sessions.first(where: { $0.id == id })?.pullRequest == link else { return nil }
        update(id) { $0.pullRequestWatch = PullRequestWatch(url: link) }
        save()
        pullRequestPolls[id] = nil
        evaluateAutomations()
        return nil
    }

    func stopWatchingPullRequest(_ id: String) {
        update(id) { $0.pullRequestWatch = nil }
        save()
        pullRequestPolls[id] = nil
        evaluateAutomations()
    }

    /// One `gh pr view`. New events become one message through the queued send path;
    /// errors back off and never message the session.
    func pollPullRequest(_ id: String, now: Date = Date()) async {
        guard let watch = sessions.first(where: { $0.id == id })?.pullRequestWatch, pullRequestPolling.insert(id).inserted else { return }
        defer { pullRequestPolling.remove(id) }
        var poll = pullRequestPolls[id] ?? PullRequestPoll()
        do {
            let output = try await pullRequestRunner(["pr", "view", watch.url, "--json", PullRequestEvents.fields])
            guard let pr = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
                throw AppError("GitHub CLI's answer could not be read.")
            }
            // Stopped, or watching another link, meanwhile.
            guard var current = sessions.first(where: { $0.id == id })?.pullRequestWatch, current.url == watch.url else { return }
            let (message, ended) = PullRequestEvents.evaluate(pr, watch: &current)
            let before = sessions
            if let message {
                let messageID = Delegation.derivedID(caller: id, operation: "pr-watch", clientRequestID: "\(current.url)#\(current.sent)")
                current.sent += 1
                update(id) { $0.queuedSends.append(QueuedSend(id: messageID, text: message, kind: ChatMessage.pullRequestWatch)) }
            }
            update(id) { $0.pullRequestWatch = ended ? nil : current }
            if current != watch || message != nil {
                guard save() else { sessions = before; throw AppError("Could not save the watch.") }
            }
            poll = PullRequestPoll(next: now.addingTimeInterval(PullRequestPoll.interval))
            if ended { pullRequestPolls[id] = nil } else { pullRequestPolls[id] = poll }
            if message != nil { processDelegationWakes() }
        } catch {
            guard sessions.first(where: { $0.id == id })?.pullRequestWatch != nil else { return }
            poll.failed(error.localizedDescription, now: now)
            pullRequestPolls[id] = poll
        }
    }
}
