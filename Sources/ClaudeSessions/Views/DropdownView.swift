import SwiftUI

/// Content only, at its natural (ideal) size — no background, clip, border or
/// fill-the-window frame. The status panel (`PanelRootView` in StatusPanel.swift)
/// owns glass, scrim, the rounded clip and the window size (= this view's ideal
/// size, measured), in both anchored and pinned modes.
struct DropdownView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.inPinnedPanel) private var inPinnedPanel

    var body: some View {
        VStack(spacing: 0) {
            header
            if !state.warnings.isEmpty {
                WarningBanner(warnings: state.warnings)
            }
            tabs
            separator
            content
            separator
            footer
        }
        .frame(width: Theme.panelWidth)
    }

    private var separator: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
            .padding(.horizontal, 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            SessionsMark(color: Theme.ink, size: 16)
            Text("Claude Sessions")
                .font(Theme.title(14))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(Theme.ink)
            Spacer(minLength: 6)
            statusBadges
            PinButton(isOn: state.pinned) { state.togglePinned() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(inPinnedPanel ? AnyView(WindowDragHandle()) : AnyView(Color.clear))
    }

    private var statusBadges: some View {
        HStack(spacing: 5) {
            if state.waitingCount > 0 {
                StatusBadge(
                    color: Theme.waiting, background: Theme.waitingBg,
                    text: L10n.tr(state.waitingCount == 1 ? "header.waiting.one" : "header.waiting.other", state.waitingCount)
                )
            }
            if state.workingCount > 0 {
                StatusBadge(color: Theme.go, background: Theme.goBg, text: L10n.tr("header.working", state.workingCount))
            }
        }
        .fixedSize()
    }

    // MARK: Tabs

    private var tabs: some View {
        TabBar(selection: Binding(get: { state.selectedTab }, set: { state.selectedTab = $0 }))
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch state.selectedTab {
        case .sessions: SessionsTabView()
        case .usage: UsageTabView()
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch state.selectedTab {
        case .sessions: SessionsFooterView()
        case .usage: UsageFooterView()
        }
    }
}

/// Setup problems (PanelWarnings), one line each, between the header and the tabs.
private struct WarningBanner: View {
    let warnings: [PanelWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.warn)
                    Text(warning.text)
                        .font(Theme.body(11))
                        .foregroundColor(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.warn.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

private struct StatusBadge: View {
    let color: Color
    let background: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.title(11, .semibold).monospacedDigit())
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
        .fixedSize()
    }
}

/// Pin = keep the panel floating on screen. Accent when on.
private struct PinButton: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(isOn ? 0 : 45))
                .foregroundColor(isOn ? Theme.accent : (hovered ? Theme.ink : Theme.inkFaint))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(isOn ? Theme.accent.opacity(0.14) : (hovered ? Theme.glassFillHover : .clear))
                )
                .overlay(Circle().strokeBorder(isOn || hovered ? Theme.hairline : .clear, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pointingHandCursor()
        .help(L10n.tr(isOn ? "pin.help.on" : "pin.help.off"))
        .accessibilityLabel(L10n.tr(isOn ? "pin.a11y.on" : "pin.a11y.off"))
    }
}

private struct TabBar: View {
    @Binding var selection: AppState.Tab
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            tab(L10n.tr("tab.sessions"), .sessions)
            tab(L10n.tr("tab.usage"), .usage)
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selection)
    }

    private func tab(_ title: String, _ value: AppState.Tab) -> some View {
        let isSelected = selection == value
        return Button { selection = value } label: {
            VStack(spacing: 5) {
                Text(title)
                    .font(Theme.title(12.5, isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? Theme.ink : Theme.inkFaint)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                ZStack {
                    Capsule().fill(Color.clear).frame(height: 2)
                    if isSelected {
                        Capsule().fill(Theme.accent).frame(height: 2)
                            .matchedGeometryEffect(id: "tab-indicator", in: indicator)
                    }
                }
                .padding(.horizontal, 6)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
