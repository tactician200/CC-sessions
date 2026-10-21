import SwiftUI

struct UsageTabView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let usage = state.usage {
                FitScrollView(maxHeight: 460) {
                    VStack(spacing: 0) {
                        UsageBarRow(
                            icon: "hourglass",
                            label: L10n.tr("usage.session"),
                            utilization: usage.fiveHour.utilization,
                            resetsAt: usage.fiveHour.resetsAt
                        )
                        separator
                        UsageBarRow(
                            icon: "calendar",
                            label: L10n.tr("usage.weekly"),
                            utilization: usage.sevenDay.utilization,
                            resetsAt: usage.sevenDay.resetsAt
                        )
                        if let budget = state.workdayBudget {
                            // Box edge at 8 + inner 8 = text at 16, aligned with the other rows.
                            WorkdayPaceRow(budget: budget)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 12)
                        }
                        modelBreakdown(usage: usage)
                        // Off and unused = nothing to decide; don't spend a block on €0,00.
                        if let extra = usage.extraUsage, extra.isEnabled || extra.usedCreditsMajor > 0 {
                            separator
                            ExtraUsageRow(extra: extra)
                        }
                    }
                }
            } else if let err = state.usageError {
                errorState(err)
            } else {
                loadingState
            }
        }
        .onAppear {
            Task { await state.fetchUsage(force: true) }
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 16)
    }

    @ViewBuilder
    private func modelBreakdown(usage: UsageSnapshot) -> some View {
        if usage.sevenDaySonnet != nil || usage.sevenDayOpus != nil {
            separator
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("usage.byModel"))
                    .font(Theme.label(9.5))
                    .foregroundColor(Theme.textTertiary)
                    .tracking(0.6)
                if let sonnet = usage.sevenDaySonnet {
                    ModelRow(name: "Sonnet", utilization: sonnet.utilization)
                }
                ModelRow(name: "Opus", utilization: usage.sevenDayOpus?.utilization ?? 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text(L10n.tr("usage.loading"))
                .font(Theme.body(11))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorState(_ err: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(Theme.warn)
                .font(.system(size: 16))
            Text(err)
                .font(Theme.body(11))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(L10n.tr("usage.retry")) {
                Task { await state.fetchUsage(force: true) }
            }
            .buttonStyle(.plain)
            .font(Theme.title(11.5))
            .foregroundColor(Theme.accent)
            .pointingHandCursor()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }
}

/// "Mon–Fri pace": today's share of the weekly limit, on a glass inset under
/// the weekly bar. Accent = on pace; warn = over today's budget.
struct WorkdayPaceRow: View {
    let budget: WorkdayBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkFaint)
                Text(L10n.tr("pace.title"))
                    .font(Theme.title(12))
                    .foregroundColor(Theme.ink)
                    .fixedSize()
                Spacer(minLength: 6)
                if let today = budget.todayText {
                    Text(today)
                        .font(Theme.number(11.5))
                        .foregroundColor(budget.isOverBudget ? Theme.warn : Theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if budget.isWorkdayToday {
                ProgressBar(
                    progress: budget.todayProgress,
                    color: budget.isOverBudget ? Theme.warn : Theme.accent,
                    height: 5
                )
            }
            Text(budget.detailText)
                .font(Theme.body(11).monospacedDigit())
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }
}

struct UsageBarRow: View {
    let icon: String
    let label: String
    let utilization: Double
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkFaint)
                    Text(label)
                        .font(Theme.title(12.5))
                        .foregroundColor(Theme.ink)
                }
                Spacer(minLength: 0)
                Text(UsagePercent.label(utilization))
                    .font(Theme.number(13))
                    .foregroundColor(Theme.ink)
            }
            ProgressBar(progress: UsagePercent.fraction(utilization), color: Theme.usageFill(utilization))
            if let resetsAt {
                // Own clock: ticks on each minute boundary of the countdown,
                // independent of fetches/AppState publications.
                TimelineView(CountdownSchedule(target: resetsAt)) { context in
                    Text(Self.resetString(resetsAt: resetsAt, now: context.date))
                        .font(Theme.body(11).monospacedDigit())
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    static func resetString(resetsAt: Date, now: Date) -> String {
        let delta = resetsAt.timeIntervalSince(now)
        if delta <= 0 { return L10n.tr("usage.resetsNow") }
        return L10n.tr("usage.resetsIn", duration(delta))
    }

    /// "6 d 5 h" · "2 h 12 min" · "8 min" — explicit, because the es_CL
    /// abbreviated DateComponentsFormatter renders days as "6dd.".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds) / 60
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(max(1, m)) min"
    }
}

