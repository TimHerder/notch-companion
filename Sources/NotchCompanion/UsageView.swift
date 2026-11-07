import SwiftUI

/// Account limits the runtimes report, and tokens from sessions started here.
struct UsageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let theme = PanelTheme.current
        let runtimes = RuntimeKind.allCases.filter {
            $0.capabilities.rateLimits == true && (model.readyRuntimes.contains($0) || model.rateLimits[$0.rawValue] != nil)
        }
        let days = UsageDay.days(model.sessions)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                if theme == .instrument {
                    RuleLabel(title: "Account limits") { refreshControls }
                        .accessibilityAddTraits(.isHeader)
                } else {
                    HStack {
                        heading("Account limits")
                        Spacer(minLength: 0)
                        refreshControls
                    }
                }
                if runtimes.isEmpty { note("Set up Codex or Claude Code to see their account limits here.") }
                ForEach(runtimes) { runtime in
                    let limits = RuntimeRateLimit.sorted(model.rateLimits[runtime.rawValue] ?? [])
                    SettingsGroup {
                        SettingsRow(runtime.title, symbol: "terminal.fill", tint: .gray) {
                            reported(limits.map(\.reportedAt).max().map { Self.reportedText($0) } ?? "—")
                        }
                        ForEach(limits) { limit in
                            // SettingsRow's divider and insets around the stacked row.
                            Rectangle().fill(PanelTheme.pick(Color.white.opacity(0.06), CompanionStyle.separator, Color.white.opacity(0.08)))
                                .frame(height: 0.5).padding(.leading, PanelTheme.pick(14, 12, 0))
                            UsageLimitRow(limit: limit).font(.system(size: 13))
                                .padding(.horizontal, theme == .refined ? 14 : 12).padding(.vertical, 10)
                        }
                    }
                    if let error = model.rateLimitErrors[runtime.rawValue] { note(error).foregroundStyle(CompanionStyle.amber) }
                    else if limits.isEmpty {
                        note(runtime == .claude ? "Claude Code reports its limits during a turn." : "Not reported yet. Refresh to ask \(runtime.title).")
                    }
                }
                if theme == .instrument {
                    RuleLabel("Sessions started here").padding(.top, 10).accessibilityAddTraits(.isHeader)
                } else {
                    heading("Sessions started here").padding(.top, 12)
                }
                if days.isEmpty { note("No messages sent from here yet.") }
                else {
                    SettingsGroup {
                        ForEach(Array(days.prefix(30).enumerated()), id: \.element.id) { index, day in
                            SettingsRow(Self.day(day.day) + " · " + day.runtime.title, divider: index > 0) {
                                if theme == .instrument {
                                    Text(Self.describe(day)).font(CompanionStyle.mono(11)).monospacedDigit()
                                } else {
                                    Text(Self.describe(day)).monospacedDigit().foregroundStyle(CompanionStyle.secondary)
                                }
                            }
                        }
                    }
                    note("Tokens your harnesses reported for each message sent here, including cached input. — means none were reported.")
                }
            }
            .padding(.top, PanelTheme.pick(8, 10, 8)).padding(.bottom, PanelTheme.pick(12, 10, 8))
        }
        .modifier(UsageScrollEdge())
        .task { await model.refreshRateLimits() }
    }

    @ViewBuilder private var refreshControls: some View {
        if model.refreshingRateLimits { ProgressView().controlSize(.mini) }
        QuietIconButton(symbol: "arrow.clockwise", label: "Refresh account limits", size: 22) {
            Task { await model.refreshRateLimits() }
        }.disabled(model.refreshingRateLimits)
    }

    @ViewBuilder private func reported(_ text: String) -> some View {
        switch PanelTheme.current {
        case .refined: Text(text).font(CompanionStyle.callout).foregroundStyle(CompanionStyle.tertiary)
        case .tahoe: Text(text).foregroundStyle(CompanionStyle.secondary)
        case .instrument: Text(text).microLabel(9.5, weight: .regular, tracking: 0.6).foregroundStyle(CompanionStyle.faint)
        }
    }

    @ViewBuilder private func heading(_ text: String) -> some View {
        if PanelTheme.current == .tahoe {
            Text(text).font(.system(size: 13, weight: .semibold)).padding(.leading, 4).accessibilityAddTraits(.isHeader)
        } else {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionStyle.secondary).padding(.leading, 4)
        }
    }
    @ViewBuilder private func note(_ text: String) -> some View {
        switch PanelTheme.current {
        case .refined:
            Text(text).font(CompanionStyle.caption).foregroundStyle(CompanionStyle.tertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        case .tahoe:
            Text(text).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        case .instrument:
            Text(text).font(.system(size: 11.5)).foregroundStyle(CompanionStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "42%", "Limit reached" or "—"; unknown is never 0. A window that reset
    /// since the report is unknown again.
    static func usedText(_ limit: RuntimeRateLimit, now: Date = Date()) -> String {
        guard !limit.isStale(now: now) else { return "—" }
        return limit.reached ? "Limit reached" : limit.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Relative within a day ("Resets in 1 h 40 min"), then the weekday, or the
    /// date beyond six days, before the time; nil when not reported.
    static func resetText(_ limit: RuntimeRateLimit, now: Date = Date(), calendar: Calendar = .app) -> String? {
        guard let reset = limit.resetsAt else { return nil }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset since last report" }
        if seconds < 86_400 {
            let minutes = Int((seconds / 60).rounded(.up))
            let (hours, rest) = (minutes / 60, minutes % 60)
            return "Resets in " + (hours == 0 ? "\(rest) min" : rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min")
        }
        return "Resets " + stamp(reset, day: seconds < 6 * 86_400 ? .weekday : .date, calendar: calendar)
    }

    /// "Updated 2:20" today, else the date instead, so an old report never looks current.
    static func reportedText(_ date: Date, now: Date = Date(), calendar: Calendar = .app) -> String {
        "Updated " + reportedTime(date, now: now, calendar: calendar)
    }
    /// The time today, else the day and month.
    static func reportedTime(_ date: Date, now: Date = Date(), calendar: Calendar = .app) -> String {
        guard !calendar.isDate(date, inSameDayAs: now) else { return stamp(date, day: nil, calendar: calendar) }
        return date.formatted(Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
                                               timeZone: calendar.timeZone).day().month(.abbreviated))
    }

    /// The context bubble's headline: the share used (unclamped, `≈` for an
    /// estimate), what is known without a window ("42k used"), or a dash.
    static func contextHeadline(_ context: RuntimeContextUsage?) -> String {
        guard let context else { return "—" }
        guard let ratio = context.ratio else { return context.label }
        return "\(context.estimated ? "≈" : "")\(Int((ratio * 100).rounded()))%"
    }

    /// The context bubble's caption: what kind of report it is, and when.
    static func contextCaption(_ context: RuntimeContextUsage, now: Date = Date(), calendar: Calendar = .app) -> String {
        let notes = [context.used == nil ? "Usage not reported" : nil, context.limit == nil ? "Window not reported" : nil,
                     (context.ratio ?? 0) > 1 ? "Over the reported window" : nil, context.estimated ? "Estimate" : nil]
        return (notes.compactMap { $0 } + [reportedText(context.reportedAt, now: now, calendar: calendar)]).joined(separator: " · ")
    }

    private enum Day { case weekday, date }
    /// The time in one style everywhere, after the weekday or date when given.
    private static func stamp(_ date: Date, day: Day?, calendar: Calendar) -> String {
        let locale = calendar.locale ?? .autoupdatingCurrent
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch day {
        case nil: return time
        case .weekday: return date.formatted(style.weekday(.abbreviated)) + " " + time
        case .date: return date.formatted(style.day().month(.abbreviated)) + " " + time
        }
    }

    /// One line for help and accessibility: "42% used · resets in 1 h".
    static func describe(_ limit: RuntimeRateLimit, now: Date = Date(), calendar: Calendar = .app) -> String {
        let used = limit.reached && !limit.isStale(now: now) ? "Limit reached" : usedText(limit, now: now) + " used"
        guard let reset = resetText(limit, now: now, calendar: calendar) else { return used }
        return used + " · " + reset.prefix(1).lowercased() + reset.dropFirst()
    }

    static func describe(_ day: UsageDay) -> String {
        let tokens = day.total.map { RuntimeContextUsage.tokens($0) + " tokens" } ?? "—"
        return day.unreportedTurns > 0 && day.total != nil ? tokens + " · \(day.unreportedTurns) unreported" : tokens
    }

    static func day(_ date: Date, calendar: Calendar = .app) -> String {
        calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated).day().month(.abbreviated))
    }
}

extension Locale {
    /// The app's language with the system region and clock, so dates in an
    /// English interface never read in German while 24- or 12-hour time stays.
    static var app: Locale { app(language: Bundle.main.preferredLocalizations.first ?? "en", system: .autoupdatingCurrent) }

    static func app(language: String, system: Locale) -> Locale {
        let language = Locale.Language(identifier: language)
        var parts = Locale.Components(locale: system)
        parts.languageComponents.languageCode = language.languageCode
        parts.languageComponents.script = language.script
        parts.hourCycle = system.hourCycle
        return Locale(components: parts)
    }
}

extension Calendar {
    /// Every usage and context date: the user's calendar and time zone in `Locale.app`.
    static var app: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = .app
        return calendar
    }
}

/// One account limit window: name and share used, a bar, then when it resets.
/// The context bubble and the Usage page share it; the container sets the size.
struct UsageLimitRow: View {
    var limit: RuntimeRateLimit

    static var captionFont: Font { PanelTheme.pick(CompanionStyle.caption, .system(size: 11), CompanionStyle.mono(10)) }
    static var captionColor: Color { PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.faint) }

    var body: some View {
        // Redrawn each minute for the countdown; the schedule's own date is the minute's start.
        TimelineView(.everyMinute) { _ in
            let now = Date()
            // A window that reset since the report is unknown again: a bare track.
            let stale = limit.isStale(now: now)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(limit.name).fontWeight(.medium).foregroundStyle(CompanionStyle.text).lineLimit(1)
                    Spacer(minLength: 0)
                    // Instrument reads values in mono, names in SF like its other rows.
                    Text(UsageView.usedText(limit, now: now)).monospacedDigit().lineLimit(1)
                        .fontDesign(PanelTheme.current == .instrument ? .monospaced : nil)
                        .foregroundStyle(limit.reached && !stale ? CompanionStyle.amber : CompanionStyle.secondary)
                }
                UsageBar(fraction: stale ? nil : limit.fraction)
                if let reset = UsageView.resetText(limit, now: now) {
                    Text(reset).font(Self.captionFont).foregroundStyle(Self.captionColor).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(limit.name)
            .accessibilityValue(UsageView.describe(limit, now: now))
        }
    }
}

/// Refined fades both scroll edges, Tahoe softens the top, Instrument cuts.
private struct UsageScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        switch PanelTheme.current {
        case .refined: content.scrollEdgeFade()
        case .tahoe: content.softTopEdge()
        case .instrument: content
        }
    }
}
