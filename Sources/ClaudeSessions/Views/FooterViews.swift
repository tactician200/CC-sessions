import SwiftUI
import AppKit

struct SessionsFooterView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        HStack(spacing: 14) {
            // A zero is noise: only show the figures that say something.
            if state.totalContextTokens > 0 {
                stat(icon: "bolt.horizontal", value: TokenFormat.short(state.totalContextTokens), label: L10n.tr("footer.inContext"))
                    .help(L10n.tr("footer.inContext.help"))
            }
            if state.activeSubagentsCount > 0 {
                stat(icon: "tree", value: "\(state.activeSubagentsCount)", label: L10n.tr("footer.subagents"))
            }
            Spacer(minLength: 0)
            SettingsMenu(launchAtLogin: $launchAtLogin)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func stat(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(Theme.number(11.5))
                .foregroundColor(Theme.ink)
            Text(label)
                .font(Theme.body(11))
                .foregroundColor(Theme.textTertiary)
        }
        .fixedSize()
    }
}

private struct SettingsMenu: View {
    @Binding var launchAtLogin: Bool
    @State private var toastEnabled = AttentionToastController.shared.isEnabled

    var body: some View {
        Menu {
            Toggle(L10n.tr("settings.launchAtLogin"), isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    LaunchAtLogin.isEnabled = newValue
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            ))
            Toggle(L10n.tr("settings.toasts"), isOn: Binding(
                get: { toastEnabled },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: AttentionToastController.enabledKey)
                    toastEnabled = newValue
                }
            ))
            if toastEnabled && !FrontWindow.canRead {
                Button(L10n.tr("settings.quietInWindow")) { FrontWindow.requestAccess() }
            }
            Divider()
            Button(L10n.tr("settings.quit")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.tr("settings.help"))
    }
}

struct UsageFooterView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
            if state.usageError == nil, let fetchedAt = state.usage?.fetchedAt {
                // Own clock (seconds for the first minute, then minutes):
                // "hace…" keeps moving between fetches without touching AppState.
                TimelineView(RelativeTimeSchedule(since: fetchedAt)) { context in
                    statusLabel(Self.updatedText(fetchedAt: fetchedAt, now: context.date))
                }
            } else {
                statusLabel(L10n.tr(state.usageError != nil ? "usage.footer.error" : "usage.footer.cache"))
            }
            Spacer(minLength: 0)
            if let sub = state.subscriptionType, !sub.isEmpty {
                Text(sub.uppercased())
                    .font(Theme.label(9.5))
                    .tracking(0.4)
                    .foregroundColor(Theme.inkFaint)
                    .fixedSize()
                    .glassChip(radius: 5)
            }
            Button {
                Task { await state.fetchUsage(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(L10n.tr("usage.refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(10.5))
            .foregroundColor(Theme.textTertiary)
            .lineLimit(1)
    }

    static func updatedText(fetchedAt: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = L10n.locale
        return L10n.tr("usage.updated", f.localizedString(for: fetchedAt, relativeTo: now))
    }
}
