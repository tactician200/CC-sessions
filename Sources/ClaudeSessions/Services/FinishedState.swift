import Foundation

/// "Terminó" vs "Inactiva" for finished sessions: a
/// finished session is "Terminó" (blue) while it holds a result you haven't seen;
/// it turns "Inactiva" (gray) once you attend it — its VS Code window in front, or
/// its row clicked — or `fadeAfter` after finishing, whichever comes first.
///
/// Seen is per finish: the `statusSince` you saw. A session that works again and
/// finishes later has a new `statusSince`, so it is "Terminó" again. In memory
/// only: after a relaunch, finishes younger than `fadeAfter` read as unseen.
/// Window match is by folder (FrontWindow), so sessions sharing one VS Code
/// window are attended together.
@MainActor
enum FinishedState {
    nonisolated static let fadeAfter: TimeInterval = 2 * 60 * 60

    /// Session id → the finish (`statusSince`) already attended.
    private static var seen: [String: Date] = [:]

    static func markSeen(_ session: Session) {
        guard session.status == .done else { return }
        seen[session.id] = session.statusSince
    }

    /// Marks finished sessions shown in the focused window as seen, sets
    /// `inactive` on every session, and forgets sessions no longer listed.
    static func apply(_ sessions: [Session], frontTitle: String?, now: Date) -> [Session] {
        var out = sessions
        for i in out.indices where out[i].status == .done {
            if FrontWindow.isShowing(title: frontTitle, windowDir: out[i].windowDir) {
                markSeen(out[i])
            }
            out[i].inactive = isInactive(statusSince: out[i].statusSince, seenFinish: seen[out[i].id], now: now)
        }
        let ids = Set(sessions.map(\.id))
        seen = seen.filter { ids.contains($0.key) }
        return out
    }

    nonisolated static func isInactive(statusSince: Date, seenFinish: Date?, now: Date) -> Bool {
        if let seenFinish, seenFinish >= statusSince { return true }
        return now.timeIntervalSince(statusSince) >= fadeAfter
    }
}

#if DEBUG
/// `--finished-selftest`.
enum FinishedStateSelfTest {
    static func run() -> Bool {
        let now = Date(timeIntervalSince1970: 1_792_600_000)
        var allPass = true
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { allPass = false }
        }
        let finish = now.addingTimeInterval(-600)
        check("a just finished, not seen → Terminó",
              !FinishedState.isInactive(statusSince: finish, seenFinish: nil, now: now))
        check("b seen this finish → Inactiva",
              FinishedState.isInactive(statusSince: finish, seenFinish: finish, now: now))
        check("c seen an earlier finish only → Terminó again",
              !FinishedState.isInactive(statusSince: finish, seenFinish: finish.addingTimeInterval(-3600), now: now))
        check("d never seen, 2 h after finishing → Inactiva",
              FinishedState.isInactive(statusSince: now.addingTimeInterval(-FinishedState.fadeAfter), seenFinish: nil, now: now))
        check("e never seen, just under 2 h → Terminó",
              !FinishedState.isInactive(statusSince: now.addingTimeInterval(-FinishedState.fadeAfter + 1), seenFinish: nil, now: now))

        let marked = MainActor.assumeIsolated { () -> [Session] in
            func session(_ id: String, _ status: Session.Status, dir: String) -> Session {
                Session(id: id, projectPath: dir, projectName: (dir as NSString).lastPathComponent, model: "Opus 5.5",
                        modelTier: .opus, contextTokens: 0, usedTokens: 0, toolCallCount: 0, lastToolName: nil,
                        lastActivity: now, subagents: [], transcriptURL: URL(fileURLWithPath: "/dev/null"),
                        status: status, waitingReason: nil, lastPrompt: nil, lastActivityText: nil,
                        statusSince: finish, windowDir: dir, claudePid: nil)
            }
            let list = [session("f1", .done, dir: "/x/acme-api"), session("f2", .done, dir: "/x/demo-web"),
                        session("w1", .working, dir: "/x/acme-api")]
            return FinishedState.apply(list, frontTitle: "app.py — acme-api", now: now)
        }
        check("f focused window attends its finished session only; working untouched",
              marked.map(\.inactive) == [true, false, false])
        let again = MainActor.assumeIsolated {
            FinishedState.apply(marked.map { var s = $0; s.inactive = false; return s }, frontTitle: nil, now: now)
        }
        check("g seen sticks after the window loses focus", again.map(\.inactive) == [true, false, false])
        return allPass
    }
}
#endif
