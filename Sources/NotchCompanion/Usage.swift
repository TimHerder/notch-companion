import Foundation

/// One account limit window as a runtime reported it. Unknown values stay nil
/// and display as —, never as zero.
struct RuntimeRateLimit: Codable, Equatable, Identifiable {
    var name: String
    var usedPercent: Double?
    var resetsAt: Date?
    var reached = false
    var reportedAt = Date()
    var id: String { name }

    /// The share used for a bar: reached is full, unknown stays nil (never 0).
    var fraction: Double? { reached ? 1 : usedPercent.map { min(1, max(0, $0 / 100)) } }
    /// The window reset after this report, so its numbers are out of date.
    func isStale(now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }

    /// Shorter windows first, a plain window before its per-model or
    /// per-bucket variants, extra usage last. Ties keep their order.
    static func sorted(_ limits: [Self]) -> [Self] {
        func order(_ limit: Self) -> (Int, Int) {
            let parts = limit.name.components(separatedBy: " · ")
            if limit.name.lowercased().hasPrefix("extra usage") { return (.max, parts.count) }
            return (parts.lazy.compactMap(minutes(label:)).first ?? .max - 1, parts.count)
        }
        return limits.sorted { order($0) < order($1) }
    }

    /// The inverse of `label(minutes:)`.
    static func minutes(label: String) -> Int? {
        switch label {
        case "Weekly": return 10_080
        case "Daily": return 1_440
        default:
            let pieces = label.split(separator: "-")
            guard pieces.count == 2, let count = Int(pieces[0]) else { return nil }
            return ["minute": 1, "hour": 60, "day": 1_440][String(pieces[1])].map { $0 * count }
        }
    }

    /// `account/rateLimits/read` (multi-bucket or single) or the
    /// `account/rateLimits/updated` notification's snapshot.
    static func codex(_ value: [String: Any]) -> [Self] {
        let buckets = (value["rateLimitsByLimitId"] as? [String: [String: Any]]).map { Array($0.values) }
            ?? [value["rateLimits"] as? [String: Any]].compactMap { $0 }
        return buckets.sorted { ($0["limitId"] as? String ?? "") < ($1["limitId"] as? String ?? "") }.flatMap { snapshot -> [Self] in
            // Name extra buckets so a single-bucket update merges into the same rows.
            let id = snapshot["limitId"] as? String
            let prefix = id == nil || id == "codex" ? nil : snapshot["limitName"] as? String ?? id
            return ["primary", "secondary"].compactMap { key in
                guard let window = snapshot[key] as? [String: Any] else { return nil }
                return Self(name: [prefix, label(minutes: window["windowDurationMins"] as? Int)].compactMap { $0 }.joined(separator: " · "),
                            usedPercent: number(window["usedPercent"]), resetsAt: date(window["resetsAt"]),
                            reached: snapshot["rateLimitReachedType"] is String)
            }
        }
    }

    /// Claude Code's `rate_limit_event.rate_limit_info`. Utilization is a fraction.
    static func claude(_ info: [String: Any]) -> [Self] {
        let labels = ["five_hour": "5-hour", "seven_day": "Weekly", "seven_day_opus": "Weekly · Opus",
                      "seven_day_sonnet": "Weekly · Sonnet", "seven_day_overage_included": "Weekly · with extra usage", "overage": "Extra usage"]
        let current = info["rateLimitType"] as? String
        let reached = info["status"] as? String == "rejected"
        if let windows = info["unifiedWindows"] as? [String: [String: Any]], !windows.isEmpty {
            return windows.sorted { $0.key < $1.key }.map { key, window in
                Self(name: labels[key] ?? key, usedPercent: number(window["utilization"]).map { $0 * 100 },
                     resetsAt: date(window["resetsAt"]), reached: reached && key == current)
            }
        }
        guard let current else { return [] }
        return [Self(name: labels[current] ?? current, usedPercent: number(info["utilization"]).map { $0 * 100 },
                     resetsAt: date(info["resetsAt"]), reached: reached)]
    }

    static func label(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Limit" }
        switch minutes {
        case 10_080: return "Weekly"
        case 1_440: return "Daily"
        case _ where minutes % 1_440 == 0: return "\(minutes / 1_440)-day"
        case _ where minutes % 60 == 0: return "\(minutes / 60)-hour"
        default: return "\(minutes)-minute"
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
    private static func date(_ value: Any?) -> Date? { number(value).map { Date(timeIntervalSince1970: $0) } }
}

/// One model's tokens in one turn, split the way providers price them.
/// `input` excludes cache reads and writes.
struct ModelTokens: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// The cache writes kept for an hour; nil when the runtime did not tell them apart.
    var cacheWriteHour: Int?

    var total: Int { input + output + cacheRead + cacheWrite }

    /// `session.info.turn_usage`: `{model: {input, output, cache_read, cache_write, cache_write_1h?}}`.
    static func decode(_ value: Any?) -> [String: Self]? {
        guard let rows = value as? [String: [String: Any]], !rows.isEmpty else { return nil }
        var result: [String: Self] = [:]
        for (model, row) in rows {
            func count(_ key: String) -> Int? { (row[key] as? Int).flatMap { $0 >= 0 ? $0 : nil } }
            guard !model.isEmpty, let input = count("input"), let output = count("output"),
                  let read = count("cache_read"), let write = count("cache_write") else { return nil }
            let hour = count("cache_write_1h")
            guard (hour ?? 0) <= write else { return nil }
            result[model] = Self(input: input, output: output, cacheRead: read, cacheWrite: write, cacheWriteHour: hour)
        }
        return result
    }

    var payload: [String: Any] {
        var row: [String: Any] = ["input": input, "output": output, "cache_read": cacheRead, "cache_write": cacheWrite]
        if let cacheWriteHour { row["cache_write_1h"] = cacheWriteHour }
        return row
    }
}

/// USD per million tokens at a provider's standard list price.
struct ModelPrice: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    /// Nil where the provider lists no cache-write price (OpenAI's older models bill none).
    var cacheWrite: Double?
    var cacheWriteHour: Double?

