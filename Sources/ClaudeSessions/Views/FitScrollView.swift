import SwiftUI

private struct PanelScrollCapKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Maximum height for scroll areas, set by the status panel from the display
    /// it sits on (visible height − margin − chrome). nil = only the view's own cap.
    var panelScrollCap: CGFloat? {
        get { self[PanelScrollCapKey.self] }
        set { self[PanelScrollCapKey.self] = newValue }
    }
}

/// ScrollView pinned to its ideal height (= content height, capped at `maxHeight`
/// and at the panel's `panelScrollCap`). A bare `ScrollView` + `.frame(maxHeight:)`
/// has no minimum height and a host can size it to 0 — the session list vanished
/// while the header still showed counts. `fixedSize(vertical:)` makes the height
/// rigid in a single layout pass (a GeometryReader measurement needs two, and the
/// first is 0). Check: `ClaudeSessions --snapshot out.png` → `min=` equals `ideal=`.
struct FitScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.panelScrollCap) private var cap

    var body: some View {
        ScrollView {
            content()
        }
        .frame(maxHeight: min(maxHeight, max(cap ?? .infinity, 120)))
        .fixedSize(horizontal: false, vertical: true)
    }
}
