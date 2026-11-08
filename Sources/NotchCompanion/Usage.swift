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

/// Tokens from sessions started here, per harness and day. A day with no
/// reported turn has no total; unreported turns are counted, never as zero.
struct UsageDay: Identifiable, Equatable {
    var runtime: RuntimeKind
    var day: Date
    var tokens = 0
    var reportedTurns = 0
    var unreportedTurns = 0
    var id: String { runtime.rawValue + "|" + day.timeIntervalSince1970.description }
    var total: Int? { reportedTurns > 0 ? tokens : nil }

    static func days(_ sessions: [CompanionSession], calendar: Calendar = .current) -> [Self] {
        var rows: [String: Self] = [:]
        for session in sessions {
            for message in session.messages where message.role == "user" && SessionHistory.isVisibleConversation(message) {
                var row = Self(runtime: session.runtime, day: calendar.startOfDay(for: message.createdAt))
                row = rows[row.id] ?? row
                if let tokens = session.turnTokens[message.turnID ?? message.id] {
                    row.tokens += tokens; row.reportedTurns += 1
                } else { row.unreportedTurns += 1 }
                rows[row.id] = row
            }
        }
        return rows.values.sorted { $0.day != $1.day ? $0.day > $1.day : $0.runtime.title < $1.runtime.title }
    }
}
