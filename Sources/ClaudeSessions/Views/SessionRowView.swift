import SwiftUI
import AppKit
import os

struct SessionRowView: View {
    let session: Session
    @Environment(\.inPinnedPanel) private var inPinnedPanel
    @State private var hovered = false
    @State private var metricHovered = false
    @AppStorage(TokenMetric.storageKey) private var metricRaw = TokenMetric.context.rawValue

    private var metric: TokenMetric { TokenMetric(rawValue: metricRaw) ?? .context }

    var body: some View {
        Button {
            SessionFocus.focus(session)
            FinishedState.markSeen(session)
            if !inPinnedPanel { MenuBarWindow.close() }
        } label: {
            rowContent
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(hovered: hovered, waiting: session.isWaiting))
        .onHover { hovered = $0 }
        .pointingHandCursor()
        .help(session.lastPrompt ?? session.projectPath)
        // The number is its own button, layered over the row (a button nested in
        // the row's label would never get the click). The row keeps a hidden copy
        // so its layout doesn't change.
        .overlay(alignment: .topTrailing) {
            Button { metricRaw = metric.toggled.rawValue } label: {
                // Hover highlight (padded, then un-padded: the layout size is unchanged).
                metrics
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(metricHovered ? Theme.glassFillPressed : .clear)
                    )
                    .padding(.horizontal, -5)
                    .padding(.vertical, -3)
            }
                .buttonStyle(.plain)
                .onHover { metricHovered = $0 }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .pointingHandCursor()
                .help(metricHelp)
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(session.projectName)
                        .font(Theme.title(13))
                        .foregroundColor(session.status == .done ? Theme.ink.opacity(0.82) : Theme.ink)
                        .lineLimit(1)
                        .layoutPriority(2)
                    if let title = session.title {
                        // Same name as the VS Code tab the click lands on. It takes the
                        // flexible width: the model chip is placed first (fixed size,
                        // higher priority) and the title truncates at the tail after it.
                        Text(title)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)
                    }
                    modelChip
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                activityLine
                // The last prompt lives in the row's tooltip (`.help`), not on a third line.
            }
            Spacer(minLength: 6)
            metrics.hidden()
        }
    }

    /// Waiting / working / inactive = filled dot; finished (not seen) = check glyph,
    /// so the state reads from the shape and not only from the colour.
    @ViewBuilder
    private var statusDot: some View {
        if session.status == .done && !session.inactive {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(stateColor)
        } else {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
        }
    }

    /// Same palette as the header chips and the toast: waiting = orange, working =
    /// green, finished not seen = blue (the toast's "terminó"), inactive = gray.
    private var stateColor: Color {
        guard session.status == .done else { return Theme.statusColor(session.status) }
        return session.inactive ? Theme.done : Theme.finished
    }

    /// Neutral glass chip — the model is metadata, not a state.
    private var modelChip: some View {
        Text(session.model)
            .font(Theme.number(10, .medium))
            .foregroundColor(Theme.inkFaint)
            .lineLimit(1)
            .fixedSize()
            .glassChip()
    }

    private var stateWord: String {
        switch session.status {
        case .waiting: return L10n.tr("state.waiting")
        case .working: return L10n.tr("state.working")
        case .done: return L10n.tr(session.inactive ? "state.inactive" : "state.finished")
        }
    }

    /// "Te espera · Permiso: Bash · hace 1 min" · "Trabajando · Edit: x · hace 31 s" ·
    /// "Terminó · hace 3 min".
    private var activityLine: some View {
        HStack(spacing: 5) {
            Text(stateWord)
                .font(Theme.title(11, .semibold))
                .foregroundColor(stateColor)
                .lineLimit(1)
                .fixedSize()
            if let detail = activityDetail {
                Text("· \(detail)")
                    .font(Theme.body(11))
                    .foregroundColor(session.isWaiting ? Theme.waiting : Theme.textSecondary)
                    .lineLimit(1)
            }
            // Elapsed time is rendered from statusSince, not stored in Session:
            // only this Text ticks, the session list doesn't republish.
            TimelineView(RelativeTimeSchedule(since: session.statusSince)) { context in
                Text("· \(RelativeTime.ago(seconds: Int(context.date.timeIntervalSince(session.statusSince))))")
                    .font(Theme.body(11).monospacedDigit())
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// What follows the state word; nil when the word says it all.
    private var activityDetail: String? {
        switch session.status {
        case .waiting:
            return session.waitingReason.map(L10n.waitingReason)
        case .working:
            var parts: [String] = []
            if let text = session.lastActivityText {
                parts.append(text)
            } else if let tool = session.lastToolName, !tool.isEmpty {
                parts.append(L10n.tr("activity.running", tool))
            }
            if !session.subagents.isEmpty {
                let n = session.subagents.count
                parts.append(L10n.tr(n == 1 ? "activity.subagents.one" : "activity.subagents.other", n))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .done:
            return nil
        }
    }

    private var metrics: some View {
        VStack(alignment: .trailing, spacing: 2) {
            let value = metric == .context ? session.contextTokens : session.usedTokens
            Text(value > 0 ? TokenFormat.short(value) : "—")
                .font(Theme.number(12, .regular))
                .foregroundColor(metricHovered ? Theme.ink : Theme.textSecondary)
            Text(metric == .context ? L10n.tr("metric.context", TokenFormat.short(session.contextWindow)) : L10n.tr("metric.used"))
                .font(Theme.body(10))
                .foregroundColor(Theme.textTertiary)
        }
        .fixedSize()
        .contentShape(Rectangle())
    }

    private var metricHelp: String {
        L10n.tr("metric.help", TokenFormat.short(session.contextTokens),
                TokenFormat.short(session.contextWindow), TokenFormat.short(session.usedTokens))
    }
}

/// Native-menu row: transparent at rest (waiting rows sit on a glass layer),
/// rounded highlight on hover, slightly brighter while pressed.
struct RowButtonStyle: ButtonStyle {
    let hovered: Bool
    var waiting: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = configuration.isPressed ? Theme.glassFillPressed
            : hovered ? Theme.glassFillHover
            : waiting ? Theme.waitingBg.opacity(0.55)
            : .clear
        let stroke: Color = (hovered || configuration.isPressed) ? Theme.hairline
            : waiting ? Theme.waiting.opacity(0.22) : .clear
        return configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
    }
}

/// Which number the session rows show; one choice for all rows, remembered.
enum TokenMetric: String {
    case context, used
    static let storageKey = "tokenMetric"
    var toggled: TokenMetric { self == .context ? .used : .context }
}

enum TokenFormat {
    static func short(_ tokens: Int) -> String {
        let k = Double(tokens) / 1000
        if k >= 1000 { return trim(String(format: "%.1f", k / 1000)) + "M" }
        if k >= 1 { return trim(String(format: "%.1f", k)) + "k" }
        return "\(tokens)"
    }

    private static func trim(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
}

enum RelativeTime {
    /// "12 s ago" · "3 min ago" · "2 h 5 min ago" (es: "hace 12 s" …)
    static func ago(seconds s: Int) -> String {
        if s < 60 { return L10n.tr("ago.seconds", max(0, s)) }
        if s < 3600 { return L10n.tr("ago.minutes", s / 60) }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m > 0 ? L10n.tr("ago.hoursMinutes", h, m) : L10n.tr("ago.hours", h)
    }
}

/// Ticks when the "hace N" label changes: every second during the first
/// minute, then on each whole minute since `since` (minute granularity is all
/// `RelativeTime.hace` shows past 60 s).
struct RelativeTimeSchedule: TimelineSchedule {
    let since: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        let since = self.since
        return AnyIterator {
            let current = next
            let elapsed = current.timeIntervalSince(since)
            if elapsed < 60 {
                next = since.addingTimeInterval(elapsed.rounded(.down) + 1)  // whole seconds
            } else {
                let minutes = (elapsed / 60).rounded(.down) + 1
                next = since.addingTimeInterval(minutes * 60)
            }
            return current
        }
    }
}

/// Click → the right VS Code window, then the exact Claude Code tab. Never opens Finder.
///
/// 1. `code <windowDir>` (awaited, bounded by `cliTimeout`) focuses the window.
/// 2. Only if the **current** request's CLI exited 0: after 350 ms, open
///    `vscode://anthropic.claude-code/open?session=<uuid>` — the extension reveals
///    the existing panel for that session (no duplicate). Never sent on the
///    fallback path: VS Code routes URIs to the last-active window, which could
///    open the session as a duplicate tab in the wrong window.
/// 3. Fallback (no windowDir / CLI missing, failed or timed out): activate VS Code.
///
/// Serialized on the main actor:
/// - Request generation: each click supersedes the previous one. The generation
///   is checked at entry to `run()` (before any visible side effect, fallback
///   activation included), before launching the CLI, after it exits and after
///   the reveal delay. A superseded request completes with `.superseded`.
/// - One CLI at a time: a new request cancels the previous CLI (process tree)
///   and **waits until it is reaped** before launching its own, so A's `code`
///   can't run concurrently with — or after — B's.
/// - The tab URI waits until the target window is confirmed in front (see
///   `windowConfirmTimeout`): VS Code hands `vscode://` URIs to the last
///   active window, so a URI sent too early opens the session in the previously
///   active window and pulls focus back there.
@MainActor
enum SessionFocus {
    static let vscodeBundleID = "com.microsoft.VSCode"
    nonisolated static let vscodeAppPath = "/Applications/Visual Studio Code.app"
    /// After `code <dir>` exits the window reaches the front 0.1–0.35 s later
    /// (typically: CLI exits after ~1.1 s, window in front at 1.2–1.4 s). Poll the
    /// focused window up to this long; never confirmed → no URI (window part done).
    static var windowConfirmTimeout: TimeInterval = 2.5
    static let windowPollInterval: TimeInterval = 0.05
    /// Once in front, a moment for VS Code to make it the last-active window.
    static let tabRevealSettle: TimeInterval = 0.15
    /// Without Accessibility the window can't be confirmed: wait out the worst measured switch.
    static let blindRevealDelay: TimeInterval = 0.8
    /// `code <dir>` normally exits in well under a second; past this it is killed → fallback.
    static var cliTimeout: TimeInterval = 5
    nonisolated static let log = Logger(subsystem: "io.github.tactician200.claude-sessions", category: "focus")

    /// Visible side effects, swappable by `--focus-selftest` (no real VS Code).
    struct Effects {
        var openURL: (URL) -> Bool
        var activateVSCode: () -> Outcome
        /// Accessibility granted (window titles readable).
        var canReadWindows: () -> Bool = { FrontWindow.canRead }
        /// Focused VS Code window title; nil if VS Code isn't in front.
        var frontTitle: () -> String? = { FrontWindow.currentTitle() }
    }
    static var effects = Effects(
        openURL: { NSWorkspace.shared.open($0) },
        activateVSCode: { liveActivateVSCode() }
    )
    #if DEBUG
    /// Test override for the CLI launcher (`--focus-selftest`).
    static var launcherOverride: CLILauncher?
    #endif

    /// The `code` launcher to use: the real VS Code CLI (DEBUG builds: a test override first).
    private static func resolveLauncher() -> CLILauncher? {
        #if DEBUG
        if let launcherOverride { return launcherOverride }
        #endif
        return CLILauncher.vscode()
    }

    private static var generation = 0
    private static var running: FocusCLIRun?

    enum Outcome: String {
        case window          // code CLI ok, tab URI not sent (invalid id / URL, window not confirmed)
        case windowAndTab    // code CLI ok + tab URI opened
        case activatedVSCode // fallback: running VS Code activated
        case launchedVSCode  // fallback: VS Code launched
        case superseded      // a newer focus request took over; nothing done
        case failed          // nothing to activate

        var ok: Bool { self != .failed && self != .superseded }
    }

    nonisolated private static let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    nonisolated static func tabURL(for sessionID: String) -> URL? {
        guard sessionID.range(of: uuidPattern, options: .regularExpression) != nil,
              let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "vscode://anthropic.claude-code/open?session=\(encoded)")
    }

    /// `dir` goes to `code <dir>` as an argv: only an absolute path to an
    /// existing directory is acceptable (a relative or option-like value would be
    /// parsed by the CLI as a flag or resolved against the app's cwd).
    nonisolated static func isValidWindowDir(_ dir: String) -> Bool {
        guard dir.hasPrefix("/"), !dir.contains("\0") else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
    }

    /// Asynchronous; `completion` (optional) runs on the main actor with the
    /// final outcome. The reveal happens whether or not a completion is given.
    static func focus(_ session: Session, completion: ((Outcome) -> Void)? = nil) {
        generation &+= 1
        let gen = generation
        running?.cancel()  // reaping is awaited by whichever request launches next
        let id = session.id
        let dir = session.windowDir
        Task { @MainActor in
            let outcome = await run(id: id, dir: dir, gen: gen)
            completion?(outcome)
        }
    }

    private static func isCurrent(_ gen: Int) -> Bool { gen == generation }

    private static func run(id: String, dir: String?, gen: Int) async -> Outcome {
        guard isCurrent(gen) else { return superseded(id: id, gen: gen, at: "entry") }
        log.notice("focus start gen=\(gen) id=\(id, privacy: .public) dir=\(dir ?? "nil", privacy: .public)")
        guard let dir else { return fallback(id: id, reason: "no windowDir") }
        guard isValidWindowDir(dir) else {
            return fallback(id: id, reason: "windowDir is not an absolute existing directory")
        }

        // Serialize: the previous CLI (if any) is cancelled and must be reaped first.
        while let previous = running {
            previous.cancel()
            _ = await previous.wait()
            if running === previous { running = nil }
            guard isCurrent(gen) else { return superseded(id: id, gen: gen, at: "reap-previous") }
        }
        guard let launcher = resolveLauncher() else {
            return fallback(id: id, reason: "code CLI missing")
        }

        let cli = FocusCLIRun(launcher: launcher, dir: dir)
        running = cli
        cli.start(timeout: cliTimeout)
        let status = await cli.wait()
        if running === cli { running = nil }
        guard isCurrent(gen) else { return superseded(id: id, gen: gen, at: "code-cli") }
        guard let status, status == 0 else {
            log.error("focus code-cli exit=\(status.map(String.init) ?? "killed/timeout", privacy: .public) id=\(id, privacy: .public) dir=\(dir, privacy: .public)")
            return fallback(id: id, reason: status.map { "code exit \($0)" } ?? "code killed/timeout")
        }
        log.notice("focus window ok id=\(id, privacy: .public) dir=\(dir, privacy: .public)")

        switch await waitForWindow(dir: dir, gen: gen) {
        case .superseded:
            return superseded(id: id, gen: gen, at: "window-wait")
        case .notConfirmed(let last):
            log.error("focus tab skipped: window not in front after \(windowConfirmTimeout)s id=\(id, privacy: .public) dir=\(dir, privacy: .public) front=\(last ?? "nil", privacy: .public)")
            return .window
        case .confirmed(let after):
            log.notice("focus window confirmed after \(String(format: "%.2f", after), privacy: .public)s id=\(id, privacy: .public)")
            return revealTab(id: id)
        case .blind:
            log.notice("focus window unconfirmed (no Accessibility), blind delay id=\(id, privacy: .public)")
            return revealTab(id: id)
        }
    }

    private enum WindowWait { case confirmed(after: TimeInterval), blind, notConfirmed(lastTitle: String?), superseded }

    private static func waitForWindow(dir: String, gen: Int) async -> WindowWait {
        func pause(_ seconds: TimeInterval) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        guard effects.canReadWindows() else {
            await pause(blindRevealDelay)
            return isCurrent(gen) ? .blind : .superseded
        }
        let start = Date()
        let deadline = start.addingTimeInterval(windowConfirmTimeout)
        while true {
            let title = effects.frontTitle()
            if FrontWindow.isShowing(title: title, windowDir: dir) {
                await pause(tabRevealSettle)
                return isCurrent(gen) ? .confirmed(after: Date().timeIntervalSince(start)) : .superseded
            }
            guard Date() < deadline else { return .notConfirmed(lastTitle: title) }
            await pause(windowPollInterval)
            guard isCurrent(gen) else { return .superseded }
        }
    }

    private static func superseded(id: String, gen: Int, at step: String) -> Outcome {
        log.info("focus superseded gen=\(gen) at=\(step, privacy: .public) id=\(id, privacy: .public)")
        return .superseded
    }

    private static func revealTab(id: String) -> Outcome {
        guard let url = tabURL(for: id) else {
            log.error("focus tab skipped: id is not a UUID id=\(id, privacy: .public)")
            return .window
        }
        let opened = effects.openURL(url)
        log.notice("focus tab uri=\(url.absoluteString, privacy: .public) opened=\(opened)")
        return opened ? .windowAndTab : .window
    }

    private static func fallback(id: String, reason: String) -> Outcome {
        let outcome = effects.activateVSCode()
        log.notice("focus fallback (\(reason, privacy: .public)) id=\(id, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
        return outcome
    }

    private static func liveActivateVSCode() -> Outcome {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: vscodeBundleID).first {
            running.activate(options: [.activateAllWindows])
            return .activatedVSCode
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscodeBundleID) else {
            return .failed
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        return .launchedVSCode
    }
}

/// How to run `code <dir>` so that **we own the real process**.
///
/// The installed `bin/code` is a bash script that runs
/// `ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$CLI" "$@"` *without* `exec`, so
/// terminating the wrapper leaves the Electron CLI alive. We replicate the
/// script instead: same Electron binary + `out/cli.js`, same env handling
/// (`VSCODE_NODE_OPTIONS`/`VSCODE_NODE_REPL_EXTERNAL_MODULE` copied, the
/// originals unset, `ELECTRON_RUN_AS_NODE=1`). Chosen over `pkill -P` on the
/// wrapper: no extra process, no pgrep race between listing and killing the
/// wrapper's child, and the pid we signal is the CLI itself. cli.js on macOS
/// spawns a *detached* `open -n -g -a Code` (own session, so process-group
/// kills miss it) — `FocusCLIRun.cancel` therefore walks the descendant tree
/// by ppid (`proc_listchildpids`) before terminating the CLI.
/// (The script's remote-CLI branch only applies inside VS Code remote
/// terminals, never to this GUI app.)
struct CLILauncher {
    let executable: URL
    let argumentsPrefix: [String]
    let environment: [String: String]?

    static func vscode(appPath: String = SessionFocus.vscodeAppPath) -> CLILauncher? {
        let contents = URL(fileURLWithPath: appPath).appendingPathComponent("Contents")
        let electron = contents.appendingPathComponent("MacOS/Code")
        let cliJS = contents.appendingPathComponent("Resources/app/out/cli.js")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: electron.path), fm.fileExists(atPath: cliJS.path) else {
            return nil
        }
        var env = ProcessInfo.processInfo.environment
        env["VSCODE_NODE_OPTIONS"] = env["NODE_OPTIONS"] ?? ""
        env["VSCODE_NODE_REPL_EXTERNAL_MODULE"] = env["NODE_REPL_EXTERNAL_MODULE"] ?? ""
        env.removeValue(forKey: "NODE_OPTIONS")
        env.removeValue(forKey: "NODE_REPL_EXTERNAL_MODULE")
        env["ELECTRON_RUN_AS_NODE"] = "1"
        return CLILauncher(executable: electron, argumentsPrefix: [cliJS.path], environment: env)
    }
}

/// One `code <dir>` execution: bounded, cancellable, and awaitable until the
/// process has been **reaped** (Foundation's `Process` waitpid()s the child
/// before calling `terminationHandler`). `wait()` returns the exit status, or
/// nil if it failed to launch, was cancelled, or timed out.
@MainActor
final class FocusCLIRun {
    private let process = Process()
    private var finished = false
    private var result: Int32?
    private var interrupted = false
    private var waiters: [CheckedContinuation<Int32?, Never>] = []
    private let dir: String
    #if DEBUG
    /// Test hook (`--focus-selftest`): "launch <dir>" / "reaped <dir>".
    static var onEvent: ((String) -> Void)?
    #endif
    /// After SIGTERM, escalate to SIGKILL; after that, give up waiting (never
    /// hang the UI on an unreapable process).
    static let killGrace: TimeInterval = 1
    static let giveUpAfterKill: TimeInterval = 2

    init(launcher: CLILauncher, dir: String) {
        self.dir = dir
        process.executableURL = launcher.executable
        process.arguments = launcher.argumentsPrefix + [dir]
        if let env = launcher.environment { process.environment = env }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    var pid: pid_t { process.processIdentifier }

    func start(timeout: TimeInterval) {
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.finish(status) }
        }
        do {
            try process.run()
        } catch {
            SessionFocus.log.error("focus code-cli failed to run: \(error.localizedDescription, privacy: .public)")
            interrupted = true
            finish(nil)
            return
        }
        #if DEBUG
        Self.onEvent?("launch \((dir as NSString).lastPathComponent)")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            SessionFocus.log.error("focus code-cli timeout after \(timeout)s pid=\(self.pid)")
            self.cancel()
        }
    }

    /// SIGTERM to the whole descendant tree (children first — once the CLI
    /// dies they are re-parented and unfindable), then SIGKILL after a grace.
    func cancel() {
        guard !finished, !interrupted else { return }
        interrupted = true
        let root = pid
        guard root > 0 else { finish(nil); return }
        Self.signalTree(root, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace) { [weak self] in
            guard let self, !self.finished else { return }
            Self.signalTree(root, SIGKILL)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.giveUpAfterKill) { [weak self] in
                guard let self, !self.finished else { return }
                SessionFocus.log.error("focus code-cli pid=\(root) not reaped after SIGKILL; giving up")
                self.finish(nil)
            }
        }
    }

    func wait() async -> Int32? {
        if finished { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(_ status: Int32?) {
        guard !finished else { return }
        finished = true
        result = interrupted ? nil : status
        #if DEBUG
        Self.onEvent?("reaped \((dir as NSString).lastPathComponent)")
        #endif
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: result) }
    }

    /// Descendants (depth-first, by ppid) then the root.
    nonisolated static func signalTree(_ root: pid_t, _ sig: Int32) {
        for child in childPIDs(of: root) { signalTree(child, sig) }
        kill(root, sig)
    }

    nonisolated static func childPIDs(of pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(n))).filter { $0 > 0 }
    }
}