    /// Only models whose prices were confirmed on the providers' official pages,
    /// with no tier the recorded usage cannot tell apart, on 2026-11-16:
    /// https://platform.claude.com/docs/en/about-claude/pricing (5-minute and
    /// 1-hour cache writes; Haiku 5.5's prompt-length tiers and Sonnet 4.5's
    /// long-context tier are left out) and https://developers.openai.com/api/docs/pricing
    /// (Standard; GPT-6 and GPT-5.6 bill cache writes Codex does not report, so they are
    /// left out; GPT-5.5 and 5.4 rates are for prompts up to 272K, see CodexProtocolState).
    static let table: [String: Self] = [
        "claude-fable-5-2": .init(input: 8, output: 40, cacheRead: 0.20, cacheWrite: 10, cacheWriteHour: 16),
        "claude-fable-5-1": .init(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.50, cacheWriteHour: 20),
        "claude-fable-5": .init(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.50, cacheWriteHour: 20),
        "claude-opus-5-5": .init(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5, cacheWriteHour: 8),
        "claude-opus-5": .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25, cacheWriteHour: 10),
        "claude-opus-4-8": .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25, cacheWriteHour: 10),
        "claude-opus-4-7": .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25, cacheWriteHour: 10),
        "claude-opus-4-6": .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25, cacheWriteHour: 10),
        "claude-opus-4-5": .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25, cacheWriteHour: 10),
        "claude-sonnet-5-5": .init(input: 2, output: 10, cacheRead: 0.10, cacheWrite: 2.50, cacheWriteHour: 4),
        "claude-sonnet-5": .init(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.50, cacheWriteHour: 4),
        "claude-sonnet-4-6": .init(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75, cacheWriteHour: 6),
        "claude-haiku-4-5": .init(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25, cacheWriteHour: 2),
        "gpt-5.5": .init(input: 5, output: 30, cacheRead: 0.50),
        "gpt-5.4": .init(input: 2.50, output: 15, cacheRead: 0.25),
        "gpt-5.4-mini": .init(input: 0.75, output: 4.50, cacheRead: 0.075),
        "gpt-5.4-nano": .init(input: 0.20, output: 1.25, cacheRead: 0.02),
        "gpt-5.3-codex": .init(input: 1.75, output: 14, cacheRead: 0.175),
        "gpt-5.2": .init(input: 1.75, output: 14, cacheRead: 0.175),
        "gpt-5.1": .init(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5": .init(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5-mini": .init(input: 0.25, output: 2, cacheRead: 0.025),
        "gpt-5-nano": .init(input: 0.05, output: 0.40, cacheRead: 0.005),
    ]

    /// Exact IDs after dropping a dated snapshot suffix or a `[1m]` tag, so
    /// `claude-opus-5` never prices `claude-opus-5-5`.
    static func price(_ model: String) -> Self? {
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let date = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(date) }
        return table[id]
    }

    /// Nil when a cache write's price or retention is unknown: never a guess.
    func cost(_ tokens: ModelTokens) -> Double? {
        var cost = Double(tokens.input) * input + Double(tokens.output) * output + Double(tokens.cacheRead) * cacheRead
        if tokens.cacheWrite > 0 {
            guard let hour = tokens.cacheWriteHour, let cacheWrite, let cacheWriteHour else { return nil }
            cost += Double(tokens.cacheWrite - hour) * cacheWrite + Double(hour) * cacheWriteHour
        }
        return cost / 1_000_000
    }
}

/// Tokens from sessions started here, per harness and day. A day with no
/// reported turn has no total; unreported turns are counted, never as zero.
/// The estimated cost counts priced tokens; the rest are `unpricedTokens`.
struct UsageDay: Identifiable, Equatable {
    var runtime: RuntimeKind
    var day: Date
    var tokens = 0
    var reportedTurns = 0
    var unreportedTurns = 0
    var cost: Double?
    var unpricedTokens = 0
    var id: String { runtime.rawValue + "|" + day.timeIntervalSince1970.description }
    var total: Int? { reportedTurns > 0 ? tokens : nil }

    static func days(_ sessions: [CompanionSession], calendar: Calendar = .current) -> [Self] {
        var rows: [String: Self] = [:]
        for session in sessions {
            for message in session.messages where message.role == "user" && SessionHistory.isVisibleConversation(message) {
                var row = Self(runtime: session.runtime, day: calendar.startOfDay(for: message.createdAt))
                row = rows[row.id] ?? row
                let turn = message.turnID ?? message.id
                if let tokens = session.turnTokens[turn] {
                    row.tokens += tokens; row.reportedTurns += 1
                    var priced = 0
                    for (model, usage) in session.turnUsage[turn] ?? [:] {
                        guard let cost = ModelPrice.price(model)?.cost(usage) else { continue }
                        row.cost = (row.cost ?? 0) + cost; priced += usage.total
                    }
                    row.unpricedTokens += max(0, tokens - priced)
                } else { row.unreportedTurns += 1 }
                rows[row.id] = row
            }
        }
        return rows.values.sorted { $0.day != $1.day ? $0.day > $1.day : $0.runtime.title < $1.runtime.title }
    }
}
