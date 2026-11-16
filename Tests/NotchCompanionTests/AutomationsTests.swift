import XCTest
@testable import NotchCompanion

@MainActor private final class AutomationTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    var calls: [String] = []
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(method)
        guard method == "session.create" || method == "session.resume" else { return [:] }
        let owner = params["companion_id"] as? String ?? UUID().uuidString
        return ["session_id": "rt-" + owner, "stored_session_id": "native-" + owner]
    }
}

@MainActor final class AutomationsTests: XCTestCase {
    private var cleanup: [() -> Void] = []
    override func tearDown() async throws { cleanup.forEach { $0() }; cleanup = [] }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ text: String, _ zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func makeModel(folder: URL? = nil) -> (AppModel, URL) {
        let suite = "notch-automations-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = AppModel(storageURL: store.appendingPathComponent("sessions.json"), playsSounds: false, client: AutomationTransport(), preferences: defaults)
        model.sessions = [CompanionSession(id: "selected", title: "Selected")]
        cleanup.append {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store)
        }
        return (model, store)
    }

    // MARK: Schedule arithmetic

    func testDailyRunsOnceAcrossBothDSTChanges() {
        let zone = "America/New_York", calendar = calendar(zone)
        // Spring forward: 2:30 does not exist on March 8, so it runs at 3:00, then 2:30 again.
        var task = ScheduledTask(repeats: .daily, time: DateComponents(hour: 2, minute: 30))
        let spring = task.occurrence(after: date("2026-03-08 00:00", zone), calendar: calendar)!
        XCTAssertEqual(spring, date("2026-03-08 03:00", zone))
        task.lastRunDay = calendar.dateComponents([.year, .month, .day], from: spring)
        XCTAssertEqual(task.occurrence(after: spring, calendar: calendar), date("2026-03-09 02:30", zone))

        // Fall back: 1:30 happens twice on November 1; it runs at the first, never the repeat.
        task.time = DateComponents(hour: 1, minute: 30)
        task.lastRunDay = nil
        let first = task.occurrence(after: date("2026-11-01 00:00", zone), calendar: calendar)!
        XCTAssertEqual(calendar.component(.hour, from: first), 1)
        task.lastRunDay = calendar.dateComponents([.year, .month, .day], from: first)
        let next = task.occurrence(after: first.addingTimeInterval(60), calendar: calendar)!
        XCTAssertEqual(next, date("2026-11-02 01:30", zone), "The repeated hour never runs it a second time")
    }

    func testTimeZoneChangeAndClockSetBackNeverRunADayTwice() {
        var task = ScheduledTask(repeats: .daily, time: DateComponents(hour: 9, minute: 0))
        // Ran at 9:00 in Berlin, which is 3:00 in New York; then the Mac moves to New York.
        task.lastRunDay = DateComponents(year: 2026, month: 11, day: 16)
        let newYork = calendar("America/New_York")
        XCTAssertEqual(task.occurrence(after: date("2026-11-16 04:00", "America/New_York"), calendar: newYork),
                       date("2026-11-17 09:00", "America/New_York"), "9:00 in New York the same day would run that day twice")
        // The clock set back to 7:00 after today's 9:00 run waits for tomorrow.
        let berlin = calendar("Europe/Berlin")
        XCTAssertEqual(task.occurrence(after: date("2026-11-16 07:00", "Europe/Berlin"), calendar: berlin), date("2026-11-17 09:00", "Europe/Berlin"))
        // Westward across the date line: 9:00 on the 16th in Tokyo is the 15th in Honolulu, whose
        // next 9:00 is the 16th again by the calendar: that day already ran.
        let honolulu = calendar("Pacific/Honolulu")
        XCTAssertEqual(task.occurrence(after: date("2026-11-15 14:00", "Pacific/Honolulu"), calendar: honolulu),
                       date("2026-11-17 09:00", "Pacific/Honolulu"))
    }

    func testWeeklyHourlyAndOnceOccurrences() {
        let zone = "Europe/Berlin", calendar = calendar(zone)
        // 2026-11-17 is a Tuesday: Monday and Wednesday at 9:00 next run on Wednesday.
        let weekly = ScheduledTask(repeats: .weekly, time: DateComponents(hour: 9, minute: 0), weekdays: [2, 4])
        XCTAssertEqual(weekly.occurrence(after: date("2026-11-17 12:00", zone), calendar: calendar), date("2026-11-18 09:00", zone))
        XCTAssertEqual(weekly.summary(calendar: calendar).hasPrefix("Mon, Wed at"), true)

        var hourly = ScheduledTask(repeats: .hours, hours: 3)
        hourly.anchor = date("2026-11-17 09:00", zone)
        XCTAssertEqual(hourly.occurrence(after: date("2026-11-17 08:00", zone), calendar: calendar), date("2026-11-17 09:00", zone))
        XCTAssertEqual(hourly.occurrence(after: date("2026-11-17 09:00", zone), calendar: calendar), date("2026-11-17 12:00", zone))
        XCTAssertEqual(hourly.occurrence(after: date("2026-11-17 13:10", zone), calendar: calendar), date("2026-11-17 15:00", zone))

        let once = ScheduledTask(repeats: .once, time: DateComponents(year: 2026, month: 12, day: 1, hour: 18, minute: 30))
        XCTAssertEqual(once.occurrence(after: date("2026-11-17 12:00", zone), calendar: calendar), date("2026-12-01 18:30", zone))
        XCTAssertEqual(once.problem(now: date("2026-12-02 00:00", zone), calendar: calendar), "Give the task a name.")
        var named = once; named.name = "Report"; named.prompt = "Write it."
        XCTAssertEqual(named.problem(now: date("2026-12-02 00:00", zone), calendar: calendar), "Choose a time in the future.")
        XCTAssertNil(named.problem(now: date("2026-11-17 00:00", zone), calendar: calendar))
    }

    // MARK: Runs

    private func task(_ model: AppModel, due: Date, continues: Bool = false, skipMissed: Bool = false) -> String {
        var task = ScheduledTask(name: "Morning review", prompt: "Review yesterday's commits.", runtime: .codex, folder: "/tmp/Project",
                                 repeats: .daily, time: DateComponents(hour: 9, minute: 0), continuesSession: continues, skipMissed: skipMissed)
        task.nextRun = due
        model.scheduledTasks = [task]
        return task.id
    }

    private func runs(_ model: AppModel) -> [QueuedSend] { model.sessions.flatMap(\.queuedSends).filter(\.isAutomation) }

    func testMissedRunsCollapseIntoOneLateRunAndNeverFireTwice() {
        let (model, _) = makeModel()
        let now = Date()
        let id = task(model, due: now.addingTimeInterval(-3 * 86_400))
        model.runDueScheduledTasks(now: now)
        XCTAssertEqual(runs(model).count, 1, "Three missed days are one catch-up run")
        let run = runs(model)[0]
        XCTAssertEqual(ChatMessage.automationLabel(run.kind), "Scheduled · Morning review · ran late")
        XCTAssertEqual(run.text, "Review yesterday's commits.")
        let task = model.scheduledTasks.first { $0.id == id }!
        XCTAssertTrue(task.lastRunLate)
        XCTAssertGreaterThan(task.nextRun!, now)
        let session = model.sessions.first { $0.id == task.sessionID }!
        XCTAssertTrue(session.title.hasPrefix("Morning review · "))
        XCTAssertEqual(session.runtime, .codex)
        XCTAssertEqual(session.workspacePath, "/tmp/Project")
        XCTAssertTrue(model.hasActiveWork, "A queued run keeps Quit and Reconnect waiting")

        model.runDueScheduledTasks(now: now)
        model.runDueScheduledTasks(now: now.addingTimeInterval(30))
        XCTAssertEqual(runs(model).count, 1)
    }

    func testARunGoesThroughTheNormalSendPathWithItsLabel() async throws {
        let (model, _) = makeModel()
        model.connection = true
        let now = Date()
        _ = task(model, due: now.addingTimeInterval(-5))
        model.runDueScheduledTasks(now: now)
        let id = try XCTUnwrap(model.scheduledTasks[0].sessionID)
        for _ in 0..<100 where model.sessions.first(where: { $0.id == id })?.messages.isEmpty != false { try await Task.sleep(for: .milliseconds(20)) }
        let session = try XCTUnwrap(model.sessions.first { $0.id == id })
        XCTAssertEqual(session.messages.first?.agentLabel, "Scheduled · Morning review")
        XCTAssertEqual(session.messages.first?.id, model.scheduledTasks[0].lastRunID, "Its derived ID is the sent message's")
        XCTAssertTrue(session.queuedSends.isEmpty)
        XCTAssertTrue(model.scheduledRunActive(model.scheduledTasks[0]), "Working on it: the next run waits")
    }

    func testOnTimeRunHasNoLateNoteAndSkipMissedSkips() {
        let (model, _) = makeModel()
        let now = Date()
        _ = task(model, due: now.addingTimeInterval(-20))
        model.runDueScheduledTasks(now: now)
        XCTAssertEqual(runs(model).map { ChatMessage.automationLabel($0.kind) }, ["Scheduled · Morning review"])

        let (skipping, _) = makeModel()
        let id = task(skipping, due: now.addingTimeInterval(-7_200), skipMissed: true)
        skipping.runDueScheduledTasks(now: now)
        XCTAssertTrue(runs(skipping).isEmpty)
        let skipped = skipping.scheduledTasks.first { $0.id == id }!
        XCTAssertEqual(skipped.lastSkipped, now.addingTimeInterval(-7_200))
        XCTAssertGreaterThan(skipped.nextRun!, now)
    }

    func testABusyDestinationQueuesAndTheNextRunWaitsForThePreviousOne() {
        let (model, _) = makeModel()
        var busy = CompanionSession(id: "dest", runtimeID: "live", title: "Morning review", state: .working,
                                    messages: [ChatMessage(role: "user", text: "Something of mine")], parentTurnComplete: false)
        busy.runtime = .codex
        model.sessions.append(busy)
        let now = Date()
        let id = task(model, due: now.addingTimeInterval(-10), continues: true)
        model.scheduledTasks[0].sessionID = "dest"
        model.runDueScheduledTasks(now: now)
        XCTAssertEqual(model.sessions.first { $0.id == "dest" }?.queuedSends.count, 1, "The run waits in the busy session's queue")
        XCTAssertNil(model.sessions.first { $0.id == "dest" }?.pendingSubmission, "It never interrupts")

        // The next occurrence comes due while the first still waits: it does not start.
        model.scheduledTasks[0].nextRun = now.addingTimeInterval(-1)
        model.runDueScheduledTasks(now: now.addingTimeInterval(1))
        XCTAssertEqual(runs(model).count, 1)
        XCTAssertEqual(model.runScheduledTaskNow(id), "The previous run is still sending or working.")

        // Delivered and working: still the previous run.
        let runID = model.scheduledTasks[0].lastRunID!
        model.update("dest") {
            $0.queuedSends = []
            $0.messages.append(ChatMessage(id: runID, role: "user", text: "Review", turnID: runID, kind: ChatMessage.scheduledKind("Morning review", late: false)))
        }
        XCTAssertTrue(model.scheduledRunActive(model.scheduledTasks[0]))
        // Finished: the waiting occurrence runs, in the same session.
        model.update("dest") { $0.state = .finished; $0.parentTurnComplete = true }
        model.runDueScheduledTasks(now: now.addingTimeInterval(2))
        XCTAssertEqual(model.sessions.first { $0.id == "dest" }?.queuedSends.count, 1)
        XCTAssertEqual(model.sessions.filter { $0.title.hasPrefix("Morning review") }.count, 1)
    }

    func testRestartAfterQueueingNeverQueuesTheSameOccurrenceAgain() throws {
        let (model, store) = makeModel()
        let now = Date()
        let due = now.addingTimeInterval(-60)
        _ = task(model, due: due)
        XCTAssertTrue(model.saveScheduledTasks())
        let stale = try Data(contentsOf: model.scheduledTasksURL)
        model.runDueScheduledTasks(now: now)
        XCTAssertEqual(runs(model).count, 1)
        model.save()
        // As if the app quit after saving the queue but before saving the task.
        try stale.write(to: model.scheduledTasksURL)
        model.shutdown()

        let (reopened, _) = makeModel(folder: store)
        reopened.sessions = try JSONDecoder().decode([CompanionSession].self, from: Data(contentsOf: store.appendingPathComponent("sessions.json")))
        reopened.loadScheduledTasks()
        XCTAssertEqual(reopened.scheduledTasks.first?.nextRun, due)
        reopened.runDueScheduledTasks(now: now)
        XCTAssertEqual(runs(reopened).count, 1, "The occurrence's derived ID finds the run already queued")
        XCTAssertEqual(reopened.scheduledTasks[0].lastRunID, runs(reopened)[0].id, "The task adopts the run, so the next waits for it")
        XCTAssertNotNil(reopened.scheduledTasks[0].sessionID)
        XCTAssertTrue(reopened.scheduledRunActive(reopened.scheduledTasks[0]))
        XCTAssertGreaterThan(reopened.scheduledTasks[0].nextRun!, now)
    }

    func testAStaleFormKeepsTheRunAndAFailedSaveKeepsTheOccurrence() throws {
        let (model, _) = makeModel()
        let now = Date()
        _ = task(model, due: now.addingTimeInterval(-10), continues: true)
        let form = model.scheduledTasks[0]
        model.runDueScheduledTasks(now: now)
        let run = model.scheduledTasks[0].lastRunID
        XCTAssertNotNil(run)
        var edited = form
        edited.prompt = "Review yesterday's commits and open issues."
        XCTAssertNil(model.saveScheduledTask(edited, now: now))
        XCTAssertEqual(model.scheduledTasks[0].lastRunID, run, "Saving a form opened before the run keeps it")
        XCTAssertEqual(model.scheduledTasks[0].sessionID, model.sessions.first { $0.queuedSends.contains { $0.id == run } }?.id)
        XCTAssertNotNil(model.runScheduledTaskNow(form.id), "Its run still blocks another")

        let (blocked, store) = makeModel()
        let due = now.addingTimeInterval(-10)
        _ = task(blocked, due: due)
        // A folder where the registry belongs makes its save fail.
        try FileManager.default.createDirectory(at: store.appendingPathComponent("sessions.json"), withIntermediateDirectories: true)
        blocked.runDueScheduledTasks(now: now)
        XCTAssertTrue(runs(blocked).isEmpty)
        XCTAssertEqual(blocked.scheduledTasks[0].nextRun, due, "Not queued, so not used up")
        XCTAssertNil(blocked.scheduledTasks[0].lastRunID)
    }

    func testAutomationWaitsForDelegatedChildren() async throws {
        let (model, _) = makeModel()
        var parent = CompanionSession(id: "p", runtimeID: "live", title: "Parent", state: .working,
                                      messages: [ChatMessage(role: "user", text: "Go")], parentTurnComplete: true)
        parent.runtime = .codex
        parent.agents = [ChildAgent(id: "c", title: "Child", state: .working, sessionID: "child")]
        parent.queuedSends = [QueuedSend(id: "q", text: "Check failed", kind: ChatMessage.pullRequestWatch)]
        model.sessions.append(parent)
        XCTAssertFalse(parent.isBusyIgnoringDelegates)
        model.processDelegationWakes()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.sessions.first { $0.id == "p" }?.queuedSends.map(\.id), ["q"], "It waits while a child works")
    }

    func testUnreadableTasksFileIsNeverOverwritten() throws {
        let (model, _) = makeModel()
        try FileManager.default.createDirectory(at: model.scheduledTasksURL, withIntermediateDirectories: true)
        model.loadScheduledTasks()
        XCTAssertTrue(model.scheduledTasksUnreadable)
        XCTAssertFalse(model.saveScheduledTasks())
    }

    func testEditPauseAndDelete() {
        let (model, _) = makeModel()
        let now = Date()
        var draft = ScheduledTask(name: " Weekly notes ", prompt: "Summarize the week.", runtime: .codex, folder: "/tmp", repeats: .weekly, weekdays: [])
        XCTAssertEqual(model.saveScheduledTask(draft, now: now), "Choose at least one day.")
        draft.weekdays = [6]
        XCTAssertNil(model.saveScheduledTask(draft, now: now))
        XCTAssertEqual(model.scheduledTasks.map(\.name), ["Weekly notes"])
        XCTAssertGreaterThan(model.scheduledTasks[0].nextRun!, now)

        model.setScheduledTaskPaused(draft.id, true, now: now)
        model.scheduledTasks[0].nextRun = now.addingTimeInterval(-60)
        model.runDueScheduledTasks(now: now)
        XCTAssertTrue(runs(model).isEmpty, "A paused task never runs")
        model.setScheduledTaskPaused(draft.id, false, now: now)
        XCTAssertGreaterThan(model.scheduledTasks[0].nextRun!, now, "Occurrences while paused are skipped")

        XCTAssertNil(model.runScheduledTaskNow(draft.id, now: now))
        XCTAssertEqual(runs(model).count, 1)
        model.deleteScheduledTask(draft.id)
        XCTAssertTrue(model.scheduledTasks.isEmpty)
        XCTAssertTrue(runs(model).isEmpty, "Its unsent run goes with it")
    }

    func testOlderRegistryAndQueueDecodeWithoutTheNewFields() throws {
        let json = #"[{"id":"old","title":"Old","runtime":"codex","queuedSends":[{"id":"q","text":"hi"}]}]"#
        let sessions = try JSONDecoder().decode([CompanionSession].self, from: Data(json.utf8))
        XCTAssertNil(sessions[0].pullRequestWatch)
        XCTAssertFalse(sessions[0].queuedSends[0].isAutomation)
    }

    // MARK: Pull request watch

    private func pr(state: String = "OPEN", mergeable: String = "MERGEABLE", checks: [[String: Any]] = [],
                    reviews: [[String: Any]] = [], comments: [[String: Any]] = []) -> [String: Any] {
        ["number": 12, "url": "https://github.com/owner/repo/pull/12", "state": state, "author": ["login": "me"],
         "mergeable": mergeable, "statusCheckRollup": checks, "reviews": reviews, "comments": comments]
    }
    private func check(_ name: String, _ conclusion: String, run: Int = 1) -> [String: Any] {
        ["__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion,
         "detailsUrl": "https://github.com/owner/repo/actions/runs/\(run)/job/\(run)", "startedAt": "2026-11-16T10:0\(run):00Z"]
    }

    func testPullRequestEventsReportEachThingOnce() {
        var watch = PullRequestWatch(url: "https://github.com/owner/repo/pull/12")
        let old = ["id": "IC_1", "author": ["login": "reviewer"], "url": "https://github.com/owner/repo/pull/12#issuecomment-1"] as [String: Any]
        // First poll: existing comments are a baseline; a failing check is reported.
        var result = PullRequestEvents.evaluate(pr(checks: [check("build", "FAILURE"), check("lint", "SUCCESS")], comments: [old]), watch: &watch)
        XCTAssertEqual(result.message, "Check `build` failed on PR #12: https://github.com/owner/repo/actions/runs/1/job/1. Investigate and fix it.")
        XCTAssertFalse(result.ended)
        result = PullRequestEvents.evaluate(pr(checks: [check("build", "FAILURE"), check("lint", "SUCCESS")], comments: [old]), watch: &watch)
        XCTAssertNil(result.message, "A repeated poll sends nothing")

        // A rerun passes; a reviewer asks for changes; comments arrive from the author and a reviewer.
        let mine = ["id": "IC_2", "author": ["login": "me"], "url": "u2"] as [String: Any]
        let theirs = ["id": "IC_3", "author": ["login": "reviewer"], "url": "https://github.com/owner/repo/pull/12#issuecomment-3"] as [String: Any]
        let changes = ["id": "PRR_1", "author": ["login": "reviewer"], "state": "CHANGES_REQUESTED", "body": "Please rename"] as [String: Any]
        result = PullRequestEvents.evaluate(pr(checks: [check("build", "SUCCESS", run: 2), check("lint", "SUCCESS")],
                                               reviews: [changes], comments: [old, mine, theirs]), watch: &watch)
        XCTAssertEqual(result.message?.components(separatedBy: "\n"), [
            "All checks pass on PR #12 now: https://github.com/owner/repo/pull/12.",
            "reviewer requested changes on PR #12: https://github.com/owner/repo/pull/12. Address the review.",
            "reviewer commented on PR #12: https://github.com/owner/repo/pull/12#issuecomment-3. Read it and respond if it needs a change."])
        XCTAssertFalse(result.message!.contains("Please rename"), "Other people's text stays out of the prompt")

        // Conflicts once, then merged ends the watch.
        result = PullRequestEvents.evaluate(pr(mergeable: "CONFLICTING", checks: [check("build", "SUCCESS", run: 2)]), watch: &watch)
        XCTAssertEqual(result.message, "PR #12 has merge conflicts with its base branch: https://github.com/owner/repo/pull/12. Resolve them.")
        XCTAssertNil(PullRequestEvents.evaluate(pr(mergeable: "CONFLICTING"), watch: &watch).message)

        // Inline review comments (an empty review summary) and thread replies, newest first from `gh api`.
        let inline: [[String: Any]] = [
            ["id": 903, "user": ["login": "reviewer"], "html_url": "https://github.com/owner/repo/pull/12#discussion_r903"],
            ["id": 902, "user": ["login": "me"], "html_url": "u"],
            ["id": 901, "user": ["login": "reviewer"], "html_url": "https://github.com/owner/repo/pull/12#discussion_r901"]]
        let quiet = ["id": "PRR_2", "author": ["login": "reviewer"], "state": "COMMENTED", "body": ""] as [String: Any]
        result = PullRequestEvents.evaluate(pr(mergeable: "CONFLICTING", reviews: [changes, quiet]), reviewComments: inline, watch: &watch)
        XCTAssertEqual(result.message, "reviewer left 2 review comments on PR #12: https://github.com/owner/repo/pull/12#discussion_r901. Read them and respond if they need a change.")
        XCTAssertNil(PullRequestEvents.evaluate(pr(mergeable: "CONFLICTING"), reviewComments: inline, watch: &watch).message)
        XCTAssertEqual(PullRequestEvents.reviewCommentsArguments("https://github.com/owner/repo/pull/12")?[3], "repos/owner/repo/pulls/12/comments")
        result = PullRequestEvents.evaluate(pr(state: "MERGED"), watch: &watch)
        XCTAssertEqual(result.message, "PR #12 was merged: https://github.com/owner/repo/pull/12.")
        XCTAssertTrue(result.ended)
    }

    func testWatchPollsQueueMessagesBackOffOnErrorsAndStopOnMerge() async throws {
        let (model, _) = makeModel()
        var session = CompanionSession(id: "s", runtimeID: "live", title: "Fix", state: .working,
                                       messages: [ChatMessage(role: "user", text: "Go")], parentTurnComplete: false)
        session.runtime = .codex
        session.pullRequest = "https://github.com/owner/repo/pull/12"
        model.sessions.append(session)
        var answers: [Result<[String: Any], Error>] = []
        var calls: [[String]] = []
        model.pullRequestRunner = { arguments in
            calls.append(arguments)
            if arguments.first == "auth" { return "Logged in" }
            if arguments.first == "api" { return "[]" }
            let next = answers.removeFirst()
            return String(decoding: try JSONSerialization.data(withJSONObject: try next.get()), as: UTF8.self)
        }
        answers = [.success(pr(checks: [check("build", "FAILURE")]))]
        let problem = await model.watchPullRequest("s")
        XCTAssertNil(problem)
        XCTAssertNotNil(model.sessions.first { $0.id == "s" }?.pullRequestWatch)
        for _ in 0..<50 where model.sessions.first(where: { $0.id == "s" })?.queuedSends.isEmpty != false { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(calls.contains(["pr", "view", "https://github.com/owner/repo/pull/12", "--json", PullRequestEvents.fields]))
        let queued = model.sessions.first { $0.id == "s" }!.queuedSends
        XCTAssertEqual(queued.map(\.kind), [ChatMessage.pullRequestWatch], "Queued behind the busy turn")
        XCTAssertEqual(ChatMessage.automationLabel(queued[0].kind), "PR watch")

        answers = [.success(pr(checks: [check("build", "FAILURE")]))]
        await model.pollPullRequest("s")
        XCTAssertEqual(model.sessions.first { $0.id == "s" }!.queuedSends.count, 1, "Nothing new, nothing sent")

        answers = [.failure(AppError("HTTP 502"))]
        await model.pollPullRequest("s")
        XCTAssertEqual(model.pullRequestPolls["s"]?.error, "HTTP 502")
        XCTAssertGreaterThan(model.pullRequestPolls["s"]!.next, Date().addingTimeInterval(200), "Errors back off")
        XCTAssertEqual(model.sessions.first { $0.id == "s" }!.queuedSends.count, 1, "Errors never message the session")

        answers = [.success(pr(state: "MERGED"))]
        await model.pollPullRequest("s")
        XCTAssertNil(model.sessions.first { $0.id == "s" }?.pullRequestWatch, "Merged stops the watch")
        XCTAssertEqual(model.sessions.first { $0.id == "s" }!.queuedSends.count, 2)
        XCTAssertNil(model.pullRequestPolls["s"])

        // Watching again starts a new generation, so its first message never reuses an old ID.
        let first = queued[0].id
        answers = [.success(pr(checks: [check("build", "FAILURE", run: 3)]))]
        _ = await model.watchPullRequest("s")
        for _ in 0..<50 where model.sessions.first(where: { $0.id == "s" })!.queuedSends.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        let ids = model.sessions.first { $0.id == "s" }!.queuedSends.map(\.id)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(ids.first, first)
        model.stopWatchingPullRequest("s")
    }

    func testWatchNeedsASignedInGitHubCLIAndAGitHubLink() async {
        let (model, _) = makeModel()
        var session = CompanionSession(id: "s", title: "Fix")
        session.pullRequest = "https://github.com/owner/repo/pull/12"
        model.sessions.append(session)
        model.pullRequestRunner = { _ in throw AppError("You are not logged into any GitHub hosts.") }
        let problem = await model.watchPullRequest("s")
        XCTAssertEqual(problem, "Watching needs the GitHub CLI installed and signed in. Run gh auth login in Terminal, then try again.")
        XCTAssertNil(model.sessions.first { $0.id == "s" }?.pullRequestWatch)
        model.update("s") { $0.pullRequest = "https://gitlab.com/owner/repo/pull/12" }
        let other = await model.watchPullRequest("s")
        XCTAssertEqual(other, "Only pull requests on github.com can be watched.")
    }
}
