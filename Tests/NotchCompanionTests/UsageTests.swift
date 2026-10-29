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
