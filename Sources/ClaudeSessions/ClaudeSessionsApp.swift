import SwiftUI
import AppKit
import Combine

/// Entry point lives in `Entry.swift` (handles headless modes before any UI).
/// AppKit lifecycle: an owned `NSStatusItem` + one `NSPanel` (StatusPanel.swift)
/// replace `MenuBarExtra(.window)`, whose system panel kept stale heights, used
/// light glass on a light system and couldn't be shaped (square scrim corners).
enum ClaudeSessionsApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Dark-only skin: the panel sets `.darkAqua` on itself. NOT app-wide — the
        // menu bar label must follow the real menu bar (light or dark).
        if !AppState.testMode { LaunchAtLogin.registerOnFirstLaunch() }
        let state = AppState()
        self.state = state
        StatusPanelController.shared.attach(state: state)
        statusItem = StatusItemController(state: state)
    }
}

/// The menu bar item: hosts `MenuBarLabelView` (mark · orange waiting count ·
/// working/total) inside the status button; a click toggles the anchored panel.
@MainActor
final class StatusItemController: NSObject {
    /// Label host that lets every click fall through to the status button.
    private final class LabelHostingView: NSHostingView<MenuBarLabelView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private static let horizontalPadding: CGFloat = 6

    private let item: NSStatusItem
    private let label: LabelHostingView
    private weak var state: AppState?
    private var observer: AnyCancellable?

    init(state: AppState) {
        self.state = state
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        label = LabelHostingView(rootView: MenuBarLabelView(state: state))
        super.init()
        item.autosaveName = "ClaudeSessionsStatusItem"
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(clicked(_:))
        // Native status menus open on mouse-down.
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        let panel = StatusPanelController.shared
        panel.statusButton = button
        panel.onAnchoredVisibilityChange = { [weak button] open in
            // After the button's own mouse tracking, which resets the highlight.
            DispatchQueue.main.async { MainActor.assumeIsolated { button?.highlight(open) } }
        }
        update()
        observer = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
    }

    /// Width follows the label (counts change width); accessibility text too.
    private func update() {
        let width = ceil(label.fittingSize.width) + 2 * Self.horizontalPadding
        if abs(item.length - width) > 0.5 { item.length = width }
        guard let state else { return }
        var text = L10n.tr("statusItem.a11y", state.workingCount, state.totalCount)
        if state.waitingCount > 0 { text += L10n.tr("statusItem.a11y.waiting", state.waitingCount) }
        item.button?.setAccessibilityLabel(text)
    }

    @objc private func clicked(_ sender: Any?) {
        StatusPanelController.shared.toggleFromStatusItem()
    }
}
