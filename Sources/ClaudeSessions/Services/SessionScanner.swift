import Foundation
import Darwin

enum SessionScanner {
    /// Fallback window (no state files): how recently a JSONL must have been
    /// modified to be considered an active session.
    static let activeCutoff: TimeInterval = 5 * 60
    static let workingThreshold: TimeInterval = 2.0
    /// State files whose `updated_at` is older than this are hidden (not deleted).
    static let staleCutoff: TimeInterval = 12 * 60 * 60

    static var projectsDirectory: URL { ClaudePaths.projectsDirectory }

    static func scan() -> [Session] { scanWithWarnings().sessions }

    /// The session list plus the panel banners (PanelWarnings), from one read of
    /// the state dir.
    static func scanWithWarnings() -> (sessions: [Session], warnings: [PanelWarning]) {
        let states = SessionStateReader.readAll()
        let warnings = PanelWarnings.current(states: states, now: Date())
        if !states.isEmpty {
            return (sorted(scanFromStates(states)), warnings)
        }
        return (sorted(scanFallback()), warnings)
    }

    // MARK: - State-file mode (source of truth)

    private static func scanFromStates(_ states: [SessionStateReader.State]) -> [Session] {
        let now = Date()
        var sessions: [Session] = []
        var seenTranscripts: Set<String> = []

        for state in states {
            // Dead pid → hidden, never deleted: the hook may have just replaced
            // this pathname with a live record (resume), and an unlocked delete
            // would destroy it. Cleanup belongs to the hook's SessionEnd.
            if let pid = state.claudePid, !isProcessAlive(pid) {
                continue
            }
            if isStale(status: state.status, updatedAt: state.updatedAt,
                       hasPid: state.claudePid != nil, now: now) {
                continue
            }

            var parsed = JSONLParser.ParsedTranscript.empty
            var transcriptURL = URL(fileURLWithPath: state.transcriptPath ?? "/dev/null")
            if let path = state.transcriptPath {
                transcriptURL = URL(fileURLWithPath: path)
                seenTranscripts.insert(path)
                parsed = TranscriptCache.parsed(path: path)
            }

            // A tool call held before the hooks (a mod asking the user) leaves the
            // state at "working": surface it as waiting (HeldToolDetector).
            var status = state.status
            var waitingReason = state.waitingReason
            var statusSince = state.statusSince
            if status == .working, let path = state.transcriptPath {
                let calls = [parsed.openToolCalls] + subagentOpenCalls(transcript: path, now: now, seen: &seenTranscripts)
                if let held = HeldDetectors.held(session: state.sessionId, transcripts: calls,
                                                 pending: state.pendingTools,
                                                 since: state.turnStartedAt ?? state.lastPromptAt, now: now) {
                    status = .waiting
                    waitingReason = L10n.tr("reason.held", held.name)
                    statusSince = held.at ?? statusSince
                }
            }

            let projectPath = state.cwd ?? parsed.cwd ?? state.windowDir ?? ""
            let projectName: String = {
                if let root = state.windowRoot { return root }
                let base = (projectPath as NSString).lastPathComponent
                return base.isEmpty ? state.sessionId : base
            }()

            sessions.append(Session(
                id: state.sessionId,
                projectPath: projectPath,
                projectName: projectName,
                model: prettyModel(parsed.model),
                modelTier: modelTier(parsed.model),
                contextTokens: parsed.contextTokens,
                usedTokens: parsed.usedTokens,
                toolCallCount: parsed.toolCallCount,
                lastToolName: state.lastTool ?? parsed.lastToolName,
                lastActivity: state.updatedAt,
                subagents: parsed.subagents,
                transcriptURL: transcriptURL,
                status: status,
                waitingReason: waitingReason,
                lastPrompt: state.lastPrompt,
                lastActivityText: state.lastActivity,
                statusSince: statusSince,
                windowDir: state.windowDir,
                claudePid: state.claudePid,
                title: parsed.title
            ))
        }

        TranscriptCache.retainOnly(seenTranscripts)
        HeldDetectors.retainOnly(Set(sessions.map(\.id)))
        return sessions
    }

