import Foundation

/// "Ritmo lun–vie": how much of the weekly limit fits per working day.
/// Pure — every input is explicit (u, R, now, day-start, calendar) so it is
/// testable with `--budget-selftest`.
///
/// - workdays = Mon–Fri days from today (inclusive if weekday) up to R (exclusive):
///   a day counts if it is Mon–Fri and its 00:00 is before R.
/// - todayBudget     = (100 − uStart) / workdaysInclToday   (nil on weekends / 0 days)
/// - usedToday       = u − uStart                            (nil on weekends)
/// - perRemainingDay = (100 − u) / workdaysAfterToday        (nil if 0 days)
struct WorkdayBudget: Equatable {
    let utilization: Double          // u, 0–100
    let dayStartUtilization: Double  // u at the first observation today
    let isWorkdayToday: Bool
    let workdaysInclToday: Int
    let workdaysAfterToday: Int
    let todayBudget: Double?
    let usedToday: Double?
    let perRemainingDay: Double?

    var remaining: Double { max(0, 100 - utilization) }

    var isOverBudget: Bool {
        guard let todayBudget, let usedToday else { return false }
        return usedToday > todayBudget
    }

    /// usedToday / todayBudget, clamped 0…1 (bar fill).
    var todayProgress: Double {
        guard let usedToday else { return 0 }
        guard let todayBudget, todayBudget > 0 else { return usedToday > 0 ? 1 : 0 }
        return min(max(usedToday / todayBudget, 0), 1)
    }

