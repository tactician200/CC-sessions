import AppKit
import Combine
import SwiftUI

// MARK: - Host environment

private struct InPinnedPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true when the panel is pinned (floating), false when it hangs from the menu
    /// bar item. Drives the drag handle and close-after-click.
    var inPinnedPanel: Bool {
        get { self[InPinnedPanelKey.self] }
        set { self[InPinnedPanelKey.self] = newValue }
    }
}

/// Panel-level inputs to the SwiftUI root that come from AppKit.
@MainActor
final class PanelMetrics: ObservableObject {
    /// Scroll-area cap for the display the panel is on (nil = views' own caps).
    @Published var scrollCap: CGFloat?
    /// Reduce Transparency: opaque base instead of glass + scrim.
    @Published var opaque = false
}

/// The panel's SwiftUI root, shared by the live panel and `--snapshot`: content at
/// its ideal size, top-aligned, on the dark scrim, clipped to `Theme.panelRadius` —
/// the same radius as the glass around it, so there are no square corners in
/// either mode. Top alignment: if the window is momentarily taller than new
/// content (one frame before the refit lands) the footer doesn't float mid-panel.
struct PanelRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var metrics: PanelMetrics

    var body: some View {
        DropdownView()
            .environmentObject(state)
            .environment(\.inPinnedPanel, state.pinned)
            .environment(\.panelScrollCap, metrics.scrollCap)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(metrics.opaque ? Theme.panelOpaque : Theme.panelScrim)
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Row-click API (kept for SessionRowView)

enum MenuBarWindow {
    /// Closes the panel when it hangs from the menu bar item (a native menu closes
    /// after a choice). No-op when pinned.
    @MainActor
    static func close() {
        StatusPanelController.shared.dismissAnchored()
    }
}

// MARK: - Panel

/// Borderless non-activating panel: never activates the app (VS Code keeps
/// focus), but can become key so Esc reaches it in anchored mode.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that never moves the window on mouse-down (rows/tabs get their
/// clicks; dragging is only `WindowDragHandle`) and reports intrinsic-size
/// invalidations — the panel refits from actual content-size changes.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicSizeInvalidated: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}

/// One panel, two modes:
/// - **anchored**: hangs under the status item like a native status menu; closes
///   on a second click of the item, Esc, a click outside, a row click, another app
///   activating, a Space change or a display change.
/// - **pinned**: floating, all Spaces + full-screen, non-activating, dragged by its
///   header, survives outside clicks, reopened at launch. Position (top-left +
///   display) is persisted apart from size; size always = measured content.
@MainActor
final class StatusPanelController {
    static let shared = StatusPanelController()

    enum Mode { case hidden, anchored, pinned }
    private(set) var mode: Mode = .hidden

    /// The status item's button: anchor for anchored mode and the fallback display.
    weak var statusButton: NSStatusBarButton?
    /// Anchored panel shown / hidden → the status item highlights like an open menu.
    var onAnchoredVisibilityChange: ((Bool) -> Void)?

    static let positionKey = "pinnedPanelPosition"
    /// Old frame autosave (earlier versions): size + position in one key, trusted on
    /// reopen — the cause of the stale 10×10 / wrong-display frames. Deleted once.
    static let legacyAutosaveKey = "NSWindow Frame ClaudeSessionsPinnedPanel"

    private weak var state: AppState?
    private let metrics = PanelMetrics()
    private var panel: StatusPanel?
    private var hosting: PanelHostingView<PanelRootView>?
    private var measureScheduled = false
    private var measuring = false
    /// Anchored panel already hangs from the item: later refits keep its left edge
    /// and top (only the height follows the content), so it never jumps while open.
    private var anchoredPlaced = false
    private var dragging = false
    private var dragTimer: Timer?
    private var dismissMonitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var stateObserver: AnyCancellable?
    /// Frontmost app when the anchored panel opened (VS Code, usually) — gets the
    /// keyboard back if pinning ever left this app active.
    private weak var previousApp: NSRunningApplication?

    // MARK: Lifecycle

    func attach(state: AppState) {
        self.state = state
        UserDefaults.standard.removeObject(forKey: Self.legacyAutosaveKey)
        metrics.opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        let ws = NSWorkspace.shared.notificationCenter
        let app = NotificationCenter.default
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification) { c, _ in c.dismissAnchored() }
        observe(ws, NSWorkspace.didActivateApplicationNotification) { c, note in
            // Another app came forward (Cmd-Tab, a row click focusing VS Code).
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { c.dismissAnchored() }
        }
        observe(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { c, _ in c.reduceTransparencyChanged() }
        observe(app, NSApplication.didChangeScreenParametersNotification) { c, _ in c.screensChanged() }
        // Fallback trigger; the real one is the hosting view's intrinsic-size
        // invalidation. Both are coalesced and ignored while hidden.
        stateObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleMeasure() } }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (StatusPanelController, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self, note)
            }
        }
        observers.append((center, token))
    }

    // MARK: Status item click

    func toggleFromStatusItem() {
        switch mode {
        case .hidden: showAnchored()
        case .anchored: dismissAnchored()
        case .pinned: panel?.orderFrontRegardless()   // already open: just bring it forward
        }
    }

    func showAnchored() {
        guard mode == .hidden, let state else { return }
        let panel = ensurePanel(state: state)
        mode = .anchored
        configure(panel)
        updateScrollCap(for: anchorScreen())
        if let frame = targetFrame(for: panel, size: measure()) {
            panel.setFrame(frame, display: false)
            anchoredPlaced = true
        }
        // Key (without activating the app) so Esc reaches it, as a native status
        // menu takes the keyboard while open. Global key monitors would need the
        // Accessibility permission. The key is handed back on dismiss (orderOut)
        // and on pin (`handOverKeyAndPin`).
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        installDismissMonitors()
        onAnchoredVisibilityChange?(true)
        refreshUsageIfShown()
    }

    func dismissAnchored() {
        guard mode == .anchored else { return }
        mode = .hidden
        anchoredPlaced = false
        removeDismissMonitors()
        panel?.orderOut(nil)   // relinquishes key: the keyboard goes back to the active app
        previousApp = nil
        onAnchoredVisibilityChange?(false)
    }

    // MARK: Pin

    /// Pin while anchored converts the same panel in place; pin while hidden opens
    /// it at the saved position; unpin closes it.
    func setPinned(_ on: Bool) {
        guard let state else { return }
        if on {
            let panel = ensurePanel(state: state)
            switch mode {
            case .pinned:
                return
            case .anchored:
                removeDismissMonitors()
                onAnchoredVisibilityChange?(false)
                anchoredPlaced = false
                mode = .pinned
                handOverKeyAndPin(panel)
                savePosition(of: panel.frame)
            case .hidden:
                mode = .pinned
                configure(panel)
                let size = measure()
                let frame = PanelLayout.pinnedFrame(
                    size: size, saved: loadPosition(), screens: Self.screens(),
                    fallback: Self.panelScreen(fallbackScreen()))
                updateScrollCap(for: Self.nsScreen(for: frame))
                panel.setFrame(frame, display: false)
                panel.orderFrontRegardless()
                panel.invalidateShadow()
                refreshUsageIfShown()
            }
            scheduleMeasure()
        } else {
            guard mode == .pinned else { return }
            mode = .hidden
            endDragTimer()
            dragging = false
            panel?.orderOut(nil)
        }
    }

    /// Anchored → pinned in place, giving the keyboard back.
    /// `becomesKeyOnlyIfNeeded` only gates FUTURE key acquisition; a panel that is
    /// already key stays key, so typing would land here while VS Code looks active.
    /// Ordering the panel out is what relinquishes key; it is re-ordered at the same
    /// frame in the same run-loop turn (one window-server transaction, no animation)
    /// so nothing flickers. The app was never activated (non-activating panel), so
    /// key returns to the active app; if this app did end up active, re-activate the
    /// app that was frontmost when the panel opened.
    private func handOverKeyAndPin(_ panel: StatusPanel) {
        let frame = panel.frame
        let animation = panel.animationBehavior
        panel.animationBehavior = .none
        panel.orderOut(nil)
        configure(panel)   // pinned: floating, all Spaces, becomesKeyOnlyIfNeeded
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()   // ordered front, NOT made key
        panel.animationBehavior = animation
        panel.invalidateShadow()
        if NSApp.isActive {
            if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                _ = previousApp.activate(options: [])
            } else {
                NSApp.deactivate()
            }
        }
        previousApp = nil
    }

    // MARK: Sizing

    private func scheduleMeasure() {
        guard mode != .hidden, !measureScheduled else { return }
        measureScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.measureScheduled = false
                self?.refit()
            }
        }
    }

    /// Resize to the measured content. Anchored keeps its top under the menu bar;
    /// pinned keeps its top edge and its display. Never during a drag or while hidden.
    func refit() {
        guard mode != .hidden, !dragging, let panel else { return }
        guard let frame = targetFrame(for: panel, size: measure()), frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: false)
        // The first measure at open can be 0×0 (no frame placed then); the first
        // successful anchored placement happens here. Latch it so later refits keep
        // the panel's position instead of re-anchoring to the status item.
        if mode == .anchored { anchoredPlaced = true }
        panel.invalidateShadow()
    }

    /// SwiftUI ideal size of the fixed-width content (root is `.fixedSize()`).
    private func measure() -> CGSize {
        guard let hosting else { return .zero }
        measuring = true
        defer { measuring = false }
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.intrinsicContentSize
        if !(size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite) {
            size = hosting.fittingSize
        }
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func targetFrame(for panel: NSPanel, size: CGSize) -> NSRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        switch mode {
        case .hidden:
            return nil
        case .anchored where anchoredPlaced:
            return PanelLayout.refitPinned(
                current: panel.frame, size: size, screens: Self.screens(),
                fallback: Self.panelScreen(fallbackScreen()))
        case .anchored:
            if let (rect, screen) = anchor() {
                return PanelLayout.anchoredFrame(size: size, button: rect, screen: Self.panelScreen(screen))
            }
            return PanelLayout.topRight(size: size, on: Self.panelScreen(fallbackScreen()))
        case .pinned:
            return PanelLayout.refitPinned(
                current: panel.frame, size: size, screens: Self.screens(),
                fallback: Self.panelScreen(fallbackScreen()))
        }
    }

    private func updateScrollCap(for screen: NSScreen?) {
        guard let screen else { return }
        let cap = floor(screen.visibleFrame.height - PanelLayout.margin - Theme.panelChromeAllowance)
        if metrics.scrollCap != cap { metrics.scrollCap = cap }
    }

    // MARK: Drag

    /// Called from the header's mouse-down. `performDrag` may return before the
    /// window server finishes the drag, so the drag lasts until the primary button
    /// is actually up (polled on a .common-mode timer); refits wait until then.
    func beginDrag() {
        guard mode == .pinned else { return }
        dragging = true
        endDragTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func endDrag() {
        endDragTimer()
        guard dragging else { return }
        dragging = false
        guard mode == .pinned, let panel else { return }
        savePosition(of: panel.frame)
        updateScrollCap(for: Self.nsScreen(for: panel.frame))
        refit()
    }

    private func endDragTimer() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    // MARK: Position persistence (top-left + display; never a size)

    private func savePosition(of frame: NSRect) {
        guard let screen = PanelLayout.dominantScreen(for: frame, in: Self.screens()) else { return }
        UserDefaults.standard.set([
            "x": Double(frame.minX), "y": Double(frame.maxY),
            "screenID": Int(screen.id), "screenName": screen.name,
        ], forKey: Self.positionKey)
    }

    private func loadPosition() -> PinnedPosition? {
        guard let d = UserDefaults.standard.dictionary(forKey: Self.positionKey),
              let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
        let id = (d["screenID"] as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? 0
        return PinnedPosition(topLeft: CGPoint(x: x, y: y), screenID: id,
                              screenName: d["screenName"] as? String ?? "")
    }

    // MARK: Screens

    static func panelScreen(_ screen: NSScreen) -> PanelScreen {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return PanelScreen(id: number?.uint32Value ?? 0, name: screen.localizedName,
                           frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    static func screens() -> [PanelScreen] { NSScreen.screens.map(panelScreen) }

    static func nsScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { PanelLayout.overlap($0.frame, frame) < PanelLayout.overlap($1.frame, frame) }
    }

    /// The status item's button rect in screen coordinates and its display — or,
    /// when AppKit reports it parked off the menu bar (menu bar hidden), a rect
    /// rebuilt at the click (`PanelLayout.menuBarAnchor`).
    private func anchor() -> (NSRect, NSScreen)? {
        var reported: (CGRect, PanelScreen)?
        if let button = statusButton, let window = button.window, let screen = window.screen {
            reported = (window.convertToScreen(button.convert(button.bounds, to: nil)), Self.panelScreen(screen))
        }
        guard let (rect, placed) = PanelLayout.menuBarAnchor(
                reported: reported, mouse: NSEvent.mouseLocation, screens: Self.screens(),
                barHeight: NSStatusBar.system.thickness),
              let screen = NSScreen.screens.first(where: { Self.panelScreen($0).id == placed.id })
        else { return nil }
        return (rect, screen)
    }

    private func anchorScreen() -> NSScreen? { anchor()?.1 ?? fallbackScreen() }

    /// The status item's display, else the main one.
    private func fallbackScreen() -> NSScreen {
        statusButton?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screensChanged() {
        switch mode {
        case .anchored:
            dismissAnchored()
        case .pinned:
            if let panel { updateScrollCap(for: Self.nsScreen(for: panel.frame)) }
            refit()   // display gone → top-right of the item's display
        case .hidden:
            break
        }
    }

    // MARK: Dismissal (anchored only)

    private func installDismissMonitors() {
        removeDismissMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps (incl. their menus and other status items).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAnchored() }
        }) {
            dismissMonitors.append(global)
        }
        // Clicks in our other windows; Esc. The status button toggles by itself.
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.mode == .anchored else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return false }   // Esc
                    self.dismissAnchored()
                    return true
                }
                if event.window === self.panel || event.window === self.statusButton?.window {
                    return false
                }
                self.dismissAnchored()
                return false
            }
            return swallow ? nil : event
        }) {
            dismissMonitors.append(local)
        }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
    }

    // MARK: Panel construction

    private func ensurePanel(state: AppState) -> StatusPanel {
        if let panel { return panel }
        let hosting = PanelHostingView(rootView: PanelRootView(state: state, metrics: metrics))
        // Only the intrinsic size: no min/max constraints fighting the manual frame.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onIntrinsicSizeInvalidated = { [weak self] in
            guard let self, !self.measuring else { return }
            self.scheduleMeasure()
        }
        // Placeholder size; the caller measures and places it before ordering front.
        let rect = NSRect(origin: .zero, size: CGSize(width: Theme.panelWidth, height: 400))
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]
        Self.clip(hosting)

        let panel = StatusPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = makeBackground(wrapping: hosting, size: rect.size)
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    private func configure(_ panel: StatusPanel) {
        switch mode {
        case .anchored:
            panel.level = .popUpMenu
            panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
            panel.becomesKeyOnlyIfNeeded = false
        case .pinned:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.becomesKeyOnlyIfNeeded = true
        case .hidden:
            break
        }
    }

    /// Concentric clip of the SwiftUI layer (the root also clips itself): nothing
    /// square can paint past the glass corners.
    private static func clip(_ view: NSView, radius: CGFloat = Theme.panelRadius) {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    /// macOS 26: NSGlassEffectView (.regular, dark, restrained tint, radius 18).
    /// Older: NSVisualEffectView .hudWindow with a rounded mask. Reduce
    /// Transparency: opaque dark rounded view.
    private func makeBackground(wrapping content: NSView, size: CGSize) -> NSView {
        Self.glassBackground(wrapping: content, size: size, radius: Theme.panelRadius, opaque: metrics.opaque)
    }

    /// Shared with the attention toast (AttentionToast.swift).
    static func glassBackground(wrapping content: NSView, size: CGSize, radius: CGFloat, opaque: Bool) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if opaque {
            let base = NSView(frame: frame)
            base.wantsLayer = true
            base.layer?.backgroundColor = Theme.panelOpaqueNS.cgColor
            base.layer?.cornerRadius = radius
            base.layer?.cornerCurve = .continuous
            base.layer?.masksToBounds = true
            base.autoresizingMask = [.width, .height]
            content.frame = base.bounds
            base.addSubview(content)
            return base
        }
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = radius
            glass.tintColor = Theme.glassTintNS
            glass.appearance = NSAppearance(named: .darkAqua)
            // Plain container between glass and hosting view: if the glass pins its
            // contentView with constraints, the hosting view's intrinsic size can't
            // reach the window through Auto Layout and fight the manual frame.
            let container = NSView(frame: frame)
            Self.clip(container, radius: radius)
            content.frame = container.bounds
            container.addSubview(content)
            glass.contentView = container
            glass.autoresizingMask = [.width, .height]
            return glass
        }
        let fx = NSVisualEffectView(frame: frame)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.maskImage = roundedMask(radius: radius)
        fx.autoresizingMask = [.width, .height]
        content.frame = fx.bounds
        fx.addSubview(content)
        return fx
    }

    private func reduceTransparencyChanged() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard opaque != metrics.opaque else { return }
        metrics.opaque = opaque
        guard let panel, let hosting else { return }
        hosting.removeFromSuperview()
        panel.contentView = makeBackground(wrapping: hosting, size: panel.frame.size)
        panel.invalidateShadow()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// The panel content now lives across opens (MenuBarExtra rebuilt it, so
    /// UsageTabView's onAppear refreshed on every open): refresh explicitly.
    private func refreshUsageIfShown() {
        guard let state, state.selectedTab == .usage else { return }
        Task { await state.fetchUsage(force: true) }
    }
}

// MARK: - Drag handle

/// Background for the header in pinned mode: dragging it moves the window.
struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            MainActor.assumeIsolated {
                StatusPanelController.shared.beginDrag()
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
