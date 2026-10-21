import Foundation

/// Reads the per-session state files (contract v1) written by the
/// `session-state.py` hook at `~/.claude/sessions-state/<session_id>.json`.
///
/// Decoding is tolerant: every field may be missing. `status` falls back to
/// the upstream boolean `working` when absent.
enum SessionStateReader {
    struct State {
        let fileURL: URL
        let sessionId: String
        let cwd: String?
        let transcriptPath: String?
        let status: Session.Status
        let waitingReason: String?
        let statusSince: Date
        let lastPrompt: String?
        let lastActivity: String?
        let lastTool: String?
        let updatedAt: Date
        let claudePid: Int?
        let windowRoot: String?
        let windowDir: String?
        /// Tool calls PreToolUse announced and PostToolUse hasn't closed (`pending_tools`).
        var pendingTools: Set<String> = []
        var lastPromptAt: Date? = nil
        /// Every UserPromptSubmit, harness notices included (absent from older hook versions).
        var turnStartedAt: Date? = nil
        /// Contract version `v` (nil = a legacy file without one). See PanelWarnings.
        var version: Int? = nil
        /// Has keys only the upstream `claude-sessions-tracker` writes. See PanelWarnings.
        var hasUpstreamKeys = false
        /// File modification time.
        var modifiedAt: Date = .distantPast
    }

    /// See ClaudePaths: fixture dir, env `CLAUDE_SESSIONS_STATE_DIR`, or `~/.claude/sessions-state`.
    static var stateDirectory: URL { ClaudePaths.stateDirectory }

    /// Candidate state files: `<session_id>.json`, non-hidden. Hidden entries
    /// (`.skipsHiddenFiles`, plus any name starting with "." — this covers the
    /// hook's atomic-write temporaries `.tmp-*`) are never sessions.
    private static func jsonFiles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: stateDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { url in
            let name = url.lastPathComponent
            return url.pathExtension == "json" && !name.hasPrefix(".")
        }
    }

    /// True when the state dir has at least one `.json` file. When true, the
    /// state files are the source of truth for the session list.
    static func hasStateFiles() -> Bool {
        !jsonFiles().isEmpty
    }

    /// One State per session_id: files whose basename differs from the
    /// `session_id` inside are rejected, and duplicates (defensive) keep the
    /// newest `updated_at` — `ForEach` needs unique identities.
    static func readAll() -> [State] {
        var byId: [String: State] = [:]
        for state in jsonFiles().compactMap(read(url:)) {
            if let existing = byId[state.sessionId], existing.updatedAt >= state.updatedAt {
                continue
            }
            byId[state.sessionId] = state
        }
        return Array(byId.values)
    }

    /// nil when unreadable, not a JSON object, or `session_id` doesn't match the
    /// filename. A missing `session_id` falls back to the filename (tolerant
    /// decoding), so the basename == session_id invariant still holds.
    static func read(url: URL) -> State? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        let basename = url.deletingPathExtension().lastPathComponent
        let sid = nonEmptyString(obj["session_id"]) ?? basename
        guard sid == basename else { return nil }

        let status: Session.Status = {
            if let raw = nonEmptyString(obj["status"])?.lowercased(),
               let s = Session.Status(rawValue: raw) {
                return s
            }
            return bool(obj["working"]) == true ? .working : .done
        }()

        // Fixture mode: a time <= 0 is seconds before now, so committed demo
        // fixtures never go stale.
        let now = ClaudePaths.isFixtureMode ? Date() : nil
        func date(_ v: Any?) -> Date? { Self.date(v, relativeTo: now) }

        let updatedAt = date(obj["updated_at"]) ?? mtime
        let statusSince = date(obj["status_since"]) ?? updatedAt

        return State(
            fileURL: url,
            sessionId: sid,
            cwd: nonEmptyString(obj["cwd"]),
            transcriptPath: ClaudePaths.resolveTranscript(nonEmptyString(obj["transcript_path"])),
            status: status,
            waitingReason: nonEmptyString(obj["waiting_reason"]),
            statusSince: statusSince,
            lastPrompt: nonEmptyString(obj["last_prompt"]),
            lastActivity: nonEmptyString(obj["last_activity"]),
            lastTool: nonEmptyString(obj["last_tool"]),
            updatedAt: updatedAt,
            claudePid: int(obj["claude_pid"]),
            windowRoot: nonEmptyString(obj["window_root"]),
            windowDir: nonEmptyString(obj["window_dir"]),
            pendingTools: Set(((obj["pending_tools"] as? [String: Any]) ?? [:]).keys),
            lastPromptAt: date(obj["last_prompt_at"]),
            turnStartedAt: date(obj["turn_started_at"]),
            version: int(obj["v"]),
            hasUpstreamKeys: !PanelWarnings.upstreamOnlyKeys.isDisjoint(with: obj.keys),
            modifiedAt: mtime
        )
    }

    // MARK: - tolerant decoders

    private static func nonEmptyString(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func date(_ v: Any?, relativeTo now: Date?) -> Date? {
        let seconds: Double
        if let n = v as? NSNumber { seconds = n.doubleValue }
        else if let s = v as? String, let d = Double(s) { seconds = d }
        else { return nil }
        if let now, seconds <= 0 { return now.addingTimeInterval(seconds) }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func bool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
}