    /// Subagents written to in the last 15 min (`<sid>/subagents/*.jsonl` next to
    /// the main transcript; background agents included): their open tool calls.
    private static func subagentOpenCalls(transcript: String, now: Date,
                                          seen: inout Set<String>) -> [[JSONLParser.OpenToolCall]] {
        let dir = URL(fileURLWithPath: transcript).deletingPathExtension().appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "jsonl",
                  let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(mtime) < 15 * 60 else { return nil }
            seen.insert(file.path)
            let calls = TranscriptCache.parsed(path: file.path).openToolCalls
            return calls.isEmpty ? nil : calls
        }
    }

    /// Dead when `kill(pid, 0)` fails with ESRCH (EPERM = alive, other user), or when
    /// the pid has been recycled by a process that is not Claude. The hook records
    /// `claude_pid` as the first non-shell ancestor of the hook process (the native
    /// `claude` binary, or `node`/`bun` running the CLI), so that is what we expect.
    /// `started_at` is deliberately NOT compared: the hook keeps it across
    /// `--resume`, and a resumed session gets a new pid with the old start time.
    static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return true }
        if kill(pid_t(pid), 0) != 0 && errno == ESRCH { return false }
        return looksLikeClaude(pid: pid)
    }

    /// Fail-open: if the process cannot be inspected (other user, race with exit),
    /// it is not judged a stranger.
    private static func looksLikeClaude(pid: Int) -> Bool {
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid_t(pid), &pathBuf, UInt32(pathBuf.count)) > 0 else { return true }
        var nameBuf = [CChar](repeating: 0, count: 256)
        let nameLen = proc_name(pid_t(pid), &nameBuf, UInt32(nameBuf.count))
        let name = nameLen > 0 ? String(cString: nameBuf) : ""
        return isClaudeProcess(name: name, path: String(cString: pathBuf), argv: { processArguments(pid) })
    }

    /// Pure identification rule (testable). Native binary: name or path contains
    /// "claude" (`…/anthropic.claude-code-x/…/native-binary/claude`). JS runtime
    /// hosts (npm install of the CLI) are accepted only when argv mentions claude.
    static func isClaudeProcess(name: String, path: String, argv: () -> String) -> Bool {
        let base = (path as NSString).lastPathComponent.lowercased()
        if name.lowercased().contains("claude") || base.contains("claude")
            || path.lowercased().contains("claude-code") { return true }
        if ["node", "bun", "deno"].contains(base) {
            let text = argv().lowercased()
            return text.isEmpty || text.contains("claude")   // unreadable argv: fail-open
        }
        return false
    }

    /// Raw `KERN_PROCARGS2` text (exec path + argv, NUL-separated); "" if unreadable.
    private static func processArguments(_ pid: Int) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buf.prefix(size).map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
    }

    // MARK: - Fallback: mtime heuristic (no state files)

    private static func scanFallback() -> [Session] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let now = Date()
        let cutoff = now.addingTimeInterval(-activeCutoff)
        var sessions: [Session] = []
        var seenTranscripts: Set<String> = []

        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = values.contentModificationDate,
                      mtime > cutoff else { continue }

                let sessionId = file.deletingPathExtension().lastPathComponent
                let isWorking = now.timeIntervalSince(mtime) < workingThreshold

                seenTranscripts.insert(file.path)
                let parsed = TranscriptCache.parsed(path: file.path)

                let decodedPath = parsed.cwd ?? decodeProjectPath(projectDir.lastPathComponent)
                let projectName: String = {
                    let name = (decodedPath as NSString).lastPathComponent
                    return name.isEmpty ? projectDir.lastPathComponent : name
                }()

                sessions.append(Session(
                    id: sessionId,
                    projectPath: decodedPath,
                    projectName: projectName,
                    model: prettyModel(parsed.model),
                    modelTier: modelTier(parsed.model),
                    contextTokens: parsed.contextTokens,
                    usedTokens: parsed.usedTokens,
                    toolCallCount: parsed.toolCallCount,
                    lastToolName: parsed.lastToolName,
                    lastActivity: mtime,
                    subagents: parsed.subagents,
                    transcriptURL: file,
                    status: isWorking ? .working : .done,
                    waitingReason: nil,
                    lastPrompt: nil,
                    lastActivityText: parsed.lastToolName,
                    statusSince: mtime,
                    windowDir: nil,
                    claudePid: nil
                ))
            }
        }

        TranscriptCache.retainOnly(seenTranscripts)
        return sessions
    }

    // MARK: - Ordering

    /// waiting (oldest statusSince first) → working (newest first) → done (newest first).
    static func sorted(_ sessions: [Session]) -> [Session] {
        func rank(_ s: Session.Status) -> Int {
            switch s {
            case .waiting: return 0
            case .working: return 1
            case .done: return 2
            }
        }
        return sessions.sorted { lhs, rhs in
            let l = rank(lhs.status), r = rank(rhs.status)
            if l != r { return l < r }
            if lhs.statusSince != rhs.statusSince {
                return lhs.status == .waiting
                    ? lhs.statusSince < rhs.statusSince
                    : lhs.statusSince > rhs.statusSince
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Helpers

    /// Claude encodes a cwd by replacing '/' (and '.') with '-', which is lossy for
    /// names that contain '-' themselves ("demo-web-app"). Rebuilds the path by
    /// probing the filesystem: each run of dash-separated tokens may be one path
    /// component joined with '-' or several components; depth-first, shortest
    /// component first, accepting only a full consumption whose every prefix
    /// exists (an empty token is a '.', so "--claude" → "/.claude"). If nothing
    /// exists, falls back to the plain '-' → '/' replacement.
    /// `root` is only for tests (the real encoding is rooted at "/").
    static func decodeProjectPath(_ encoded: String, root: String = "/") -> String {
        var tokens = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if tokens.first == "" { tokens.removeFirst() }
        // "--x" → "." + "x"
        var parts: [String] = []
        var i = 0
        while i < tokens.count {
            if tokens[i].isEmpty, i + 1 < tokens.count {
                parts.append("." + tokens[i + 1]); i += 2
            } else {
                parts.append(tokens[i]); i += 1
            }
        }
        let fm = FileManager.default
        var budget = 2000   // bounded probing: never stall a scan on a pathological name
        func search(_ dir: String, _ from: Int) -> String? {
            if from == parts.count { return dir }
            var name = ""
            for j in from..<parts.count {
                name = j == from ? parts[j] : name + "-" + parts[j]
                budget -= 1
                if budget < 0 { return nil }
                let candidate = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: candidate, isDirectory: &isDir) else { continue }
                if j == parts.count - 1 { return candidate }
                if isDir.boolValue, let found = search(candidate, j + 1) { return found }
            }
            return nil
        }
        if !parts.isEmpty, let found = search(root, 0) { return found }
        return encoded.replacingOccurrences(of: "-", with: "/")
    }

    /// Hidden-by-staleness rule for state files. A live claude pid is authoritative
    /// (a session waiting on you for >12 h must stay visible); the cutoff only
    /// applies to finished sessions or to records with no pid to vouch for them.
    static func isStale(status: Session.Status, updatedAt: Date, hasPid: Bool, now: Date) -> Bool {
        guard now.timeIntervalSince(updatedAt) > staleCutoff else { return false }
        return status == .done || !hasPid
    }

    /// Generic model-id prettifier:
    /// `claude-opus-5-5` → "Opus 5.5", `claude-fable-5-1` → "Fable 5.1",
    /// `claude-sonnet-5` → "Sonnet 5", `claude-haiku-4-5-20251001` → "Haiku 4.5",
    /// legacy `claude-3-5-sonnet-20241022` → "Sonnet 3.5". Unknown → raw.
    static func prettyModel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        var id = raw.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }  // e.g. "[1m]"
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        guard id.hasPrefix("claude-") else { return raw }

        let tokens = id.dropFirst("claude-".count)
            .split(separator: "-")
            .map(String.init)
        func isVersionPart(_ t: String) -> Bool {
            !t.isEmpty && t.count <= 2 && t.allSatisfy(\.isNumber)
        }
        func isFamily(_ t: String) -> Bool {
            !t.isEmpty && t.allSatisfy(\.isLetter)
        }

        var family: String?
        var version: [String] = []
        if let first = tokens.first, isFamily(first) {
            family = first
            for t in tokens.dropFirst() {
                guard isVersionPart(t) else { break }
                version.append(t)
            }
        } else {
            // legacy: claude-<maj>-<min>-<family>-<date>
            for t in tokens {
                if isVersionPart(t) { version.append(t); continue }
                if isFamily(t) { family = t }
                break
            }
        }

        guard let family, !version.isEmpty else { return raw }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + version.joined(separator: ".")
    }

    static func modelTier(_ raw: String?) -> Session.ModelTier {
        guard let raw = raw?.lowercased() else { return .unknown }
        if raw.contains("opus") { return .opus }
        if raw.contains("fable") { return .fable }
        if raw.contains("sonnet") { return .sonnet }
        if raw.contains("haiku") { return .haiku }
        return .unknown
    }
}

