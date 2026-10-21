import Foundation

/// A tool call held before the hooks, waiting on the user. A `tool.call` mod
/// (e.g. one that gates risky Bash commands behind a Proceed / Cancel pane, for up
/// to 10 min) runs BEFORE PreToolUse, and Claude Code fires no event while it
/// holds — the state file stays "working". Without this detector such a hold can
/// run out its whole timeout unseen, with zero hook events in between.
///
/// Signature: a tool_use already in a transcript (main or subagent) that
/// PreToolUse never announced (not in `pending_tools`), while nothing announced
/// from that same transcript is still running, continuously for longer than
/// `grace`. A call queued behind a running one in its transcript is not held; a
/// permission prompt comes after PreToolUse and has its own Notification.
///
/// The grace runs from when a scan FIRST saw the call unannounced, not from its
/// line's timestamp: the hook drops an id
/// at PostToolUse a few ms before Claude Code writes the tool_result, and serial
/// calls of one message wait a hook start between PostToolUse(A) and
/// PreToolUse(B). A scan landing in such a gap would see an old call "unannounced"
/// and flash a false "te espera" + toast. Those gaps last milliseconds; a hold lasts.
struct HeldToolDetector {
    /// Time a call may stay unannounced before it counts as held (other mods, slow hooks).
    static let grace: TimeInterval = 8

    /// Candidate call id → first scan that saw it unannounced. One per session.
    private(set) var firstSeen: [String: Date] = [:]

    mutating func held(transcripts: [[JSONLParser.OpenToolCall]], pending: Set<String>,
                       since turnStart: Date?, now: Date) -> JSONLParser.OpenToolCall? {
        var candidates: [JSONLParser.OpenToolCall] = []
        for calls in transcripts {
            guard !calls.contains(where: { pending.contains($0.id) }) else { continue }
            guard let call = calls.first(where: { !pending.contains($0.id) }), let at = call.at else { continue }
            // Left open by an earlier turn (interrupted): not this turn's hold.
            if let turnStart, at < turnStart.addingTimeInterval(-1) { continue }
            candidates.append(call)
        }
        var seen: [String: Date] = [:]
        var found: JSONLParser.OpenToolCall?
        for call in candidates {
            let first = firstSeen[call.id] ?? now
            seen[call.id] = first
            guard now.timeIntervalSince(first) > Self.grace else { continue }
            if found == nil || (call.at ?? now) < (found?.at ?? now) { found = call }
        }
        firstSeen = seen   // a call announced or answered in between starts over
        return found
    }
}

#if DEBUG
/// `--held-selftest`: the detector on hand-built transcripts.
enum HeldToolSelfTest {
    static func run() -> Bool {
        typealias Call = JSONLParser.OpenToolCall
        let now = Date(timeIntervalSince1970: 1_792_498_600)
        let turn = now.addingTimeInterval(-60)
        func call(_ id: String, _ ago: TimeInterval, _ name: String = "Bash") -> Call {
            Call(id: id, name: name, at: now.addingTimeInterval(-ago))
        }
        var allPass = true
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { allPass = false }
        }
        /// Two scans `grace + 1` s apart with the same input: what the second one says.
        func heldAfterGrace(_ t: [[Call]], _ p: Set<String>, since: Date? = turn) -> Call? {
            var d = HeldToolDetector()
            _ = d.held(transcripts: t, pending: p, since: since, now: now)
            return d.held(transcripts: t, pending: p, since: since,
                          now: now.addingTimeInterval(HeldToolDetector.grace + 1))
        }

        check("a unannounced call, nothing running, for longer than the grace → held",
              heldAfterGrace([[call("a", 20)]], [])?.id == "a")
        check("b same call announced by PreToolUse (running) → not held",
              heldAfterGrace([[call("a", 20)]], ["a"]) == nil)
        var first = HeldToolDetector()
        check("c first sight of an old call → not held yet (grace runs from first sight)",
              first.held(transcripts: [[call("a", 300)]], pending: [], since: turn, now: now) == nil)
        check("d queued behind a running call in the same transcript → not held",
              heldAfterGrace([[call("a", 30), call("b", 30)]], ["a"]) == nil)
        check("e main runs the Agent call; subagent's call unannounced → held (subagent)",
              heldAfterGrace([[call("agent", 90, "Agent")], [call("s1", 15)]], ["agent"])?.id == "s1")
        check("f left open by an earlier, interrupted turn → not held",
              heldAfterGrace([[call("old", 600)]], []) == nil)
        check("g no timestamp → not held",
              heldAfterGrace([[Call(id: "x", name: "Bash", at: nil)]], []) == nil)
        check("h nothing open → not held", heldAfterGrace([[], []], []) == nil)

        // j: the gap false positive. A ran 30 s; one scan lands between
        // PostToolUse(A) (id dropped) and its tool_result line; next scan A is gone.
        var gap = HeldToolDetector()
        let a = call("A", 30)
        let s1 = gap.held(transcripts: [[a]], pending: [], since: turn, now: now)
        let s2 = gap.held(transcripts: [[]], pending: [], since: turn, now: now.addingTimeInterval(2))
        // B of the same message: unannounced for one scan, then PreToolUse(B) arrives.
        let b = call("B", 30)
        let s3 = gap.held(transcripts: [[b]], pending: [], since: turn, now: now.addingTimeInterval(4))
        let s4 = gap.held(transcripts: [[b]], pending: ["B"], since: turn, now: now.addingTimeInterval(6))
        let s5 = gap.held(transcripts: [[b]], pending: [], since: turn, now: now.addingTimeInterval(8))
        check("j ms gaps around Post/PreToolUse never read as held, and announcing resets the clock",
              s1 == nil && s2 == nil && s3 == nil && s4 == nil && s5 == nil && gap.firstSeen["B"] != nil)

        // Parser: tool_use without result stays open; with result it closes.
        let lines = [
            #"{"type":"assistant","timestamp":"2026-10-20T12:16:13.117Z","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-20T12:16:14.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#,
            #"{"type":"api-request-blob","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#,
        ].joined(separator: "\n")
        let parsed = JSONLParser.parse(data: Data(lines.utf8))
        check("i parser keeps only the unanswered call open (blob replay ignored), with its timestamp",
              parsed.openToolCalls.map(\.id) == ["t1"] && parsed.openToolCalls.first?.at != nil)
        return allPass
    }
}
#endif