struct ModelRow: View {
    let name: String
    let utilization: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(Theme.title(12, .medium))
                    .foregroundColor(Theme.ink)
                Spacer(minLength: 0)
                Text(UsagePercent.label(utilization))
                    .font(Theme.number(11.5))
                    .foregroundColor(Theme.textSecondary)
            }
            ProgressBar(progress: UsagePercent.fraction(utilization), color: Theme.dataFillSoft, height: 4)
        }
    }
}

struct ExtraUsageRow: View {
    let extra: UsageSnapshot.ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkFaint)
                    Text(L10n.tr("usage.extra"))
                        .font(Theme.title(12.5))
                        .foregroundColor(Theme.ink)
                }
                Spacer()
                Text(extra.isEnabled ? "ON" : "OFF")
                    .font(Theme.label(9.5))
                    .foregroundColor(extra.isEnabled ? Theme.go : Theme.textTertiary)
                    .glassChip(radius: 5, fill: extra.isEnabled ? Theme.goBg : Theme.glassFill)
            }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(extra.currencySymbol)\(formatMoney(extra.usedCreditsMajor))")
                    .font(Theme.number(20, .bold))
                    .foregroundColor(Theme.ink)
                Text("/ \(extra.currencySymbol)\(formatMoney(extra.monthlyLimitMajor))")
                    .font(Theme.number(12, .regular))
                    .foregroundColor(Theme.textSecondary)
            }
            ProgressBar(progress: UsagePercent.fraction(extra.utilization), color: Theme.usageFill(extra.utilization))
            Text(L10n.tr(extra.isEnabled ? "usage.extra.on" : "usage.extra.off", UsagePercent.label(extra.utilization)))
                .font(Theme.body(11).monospacedDigit())
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func formatMoney(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = L10n.locale
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

/// Ticks when `UsageBarRow.duration` changes: it shows floor(remaining / 60)
/// minutes, which drops just *after* each whole-minute boundary before
/// `target` — so ticks land `epsilon` past the boundary — then once past
/// `target` ("ahora"), then the schedule ends.
struct CountdownSchedule: TimelineSchedule {
    let target: Date
    static let epsilon: TimeInterval = 0.01

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        let target = self.target
        return AnyIterator {
            guard let current = next else { return nil }
            let remaining = target.timeIntervalSince(current)
            if remaining <= 0 {
                next = nil
            } else {
                let k = (remaining / 60).rounded(.down)
                next = target.addingTimeInterval(-k * 60 + Self.epsilon)
            }
            return current
        }
    }
}

#if DEBUG
/// `--budget-selftest` companion: the usage tab's own clocks.
enum UsageClockSelfTest {
    static func run() -> Bool {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func label(_ now: Date) -> String {
            UsageBarRow.resetString(resetsAt: t, now: now)
        }
        let ticks = Array(CountdownSchedule(target: t)
            .entries(from: t.addingTimeInterval(-125), mode: .normal).prefix(10))
        let labels = ticks.map(label)
        let expected = ["Se reinicia en 2 min", "Se reinicia en 1 min", "Se reinicia en 1 min", "Se reinicia ahora"]
        // Between ticks the label must not change (allowed lag ≤ epsilon):
        // sample just before the boundary that precedes each next tick.
        var stale: [String] = []
        for (i, tick) in ticks.enumerated().dropLast() {
            let justBefore = ticks[i + 1].addingTimeInterval(-CountdownSchedule.epsilon - 0.001)
            if label(justBefore) != label(tick) { stale.append("\(label(tick)) → \(label(justBefore))") }
        }
        let since = t
        let rel = Array(RelativeTimeSchedule(since: since)
            .entries(from: since.addingTimeInterval(58.5), mode: .normal).prefix(4))
            .map { $0.timeIntervalSince(since) }
        let conditions: [(String, Bool)] = [
            ("countdown labels \(labels) == \(expected)", labels == expected),
            ("countdown ends after target (\(ticks.count) ticks)", ticks.count == 4),
            ("no stale label between ticks \(stale)", stale.isEmpty),
            ("relative ticks on whole seconds then minutes \(rel)", rel == [58.5, 59, 60, 120]),
        ]
        let failed = conditions.filter { !$0.1 }.map(\.0)
        if failed.isEmpty {
            print("PASS h usage clocks (countdown minute boundaries, relative-time ticks)")
            return true
        }
        print("FAIL h usage clocks: \(failed.joined(separator: "; "))")
        return false
    }
}
#endif
