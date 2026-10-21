import Foundation

/// One-line banners at the top of the panel for setup problems the session list
/// can't show by itself.
enum PanelWarning: String, Equatable, Sendable, CaseIterable {
    /// The plugin's launcher found no Python 3.9+ (`.hook-unavailable` marker).
    case hookNeedsPython
    /// The upstream `claude-sessions-tracker` plugin writes the same state dir.
    case upstreamTracker
    /// A state file with a contract version newer than this app knows.
    case updateApp
    /// A state file with a contract version older than this app supports.
    case updatePlugin

    var text: String {
        switch self {
        case .hookNeedsPython: return L10n.tr("warning.hookPython")
        case .upstreamTracker: return L10n.tr("warning.upstreamTracker")
        case .updateApp: return L10n.tr("warning.updateApp")
        case .updatePlugin: return L10n.tr("warning.updatePlugin")
        }
    }
}

enum PanelWarnings {
    /// State-file contract versions this app reads (the hook writes `"v": 1`).
    /// A file without `v` is a legacy record: read as-is, no warning.
    static let knownStateVersions = [1]
    /// Upstream plugin name; `enabledPlugins` keys are `<name>@<marketplace>`.
    static let upstreamPlugin = "claude-sessions-tracker"
    /// Keys only the upstream tracker writes (our hook never does). A marker
    /// wouldn't do: the tracker re-reads the file and keeps unknown keys.
    static let upstreamOnlyKeys: Set<String> = ["last_event", "working_since", "stopped_at"]
    /// Only recently written files count: an old leftover proves nothing is running.
    static let upstreamWindow: TimeInterval = 10 * 60

    struct StateSample: Equatable {
        let version: Int?
        let hasUpstreamKeys: Bool
        let modifiedAt: Date
        let updatedAt: Date
    }

    /// Pure: everything injected. Order = display order.
    static func detect(hookUnavailable: Bool, settings: [String: Any]?,
                       states: [StateSample], now: Date) -> [PanelWarning] {
        var out: [PanelWarning] = []
        if hookUnavailable { out.append(.hookNeedsPython) }
        let recentUpstream = states.contains {
            $0.hasUpstreamKeys && now.timeIntervalSince($0.modifiedAt) <= upstreamWindow
        }
        if upstreamEnabled(settings: settings) || recentUpstream { out.append(.upstreamTracker) }
        // Versions only from records still shown (not stale): a leftover file of
        // an old install shouldn't nag forever.
        let versions = states
            .filter { now.timeIntervalSince($0.updatedAt) <= SessionScanner.staleCutoff }
            .compactMap(\.version)
        let maxKnown = knownStateVersions.max() ?? 1, minKnown = knownStateVersions.min() ?? 1
        if versions.contains(where: { $0 > maxKnown }) { out.append(.updateApp) }
        if versions.contains(where: { $0 < minKnown }) { out.append(.updatePlugin) }
        return out
    }

    /// `enabledPlugins` as Claude Code writes it (`{"name@marketplace": true}`);
    /// a list of names is accepted too. Disabled (`false`) entries don't count.
    static func upstreamEnabled(settings: [String: Any]?) -> Bool {
        func matches(_ key: String) -> Bool { key == upstreamPlugin || key.hasPrefix(upstreamPlugin + "@") }
        switch settings?["enabledPlugins"] {
        case let dict as [String: Any]:
            return dict.contains { key, value in
                matches(key) && ((value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? true))
            }
        case let list as [Any]:
            return list.contains { ($0 as? String).map(matches) ?? false }
        default:
            return false
        }
    }

