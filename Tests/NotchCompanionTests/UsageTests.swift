import XCTest
@testable import NotchCompanion

@MainActor private final class UsageFixture: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var calls: [(String, [String: Any])] = []
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if method == "runtime.rateLimits" { return ["limits": [RuntimeRateLimit(name: "Weekly", usedPercent: 12)]] }
        if method == "session.create" { return ["session_id": "live", "stored_session_id": "saved"] }
        return [:]
    }
}

@MainActor final class UsageTests: XCTestCase {
    func testCodexRateLimitPayloads() {
        let read = RuntimeRateLimit.codex(["rateLimits": ["limitId": "codex"], "rateLimitsByLimitId": [
            "codex": ["limitId": "codex", "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                      "secondary": ["usedPercent": 7, "windowDurationMins": 10_080]],
            "codex_other": ["limitId": "codex_other", "limitName": "Spark", "primary": ["usedPercent": 100, "windowDurationMins": 300],
                            "rateLimitReachedType": "rate_limit_reached"]]])
        XCTAssertEqual(read.map(\.name), ["5-hour", "Weekly", "Spark · 5-hour"])
        XCTAssertEqual(read.map(\.usedPercent), [42, 7, 100])
        XCTAssertEqual(read[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(read[1].resetsAt, "A missing reset stays unknown")
        XCTAssertEqual(read.map(\.reached), [false, false, true])
        let update = RuntimeRateLimit.codex(["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 43, "windowDurationMins": 300]]])
        XCTAssertEqual(update.map(\.name), ["5-hour"], "A single-bucket update names rows like the read")
        XCTAssertEqual(RuntimeRateLimit.codex([:]), [])
        XCTAssertEqual(RuntimeRateLimit.label(minutes: nil), "Limit")
        XCTAssertEqual(RuntimeRateLimit.label(minutes: 1_440), "Daily")
    }

    func testClaudeRateLimitEvents() {
        let windows = RuntimeRateLimit.claude(["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.5,
            "unifiedWindows": ["five_hour": ["utilization": 0.25, "resetsAt": 1_800_000_000], "seven_day": ["utilization": 0.9, "resetsAt": 1_800_100_000]]])
        XCTAssertEqual(windows.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(windows.map(\.usedPercent), [25, 90])
        let rejected = RuntimeRateLimit.claude(["status": "rejected", "rateLimitType": "seven_day_opus", "resetsAt": 1_800_000_000])
        XCTAssertEqual(rejected.first?.name, "Weekly · Opus")
        XCTAssertNil(rejected.first?.usedPercent, "No utilization is unknown, never 0")
        XCTAssertEqual(rejected.first?.reached, true)
        XCTAssertEqual(RuntimeRateLimit.claude(["status": "allowed"]), [])
    }

    func testClaudeReportsLimitsAndPerTurnTokenDifferences() throws {
        var state = ClaudeProtocolState(sessionID: "s")
        let limits = try state.receive(["type": "rate_limit_event", "session_id": "s", "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.1]])
        XCTAssertEqual(limits.first?.name, "runtime.rateLimits")
        XCTAssertEqual((limits.first?.payload["limits"] as? [RuntimeRateLimit])?.first?.usedPercent, 10)
        func turn(_ usage: [String: Int]) throws -> Int? {
            try state.begin(UUID().uuidString)
            let events = try state.receive(["type": "result", "session_id": "s", "result": "ok", "modelUsage": ["m": usage]])
            return events.first { $0.payload["turn_tokens"] != nil }?.payload["turn_tokens"] as? Int
        }
        XCTAssertEqual(try turn(["inputTokens": 100, "outputTokens": 20, "cacheReadInputTokens": 1_000]), 1_120)
        XCTAssertEqual(try turn(["inputTokens": 150, "outputTokens": 30, "cacheReadInputTokens": 2_000]), 1_060,
                       "modelUsage is cumulative for the process; each turn reports the difference")
    }

    func testCodexTurnTokensNeedAStartingTotalFromThisProcess() throws {
        var state = CodexProtocolState()
        _ = try state.register(["id": "fresh"])
        state.tokenTotals["fresh"] = 0
        _ = try state.register(["id": "resumed"])
        func usage(_ thread: String, _ turn: String, total: Int) -> Int? {
            state.notifications("thread/tokenUsage/updated", ["threadId": thread, "turnId": turn,
                "tokenUsage": ["total": ["totalTokens": total], "last": ["totalTokens": 10]]]).first?.payload["turn_tokens"] as? Int
        }
        _ = state.notifications("turn/started", ["threadId": "fresh", "turn": ["id": "a"]])
        XCTAssertEqual(usage("fresh", "a", total: 500), 500)
        XCTAssertEqual(usage("fresh", "a", total: 800), 800, "A later report replaces the turn's running total")
        _ = state.notifications("turn/started", ["threadId": "resumed", "turn": ["id": "b"]])
        XCTAssertNil(usage("resumed", "b", total: 9_000), "A resumed thread's first turn has no baseline and stays unknown")
        _ = state.notifications("turn/completed", ["threadId": "resumed", "turn": ["id": "b", "status": "completed"]])
        _ = state.notifications("turn/started", ["threadId": "resumed", "turn": ["id": "c"]])
        XCTAssertEqual(usage("resumed", "c", total: 9_400), 400)
        let limits = state.notifications("account/rateLimits/updated", ["rateLimits": ["primary": ["usedPercent": 5, "windowDurationMins": 300]]])
        XCTAssertEqual(limits.first?.name, "runtime.rateLimits")
    }

    func testAggregationKeepsUnknownUsageUnknown() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        func message(_ id: String, _ date: Date) -> ChatMessage { ChatMessage(id: id, role: "user", text: id, createdAt: date.addingTimeInterval(60), turnID: id) }
        var codex = CompanionSession(); codex.runtime = .codex
        codex.messages = [message("a", today), message("b", today), message("c", yesterday)]
        codex.turnTokens = ["a": 1_000, "b": 0]
        var hermes = CompanionSession(); hermes.runtime = .hermes
        hermes.messages = [message("d", today), ChatMessage(role: "assistant", text: "answer")]
        let days = UsageDay.days([codex, hermes], calendar: calendar)
        XCTAssertEqual(days.map(\.runtime), [.codex, .hermes, .codex])
        XCTAssertEqual(days[0].total, 1_000)
        XCTAssertEqual(days[0].reportedTurns, 2, "A reported zero is a real report")
        XCTAssertNil(days[1].total, "A harness that reports nothing has no total, not 0")
        XCTAssertEqual(days[1].unreportedTurns, 1)
        XCTAssertNil(days[2].total)
        XCTAssertEqual(UsageView.describe(days[1]), "—")
        var mixed = days[0]; mixed.unreportedTurns = 3
        XCTAssertEqual(UsageView.describe(mixed), "1k tokens · 3 unreported")
        XCTAssertEqual(UsageView.describe(RuntimeRateLimit(name: "Weekly")), "— used")
    }

    func testLimitBarsNeverShowUnknownAsZero() {
        XCTAssertNil(RuntimeRateLimit(name: "Weekly").fraction, "An unreported percentage draws a bare track, not 0 %")
        XCTAssertEqual(RuntimeRateLimit(name: "5-hour", reached: true).fraction, 1, "Reached fills the bar without a percentage")
        XCTAssertEqual(RuntimeRateLimit(name: "Weekly", usedPercent: 140).fraction, 1)
        XCTAssertEqual(RuntimeRateLimit(name: "Weekly", usedPercent: -5).fraction, 0)
        XCTAssertEqual(try XCTUnwrap(RuntimeRateLimit(name: "Weekly", usedPercent: 42.4).fraction), 0.424, accuracy: 0.000_1)
        XCTAssertEqual(UsageView.usedText(RuntimeRateLimit(name: "Weekly", usedPercent: 42.6)), "43%")
        XCTAssertEqual(UsageView.usedText(RuntimeRateLimit(name: "Weekly", usedPercent: 0)), "0%", "A reported zero is real")
        XCTAssertEqual(UsageView.usedText(RuntimeRateLimit(name: "Weekly")), "—")
        XCTAssertEqual(UsageView.usedText(RuntimeRateLimit(name: "5-hour", usedPercent: 100, reached: true)), "Limit reached")
        let context = RuntimeContextUsage(used: 220_000, limit: 200_000)
        XCTAssertEqual(context.ratio, 1.1, "The headline reads an over-limit report as one")
        XCTAssertEqual(context.fraction, 1, "The gauge and bar stay clamped")
    }

    func testResetAndReportTimesReadRelativeWithinADayThenDated() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Two-digit hours throughout, so a user's leading-zero time preference cannot change the text.
        let now = Date(timeIntervalSince1970: 1_800_014_400) // Fri 15 Jan 2027 12:00 UTC
        func reset(in seconds: TimeInterval, percent: Double? = 42, reached: Bool = false) -> RuntimeRateLimit {
            RuntimeRateLimit(name: "5-hour", usedPercent: percent, resetsAt: now.addingTimeInterval(seconds), reached: reached)
        }
        func text(_ limit: RuntimeRateLimit) -> String? { UsageView.resetText(limit, now: now, calendar: calendar) }
        XCTAssertNil(text(RuntimeRateLimit(name: "Weekly")), "No reset reported, no line")
        XCTAssertEqual(text(reset(in: 30)), "Resets in 1 min", "Counts up, never claims an earlier reset")
        XCTAssertEqual(text(reset(in: 45 * 60)), "Resets in 45 min")
        XCTAssertEqual(text(reset(in: 3_600 - 5)), "Resets in 1 h")
        XCTAssertEqual(text(reset(in: 100 * 60)), "Resets in 1 h 40 min")
        XCTAssertEqual(text(reset(in: 2 * 86_400 + 6 * 3_600 + 20 * 60)), "Resets Sun 18:20", "Beyond a day: weekday and the same time style")
        XCTAssertEqual(text(reset(in: 10 * 86_400)), "Resets 25 Jan 12:00", "Beyond six days the weekday would be ambiguous")
        XCTAssertEqual(UsageView.describe(reset(in: 100 * 60), now: now, calendar: calendar), "42% used · resets in 1 h 40 min")
        let passed = reset(in: -60, percent: 100, reached: true)
        XCTAssertTrue(passed.isStale(now: now))
        XCTAssertEqual(text(passed), "Reset since last report")
        XCTAssertEqual(UsageView.usedText(passed, now: now), "—", "A window that reset since the report is unknown again")
        XCTAssertEqual(UsageView.describe(passed, now: now, calendar: calendar), "— used · reset since last report")

        XCTAssertEqual(UsageView.reportedText(now.addingTimeInterval(-2 * 3_600), now: now, calendar: calendar), "Updated 10:00")
        XCTAssertEqual(UsageView.reportedText(now.addingTimeInterval(-26 * 3_600), now: now, calendar: calendar), "Updated 14 Jan",
                       "An old report shows its date, never a time that looks like today")
        func caption(_ context: RuntimeContextUsage) -> String {
            var context = context
            context.reportedAt = now.addingTimeInterval(-2 * 3_600)
            return UsageView.contextCaption(context, now: now, calendar: calendar)
        }
        XCTAssertEqual(caption(RuntimeContextUsage(used: 42_000, limit: 200_000)), "Updated 10:00")
        XCTAssertEqual(caption(RuntimeContextUsage(used: 42_000, limit: 200_000, estimated: true)), "Estimate · Updated 10:00")
        XCTAssertEqual(caption(RuntimeContextUsage(used: 42_000)), "Window not reported · Updated 10:00")
        XCTAssertEqual(caption(RuntimeContextUsage(used: 220_000, limit: 200_000)), "Over the reported window · Updated 10:00")
    }

    func testDatesReadInTheAppLanguageWithTheSystemRegionAndClock() throws {
        let now = Date(timeIntervalSince1970: 1_800_014_400) // Fri 15 Jan 2027 12:00 UTC
        func calendar(system: String) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale.app(language: "en", system: Locale(identifier: system))
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }
        let reset = RuntimeRateLimit(name: "Weekly", usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(UsageView.resetText(reset, now: now, calendar: calendar(system: "de_DE")), "Resets Sun 12:00",
                       "An English weekday on a German system, keeping its 24-hour clock")
        XCTAssertEqual(UsageView.day(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar(system: "de_DE")).prefix(4), "Tue ")
        let twelveHour = try XCTUnwrap(UsageView.resetText(reset, now: now, calendar: calendar(system: "de_DE@hours=h12")))
        XCTAssertTrue(twelveHour.hasPrefix("Resets Sun 12:00") && twelveHour.hasSuffix("PM"), "A 12-hour preference stays: \(twelveHour)")
        // The shared default takes the bundle's language and the system's region and clock.
        let app = try XCTUnwrap(Calendar.app.locale)
        XCTAssertEqual(app.language.languageCode, Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en").languageCode)
        XCTAssertEqual(app.region, Locale.autoupdatingCurrent.region)
        XCTAssertEqual(app.hourCycle, Locale.autoupdatingCurrent.hourCycle)
    }

    func testContextHeadlineShowsWhatIsKnown() {
        XCTAssertEqual(UsageView.contextHeadline(nil), "—", "No report yet")
        XCTAssertEqual(UsageView.contextHeadline(RuntimeContextUsage(used: 42_000)), "42k used", "No window: the tokens, never a dash")
        XCTAssertEqual(UsageView.contextHeadline(RuntimeContextUsage(used: 42_000, estimated: true)), "≈42k used")
        XCTAssertEqual(UsageView.contextHeadline(RuntimeContextUsage(used: 42_000, limit: 200_000, estimated: true)), "≈21%")
        XCTAssertEqual(UsageView.contextHeadline(RuntimeContextUsage(used: 220_000, limit: 200_000)), "110%", "Unclamped over the window")
    }

    func testLimitWindowsShowShortestFirstAndExtraUsageLast() {
        // Claude's windows arrive sorted by native key, which puts overage second.
        let claude = RuntimeRateLimit.claude(["status": "allowed", "unifiedWindows": [
            "five_hour": ["utilization": 0.1], "overage": ["utilization": 0.2], "seven_day": ["utilization": 0.3],
            "seven_day_opus": ["utilization": 0.4], "seven_day_sonnet": ["utilization": 0.5]]])
        XCTAssertEqual(RuntimeRateLimit.sorted(claude).map(\.name), ["5-hour", "Weekly", "Weekly · Opus", "Weekly · Sonnet", "Extra usage"])
        let codex = ["Weekly", "Spark · Weekly", "Limit", "5-hour", "Spark · 5-hour", "90-minute"].map { RuntimeRateLimit(name: $0) }
        XCTAssertEqual(RuntimeRateLimit.sorted(codex).map(\.name), ["90-minute", "5-hour", "Spark · 5-hour", "Weekly", "Spark · Weekly", "Limit"],
                       "A plain window precedes its bucket's; an unknown duration sorts after known ones")
        XCTAssertEqual(RuntimeRateLimit.minutes(label: RuntimeRateLimit.label(minutes: 4_320)), 4_320, "Reads back what label(minutes:) writes")
    }

    func testAppModelStoresLimitsAcrossLaunchesAndRecordsTurnTokens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "notch-usage-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(["codex": RuntimeRoute.defaultProfile(.codex, defaults: preferences),
                         "hermes": RuntimeRoute.defaultProfile(.hermes, defaults: preferences)], forKey: "runtime.configuredProfiles")
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let transport = UsageFixture()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: transport, preferences: preferences)
        XCTAssertFalse(model.showUsage, "The page is off by default")
        model.receive("runtime.rateLimits", payload: ["runtime": "claude", "limits": [RuntimeRateLimit(name: "5-hour", usedPercent: 30), RuntimeRateLimit(name: "Weekly", usedPercent: 60)]])
        model.receive("runtime.rateLimits", payload: ["runtime": "claude", "limits": [RuntimeRateLimit(name: "5-hour", usedPercent: 35)]])
        XCTAssertEqual(model.rateLimits["claude"]?.map(\.usedPercent), [35, 60], "An update replaces its window and keeps the others")
        await model.refreshRateLimits()
        XCTAssertEqual(transport.calls.map { $0.1["runtime"] as? String }, ["codex"], "Only ready runtimes that report limits are asked")
        await model.connect()
        await model.newSession(showPanel: false, runtime: .codex)
        model.draft = "Count me"
        await model.send()
        let turn = try XCTUnwrap(model.current?.latestUserTurnID, model.errorMessage ?? "no error")
        model.receive("session.info", payload: ["session_id": "", "turn_tokens": 7])
        XCTAssertTrue(model.current?.turnTokens.isEmpty == true, "Unbound events are ignored")
        model.sessions[0].runtimeID = "live"
        model.receive("session.info", payload: ["session_id": "live", "turn_tokens": 40])
        model.receive("session.info", payload: ["session_id": "live", "turn_tokens": 90])
        XCTAssertEqual(model.current?.turnTokens, [turn: 90])
        model.shutdown()
        let restored = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false, client: UsageFixture(), preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.rateLimits["codex"]?.first?.usedPercent, 12)
        XCTAssertEqual(restored.rateLimits["claude"]?.count, 2)
        XCTAssertEqual(restored.sessions.first { $0.runtime == .codex }?.turnTokens, [turn: 90])
    }
}
