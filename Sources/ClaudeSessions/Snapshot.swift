import AppKit
import SwiftUI

/// `--snapshot <out.png> [--tab usage] [--appearance light|dark] [--fixtures <dir>]`:
/// renders the panel offscreen and writes a PNG, so layout can be checked without
/// opening the menu bar (no keychain, no network, no screen-recording
/// permission). Sessions come from the live scan, or only from `<dir>` with
/// `--fixtures` (exit 1 if it holds none); usage is always placeholder numbers.
///
/// Renders `PanelRootView` — the live panel's own root: content + dark scrim +
/// rounded clip (radius `Theme.panelRadius`) — over a margin. The panel skin is
/// dark in both appearances (as in the live app); `--appearance` sets the system
/// appearance and the margin: light = WHITE, the worst-case backdrop the contrast
/// table in Theme.swift assumes; dark = a dark desktop grey. Offscreen rendering
/// can't sample the glass, so the PNG shows scrim-over-backdrop. Prints:
/// - `min=` / `ideal=`: content with no proposal vs zero proposal — a collapsed
///   list shows up as `min` height < `ideal` height.
/// - `intrinsic=`: what the live panel measures (NSHostingView with
///   `sizingOptions = [.intrinsicContentSize]`) = the window size it will get.
enum Snapshot {
    static let margin: CGFloat = 16

    enum Appearance: String {
        case light, dark
        var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
        var backdrop: Color { self == .light ? Theme.snapshotBackdrop : Theme.snapshotBackdropDark }
        var backdropNS: NSColor { self == .light ? .white : NSColor(srgbRed: 0x1F / 255.0, green: 0x1F / 255.0, blue: 0x21 / 255.0, alpha: 1) }
    }

    @MainActor
    static func run(to path: String, tab: AppState.Tab = .sessions, appearance: Appearance = .dark) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let state = AppState(live: false)
        if ClaudePaths.isFixtureMode && state.sessions.isEmpty {
            FileHandle.standardError.write("snapshot: no sessions in --fixtures \(ClaudePaths.fixtureRoot?.path ?? "")\n".data(using: .utf8)!)
            exit(1)
        }
        state.selectedTab = tab
        state.subscriptionType = "max"
        state.applyUsage(fixtureUsage(now: Date()), dayStart: 0)
        let metrics = PanelMetrics()

        // The panel's measurement path, verbatim.
        let measured = PanelHostingView(rootView: PanelRootView(state: state, metrics: metrics))
        measured.sizingOptions = [.intrinsicContentSize]
        measured.layoutSubtreeIfNeeded()
        let intrinsic = measured.intrinsicContentSize

        let framed = PanelRootView(state: state, metrics: metrics)
            .frame(width: intrinsic.width, height: intrinsic.height)
            .padding(margin)
            .background(appearance.backdrop)
        let view = NSHostingView(rootView: framed)
        view.appearance = NSAppearance(named: appearance.name)
        let size = CGSize(width: intrinsic.width + 2 * margin, height: intrinsic.height + 2 * margin)
        view.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance.name)
        window.backgroundColor = appearance.backdropNS
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write("snapshot: no bitmap\n".data(using: .utf8)!)
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // sRGB, not the display's profile: an embedded display profile names the monitor model.
        guard let srgb = rep.converting(to: .sRGB, renderingIntent: .default),
              let encoded = srgb.representation(using: .png, properties: [:]) else { exit(1) }
        let png = strippingMetadata(png: encoded)
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write("snapshot: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        func content() -> some View {
            DropdownView()
                .environmentObject(state)
                .environment(\.colorScheme, .dark)
        }
        let ideal = NSHostingController(rootView: content().fixedSize())
            .sizeThatFits(in: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                     height: CGFloat.greatestFiniteMagnitude))
        let minimum = NSHostingController(rootView: content())
            .sizeThatFits(in: .zero)
        print("min=\(Int(minimum.width))x\(Int(minimum.height))")
        print("snapshot tab=\(tab.rawValue) \(Int(size.width))x\(Int(size.height)) ideal=\(Int(ideal.width))x\(Int(ideal.height)) intrinsic=\(Int(intrinsic.width))x\(Int(intrinsic.height)) sessions=\(state.sessions.count) → \(path)")
        if let b = state.workdayBudget {
            print("pace: \(b.todayText ?? "—") · \(b.detailText)")
        }
    }

    /// Drops the PNG's text/EXIF chunks (AppKit writes an eXIf chunk): the images
    /// go into a public README and must carry nothing but pixels.
    static func strippingMetadata(png data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else { return data }
        let dropped: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "tIME", "iCCP"]
        var out = Data(bytes[0..<8])
        var i = 8
        while i + 12 <= bytes.count {
            let length = bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = i + 12 + length
            guard end <= bytes.count else { return data }   // malformed: leave as is
            let type = String(decoding: bytes[i + 4..<i + 8], as: UTF8.self)
            if !dropped.contains(type) { out.append(contentsOf: bytes[i..<end]) }
            i = end
        }
        return out
    }

    /// 5 h 35 % · 7 d 10 % resetting next Monday 00:00 (local) · sonnet/opus split.
    static func fixtureUsage(now: Date) -> UsageSnapshot {
        let cal = WorkdayBudget.userCalendar()
        let nextMonday = cal.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0, weekday: 2),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(7 * 86_400)
        return UsageSnapshot(
            fiveHour: .init(utilization: 35, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)),
            sevenDay: .init(utilization: 10, resetsAt: nextMonday),
            sevenDaySonnet: .init(utilization: 4, resetsAt: nextMonday),
            sevenDayOpus: .init(utilization: 6, resetsAt: nextMonday),
            extraUsage: nil,
            fetchedAt: now.addingTimeInterval(-40)
        )
    }
}