    static func compute(
        utilization u: Double,
        resetsAt: Date,
        now: Date,
        dayStart: Double,
        calendar: Calendar
    ) -> WorkdayBudget {
        let uStart = min(dayStart, u)
        let today = calendar.startOfDay(for: now)
        let todayIsWorkday = isWeekday(today, calendar)

        var incl = 0
        var day = today
        for _ in 0..<15 {  // weekly window: never more than 8 days; hard cap
            guard day < resetsAt else { break }
            if isWeekday(day, calendar) { incl += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let after = todayIsWorkday && incl > 0 ? incl - 1 : incl

        let todayBudget: Double? = (todayIsWorkday && incl > 0) ? (100 - uStart) / Double(incl) : nil
        let usedToday: Double? = todayIsWorkday ? u - uStart : nil
        let perRemaining: Double? = after > 0 ? max(0, 100 - u) / Double(after) : nil

        return WorkdayBudget(
            utilization: u,
            dayStartUtilization: uStart,
            isWorkdayToday: todayIsWorkday,
            workdaysInclToday: incl,
            workdaysAfterToday: after,
            todayBudget: todayBudget,
            usedToday: usedToday,
            perRemainingDay: perRemaining
        )
    }

    /// Mon–Fri by weekday number (1 = Sunday … 7 = Saturday), not locale weekend rules.
    static func isWeekday(_ date: Date, _ calendar: Calendar) -> Bool {
        let wd = calendar.component(.weekday, from: date)
        return (2...6).contains(wd)
    }

    /// Gregorian calendar in the user's time zone (tests pass a fixed zone).
    static func userCalendar(timeZone: TimeZone = .current) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}

/// Day-start baseline: u at the first observation of the local day **within the
/// current weekly reset cycle**. Persisted in UserDefaults as
/// `{date: "yyyy-MM-dd", start: u, resetsAt: epoch}` — only one record is kept.
///
/// - New local day → baseline = first observation (accepted limitation: usage
///   before the app's first fetch of the day counts as "before today").
/// - Same day, reset cycle changed (`resetsAt` moved by more than
///   `cycleTolerance`) → the weekly window restarted today, so everything in
///   the new cycle was used today: baseline = **0** (not the first new
///   observation). E.g. start 5, u 70, reset, next u 10 → used today 10.
/// - Same day and cycle, u dropped below the baseline (reset seen without a
///   `resetsAt` change) → baseline = u.
struct WorkdayDayStartStore {
    static let defaultsKey = "workdayBudget.dayStart.v2"
    static let legacyDefaultsKey = "workdayBudget.dayStart"
    /// The API's resetsAt may jitter by seconds between fetches; a real cycle
    /// change moves it by days.
    static let cycleTolerance: TimeInterval = 3600
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resolve(utilization u: Double, resetsAt: Date, now: Date, calendar: Calendar) -> Double {
        let key = Self.dateKey(now, calendar)
        let stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        let storedDate = stored["date"] as? String
        let storedStart = (stored["start"] as? NSNumber)?.doubleValue
        let storedReset = (stored["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }

        let start: Double
        if storedDate == key, let storedStart {
            let sameCycle = storedReset.map { abs($0.timeIntervalSince(resetsAt)) <= Self.cycleTolerance } ?? false
            if !sameCycle {
                start = 0
            } else if u >= storedStart {
                return storedStart
            } else {
                start = u
            }
        } else {
            start = u
        }
        defaults.set(
            ["date": key, "start": start, "resetsAt": resetsAt.timeIntervalSince1970] as [String: Any],
            forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        return start
    }

    static func dateKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Percentages in the UI language's locale, at most one decimal
/// ("22,5" es · "22.5" en).
enum PercentFormat {
    static func string(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// "22,5 %" (es) · "22.5%" (en)
    static func pct(_ value: Double) -> String { L10n.percent(string(value)) }
}

extension WorkdayBudget {
    /// "Today 6.1% of 22.5%" · "Hoy 6,1 % de 22,5 %" (nil on weekends)
    var todayText: String? {
        guard let todayBudget, let usedToday else { return nil }
        return L10n.tr("pace.today", PercentFormat.pct(max(0, usedToday)), PercentFormat.pct(todayBudget))
    }

    /// "Quedan 90 % · desde mañana 22,5 %/día (4 días hábiles)" — "desde mañana"
    /// because todayText's budget counts today and this rate doesn't · weekend:
    /// "Fin de semana · quedan 40 % para 5 días hábiles"
    var detailText: String {
        let left = PercentFormat.pct(remaining)
        if !isWorkdayToday {
            if workdaysInclToday == 0 {
                return L10n.tr("pace.weekend.none", left)
            }
            return L10n.tr("pace.weekend", left, Self.days(workdaysInclToday))
        }
        guard let perRemainingDay else {
            return L10n.tr("pace.lastDay", left)
        }
        return L10n.tr("pace.perDay", left, PercentFormat.pct(perRemainingDay), Self.days(workdaysAfterToday))
    }

    static func days(_ n: Int) -> String {
        L10n.tr(n == 1 ? "workdays.one" : "workdays.other", n)
    }
}

#if DEBUG
// MARK: - Self-test (`--budget-selftest`)

enum WorkdayBudgetSelfTest {
    /// Prints PASS/FAIL per case; returns false if any failed.
    static func run() -> Bool {
        let tz = TimeZone(identifier: "UTC")!
        let cal = WorkdayBudget.userCalendar(timeZone: tz)
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
            cal.date(from: DateComponents(timeZone: tz, year: y, month: m, day: d, hour: h, minute: min))!
        }
        func near(_ a: Double?, _ b: Double) -> Bool {
            guard let a else { return false }
            return abs(a - b) < 1e-9
        }
        var allPass = true
        func check(_ name: String, _ conditions: [(String, Bool)]) {
            let failed = conditions.filter { !$0.1 }.map(\.0)
            if failed.isEmpty {
                print("PASS \(name)")
            } else {
                allPass = false
                print("FAIL \(name): \(failed.joined(separator: ", "))")
            }
        }

        // (a) Monday 10:00, u=10, start=0, R = next Monday 00:00
        let a = WorkdayBudget.compute(
            utilization: 10, resetsAt: date(2026, 10, 26), now: date(2026, 10, 19, 10),
            dayStart: 0, calendar: cal)
        check("a monday-10h u=10 → 22,5 %/día", [
            ("workdaysInclToday==5 (got \(a.workdaysInclToday))", a.workdaysInclToday == 5),
            ("workdaysAfterToday==4 (got \(a.workdaysAfterToday))", a.workdaysAfterToday == 4),
            ("perRemainingDay==22.5 (got \(String(describing: a.perRemainingDay)))", near(a.perRemainingDay, 22.5)),
            ("todayBudget==20 (got \(String(describing: a.todayBudget)))", near(a.todayBudget, 20)),
            ("usedToday==10 (got \(String(describing: a.usedToday)))", near(a.usedToday, 10)),
            ("detailText (got \(a.detailText))", a.detailText == "Quedan 90 % · desde mañana 22,5 %/día (4 días hábiles)"),
            ("todayText (got \(a.todayText ?? "nil"))", a.todayText == "Hoy 10 % de 20 %"),
        ])

        // (b) Saturday 12:00, u=60, R = next Monday 00:00
        let b = WorkdayBudget.compute(
            utilization: 60, resetsAt: date(2026, 10, 26), now: date(2026, 10, 24, 12),
            dayStart: 55, calendar: cal)
        check("b saturday u=60 → nil budget", [
            ("isWorkdayToday==false", !b.isWorkdayToday),
            ("todayBudget==nil", b.todayBudget == nil),
            ("usedToday==nil", b.usedToday == nil),
            ("workdaysInclToday==0 (got \(b.workdaysInclToday))", b.workdaysInclToday == 0),
            ("workdaysAfterToday==0 (got \(b.workdaysAfterToday))", b.workdaysAfterToday == 0),
            ("perRemainingDay==nil", b.perRemainingDay == nil),
            ("todayText==nil", b.todayText == nil),
        ])

        // (c) Wednesday 11:00, u=40, start=30, R = Friday 15:00
        let c = WorkdayBudget.compute(
            utilization: 40, resetsAt: date(2026, 10, 23, 15), now: date(2026, 10, 21, 11),
            dayStart: 30, calendar: cal)
        check("c wednesday → Fri 15:00 = 3 días", [
            ("workdaysInclToday==3 (got \(c.workdaysInclToday))", c.workdaysInclToday == 3),
            ("workdaysAfterToday==2 (got \(c.workdaysAfterToday))", c.workdaysAfterToday == 2),
            ("todayBudget==70/3 (got \(String(describing: c.todayBudget)))", near(c.todayBudget, 70.0 / 3.0)),
            ("usedToday==10 (got \(String(describing: c.usedToday)))", near(c.usedToday, 10)),
            ("perRemainingDay==30 (got \(String(describing: c.perRemainingDay)))", near(c.perRemainingDay, 30)),
        ])

        // (d) u drops below the stored start → weekly reset → start replaced
        let suite = "io.github.tactician200.claude-sessions.budget-selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = WorkdayDayStartStore(defaults: defaults)
        let rD = date(2026, 10, 26)
        let monday = date(2026, 10, 19, 9)
        let first = store.resolve(utilization: 50, resetsAt: rD, now: monday, calendar: cal)
        let later = store.resolve(utilization: 58, resetsAt: rD, now: date(2026, 10, 19, 13), calendar: cal)
        let afterReset = store.resolve(utilization: 2, resetsAt: rD, now: date(2026, 10, 19, 15), calendar: cal)
        let afterResetLater = store.resolve(utilization: 5, resetsAt: rD, now: date(2026, 10, 19, 17), calendar: cal)
        let nextDay = store.resolve(utilization: 9, resetsAt: rD, now: date(2026, 10, 20, 8), calendar: cal)
        defaults.removePersistentDomain(forName: suite)
        check("d u drop (same resetsAt) replaces day-start", [
            ("first observation 50 (got \(first))", first == 50),
            ("kept while u rises (got \(later))", later == 50),
            ("replaced when u drops to 2 (got \(afterReset))", afterReset == 2),
            ("kept after replacement (got \(afterResetLater))", afterResetLater == 2),
            ("new local day → new start 9 (got \(nextDay))", nextDay == 9),
        ])

        // (e) edge: Friday, R = Saturday 00:00 → last workday, no per-day figure
        let e = WorkdayBudget.compute(
            utilization: 80, resetsAt: date(2026, 10, 24), now: date(2026, 10, 23, 10),
            dayStart: 70, calendar: cal)
        check("e friday last workday", [
            ("workdaysInclToday==1 (got \(e.workdaysInclToday))", e.workdaysInclToday == 1),
            ("perRemainingDay==nil", e.perRemainingDay == nil),
            ("todayBudget==30 (got \(String(describing: e.todayBudget)))", near(e.todayBudget, 30)),
        ])

        // (f) weekly reset mid-day where u never drops below the baseline:
        // start 5, u 70, reset (resetsAt moves a week), next u 10 → baseline 0
        // (whole new cycle used today) → used today 10, not 5.
        defaults.removePersistentDomain(forName: suite)
        let r1 = date(2026, 10, 19, 14), r2 = date(2026, 10, 26, 14)
        let f1 = store.resolve(utilization: 5, resetsAt: r1, now: date(2026, 10, 19, 9), calendar: cal)
        let f2 = store.resolve(utilization: 70, resetsAt: r1, now: date(2026, 10, 19, 12), calendar: cal)
        let f3 = store.resolve(utilization: 10, resetsAt: r2, now: date(2026, 10, 19, 15), calendar: cal)
        let f4 = store.resolve(utilization: 14, resetsAt: r2.addingTimeInterval(2), now: date(2026, 10, 19, 17), calendar: cal)
        let f5 = store.resolve(utilization: 20, resetsAt: r2, now: date(2026, 10, 20, 8), calendar: cal)
        defaults.removePersistentDomain(forName: suite)
        let fBudget = WorkdayBudget.compute(
            utilization: 10, resetsAt: r2, now: date(2026, 10, 19, 15), dayStart: f3, calendar: cal)
        check("f reset cycle change replaces baseline (5 → 70 → reset → 10)", [
            ("first observation 5 (got \(f1))", f1 == 5),
            ("kept while u rises to 70 (got \(f2))", f2 == 5),
            ("new cycle → baseline 0 (got \(f3))", f3 == 0),
            ("usedToday==10 (got \(String(describing: fBudget.usedToday)))", near(fBudget.usedToday, 10)),
            ("resetsAt jitter 2 s = same cycle, kept 0 (got \(f4))", f4 == 0),
            ("new local day → first observation 20 (got \(f5))", f5 == 20),
        ])

        // (g) utilization is 0–100 (API): no ×100 heuristic. Label rounds half
        // away from zero (0.5 → "1 %"); only the bar fraction is clamped.
        let g: [(Double, String, Double)] = [
            (0, "0 %", 0), (0.5, "1 %", 0.005), (1, "1 %", 0.01), (2, "2 %", 0.02),
            (100, "100 %", 1), (130, "130 %", 1), (-3, "0 %", 0), (.nan, "0 %", 0),
        ]
        check("g utilization 0–100 labels (0 / 0,5 / 1 / 2 …)", g.map { u, label, fraction in
            ("u=\(u) → \(label) frac \(fraction) (got \(UsagePercent.label(u)) frac \(UsagePercent.fraction(u)))",
             UsagePercent.label(u) == label && abs(UsagePercent.fraction(u) - fraction) < 1e-9)
        })

        return allPass
    }
}
#endif
