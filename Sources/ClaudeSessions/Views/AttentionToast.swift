import SwiftUI
import AppKit
import ApplicationServices

/// A session started needing you (permission / question / plan) or finished its turn.
struct AttentionEvent: Equatable {
    enum Kind: Equatable { case waiting, finished }
    let session: Session
    let kind: Kind
}

/// Pure transition detector, scan to scan (selftest: `--attention-selftest`).
enum AttentionDetector {
    /// `previous == nil` is the first scan after launch: it only seeds, never fires
    /// (sessions already waiting when the app starts are not news).
    static func events(previous: [String: Session]?, current: [Session]) -> [AttentionEvent] {
        guard let previous else { return [] }
        var out: [AttentionEvent] = []
        for s in current {
            let p = previous[s.id]
            if s.status == .waiting, p?.status != .waiting {
                out.append(AttentionEvent(session: s, kind: .waiting))
            } else if s.status == .done, let p, p.status != .done {
                out.append(AttentionEvent(session: s, kind: .finished))
            }
        }
        // Waiting first: it blocks Claude, finished doesn't.
        return out.filter { $0.kind == .waiting } + out.filter { $0.kind == .finished }
    }
}

/// Which events become a toast. Quiet (no toast) when the toast setting is off,
/// or per event when its session's own VS Code window is already frontmost
/// (`isQuiet`). There is no panel-visible / pinned rule.
enum AttentionFilter {
    static func toShow(_ events: [AttentionEvent], enabled: Bool,
                       isQuiet: (AttentionEvent) -> Bool) -> [AttentionEvent] {
        guard enabled else { return [] }
        return events.filter { !isQuiet($0) }
    }
}

/// "Already looking at it": VS Code is frontmost and its focused window is the
/// session's folder. Needs Accessibility (the window title isn't readable
/// otherwise); untrusted → never quiet, the toast always shows.
enum FrontWindow {
    static var canRead: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func isShowing(windowDir: String?) -> Bool {
        isShowing(title: focusedVSCodeTitle(), windowDir: windowDir)
    }

    /// The focused VS Code window's title, read once per scan (nil if VS Code
    /// isn't in front or Accessibility isn't granted).
    static func currentTitle() -> String? { focusedVSCodeTitle() }

    /// Pure core of `isShowing`: no focused VS Code title (untrusted, other app,
    /// no window) or no `windowDir` → never "already looking at it".
    static func isShowing(title: String?, windowDir: String?) -> Bool {
        guard let windowDir, let title else { return false }
        return titleMatches(title, windowDir: windowDir)
    }

    /// VS Code titles: "file — folder" or "folder" (plus "— Visual Studio Code" when
    /// not in a custom title setup). The folder is a whole " — " component.
    /// A folder with its own `window.title` (`.vscode/settings.json`, e.g.
    /// "◆ Acme ${separator}…") doesn't show its name: it matches by the
    /// literal prefix of that setting instead.
    static func titleMatches(_ title: String, windowDir: String) -> Bool {
        titleMatches(title, windowDir: windowDir, customPrefix: customTitlePrefix(windowDir: windowDir))
    }

    static func titleMatches(_ title: String, windowDir: String, customPrefix: String?) -> Bool {
        let root = (windowDir as NSString).lastPathComponent
        guard !root.isEmpty else { return false }
        if title.components(separatedBy: " — ").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(root) {
            return true
        }
        guard let customPrefix else { return false }
        return title == customPrefix || title.hasPrefix(customPrefix + " ")
    }

    static func customTitlePrefix(windowDir: String) -> String? {
        let settings = (windowDir as NSString).appendingPathComponent(".vscode/settings.json")
        guard let text = try? String(contentsOfFile: settings, encoding: .utf8) else { return nil }
        return customTitlePrefix(settings: text)
    }

