import SwiftUI

struct SubagentGroupView: View {
    let subagents: [Subagent]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("subagents.header"))
                .font(Theme.label(9.5))
                .foregroundColor(Theme.textTertiary)
                .tracking(0.6)
            ForEach(subagents) { sub in
                HStack(spacing: 8) {
                    Image(systemName: iconFor(sub.type))
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.inkFaint)
                        .frame(width: 12, height: 12)
                    Text(sub.type)
                        .font(Theme.title(11.5, .medium))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                    if !sub.description.isEmpty {
                        Text("· \(sub.description)")
                            .font(Theme.body(11))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Circle().fill(Theme.go).frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .padding(.leading, 28)   // hangs under the session title, past the status dot
        .padding(.bottom, 4)
    }

    private func iconFor(_ type: String) -> String {
        let t = type.lowercased()
        if t.contains("explore") { return "magnifyingglass" }
        if t.contains("plan") { return "map" }
        if t.contains("review") { return "checkmark.shield" }
        if t.contains("status") { return "list.bullet.clipboard" }
        return "chevron.left.forwardslash.chevron.right"
    }
}
