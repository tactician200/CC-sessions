import Foundation

/// Every Claude Code file the app reads, from one place:
/// - `--fixtures <dir>` (snapshot, dump): `<dir>/sessions-state`, `<dir>/projects`,
///   `<dir>/settings.json`, and nothing outside `<dir>` — no fallback to `~/.claude`.
/// - env `CLAUDE_SESSIONS_STATE_DIR`: the state dir only (tests; the hook honours it too).
/// - default: `~/.claude/…`.
enum ClaudePaths {
    /// Set once at startup by `--fixtures`, before any scan.
    static var fixtureRoot: URL?

    static var isFixtureMode: Bool { fixtureRoot != nil }

    private static var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static var stateDirectory: URL {
        if let root = fixtureRoot { return root.appendingPathComponent("sessions-state", isDirectory: true) }
        if let override = ProcessInfo.processInfo.environment["CLAUDE_SESSIONS_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return claudeHome.appendingPathComponent("sessions-state", isDirectory: true)
    }

    static var projectsDirectory: URL {
        (fixtureRoot ?? claudeHome).appendingPathComponent("projects", isDirectory: true)
    }

    static var settingsFile: URL {
        (fixtureRoot ?? claudeHome).appendingPathComponent("settings.json")
    }

    /// Written by the plugin's launcher when no Python 3.9+ is found.
    static var hookUnavailableMarker: URL {
        stateDirectory.appendingPathComponent(".hook-unavailable")
    }

    /// Fixture mode: a relative transcript path resolves against the fixture root,
    /// and a path that lands outside it is dropped. Otherwise unchanged.
    static func resolveTranscript(_ path: String?) -> String? {
        guard let path else { return nil }
        guard let root = fixtureRoot else { return path }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let resolved = url.standardizedFileURL.path
        return resolved.hasPrefix(root.standardizedFileURL.path + "/") ? resolved : nil
    }
}