    /// Literal text before the first `${…}` of `"window.title"`, trimmed; nil when
    /// there is none or it has no letter/digit (a bare "◆" would match every such window).
    static func customTitlePrefix(settings: String) -> String? {
        guard let match = settings.range(of: #""window\.title"\s*:\s*"([^"\\]|\\.)*""#, options: .regularExpression)
        else { return nil }
        let entry = settings[match]
        guard let valueStart = entry.range(of: #":\s*""#, options: .regularExpression)?.upperBound else { return nil }
        let value = entry[valueStart..<entry.index(before: entry.endIndex)]
        let literal = value.components(separatedBy: "${").first ?? ""
        let prefix = literal.trimmingCharacters(in: .whitespaces)
        guard prefix.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return prefix
    }

    private static func focusedVSCodeTitle() -> String? {
        guard canRead,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier?.hasPrefix("com.microsoft.VSCode") == true
        else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)  // a hung VS Code must not stall the scan
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}

/// Small glass card at the top right of the display you're on. Never takes key
/// focus or activates the app, joins every Space (fullscreen VS Code included),
/// 2 s on screen; hovering holds it, a click on a row goes to that session.
@MainActor
final class AttentionToastController {
    static let shared = AttentionToastController()
    static let enabledKey = "attentionToast"
    static let visibleSeconds: TimeInterval = 2

    private final class ToastPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: ToastPanel?
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    /// Test hook: window number once ordered front (`--toast-demo`).
    var onShown: ((Int) -> Void)?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Filters "already looking at it", then shows (or replaces) the card.
    func handle(_ events: [AttentionEvent]) {
        let shown = AttentionFilter.toShow(events, enabled: isEnabled) {
            FrontWindow.isShowing(windowDir: $0.session.windowDir)
        }
        guard !shown.isEmpty else { return }
        show(shown)
    }

    func show(_ events: [AttentionEvent]) {
        let view = AttentionToastView(
            events: events,
            onTap: { [weak self] session in
                SessionFocus.focus(session)
                self?.hide(animated: false)
            },
            onHover: { [weak self] inside in self?.setHovering(inside) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let content = StatusPanelController.glassBackground(
            wrapping: hosting, size: size, radius: AttentionToastView.radius, opaque: opaque)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = content
        panel.setFrame(NSRect(origin: Self.origin(for: size), size: size), display: true)
        panel.invalidateShadow()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        } else {
            panel.alphaValue = 1
        }
        onShown?(panel.windowNumber)
        scheduleHide()
    }

    private func makePanel() -> ToastPanel {
        let p = ToastPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        // No `isFloatingPanel = true`: it resets the level to .floating (3).
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.appearance = NSAppearance(named: .darkAqua)
        return p
    }

    /// Top right of the display under the mouse (where you are), below the menu
    /// bar when it shows; in fullscreen the visible frame reaches the top edge.
    private static func origin(for size: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        return CGPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 10)
    }

    private func setHovering(_ inside: Bool) {
        hovering = inside
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard !hovering else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }

    func hide(animated: Bool) {
        hideWork?.cancel()
        hovering = false
        guard let panel, panel.isVisible else { return }
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                            completionHandler: { panel.orderOut(nil) })
    }
}

struct AttentionToastView: View {
    static let radius: CGFloat = 14
    static let maxRows = 3

    let events: [AttentionEvent]
    let onTap: (Session) -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(events.prefix(Self.maxRows).enumerated()), id: \.offset) { _, event in
                ToastRow(event: event) { onTap(event.session) }
            }
            if events.count > Self.maxRows {
                Text(L10n.tr("toast.more", events.count - Self.maxRows))
                    .font(Theme.body(10.5))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
        }
        .padding(6)
        .frame(width: 300, alignment: .leading)
        .background(Theme.panelScrim)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .onHover(perform: onHover)
        .fixedSize()
    }
}

