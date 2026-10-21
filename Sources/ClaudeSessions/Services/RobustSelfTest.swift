import Foundation
import Darwin

// Test-only: compiled into DEBUG builds, absent from release.
#if DEBUG

/// `--robust-selftest`: pure pieces of the scanner/focus hardening — staleness rule,
/// pid identity, `code` argument validator, project-path decoder. PASS/FAIL per
/// case, exit 1 on any failure.
enum RobustSelfTest {
    static func run() -> Bool {
        var allPass = true
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("PASS \(name)") } else {
                allPass = false
                print("FAIL \(name) \(detail())")
            }
        }

        // 1. Staleness: a live pid is authoritative for non-done sessions.
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        check("stale: waiting 13h + live pid stays visible",
              !SessionScanner.isStale(status: .waiting, updatedAt: ago(13), hasPid: true, now: now))
        check("stale: working 30h + live pid stays visible",
              !SessionScanner.isStale(status: .working, updatedAt: ago(30), hasPid: true, now: now))
        check("stale: done 13h + pid hidden",
              SessionScanner.isStale(status: .done, updatedAt: ago(13), hasPid: true, now: now))
        check("stale: waiting 13h without pid hidden",
              SessionScanner.isStale(status: .waiting, updatedAt: ago(13), hasPid: false, now: now))
        check("stale: done 11h shown",
              !SessionScanner.isStale(status: .done, updatedAt: ago(11), hasPid: true, now: now))
        check("stale: working 1h without pid shown",
              !SessionScanner.isStale(status: .working, updatedAt: ago(1), hasPid: false, now: now))

        // 3. pid identity.
        let nativePath = "/Users/alex/.vscode/extensions/anthropic.claude-code-2.1.304-darwin-arm64/resources/native-binary/claude"
        check("pid: native binary path", SessionScanner.isClaudeProcess(name: "claude", path: nativePath, argv: { "" }))
        check("pid: name only", SessionScanner.isClaudeProcess(name: "claude", path: "/opt/bin/x", argv: { "" }))
        check("pid: node running claude",
              SessionScanner.isClaudeProcess(name: "node", path: "/opt/homebrew/bin/node", argv: { "node /x/bin/claude --resume" }))
        check("pid: node running something else is not claude",
              !SessionScanner.isClaudeProcess(name: "node", path: "/opt/homebrew/bin/node", argv: { "node server.js" }))
        check("pid: recycled to zsh is not claude",
              !SessionScanner.isClaudeProcess(name: "zsh", path: "/bin/zsh", argv: { "-zsh" }))
        check("pid: recycled to Safari is not claude",
              !SessionScanner.isClaudeProcess(name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", argv: { "" }))
        check("pid: self (ClaudeSessions) alive", SessionScanner.isProcessAlive(Int(getpid())))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        if (try? sleeper.run()) != nil {
            check("pid: live non-claude process (sleep) counts as dead",
                  !SessionScanner.isProcessAlive(Int(sleeper.processIdentifier)))
            sleeper.terminate()
            sleeper.waitUntilExit()
            check("pid: reaped pid dead", !SessionScanner.isProcessAlive(Int(sleeper.processIdentifier)))
        } else {
            check("pid: could not launch /bin/sleep", false)
        }

        // 4. `code` argument validator.
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-sessions-robust-\(getpid())")
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("a-file")
        fm.createFile(atPath: file.path, contents: Data())
        check("dir: existing absolute directory", SessionFocus.isValidWindowDir(tmp.path))
        check("dir: file rejected", !SessionFocus.isValidWindowDir(file.path))
        check("dir: missing rejected", !SessionFocus.isValidWindowDir(tmp.appendingPathComponent("nope").path))
        check("dir: relative rejected", !SessionFocus.isValidWindowDir("relative/dir"))
        check("dir: option-like rejected", !SessionFocus.isValidWindowDir("--install-extension"))
        check("dir: empty rejected", !SessionFocus.isValidWindowDir(""))
        check("dir: NUL rejected", !SessionFocus.isValidWindowDir(tmp.path + "\0x"))

        // 6. decodeProjectPath against a temp tree.
        func mk(_ rel: String) { try? fm.createDirectory(at: tmp.appendingPathComponent(rel), withIntermediateDirectories: true) }
        mk("Users/alex/code/projects/demo-web-app")
        mk("Users/alex/.claude")
        mk("Users/alex/demo/web")         // decoy: "demo/web" exists but "app" does not
        mk("Users/alex/demo-web-app")
        let root = tmp.path
        check("decode: dashed project name",
              SessionScanner.decodeProjectPath("-Users-alex-code-projects-demo-web-app", root: root)
                == root + "/Users/alex/code/projects/demo-web-app")
        check("decode: dot directory (--claude)",
              SessionScanner.decodeProjectPath("-Users-alex--claude", root: root) == root + "/Users/alex/.claude")
        check("decode: backtracks past a decoy prefix",
              SessionScanner.decodeProjectPath("-Users-alex-demo-web-app", root: root) == root + "/Users/alex/demo-web-app")
        check("decode: nothing exists → lossy fallback",
              SessionScanner.decodeProjectPath("-no-such-thing", root: root) == "/no/such/thing")
        check("decode: real root, existing /tmp",
              SessionScanner.decodeProjectPath("-tmp") == "/tmp")

        return allPass
    }
}
#endif