/// Runs `SessionScanner.scan()` (file IO + JSONL parsing) on one serial
/// background queue, never on the main actor. Callers keep at most one scan in
/// flight (AppState guards it); the serial queue makes overlapping callers
/// (e.g. a timer tick racing a manual refresh) queue instead of parse in parallel.
/// Headless modes (`--dump`, `--snapshot`, `--focus`) call `scan()` directly.
enum SessionScanWorker {
    private static let queue = DispatchQueue(label: "io.github.tactician200.claude-sessions.scan", qos: .utility)

    static func scan() async -> (sessions: [Session], warnings: [PanelWarning]) {
        await withCheckedContinuation { (cont: CheckedContinuation<(sessions: [Session], warnings: [PanelWarning]), Never>) in
            queue.async { cont.resume(returning: SessionScanner.scanWithWarnings()) }
        }
    }
}

// TranscriptCache (incremental parse cache) lives in TranscriptCache.swift.

/// One HeldToolDetector per session, kept across scans (its grace runs from the
/// first scan that saw a call unannounced). Lock: `scan()` also runs headless.
enum HeldDetectors {
    private static var detectors: [String: HeldToolDetector] = [:]
    private static let lock = NSLock()

    static func held(session: String, transcripts: [[JSONLParser.OpenToolCall]], pending: Set<String>,
                     since: Date?, now: Date) -> JSONLParser.OpenToolCall? {
        lock.lock()
        defer { lock.unlock() }
        var detector = detectors[session] ?? HeldToolDetector()
        let held = detector.held(transcripts: transcripts, pending: pending, since: since, now: now)
        detectors[session] = detector
        return held
    }

    static func retainOnly(_ sessions: Set<String>) {
        lock.lock()
        detectors = detectors.filter { sessions.contains($0.key) }
        lock.unlock()
    }
}