#if DEBUG
// MARK: - Self-test (`--focus-selftest`)

/// Headless check of SessionFocus serialization with a fake CLI (a bash script
/// that logs, spawns a child standing in for cli.js's detached `open`, sleeps
/// and exits with a chosen code) and fake effects — no VS Code, no windows.
/// The fake dir basename encodes behaviour: `<name>_<sleepSeconds>_<exitCode>`.
@MainActor
enum SessionFocusSelfTest {
    static func run() -> Bool {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-sessions-focus-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = tmp.appendingPathComponent("fake-code")
        let log = tmp.appendingPathComponent("log.txt")
        let body = """
        #!/bin/bash
        IFS=_ read -r name secs code <<< "$(basename "$1")"
        echo "start $name $$" >> "$FOCUS_TEST_LOG"
        trap 'echo "term $name" >> "$FOCUS_TEST_LOG"; exit 143' TERM
        /bin/sleep 30 &
        echo "child $name $!" >> "$FOCUS_TEST_LOG"
        /bin/sleep "$secs" &
        wait $!
        echo "end $name" >> "$FOCUS_TEST_LOG"
        exit "$code"
        """
        FileManager.default.createFile(atPath: script.path, contents: body.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: log.path, contents: nil)
        var env = ProcessInfo.processInfo.environment
        env["FOCUS_TEST_LOG"] = log.path
        SessionFocus.launcherOverride = CLILauncher(executable: script, argumentsPrefix: [], environment: env)

        var opened: [String] = []
        var activations = 0
        var events: [String] = []
        // Fake front window: the last folder whose fake `code` ran is in front,
        // unless a case overrides it (`frontOverride`) or turns AX off.
        var canRead = true
        var frontOverride: (() -> String?)?
        SessionFocus.effects = .init(
            openURL: { opened.append($0.absoluteString); return true },
            activateVSCode: { activations += 1; return .activatedVSCode },
            canReadWindows: { canRead },
            frontTitle: {
                if let frontOverride { return frontOverride() }
                return events.last { $0.hasPrefix("launch ") }.map { "f.swift — " + $0.dropFirst("launch ".count) }
            }
        )
        FocusCLIRun.onEvent = { events.append($0) }

        func session(_ id: String, _ dir: String?) -> Session {
            Session(id: id, projectPath: dir ?? "", projectName: id, model: "—", modelTier: .unknown,
                    contextTokens: 0, usedTokens: 0, toolCallCount: 0, lastToolName: nil, lastActivity: Date(), subagents: [],
                    transcriptURL: URL(fileURLWithPath: "/dev/null"), status: .done, waitingReason: nil,
                    lastPrompt: nil, lastActivityText: nil, statusSince: Date(), windowDir: dir,
                    claudePid: nil)
        }
        // The focus path only launches `code` for an existing absolute directory.
        func dir(_ spec: String) -> String {
            let url = tmp.appendingPathComponent(spec)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        func pump(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        func logLines() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func childPid(_ name: String) -> pid_t? {
            logLines().first { $0.hasPrefix("child \(name) ") }
                .flatMap { $0.split(separator: " ").last.flatMap { pid_t(String($0)) } }
        }
        func alive(_ pid: pid_t?) -> Bool {
            guard let pid else { return false }
            return kill(pid, 0) == 0 || errno != ESRCH
        }
        func reset() {
            opened = []; activations = 0; events = []; canRead = true; frontOverride = nil
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        var allPass = true
        func check(_ name: String, _ conditions: [(String, Bool)]) {
            let failed = conditions.filter { !$0.1 }.map(\.0)
            if failed.isEmpty { print("PASS \(name)") } else {
                allPass = false
                print("FAIL \(name): \(failed.joined(separator: "; "))")
            }
        }
        let uuidA = "aaaaaaaa-0000-4000-8000-000000000001" // pii-gate:allow (invented)
        let uuidB = "bbbbbbbb-0000-4000-8000-000000000002" // pii-gate:allow (invented)
        let urlB = SessionFocus.tabURL(for: uuidB)!.absoluteString

        // (a) A's CLI is running (3 s) when B is clicked → A cancelled + reaped
        // (its child too) before B launches; only B's URI is opened.
        reset()
        var outA: SessionFocus.Outcome?, outB: SessionFocus.Outcome?
        SessionFocus.focus(session(uuidA, dir("A_3_0"))) { outA = $0 }
        pump(0.5) { logLines().contains { $0.hasPrefix("child A ") } }
        let childA = childPid("A")
        let t0 = Date()
        SessionFocus.focus(session(uuidB, dir("B_0_0"))) { outB = $0 }
        pump(8) { outA != nil && outB != nil }
        let elapsed = Date().timeIntervalSince(t0)
        let iReapA = events.firstIndex(of: "reaped A_3_0"), iLaunchB = events.firstIndex(of: "launch B_0_0")
        check("a supersede: A cancelled + reaped before B launches, only B's URI", [
            ("A superseded (got \(outA?.rawValue ?? "nil"))", outA == .superseded),
            ("B windowAndTab (got \(outB?.rawValue ?? "nil"))", outB == .windowAndTab),
            ("opened == [B] (got \(opened))", opened == [urlB]),
            ("no fallback activation (got \(activations))", activations == 0),
            ("reaped A before launch B (events \(events))", iReapA != nil && iLaunchB != nil && iReapA! < iLaunchB!),
            ("A's child killed (pid \(childA.map(String.init) ?? "nil"))", childA != nil && !alive(childA)),
            ("A never finished on its own (log \(logLines()))", !logLines().contains("end A")),
            ("B did not wait out A's 3 s (elapsed \(String(format: "%.2f", elapsed)) s)", elapsed < 2.5),
        ])

        // (b) generation checked at entry: back-to-back clicks → C never
        // launches; a superseded no-windowDir click never activates VS Code.
        reset()
        var outC: SessionFocus.Outcome?, outD: SessionFocus.Outcome?, outE: SessionFocus.Outcome?
        SessionFocus.focus(session(uuidA, nil)) { outE = $0 }
        SessionFocus.focus(session(uuidA, dir("C_0_0"))) { outC = $0 }
        SessionFocus.focus(session(uuidB, dir("D_0_0"))) { outD = $0 }
        pump(5) { outC != nil && outD != nil && outE != nil }
        check("b entry check: superseded requests have no side effects", [
            ("E (no dir) superseded (got \(outE?.rawValue ?? "nil"))", outE == .superseded),
            ("C superseded (got \(outC?.rawValue ?? "nil"))", outC == .superseded),
            ("D windowAndTab (got \(outD?.rawValue ?? "nil"))", outD == .windowAndTab),
            ("C never launched (events \(events))", !events.contains("launch C_0_0")),
            ("no activation (got \(activations))", activations == 0),
            ("opened == [D] (got \(opened))", opened == [urlB]),
        ])

        // (c) CLI hangs past the timeout → killed + reaped → fallback, no URI.
        reset()
        SessionFocus.cliTimeout = 1
        var outG: SessionFocus.Outcome?
        let tG = Date()
        SessionFocus.focus(session(uuidA, dir("G_20_0"))) { outG = $0 }
        pump(6) { outG != nil }
        let elapsedG = Date().timeIntervalSince(tG)
        let childG = childPid("G")
        SessionFocus.cliTimeout = 5
        check("c timeout → kill tree, fallback, no URI", [
            ("G activatedVSCode (got \(outG?.rawValue ?? "nil"))", outG == .activatedVSCode),
            ("activations == 1 (got \(activations))", activations == 1),
            ("no URI (got \(opened))", opened.isEmpty),
            ("reaped G (events \(events))", events.contains("reaped G_20_0")),
            ("G's child killed", childG != nil && !alive(childG)),
            ("bounded (elapsed \(String(format: "%.2f", elapsedG)) s)", elapsedG < 3),
        ])

        // (d) non-zero exit → fallback, no URI; (e) non-UUID id → window only.
        reset()
        var outH: SessionFocus.Outcome?
        SessionFocus.focus(session(uuidA, dir("H_0_3"))) { outH = $0 }
        pump(5) { outH != nil }
        check("d exit 3 → fallback, no URI", [
            ("H activatedVSCode (got \(outH?.rawValue ?? "nil"))", outH == .activatedVSCode),
            ("no URI (got \(opened))", opened.isEmpty),
        ])
        reset()
        var outI: SessionFocus.Outcome?
        SessionFocus.focus(session("not-a-uuid", dir("I_0_0"))) { outI = $0 }
        pump(5) { outI != nil }
        check("e non-UUID id → window, no URI", [
            ("I window (got \(outI?.rawValue ?? "nil"))", outI == .window),
            ("no URI (got \(opened))", opened.isEmpty),
            ("no activation", activations == 0),
        ])

        // (g) the window never reaches the front → no URI (it would open the
        // session in whatever window was last active), bounded by the timeout.
        reset()
        SessionFocus.windowConfirmTimeout = 0.5
        frontOverride = { "app.py — some-other-folder" }
        var outJ: SessionFocus.Outcome?
        let tJ = Date()
        SessionFocus.focus(session(uuidA, dir("J_0_0"))) { outJ = $0 }
        pump(4) { outJ != nil }
        let elapsedJ = Date().timeIntervalSince(tJ)
        check("g window never confirmed → window only, no URI", [
            ("J window (got \(outJ?.rawValue ?? "nil"))", outJ == .window),
            ("no URI (got \(opened))", opened.isEmpty),
            ("no activation", activations == 0),
            ("bounded (elapsed \(String(format: "%.2f", elapsedJ)) s)", elapsedJ < 2),
        ])

        // (h) the window arrives late (0.3 s after the CLI) → URI only after it.
        reset()
        var cliDoneAt: Date?  // first poll after the fake CLI exited
        var uriAt: Date?
        frontOverride = {
            guard events.contains("reaped K_0_0") else { return "x — other" }
            let since = cliDoneAt ?? Date()
            cliDoneAt = since
            return Date().timeIntervalSince(since) >= 0.3 ? "f.swift — K_0_0" : "x — other"
        }
        let savedOpen = SessionFocus.effects.openURL
        SessionFocus.effects.openURL = { uriAt = Date(); return savedOpen($0) }
        var outK: SessionFocus.Outcome?
        SessionFocus.focus(session(uuidB, dir("K_0_0"))) { outK = $0 }
        pump(4) { outK != nil }
        SessionFocus.effects.openURL = savedOpen
        let waited = cliDoneAt.flatMap { start in uriAt.map { $0.timeIntervalSince(start) } }
        check("h late window → URI sent only once it is in front", [
            ("K windowAndTab (got \(outK?.rawValue ?? "nil"))", outK == .windowAndTab),
            ("opened == [B] (got \(opened))", opened == [urlB]),
            ("URI ≥ 0.3 s after the CLI (waited \(waited.map { String(format: "%.2f", $0) } ?? "nil") s)", (waited ?? 0) >= 0.3),
        ])

        // (i) Accessibility not granted → can't confirm: blind delay, URI sent.
        reset()
        SessionFocus.windowConfirmTimeout = 2.5
        canRead = false
        var outL: SessionFocus.Outcome?
        SessionFocus.focus(session(uuidB, dir("L_0_0"))) { outL = $0 }
        pump(4) { outL != nil }
        check("i no Accessibility → blind delay, URI sent", [
            ("L windowAndTab (got \(outL?.rawValue ?? "nil"))", outL == .windowAndTab),
            ("opened == [B] (got \(opened))", opened == [urlB]),
        ])

        // (f) the real launcher replicates bin/code (no VS Code is run here).
        if let real = CLILauncher.vscode() {
            check("f real launcher = Electron + cli.js, ELECTRON_RUN_AS_NODE=1, NODE_OPTIONS unset", [
                ("executable \(real.executable.lastPathComponent)", real.executable.path.hasSuffix("Contents/MacOS/Code")),
                ("cli.js arg", real.argumentsPrefix.first?.hasSuffix("Resources/app/out/cli.js") == true),
                ("ELECTRON_RUN_AS_NODE", real.environment?["ELECTRON_RUN_AS_NODE"] == "1"),
                ("NODE_OPTIONS unset", real.environment?["NODE_OPTIONS"] == nil),
                ("VSCODE_NODE_OPTIONS set", real.environment?["VSCODE_NODE_OPTIONS"] != nil),
            ])
        } else {
            print("SKIP f real launcher: VS Code not installed at \(SessionFocus.vscodeAppPath)")
        }

        SessionFocus.launcherOverride = nil
        SessionFocus.windowConfirmTimeout = 2.5
        FocusCLIRun.onEvent = nil
        return allPass
    }
}
#endif
