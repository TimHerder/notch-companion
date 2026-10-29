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
                    let limits = model.rateLimits[runtime.rawValue] ?? []
                    SettingsGroup {
                        SettingsRow(runtime.title, symbol: "terminal.fill", tint: .gray) {
                            reported(limits.map { "Reported " + $0.reportedAt.formatted(date: .omitted, time: .shortened) }.max() ?? "—")
                        }
                        ForEach(limits) { limit in
                            SettingsRow(limit.name, divider: true) { limitValue(limit) }
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

    @ViewBuilder private func limitValue(_ limit: RuntimeRateLimit) -> some View {
        switch PanelTheme.current {
        case .refined:
            Text(Self.describe(limit)).monospacedDigit()
                .foregroundStyle(limit.reached ? CompanionStyle.amber : CompanionStyle.secondary)
        case .tahoe:
            HStack(spacing: 10) {
                Text(Self.describe(limit)).monospacedDigit().fixedSize()
                    .foregroundStyle(limit.reached ? CompanionStyle.amber : CompanionStyle.secondary)
                meter(limit)
            }
        case .instrument:
            HStack(spacing: 10) {
                if limit.usedPercent != nil || limit.reached {
                    SegmentMeter(fraction: limit.reached ? 1 : limit.usedPercent.map { min(1, max(0, $0 / 100)) })
                }
                Text(Self.describe(limit)).font(CompanionStyle.mono(11)).monospacedDigit()
                    .foregroundStyle(limit.reached ? CompanionStyle.signal : CompanionStyle.text)
                    .lineLimit(1).fixedSize()
            }
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

    /// Tahoe: a small capacity bar, as in Storage and Battery settings; unknown stays empty.
    private func meter(_ limit: RuntimeRateLimit) -> some View {
        let fraction = limit.reached ? 1 : min(1, max(0, (limit.usedPercent ?? 0) / 100))
        return Capsule().fill(Color.white.opacity(0.12))
            .overlay(alignment: .leading) {
                Capsule().fill(limit.reached || fraction >= 0.8 ? CompanionStyle.amber : CompanionStyle.accent)
                    .frame(width: 44 * CGFloat(fraction))
            }
            .frame(width: 44, height: 5)
            .accessibilityHidden(true)
    }

    static func describe(_ limit: RuntimeRateLimit) -> String {
        let used = limit.reached ? "Limit reached" : limit.usedPercent.map { "\(Int($0.rounded()))% used" } ?? "— used"
        guard let reset = limit.resetsAt else { return used }
        let when = Calendar.current.isDateInToday(reset) ? reset.formatted(date: .omitted, time: .shortened)
            : reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return used + " · resets " + when
    }

    static func describe(_ day: UsageDay) -> String {
        let tokens = day.total.map { RuntimeContextUsage.tokens($0) + " tokens" } ?? "—"
        return day.unreportedTurns > 0 && day.total != nil ? tokens + " · \(day.unreportedTurns) unreported" : tokens
    }

    static func day(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Today" : Calendar.current.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
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
