import SwiftUI

struct SessionsTabView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.sessions.isEmpty {
            emptyState
        } else {
            FitScrollView(maxHeight: 420) {
                VStack(spacing: 2) {
                    ForEach(state.sessions) { session in
                        SessionRowView(session: session)
                        if !session.subagents.isEmpty {
                            SubagentGroupView(subagents: session.subagents)
                        }
                    }
                }
                // Row highlights are inset from the panel edge, like a native menu.
                .padding(.horizontal, Theme.rowInset)
                .padding(.vertical, Theme.rowInset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            SessionsMark(color: Theme.textTertiary, size: 28)
            Text(L10n.tr("empty.title"))
                .font(Theme.title(13, .medium))
                .foregroundColor(Theme.textSecondary)
            Text(L10n.tr("empty.hint"))
                .font(Theme.body(11))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
