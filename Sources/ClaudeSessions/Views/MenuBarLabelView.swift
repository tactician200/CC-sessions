import SwiftUI
import AppKit

/// Menu bar item content, hosted in the status button (StatusItemController).
/// Mark and counts use `.primary`, which resolves against the menu bar's own
/// appearance (light or dark wallpaper); only the waiting count is orange.
struct MenuBarLabelView: View {
    @ObservedObject var state: AppState
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            SessionsMark(color: .primary, size: 15)
            if state.waitingCount > 0 {
                Text("\(state.waitingCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.waiting)
                Text("/\(state.totalCount)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            } else {
                Text(countText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal, 3)
        .background(Capsule().fill(Theme.waiting.opacity(pulsing ? 0.45 : 0)))
        .fixedSize()
        // ~2 s orange glow when a session starts needing you (invisible while a
        // fullscreen app hides the menu bar — the toast covers that case).
        .onChange(of: state.attentionPulse) { _ in
            withAnimation(.easeOut(duration: 0.2)) { pulsing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + AttentionToastController.visibleSeconds) {
                withAnimation(.easeIn(duration: 0.5)) { pulsing = false }
            }
        }
    }

    private var countText: String {
        state.totalCount == 0 ? "—" : "\(state.workingCount)/\(state.totalCount)"
    }
}
