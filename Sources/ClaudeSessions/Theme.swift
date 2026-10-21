import SwiftUI
import AppKit

/// Single token source. Skin = our own panel (Liquid Glass `NSGlassEffectView`,
/// dark, radius `panelRadius`) + a dark glass palette for what the system
/// doesn't name.
enum Theme {
    // MARK: Ink
    //
    // Contrast check: WCAG 2.x relative luminance, sRGB compositing, WORST
    // CASE = pure white behind the glass (the glass tint only darkens it):
    //   scrim #0F1416 @ .90 over white            → backdrop (39, 43, 45)
    //   + white .06 inset / .09 hover / .12 pressed fills on top of that.
    //   token            scrim  .06    .09    .12    goBg .14  waitBg .14
    //   ink     #E8EFED  12.18  10.14  9.19   8.33   9.18      9.35
    //   inkFaint#BAC5C3   8.03   6.68  6.06   5.49   6.05      6.16
    //   tertiary#A9B5B3   6.73   5.60  5.08   4.60   5.07      5.17
    //   go      #34D399   7.39   6.15  5.58   5.05   5.57      5.67
    //   waiting #FF9F0A   6.91   5.75  5.22   4.72   5.21      5.31
    //   warn    #FBBF24   8.51   7.08  6.43   5.82   6.41      6.53
    //   accent  #2FE6C8   8.98   7.47  6.78   6.14   6.77      6.89
    // Every text token ≥ 4.5:1 on every fill (≤ 11 pt text). Was: scrim .84,
    // tertiary = inkFaint .85 → 3.94 on scrim / 3.36 in an inset.
    // Recompute when a token changes: ratio = (L1+.05)/(L2+.05), L = .2126R+.7152G+.0722B
    // on linearised sRGB; composite = fg·α + bg·(1−α) in gamma space.
    static let ink = Color(hex: "#E8EFED")
    static let inkFaint = Color(hex: "#BAC5C3")
    static let textPrimary = ink
    static let textSecondary = inkFaint
    /// Opaque (an opacity token drops below 4.5:1 in insets).
    static let textTertiary = Color(hex: "#A9B5B3")

    /// Dark layer between the glass and the content, clipped to `panelRadius`.
    /// Glass alone takes the colour of whatever is behind it (a light VS Code
    /// turned it mid-grey); this keeps the dark base on any backdrop.
    static let panelScrimHex = "#0F1416"
    static let panelScrimOpacity = 0.90
    static let panelScrim = Color(hex: panelScrimHex).opacity(panelScrimOpacity)
    /// Reduce Transparency: the same base, opaque.
    static let panelOpaque = Color(hex: panelScrimHex)
    static let panelOpaqueNS = NSColor(srgbRed: 0x0F / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0, alpha: 1)
    /// Restrained dark tint for `NSGlassEffectView` (under the scrim; mostly visible
    /// on the rim/specular edge).
    static let glassTintNS = NSColor(srgbRed: 0x0F / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0, alpha: 0.35)

    // MARK: Glass (white translucent layer + hairline, never a card shadow)
    static let glassFill = Color.white.opacity(0.06)
    static let glassFillHover = Color.white.opacity(0.09)
    static let glassFillPressed = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.12)
    static let separator = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.08)

    // MARK: Accent — the ONLY interaction colour (active tab, pin on, pace bar)
    static let accent = Color(hex: "#2FE6C8")
    static let onAccent = Color(hex: "#06211D")

    // MARK: Status
    static let go = Color(hex: "#34D399")
    static let goBg = Color(hex: "#34D399").opacity(0.14)
    static let waitingHex = "#FF9F0A"   // system orange
    static let waiting = Color(hex: waitingHex)
    static let waitingBg = Color(hex: waitingHex).opacity(0.14)
    static let done = inkFaint.opacity(0.55)       // finished and attended ("Inactiva")
    static let finished = Color(hex: "#60A5FA")    // finished, not seen yet ("Terminó")
    static let warn = Color(hex: "#FBBF24")
    static let working = go

    /// Data bars (usage) are neutral ink; colour is reserved for state.
    static let dataFill = ink.opacity(0.78)
    static let dataFillSoft = inkFaint.opacity(0.7)

    static func statusColor(_ status: Session.Status) -> Color {
        switch status {
        case .waiting: return waiting
        case .working: return working
        case .done: return done
        }
    }

    /// Usage bar fill: neutral until it gets tight.
    static func usageFill(_ percent: Double) -> Color {
        percent >= 90 ? waiting : (percent >= 75 ? warn : dataFill)
    }

    // MARK: Type — SF Rounded for titles, monospaced digits for numbers
    static func title(_ size: CGFloat = 13, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func number(_ size: CGFloat = 12, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static func body(_ size: CGFloat = 11, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    // MARK: Geometry
    static let panelWidth: CGFloat = 420      // header holds title + 2 badges + pin
    static let rowRadius: CGFloat = 10        // hover/glass rows, inset from panel edge
    static let rowInset: CGFloat = 6          // row highlight inset from the panel edge
    static let chipRadius: CGFloat = 6
    /// Our panel's corner radius (both modes): glass, scrim and content clip are
    /// all this radius, so the shapes are concentric. A design token, not a
    /// claimed system-menu radius.
    static let panelRadius: CGFloat = 18
    /// Header + tabs + separators + footer, reserved when capping scroll areas to
    /// the display height (measured 108 = 528 total − 420 list in `--snapshot`;
    /// slack for a wrapped badge or error footer).
    static let panelChromeAllowance: CGFloat = 150

    /// Snapshot-only backdrop: white = the worst case the contrast table assumes
    /// (offscreen rendering can't sample the glass). Never used in the live UI.
    static let snapshotBackdrop = Color.white
    /// Snapshot-only backdrop for `--appearance dark`: a dark desktop grey.
    static let snapshotBackdropDark = Color(hex: "#1F1F21")
}

/// Neutral glass chip: white .06 fill + .12 hairline.
struct GlassChip: ViewModifier {
    var radius: CGFloat = Theme.chipRadius
    var fill: Color = Theme.glassFill
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

extension View {
    func glassChip(radius: CGFloat = Theme.chipRadius, fill: Color = Theme.glassFill) -> some View {
        modifier(GlassChip(radius: radius, fill: fill))
    }

    /// Pointing-hand cursor on hover (native `.pointerStyle` on macOS 15+).
    @ViewBuilder
    func pointingHandCursor() -> some View {
        if #available(macOS 15, *) {
            self.pointerStyle(.link)
        } else {
            self.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch raw.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