private struct ToastRow: View {
    let event: AttentionEvent
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(event.kind == .waiting ? Theme.waiting : Theme.finished)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.session.projectName)
                            .font(Theme.title(12.5))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(L10n.tr(event.kind == .waiting ? "toast.waiting" : "toast.finished"))
                            .font(Theme.title(11.5, .semibold))
                            .foregroundColor(event.kind == .waiting ? Theme.waiting : Theme.finished)
                            .lineLimit(1)
                            .fixedSize()
                        Spacer(minLength: 4)
                        Text(L10n.tr("toast.clickToGo"))
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(detail)
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(hovered: hovered))
        .onHover { hovered = $0 }
        .pointingHandCursor()
    }

    private var detail: String {
        let s = event.session
        let lead = event.kind == .waiting
            ? (s.waitingReason.map(L10n.waitingReason) ?? L10n.tr("state.waiting"))
            : (s.lastActivityText ?? L10n.tr("toast.done"))
        if let title = s.title { return "\(lead) · \(title)" }
        return lead
    }
}

#if DEBUG
/// `--attention-selftest`: detector transitions + title matching. Exit 1 on failure.
enum AttentionSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL") \(name)")
            ok = ok && cond
        }
        func s(_ id: String, _ status: Session.Status) -> Session {
            Session(id: id, projectPath: "/p/\(id)", projectName: id, model: "—", modelTier: .unknown,
                    contextTokens: 0, usedTokens: 0, toolCallCount: 0, lastToolName: nil,
                    lastActivity: Date(), subagents: [], transcriptURL: URL(fileURLWithPath: "/dev/null"),
                    status: status, waitingReason: nil, lastPrompt: nil, lastActivityText: nil,
                    statusSince: Date(), windowDir: "/p/\(id)", claudePid: nil)
        }
        func dict(_ xs: [Session]) -> [String: Session] { Dictionary(xs.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }) }

        check("a first scan seeds only", AttentionDetector.events(previous: nil, current: [s("a", .waiting)]).isEmpty)
        let ev = AttentionDetector.events(previous: dict([s("a", .working), s("b", .working)]),
                                          current: [s("a", .done), s("b", .waiting)])
        check("b working→waiting and working→done fire, waiting first",
              ev.map { "\($0.session.id):\($0.kind)" } == ["b:waiting", "a:finished"])
        check("c still waiting does not refire",
              AttentionDetector.events(previous: dict([s("a", .waiting)]), current: [s("a", .waiting)]).isEmpty)
        check("d new session already waiting fires",
              AttentionDetector.events(previous: [:], current: [s("n", .waiting)]).map(\.kind) == [.waiting])
        check("e new session already done does not fire",
              AttentionDetector.events(previous: [:], current: [s("n", .done)]).isEmpty)
        check("f waiting→done (answered, then finished) fires finished",
              AttentionDetector.events(previous: dict([s("a", .waiting)]), current: [s("a", .done)]).map(\.kind) == [.finished])
        check("g title match: file — folder",
              FrontWindow.titleMatches("Theme.swift — claude-sessions", windowDir: "/Users/alex/claude-sessions"))
        check("h title match: no partial folder names",
              !FrontWindow.titleMatches("Theme.swift — claude-sessions-old", windowDir: "/Users/alex/claude-sessions"))
        check("i title match: folder — Visual Studio Code",
              FrontWindow.titleMatches("billing-service — Visual Studio Code", windowDir: "/Users/alex/billing-service"))

        // Toast quiet rule (AttentionFilter + FrontWindow.isShowing(title:windowDir:)).
        let waitingA = AttentionEvent(session: s("a", .waiting), kind: .waiting)
        let finishedB = AttentionEvent(session: s("b", .done), kind: .finished)
        let both = [waitingA, finishedB]
        func quietIfFront(_ e: AttentionEvent) -> Bool {
            FrontWindow.isShowing(title: "x.swift — \(e.session.projectName)", windowDir: e.session.windowDir)
        }
        check("q1 setting off → nothing shown, even with no window match",
              AttentionFilter.toShow(both, enabled: false, isQuiet: { _ in false }).isEmpty)
        check("q2 setting on, nothing frontmost → all shown, order kept",
              AttentionFilter.toShow(both, enabled: true, isQuiet: { _ in false }).map(\.session.id) == ["a", "b"])
        check("q3 only the event whose own window is frontmost is silenced (waiting)",
              AttentionFilter.toShow(both, enabled: true, isQuiet: { $0.session.id == "a" }).map(\.session.id) == ["b"])
        check("q4 same for a finished event",
              AttentionFilter.toShow(both, enabled: true, isQuiet: { $0.session.id == "b" }).map(\.session.id) == ["a"])
        check("q5 every window frontmost → nothing shown",
              AttentionFilter.toShow(both, enabled: true, isQuiet: { _ in true }).isEmpty)
        check("q6 empty events → empty",
              AttentionFilter.toShow([], enabled: true, isQuiet: { _ in false }).isEmpty)
        check("q7 frontmost title is the session's folder → quiet",
              AttentionFilter.toShow(both, enabled: true, isQuiet: quietIfFront).isEmpty)
        check("q8 isShowing: no focused VS Code title (untrusted / other app) → never quiet",
              !FrontWindow.isShowing(title: nil, windowDir: "/p/a"))
        check("q9 isShowing: session without windowDir → never quiet",
              !FrontWindow.isShowing(title: "a.swift — a", windowDir: nil))
        check("q10 isShowing: another folder frontmost → not quiet",
              !FrontWindow.isShowing(title: "a.swift — other", windowDir: "/p/a"))
        check("q11 isShowing: matching folder → quiet",
              FrontWindow.isShowing(title: "a", windowDir: "/p/a"))
        check("q12 title match: trailing slash in windowDir still matches",
              FrontWindow.titleMatches("f.py — a", windowDir: "/p/a/"))
        check("q13 title match: empty / root windowDir never matches",
              !FrontWindow.titleMatches("f.py — a", windowDir: "") && !FrontWindow.titleMatches("f.py — a", windowDir: "/"))
        check("q14 title match: plain hyphen is not a separator",
              !FrontWindow.titleMatches("f.py - a", windowDir: "/p/a"))
        check("q15 title match: surrounding spaces in components are trimmed",
              FrontWindow.titleMatches("f.py —  a  — Visual Studio Code", windowDir: "/p/a"))

        // Custom window.title in a folder's .vscode/settings.json: "◆ Acme ${separator}…".
        let acmeSettings = """
        // Project identity
        {
          "window.title": "◆ Acme ${separator}${dirty}${activeEditorShort}",
          "workbench.colorCustomizations": {}
        }
        """
        check("q16 custom title: literal prefix before ${…}",
              FrontWindow.customTitlePrefix(settings: acmeSettings) == "◆ Acme")
        check("q17 custom title: no window.title / starts with ${…} / bare symbol → nil",
              FrontWindow.customTitlePrefix(settings: "{}") == nil
              && FrontWindow.customTitlePrefix(settings: #"{"window.title": "${rootName}${separator}x"}"#) == nil
              && FrontWindow.customTitlePrefix(settings: #"{"window.title": "◆ ${rootName}"}"#) == nil)
        check("q18 custom title: prefix matches its window",
              FrontWindow.titleMatches("◆ Acme — Quarterly report…", windowDir: "/p/acme-api", customPrefix: "◆ Acme")
              && FrontWindow.titleMatches("◆ Acme", windowDir: "/p/acme-api", customPrefix: "◆ Acme"))
        check("q19 custom title: a longer name with the same start does not match",
              !FrontWindow.titleMatches("◆ Acme2 — x", windowDir: "/p/acme-api", customPrefix: "◆ Acme")
              && !FrontWindow.titleMatches("◆ Globex — x", windowDir: "/p/acme-api", customPrefix: "◆ Acme"))
        check("q20 custom title: folder name still matches without a prefix",
              FrontWindow.titleMatches("x — acme-api", windowDir: "/p/acme-api", customPrefix: nil))
        return ok
    }
}
#endif
