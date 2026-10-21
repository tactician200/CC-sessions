import Foundation

// Test-only: compiled into DEBUG builds, absent from release.
#if DEBUG

/// `--gaps-selftest`: edge cases — SessionStateReader tolerant decoding,
/// SessionScanner.sorted ordering, prettyModel / modelTier. (The toast quiet rule
/// lives in `--attention-selftest`.) PASS/FAIL per case, exit 1 on any failure.
/// Never touches the real state dir: state files are written to a temp dir and
/// read through `SessionStateReader.read(url:)`.
enum GapsSelfTest {
    static func run() -> Bool {
        var allPass = true
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("PASS \(name)") } else {
                allPass = false
                print("FAIL \(name) \(detail())")
            }
        }
        readerCases(check)
        sortCases(check)
        modelCases(check)
        return allPass
    }

    // MARK: - 1. SessionStateReader

    private static func readerCases(_ check: (String, Bool, @autoclosure () -> String) -> Void) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-sessions-gaps-\(getpid())")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        /// Writes `<name>.json` with `body` (JSON text) and decodes it.
        func read(_ name: String, _ body: String) -> SessionStateReader.State? {
            let url = dir.appendingPathComponent("\(name).json")
            try? body.data(using: .utf8)!.write(to: url)
            return SessionStateReader.read(url: url)
        }
        func secs(_ d: Date?) -> Double? { d?.timeIntervalSince1970 }

        // session_id vs basename
        check("reader: matching session_id decodes",
              read("s1", #"{"session_id":"s1","status":"working"}"#)?.sessionId == "s1", "")
        check("reader: session_id != file basename → rejected",
              read("s2", #"{"session_id":"other","status":"working"}"#) == nil, "")
        check("reader: missing session_id falls back to basename",
              read("s3", #"{"status":"done"}"#)?.sessionId == "s3", "")
        check("reader: blank session_id falls back to basename",
              read("s4", #"{"session_id":"   ","status":"done"}"#)?.sessionId == "s4", "")
        check("reader: non-string session_id falls back to basename",
              read("s5", #"{"session_id":123,"status":"done"}"#)?.sessionId == "s5", "")
        check("reader: session_id is trimmed before the basename comparison",
              read("s6", #"{"session_id":" s6 "}"#)?.sessionId == "s6", "")

        // status variants
        check("reader: status WAITING (upper case)",
              read("st1", #"{"status":"WAITING"}"#)?.status == .waiting, "")
        check("reader: status ' Working ' (padded, mixed case)",
              read("st2", #"{"status":" Working "}"#)?.status == .working, "")
        check("reader: status Done",
              read("st3", #"{"status":"Done"}"#)?.status == .done, "")
        check("reader: explicit status wins over working:true",
              read("st4", #"{"status":"waiting","working":true}"#)?.status == .waiting, "")
        check("reader: explicit done wins over working:true",
              read("st5", #"{"status":"done","working":true}"#)?.status == .done, "")
        check("reader: missing status + working:true → working",
              read("st6", #"{"working":true}"#)?.status == .working, "")
        check("reader: missing status + working:false → done",
              read("st7", #"{"working":false}"#)?.status == .done, "")
        check("reader: missing status + working:\"yes\" → working",
              read("st8", #"{"working":"yes"}"#)?.status == .working, "")
        check("reader: missing status + working:\"1\" → working",
              read("st9", #"{"working":"1"}"#)?.status == .working, "")
        check("reader: missing status + working:\"false\" → done",
              read("st10", #"{"working":"false"}"#)?.status == .done, "")
        check("reader: missing status + working:1 (number) → working",
              read("st11", #"{"working":1}"#)?.status == .working, "")
        check("reader: missing status + missing working → done",
              read("st12", #"{}"#)?.status == .done, "")
        check("reader: unknown status falls back to working flag",
              read("st13", #"{"status":"paused","working":true}"#)?.status == .working, "")
        check("reader: unknown status, no working flag → done",
              read("st14", #"{"status":"paused"}"#)?.status == .done, "")
        check("reader: non-string status falls back to working flag",
              read("st15", #"{"status":5,"working":true}"#)?.status == .working, "")

        // timestamps: epoch numbers / numeric strings; ISO is NOT supported (hook writes epoch floats)
        let t1 = read("t1", #"{"updated_at":1700000000.5,"status_since":1699999000}"#)
        check("reader: updated_at / status_since as epoch numbers",
              secs(t1?.updatedAt) == 1700000000.5 && secs(t1?.statusSince) == 1699999000, "\(String(describing: t1))")
        let t2 = read("t2", #"{"updated_at":"1700000000","status_since":"1699999000.25"}"#)
        check("reader: timestamps as numeric strings",
              secs(t2?.updatedAt) == 1700000000 && secs(t2?.statusSince) == 1699999000.25, "")
        let t3 = read("t3", #"{"updated_at":1700000000}"#)
        check("reader: missing status_since defaults to updated_at",
              secs(t3?.statusSince) == 1700000000, "")
        let before = Date()
        let t4 = read("t4", #"{"updated_at":"2026-10-21T10:00:00Z","status_since":"2026-10-21T09:00:00Z"}"#)
        let after = Date()
        check("reader: ISO-8601 timestamps are unsupported → updated_at falls back to file mtime",
              t4 != nil && t4!.updatedAt >= before.addingTimeInterval(-5) && t4!.updatedAt <= after.addingTimeInterval(5),
              "\(String(describing: t4?.updatedAt))")
        check("reader: status_since falls back to updated_at when undecodable",
              t4?.statusSince == t4?.updatedAt, "")
        let t5 = read("t5", #"{"updated_at":"garbage"}"#)
        check("reader: garbage updated_at → mtime fallback (still decodes)",
              t5 != nil && abs(t5!.updatedAt.timeIntervalSinceNow) < 10, "")

        // turn_started_at / last_prompt_at
        let p1 = read("p1", #"{"turn_started_at":1700000100.75,"last_prompt_at":1700000050}"#)
        check("reader: turn_started_at / last_prompt_at as epoch numbers",
              secs(p1?.turnStartedAt) == 1700000100.75 && secs(p1?.lastPromptAt) == 1700000050, "")
        let p2 = read("p2", #"{"turn_started_at":"1700000100","last_prompt_at":"1700000050.5"}"#)
        check("reader: turn_started_at / last_prompt_at as numeric strings",
              secs(p2?.turnStartedAt) == 1700000100 && secs(p2?.lastPromptAt) == 1700000050.5, "")
        let p3 = read("p3", #"{"status":"working"}"#)
        check("reader: turn_started_at / last_prompt_at absent → nil (not mtime)",
              p3 != nil && p3!.turnStartedAt == nil && p3!.lastPromptAt == nil, "")
        let p4 = read("p4", #"{"turn_started_at":"2026-10-21T10:00:00Z","last_prompt_at":null}"#)
        check("reader: ISO / null prompt timestamps → nil",
              p4 != nil && p4!.turnStartedAt == nil && p4!.lastPromptAt == nil, "")
        let p5 = read("p5", #"{"turn_started_at":1700000100}"#)
        check("reader: turn_started_at independent of last_prompt_at",
              secs(p5?.turnStartedAt) == 1700000100 && p5?.lastPromptAt == nil, "")

        // pending_tools
        check("reader: pending_tools dict → its keys",
              read("pt1", #"{"pending_tools":{"tu_1":{"name":"Bash"},"tu_2":{"name":"Edit"}}}"#)?.pendingTools == ["tu_1", "tu_2"], "")
        check("reader: pending_tools empty dict → empty",
              read("pt2", #"{"pending_tools":{}}"#)?.pendingTools == [], "")
        check("reader: pending_tools array → empty",
              read("pt3", #"{"pending_tools":["tu_1"]}"#)?.pendingTools == [], "")
        check("reader: pending_tools string → empty",
              read("pt4", #"{"pending_tools":"tu_1"}"#)?.pendingTools == [], "")
        check("reader: pending_tools null → empty",
              read("pt5", #"{"pending_tools":null}"#)?.pendingTools == [], "")
        check("reader: pending_tools absent → empty (state still decodes)",
              read("pt6", #"{"status":"working"}"#)?.pendingTools == [], "")

        // other fields
        let o1 = read("o1", #"{"claude_pid":"4242","cwd":"  /p/x  ","waiting_reason":"","last_prompt":"hi","last_tool":"Bash"}"#)
        check("reader: claude_pid as numeric string", o1?.claudePid == 4242, "")
        check("reader: strings are trimmed; blank → nil",
              o1?.cwd == "/p/x" && o1?.waitingReason == nil && o1?.lastPrompt == "hi" && o1?.lastTool == "Bash", "")
        check("reader: claude_pid as number", read("o2", #"{"claude_pid":77}"#)?.claudePid == 77, "")
        check("reader: claude_pid garbage → nil", read("o3", #"{"claude_pid":"abc"}"#)?.claudePid == nil, "")
        check("reader: claude_pid null / absent → nil",
              read("o4", #"{"claude_pid":null}"#)?.claudePid == nil && read("o5", #"{}"#)?.claudePid == nil, "")
        check("reader: non-string text fields → nil",
              read("o6", #"{"cwd":5,"last_activity":["x"],"window_dir":{}}"#).map { $0.cwd == nil && $0.lastActivity == nil && $0.windowDir == nil } == true, "")
        let o7 = read("o7", #"{"window_root":"proj","window_dir":"/p/proj","transcript_path":"/t/o7.jsonl","last_activity":"Bash: ls"}"#)
        check("reader: window_root / window_dir / transcript_path / last_activity decode",
              o7?.windowRoot == "proj" && o7?.windowDir == "/p/proj" && o7?.transcriptPath == "/t/o7.jsonl"
                && o7?.lastActivity == "Bash: ls", "")
        check("reader: unknown extra keys are ignored",
              read("o8", #"{"v":9,"future_field":{"a":1},"status":"done"}"#)?.status == .done, "")

        // malformed input
        check("reader: truncated JSON → nil",
              read("m1", #"{"session_id":"m1","status":"work"#) == nil, "")
        check("reader: empty file → nil", read("m2", "") == nil, "")
        check("reader: top-level array → nil", read("m3", #"["a","b"]"#) == nil, "")
        check("reader: top-level string → nil", read("m4", #""m4""#) == nil, "")
        check("reader: not JSON at all → nil", read("m5", "status=working") == nil, "")
        check("reader: missing file → nil",
              SessionStateReader.read(url: dir.appendingPathComponent("nope.json")) == nil, "")
        check("reader: fileURL kept on the state",
              read("m6", "{}")?.fileURL.lastPathComponent == "m6.json", "")
    }

    // MARK: - 3. SessionScanner.sorted

    private static func sortCases(_ check: (String, Bool, @autoclosure () -> String) -> Void) {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Double) -> Date { base.addingTimeInterval(s) }
        func mk(_ id: String, _ status: Session.Status, _ since: Date) -> Session {
            Session(id: id, projectPath: "/p/\(id)", projectName: id, model: "—", modelTier: .unknown,
                    contextTokens: 0, usedTokens: 0, toolCallCount: 0, lastToolName: nil,
                    lastActivity: since, subagents: [], transcriptURL: URL(fileURLWithPath: "/dev/null"),
                    status: status, waitingReason: nil, lastPrompt: nil, lastActivityText: nil,
                    statusSince: since, windowDir: nil, claudePid: nil)
        }
        func ids(_ xs: [Session]) -> [String] { SessionScanner.sorted(xs).map(\.id) }

        check("sort: empty", ids([]).isEmpty, "")
        check("sort: single", ids([mk("a", .done, at(0))]) == ["a"], "")
        check("sort: rank waiting < working < done regardless of time",
              ids([mk("d", .done, at(300)), mk("k", .working, at(200)), mk("w", .waiting, at(100))]) == ["w", "k", "d"],
              "\(ids([mk("d", .done, at(300)), mk("k", .working, at(200)), mk("w", .waiting, at(100))]))")
        check("sort: waiting oldest statusSince first",
              ids([mk("w2", .waiting, at(20)), mk("w3", .waiting, at(30)), mk("w1", .waiting, at(10))]) == ["w1", "w2", "w3"], "")
        check("sort: working newest statusSince first",
              ids([mk("k1", .working, at(10)), mk("k3", .working, at(30)), mk("k2", .working, at(20))]) == ["k3", "k2", "k1"], "")
        check("sort: done newest statusSince first",
              ids([mk("d1", .done, at(10)), mk("d3", .done, at(30)), mk("d2", .done, at(20))]) == ["d3", "d2", "d1"], "")
        check("sort: equal statusSince → id ascending (waiting)",
              ids([mk("b", .waiting, at(5)), mk("c", .waiting, at(5)), mk("a", .waiting, at(5))]) == ["a", "b", "c"], "")
        check("sort: equal statusSince → id ascending (working)",
              ids([mk("b", .working, at(5)), mk("c", .working, at(5)), mk("a", .working, at(5))]) == ["a", "b", "c"], "")
        check("sort: equal statusSince → id ascending (done)",
              ids([mk("b", .done, at(5)), mk("a", .done, at(5))]) == ["a", "b"], "")
        let mixed = [mk("d-new", .done, at(900)), mk("k-old", .working, at(100)), mk("w-new", .waiting, at(800)),
                     mk("k-new", .working, at(700)), mk("w-old", .waiting, at(50)), mk("d-old", .done, at(10)),
                     mk("w-tie-b", .waiting, at(400)), mk("w-tie-a", .waiting, at(400))]
        let expected = ["w-old", "w-tie-a", "w-tie-b", "w-new", "k-new", "k-old", "d-new", "d-old"]
        check("sort: mixed list", ids(mixed) == expected, "\(ids(mixed))")
        check("sort: input order does not matter",
              ids(mixed.reversed()) == expected && ids(mixed.shuffled()) == expected, "")
        check("sort: does not drop or duplicate", ids(mixed).count == mixed.count && Set(ids(mixed)).count == mixed.count, "")
    }

    // MARK: - 4. prettyModel / modelTier

    private static func modelCases(_ check: (String, Bool, @autoclosure () -> String) -> Void) {
        func pretty(_ raw: String?, _ want: String) {
            let got = SessionScanner.prettyModel(raw)
            check("model: prettyModel(\(raw.map { "\"\($0)\"" } ?? "nil")) == \"\(want)\"", got == want, "got \"\(got)\"")
        }
        func tier(_ raw: String?, _ want: Session.ModelTier) {
            let got = SessionScanner.modelTier(raw)
            check("model: modelTier(\(raw.map { "\"\($0)\"" } ?? "nil")) == .\(want.rawValue)", got == want, "got .\(got.rawValue)")
        }

        pretty("claude-opus-5-5", "Opus 5.5")
        pretty("claude-sonnet-5-5", "Sonnet 5.5")
        pretty("claude-haiku-4-5-20251001", "Haiku 4.5")
        pretty("claude-3-5-sonnet-20241022", "Sonnet 3.5")
        pretty("claude-fable-5-1", "Fable 5.1")
        pretty("claude-sonnet-5", "Sonnet 5")
        pretty("claude-opus-4-20250514", "Opus 4")
        pretty("claude-opus-4-1-20250805", "Opus 4.1")
        pretty("claude-3-opus-20240229", "Opus 3")
        pretty("CLAUDE-OPUS-5-5", "Opus 5.5")
        pretty("claude-opus-4-1[1m]", "Opus 4.1")
        pretty("anthropic/claude-sonnet-4-5", "Sonnet 4.5")
        pretty(nil, "—")
        pretty("", "—")
        pretty("garbage", "garbage")
        pretty("<synthetic>", "<synthetic>")
        pretty("gpt-4o", "gpt-4o")
        pretty("claude-", "claude-")
        pretty("claude-opus", "claude-opus")        // family without version → raw
        pretty("claude-5-5", "claude-5-5")          // version without family → raw

        tier("claude-opus-5-5", .opus)
        tier("claude-sonnet-5-5", .sonnet)
        tier("claude-haiku-4-5-20251001", .haiku)
        tier("claude-3-5-sonnet-20241022", .sonnet)
        tier("claude-fable-5-1", .fable)
        tier("CLAUDE-OPUS-5-5", .opus)
        tier("garbage", .unknown)
        tier("<synthetic>", .unknown)
        tier("", .unknown)
        tier(nil, .unknown)
    }
}
#endif
