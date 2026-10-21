import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    /// Setup problems shown as banners in the panel (PanelWarnings).
    @Published var warnings: [PanelWarning] = []
    @Published var usage: UsageSnapshot?
    @Published var usageError: String?
    @Published var selectedTab: Tab = .sessions
    @Published var subscriptionType: String?
    /// "Ritmo lun–vie" — derived from `usage` + the persisted day-start on each fetch.
    @Published var workdayBudget: WorkdayBudget?
    /// Pinned = floating panel open. Persisted; reopened on launch.
    @Published private(set) var pinned: Bool = false
    /// Bumped when a session starts needing you or finishes: the menu bar mark pulses.
    @Published private(set) var attentionPulse = 0

    /// `CLAUDE_SESSIONS_STATE_DIR` set = a test instance on fixture state: no
    /// keychain, no usage request, no login item, own UserDefaults domain.
    static let testMode = ProcessInfo.processInfo.environment["CLAUDE_SESSIONS_STATE_DIR"] != nil

    static let pinnedDefaultsKey = "pinned"

    enum Tab: String, CaseIterable {
        case sessions, usage
    }

    enum StatusColor {
        case idle, working, allWorking
    }

    /// false in snapshot mode: no keychain, network, timers, panels or UserDefaults writes.
    let live: Bool
    private var cancellables: Set<AnyCancellable> = []
    /// One background scan at a time; ticks that land while one runs are dropped.
    private var scanInFlight = false
    /// Last scan by id, for transition detection; nil until the first scan (seed).
    private var lastSeen: [String: Session]?

    init(live: Bool = true) {
        self.live = live
        guard live else {
            let scan = SessionScanner.scanWithWarnings()   // headless snapshot: synchronous
            sessions = FinishedState.apply(scan.sessions, frontTitle: nil, now: Date())
            warnings = scan.warnings
            return
        }
        // `open … --args -initialTab usage` (argument domain): live captures of a tab.
        if let raw = UserDefaults.standard.string(forKey: "initialTab"), let tab = Tab(rawValue: raw) {
            selectedTab = tab
        }
        if !Self.testMode {
            self.subscriptionType = CredentialsReader.read()?.subscriptionType
        }
        scanSessions()
        if !Self.testMode { Task { await self.fetchUsage() } }
        startTimers()
        if UserDefaults.standard.bool(forKey: Self.pinnedDefaultsKey) {
            // After the AppDelegate attached the panel controller and status item.
            DispatchQueue.main.async { [weak self] in self?.setPinned(true) }
        }
    }

    func setPinned(_ on: Bool) {
        pinned = on
        guard live else { return }
        UserDefaults.standard.set(on, forKey: Self.pinnedDefaultsKey)
        // Pin while the panel hangs from the menu bar converts it in place;
        // unpin closes it (StatusPanel.swift).
        StatusPanelController.shared.setPinned(on)
    }

    func togglePinned() { setPinned(!pinned) }

    /// Sets usage and derives the workday pace. `dayStart` overrides the
    /// persisted store (snapshot fixture); otherwise the store resolves it.
    func applyUsage(_ snapshot: UsageSnapshot, now: Date = Date(), dayStart: Double? = nil) {
        usage = snapshot
        guard let resetsAt = snapshot.sevenDay.resetsAt else {
            workdayBudget = nil
            return
        }
        let cal = WorkdayBudget.userCalendar()
        let u = snapshot.sevenDay.utilization
        let start = dayStart ?? WorkdayDayStartStore().resolve(
            utilization: u, resetsAt: resetsAt, now: now, calendar: cal)
        workdayBudget = WorkdayBudget.compute(
            utilization: u, resetsAt: resetsAt, now: now, dayStart: start, calendar: cal)
    }

    private func startTimers() {
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.scanSessions() }
            }
            .store(in: &cancellables)

        Timer.publish(every: 180, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard !Self.testMode else { return }
                Task { @MainActor in await self?.fetchUsage() }
            }
            .store(in: &cancellables)
    }

    /// Scans off the main actor (SessionScanWorker) and publishes on the main
    /// actor only when the result changed — Session equality has no clock-derived
    /// fields, so an idle list doesn't republish (and re-layout) every tick.
    func scanSessions() {
        guard !scanInFlight else { return }
        scanInFlight = true
        Task { @MainActor in
            let scan = await SessionScanWorker.scan()
            let scanned = FinishedState.apply(scan.sessions,
                                              frontTitle: Self.testMode ? nil : FrontWindow.currentTitle(), now: Date())
            scanInFlight = false
            if scan.warnings != warnings { warnings = scan.warnings }
            let events = AttentionDetector.events(previous: lastSeen, current: scanned)
            lastSeen = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            if scanned != sessions {
                sessions = scanned
            }
            if !events.isEmpty, AttentionToastController.shared.isEnabled {
                attentionPulse += 1
                AttentionToastController.shared.handle(events)
            }
        }
    }

    /// `usage` keeps the last good snapshot on failure; `usageError` is cleared
    /// only by data from a successful request — UsageFetcher rethrows the
    /// unresolved failure during Retry-After / throttle instead of returning
    /// its cache, so a refresh in backoff keeps the error visible.
    func fetchUsage(force: Bool = false) async {
        // Test instances never touch the keychain or the API, whoever asks (Usage tab, footer).
        guard live, !Self.testMode else { return }
        do {
            applyUsage(try await UsageFetcher.shared.fetch(force: force))
            usageError = nil
        } catch {
            usageError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // Derived state
    var workingCount: Int { sessions.filter(\.isWorking).count }
    var waitingCount: Int { sessions.filter(\.isWaiting).count }
    var totalCount: Int { sessions.count }
    /// Context loaded across the open sessions (footer).
    var totalContextTokens: Int { sessions.reduce(0) { $0 + $1.contextTokens } }
    var activeSubagentsCount: Int { sessions.reduce(0) { $0 + $1.subagents.count } }

    var statusColor: StatusColor {
        if totalCount == 0 { return .idle }
        if workingCount == 0 { return .idle }
        if workingCount == totalCount { return .allWorking }
        return .working
    }
}
