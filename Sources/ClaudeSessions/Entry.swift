import Foundation

/// Process entry point. Headless modes run before any NSApplication / SwiftUI setup:
/// - `--dump`: one scan, JSON array to stdout, exit 0 (grader mode).
/// - `--snapshot <out.png> [--tab usage] [--appearance light|dark]`: offscreen
///   render of the dropdown (see Snapshot).
/// - `--fixtures <dir>` (with `--snapshot` or `--dump`): read only `<dir>` — its
///   `sessions-state/`, `projects/` and `settings.json` — never `~/.claude`.
///   Snapshot exits 1 when it finds no session there.
/// - `--language en|es`: UI language for this run (default: the system's).
/// - `--budget-selftest`: WorkdayBudget cases, PASS/FAIL, exit 1 on failure.
/// - `--layout-selftest`: panel placement (PanelLayout) on a typical multi-display
///   geometry, PASS/FAIL, exit 1 on failure.
/// - `--focus-selftest`: SessionFocus serialization against a fake CLI and fake
///   effects (no VS Code), PASS/FAIL, exit 1 on failure.
/// - `--attention-selftest`: toast transitions + window-title matching.
/// - `--incremental-selftest`: split-fed ParserState == one-shot parse, and
///   TranscriptCache append / partial line / shrink / new inode on a temp file.
/// - `--robust-selftest`: staleness rule, pid identity, `code` dir validator, project-path decoder.
/// - `--gaps-selftest`: SessionStateReader tolerant decoding (temp files), SessionScanner.sorted
///   ordering, prettyModel / modelTier.
/// - `--finished-selftest`: "Terminó" vs "Inactiva" (seen per finish, 2 h fade).
/// - `--l10n-selftest`: en/es tables, keys used by the sources, hook reasons.
/// - `--warnings-selftest`: panel warnings (hook without Python, upstream tracker,
///   state-file version) on injected data.
/// - `--focus <session-id-prefix>`: same click path as a row; exit 1 if not found.
///
/// Self-tests and the hidden diagnostics (`--incremental-realdata`,
/// `--incremental-bench`) exist only in DEBUG builds (`swift build`); a release
/// build (`swift build -c release`) compiles none of them in.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--language") {
            guard i + 1 < args.count, L10n.supported.contains(args[i + 1]) else {
                fail("--language must be one of \(L10n.supported.joined(separator: "|"))")
            }
            L10n.force(args[i + 1])
        }
        if let i = args.firstIndex(of: "--fixtures") {
            guard i + 1 < args.count else { fail("usage: --fixtures <dir>") }
            let url = URL(fileURLWithPath: args[i + 1]).absoluteURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                fail("--fixtures: no such directory: \(args[i + 1])")
            }
            ClaudePaths.fixtureRoot = url
        }
        if args.contains("--dump") {
            dumpSessions()
            exit(0)
        }
        #if DEBUG
        // Self-tests assert the Spanish wording unless a language is given.
        if !args.contains("--language"), args.contains(where: { $0.hasSuffix("-selftest") }) {
            L10n.force("es")
        }
        if args.contains("--l10n-selftest") {
            exit(L10nSelfTest.run() ? 0 : 1)
        }
        if args.contains("--warnings-selftest") {
            exit(PanelWarningsSelfTest.run() ? 0 : 1)
        }
        if args.contains("--budget-selftest") {
            let budget = WorkdayBudgetSelfTest.run()
            let clocks = UsageClockSelfTest.run()
            let fetcher = UsageFetcherSelfTest.run()
            exit(budget && clocks && fetcher ? 0 : 1)
        }
        if args.contains("--focus-selftest") {
            exit(MainActor.assumeIsolated { SessionFocusSelfTest.run() } ? 0 : 1)
        }
        if args.contains("--attention-selftest") {
            exit(AttentionSelfTest.run() ? 0 : 1)
        }
        if args.contains("--incremental-selftest") {
            exit(IncrementalSelfTest.run() ? 0 : 1)
        }
        // Hidden diagnostics (read-only on their input): real-data equivalence, perf.
        if let i = args.firstIndex(of: "--incremental-realdata"), i + 1 < args.count {
            exit(IncrementalRealDataCheck.run(root: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--incremental-bench"), i + 1 < args.count {
            exit(IncrementalBench.run(source: args[i + 1]) ? 0 : 1)
        }
        if args.contains("--robust-selftest") {
            exit(RobustSelfTest.run() ? 0 : 1)
        }
        if args.contains("--finished-selftest") {
            exit(FinishedStateSelfTest.run() ? 0 : 1)
        }
        if args.contains("--gaps-selftest") {
            exit(GapsSelfTest.run() ? 0 : 1)
        }
        if args.contains("--held-selftest") {
            exit(HeldToolSelfTest.run() ? 0 : 1)
        }
        if args.contains("--layout-selftest") {
            exit(PanelLayoutSelfTest.run() ? 0 : 1)
        }
        #endif
        if let i = args.firstIndex(of: "--focus") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write("usage: --focus <session-id-prefix>\n".data(using: .utf8)!)
                exit(2)
            }
            exit(focusCLI(prefix: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            var tab: AppState.Tab = .sessions
            if let t = args.firstIndex(of: "--tab"), t + 1 < args.count {
                guard let parsed = AppState.Tab(rawValue: args[t + 1]) else {
                    FileHandle.standardError.write("--tab must be sessions|usage\n".data(using: .utf8)!)
                    exit(2)
                }
                tab = parsed
            }
            var appearance: Snapshot.Appearance = .dark
            if let a = args.firstIndex(of: "--appearance") {
                guard a + 1 < args.count, let parsed = Snapshot.Appearance(rawValue: args[a + 1]) else {
                    fail("--appearance must be light|dark")
                }
                appearance = parsed
            }
            MainActor.assumeIsolated { Snapshot.run(to: args[i + 1], tab: tab, appearance: appearance) }
            exit(0)
        }
        MainActor.assumeIsolated { ClaudeSessionsApp.main() }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(2)
    }

    /// Finds the session by id prefix and runs SessionFocus (window + tab URI),
    /// pumping the main run loop until the async focus completes.
    static func focusCLI(prefix: String) -> Int32 {
        let matches = SessionScanner.scan().filter { $0.id.hasPrefix(prefix) }
        guard let session = matches.first else {
            print("focus \(prefix) not found")
            return 1
        }
        if matches.count > 1 {
            FileHandle.standardError.write("focus: \(matches.count) sessions match '\(prefix)', using \(session.id)\n".data(using: .utf8)!)
        }
        var outcome: SessionFocus.Outcome?
        MainActor.assumeIsolated {
            SessionFocus.focus(session) { outcome = $0 }
        }
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let result = outcome ?? .failed
        let status = result.ok ? "ok" : "failed"
        print("focus \(session.id) dir=\(session.windowDir ?? "nil") \(status) (\(outcome?.rawValue ?? "timeout"))")
        return result.ok ? 0 : 1
    }

    static func dumpSessions() {
        let sessions = SessionScanner.scan()
        let array: [[String: Any]] = sessions.map { s in
            [
                "id": s.id,
                "projectName": s.projectName,
                "status": s.status.rawValue,
                "waitingReason": s.waitingReason ?? NSNull(),
                "lastActivityText": s.lastActivityText ?? NSNull(),
                "statusSince": s.statusSince.timeIntervalSince1970,
                "windowDir": s.windowDir ?? NSNull(),
                "contextTokens": s.contextTokens,
                "usedTokens": s.usedTokens,
            ]
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: array,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("dump failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