    /// Reads the marker and the settings file (ClaudePaths: fixture-aware). The
    /// state files come from the scan that already read them.
    static func current(states: [SessionStateReader.State], now: Date) -> [PanelWarning] {
        let fm = FileManager.default
        let settings = (try? Data(contentsOf: ClaudePaths.settingsFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return detect(
            hookUnavailable: fm.fileExists(atPath: ClaudePaths.hookUnavailableMarker.path),
            settings: settings,
            states: states.map {
                StateSample(version: $0.version, hasUpstreamKeys: $0.hasUpstreamKeys,
                            modifiedAt: $0.modifiedAt, updatedAt: $0.updatedAt)
            },
            now: now
        )
    }
}

#if DEBUG
/// `--warnings-selftest`: the detection rules on injected data (no file reads).
enum PanelWarningsSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ got: [PanelWarning], _ expected: [PanelWarning]) {
            let pass = got == expected
            print("\(pass ? "PASS" : "FAIL") \(name)\(pass ? "" : " (got \(got.map(\.rawValue)))")")
            if !pass { ok = false }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func s(v: Int? = 1, upstream: Bool = false, modifiedAgo: TimeInterval = 5, updatedAgo: TimeInterval = 5) -> PanelWarnings.StateSample {
            .init(version: v, hasUpstreamKeys: upstream,
                  modifiedAt: now.addingTimeInterval(-modifiedAgo), updatedAt: now.addingTimeInterval(-updatedAgo))
        }
        func detect(_ hook: Bool = false, _ settings: [String: Any]? = nil, _ states: [PanelWarnings.StateSample] = []) -> [PanelWarning] {
            PanelWarnings.detect(hookUnavailable: hook, settings: settings, states: states, now: now)
        }

        check("a nothing wrong → no warnings", detect(false, ["enabledPlugins": ["other@mp": true]], [s(), s(v: nil)]), [])
        check("b .hook-unavailable → Python warning", detect(true), [.hookNeedsPython])
        check("c tracker enabled as name@marketplace", detect(false, ["enabledPlugins": ["claude-sessions-tracker@some-mp": true]]), [.upstreamTracker])
        check("d tracker enabled by bare name", detect(false, ["enabledPlugins": ["claude-sessions-tracker": true]]), [.upstreamTracker])
        check("e tracker present but disabled → nothing", detect(false, ["enabledPlugins": ["claude-sessions-tracker@mp": false]]), [])
        check("f similar plugin name is not the tracker", detect(false, ["enabledPlugins": ["claude-sessions-tracker-fork@mp": true]]), [])
        check("g enabledPlugins as a list", detect(false, ["enabledPlugins": ["claude-sessions-tracker@mp"]]), [.upstreamTracker])
        check("h upstream keys in a file written 2 min ago", detect(false, nil, [s(v: nil, upstream: true, modifiedAgo: 120)]), [.upstreamTracker])
        check("i upstream keys in a file untouched for 11 min → nothing", detect(false, nil, [s(v: nil, upstream: true, modifiedAgo: 660)]), [])
        check("j newer contract version → update the app", detect(false, nil, [s(v: 2)]), [.updateApp])
        check("k older contract version → update the plugin", detect(false, nil, [s(v: 0)]), [.updatePlugin])
        check("l missing v (legacy) → no warning", detect(false, nil, [s(v: nil)]), [])
        check("m newer version only in a stale record → nothing", detect(false, nil, [s(v: 2, modifiedAgo: 90_000, updatedAgo: 90_000)]), [])
        check("n everything at once, in display order",
              detect(true, ["enabledPlugins": ["claude-sessions-tracker@mp": true]], [s(v: 2), s(v: 0)]),
              [.hookNeedsPython, .upstreamTracker, .updateApp, .updatePlugin])
        check("o malformed settings → nothing", detect(false, ["enabledPlugins": "claude-sessions-tracker"]), [])

        let keys = Set(PanelWarning.allCases.map(\.text))
        let localized = keys.count == PanelWarning.allCases.count && !keys.contains { $0.hasPrefix("warning.") }
        print("\(localized ? "PASS" : "FAIL") p every warning has its own localized text")
        return ok && localized
    }
}
#endif
