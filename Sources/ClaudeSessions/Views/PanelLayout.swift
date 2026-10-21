import CoreGraphics
import Foundation

/// Display geometry as the placement functions see it (Cocoa coordinates, y up,
/// origin at the bottom-left of the main display). Pure value: the AppKit side
/// builds these from `NSScreen`, the self-test from hand-built display layouts.
struct PanelScreen: Equatable {
    /// CGDirectDisplayID (`deviceDescription["NSScreenNumber"]`).
    var id: UInt32
    /// `localizedName` — fallback match when a reconnected display got a new id.
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Where the pinned panel was left: top-left point + its display. Never a size —
/// the size always comes from the measured content.
struct PinnedPosition: Equatable {
    var topLeft: CGPoint
    var screenID: UInt32
    var screenName: String
}

/// Pure placement for the status panel (anchored under the menu bar item, or
/// pinned where the user dropped it). No AppKit: `--layout-selftest` runs it headless.
enum PanelLayout {
    /// Gap to the screen edges in anchored mode, and the height-cap margin.
    static let margin: CGFloat = 8
    /// Space between the menu bar item and the anchored panel's top edge.
    static let anchorGap: CGFloat = 6
    /// Default pinned spot: this far from the top-right corner of the visible frame.
    static let fallbackInset = CGSize(width: 16, height: 8)

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// The display holding the largest part of `frame`; nil if it touches none.
    static func dominantScreen(for frame: CGRect, in screens: [PanelScreen]) -> PanelScreen? {
        let best = screens.max { overlap($0.frame, frame) < overlap($1.frame, frame) }
        guard let best, overlap(best.frame, frame) > 0 else { return nil }
        return best
    }

    /// Inclusive containment (a top-left point sits on the frame's top edge).
    static func contains(_ rect: CGRect, _ p: CGPoint) -> Bool {
        p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }

    /// Height never exceeds the display's visible height minus the margin.
    static func cappedHeight(_ height: CGFloat, on screen: PanelScreen) -> CGFloat {
        min(height, max(screen.visibleFrame.height - margin, 120))
    }

    /// Pulls `frame` inside `visible` (horizontal inset `inset`). When it can't fit,
    /// the left and top edges win (title and tabs stay reachable).
    static func clamp(_ frame: CGRect, into visible: CGRect, inset: CGFloat) -> CGRect {
        var f = frame
        f.origin.x = max(visible.minX + inset, min(f.minX, visible.maxX - inset - f.width))
        f.origin.y = min(visible.maxY - f.height, max(f.minY, visible.minY))
        return f
    }

    /// The rect to hang the panel from. AppKit's item rect is trusted only while it
    /// sits in the menu bar strip at the top of its display: with the menu bar hidden
    /// (an app in fullscreen) AppKit can report the item at a parked spot near the
    /// BOTTOM of the main display, horizontally away from where the item is drawn,
    /// so the panel would open mid-screen and then jump on the next refit. Parked →
    /// rebuild the rect at the mouse when it is in a menu bar strip (the click is on
    /// the item); else nil (caller falls back to the top-right).
    static func menuBarAnchor(reported: (CGRect, PanelScreen)?, mouse: CGPoint,
                              screens: [PanelScreen], barHeight: CGFloat) -> (CGRect, PanelScreen)? {
        func strip(_ s: PanelScreen) -> CGFloat { max(barHeight, s.frame.maxY - s.visibleFrame.maxY) }
        func inStrip(_ y: CGFloat, _ s: PanelScreen) -> Bool {
            y <= s.frame.maxY + 0.5 && y >= s.frame.maxY - max(strip(s), 40)
        }
        if let (rect, screen) = reported, inStrip(rect.midY, screen),
           rect.midX >= screen.frame.minX, rect.midX <= screen.frame.maxX {
            return (rect, screen)
        }
        guard let screen = screens.first(where: { contains($0.frame, mouse) }), inStrip(mouse.y, screen)
        else { return nil }
        let width = reported?.0.width ?? barHeight
        let height = strip(screen)
        return (CGRect(x: mouse.x - width / 2, y: screen.frame.maxY - height, width: width, height: height), screen)
    }

    /// Anchored: left edge under the item's left edge, top just below the menu bar,
    /// fully inside the item's display.
    static func anchoredFrame(size: CGSize, button: CGRect, screen: PanelScreen) -> CGRect {
        let visible = screen.visibleFrame
        let height = cappedHeight(size.height, on: screen)
        let top = min(button.minY, visible.maxY) - anchorGap
        let frame = CGRect(x: button.minX, y: top - height, width: size.width, height: height)
        return clamp(frame, into: visible, inset: margin)
    }

    /// Default pinned spot: top-right of `screen`.
    static func topRight(size: CGSize, on screen: PanelScreen) -> CGRect {
        let visible = screen.visibleFrame
        let height = cappedHeight(size.height, on: screen)
        let frame = CGRect(
            x: visible.maxX - size.width - fallbackInset.width,
            y: visible.maxY - fallbackInset.height - height,
            width: size.width, height: height)
        return clamp(frame, into: visible, inset: 0)
    }

    /// Pinned panel on (re)open: the saved top-left on its saved display. Saved
    /// display gone, or the point is off every display → top-right of `fallback`
    /// (the status item's display).
    static func pinnedFrame(size: CGSize, saved: PinnedPosition?, screens: [PanelScreen],
                            fallback: PanelScreen) -> CGRect {
        guard let saved,
              let screen = screens.first(where: { $0.id == saved.screenID })
                ?? screens.first(where: { $0.name == saved.screenName }),
              screens.contains(where: { contains($0.frame, saved.topLeft) })
        else { return topRight(size: size, on: fallback) }
        let height = cappedHeight(size.height, on: screen)
        let frame = CGRect(x: saved.topLeft.x, y: saved.topLeft.y - height,
                           width: size.width, height: height)
        return clamp(frame, into: screen.visibleFrame, inset: 0)
    }

    /// Pinned panel after a content-size change or a drop: the display is chosen
    /// from the frame BEFORE resizing (largest overlap), the top edge is kept, and
    /// the result is pulled inside that same display — a height change never moves
    /// it to the neighbour.
    static func refitPinned(current: CGRect, size: CGSize, screens: [PanelScreen],
                            fallback: PanelScreen) -> CGRect {
        guard let screen = dominantScreen(for: current, in: screens) else {
            return topRight(size: size, on: fallback)
        }
        let height = cappedHeight(size.height, on: screen)
        let frame = CGRect(x: current.minX, y: current.maxY - height,
                           width: size.width, height: height)
        return clamp(frame, into: screen.visibleFrame, inset: 0)
    }
}

#if DEBUG
/// `--layout-selftest`: the placement rules against a typical three-display layout
/// (external 1920×1080 main display at 0,0 · built-in 1470×956 to its right ·
/// an iPad-sized display to its left).
enum PanelLayoutSelfTest {
    static func run() -> Bool {
        let main = PanelScreen(id: 1, name: "External Display",
                               frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        let builtIn = PanelScreen(id: 2, name: "Built-in Retina Display",
                                  frame: CGRect(x: 1920, y: 0, width: 1470, height: 956),
                                  visibleFrame: CGRect(x: 1920, y: 0, width: 1470, height: 919))
        let sidecar = PanelScreen(id: 3, name: "Side Display",
                                  frame: CGRect(x: -1180, y: 0, width: 1180, height: 820),
                                  visibleFrame: CGRect(x: -1180, y: 0, width: 1180, height: 796))
        let screens = [main, builtIn, sidecar]
        let width = Theme.panelWidth

        var allPass = true
        func check(_ name: String, _ conditions: [(String, Bool)]) {
            let failed = conditions.filter { !$0.1 }.map(\.0)
            if failed.isEmpty {
                print("PASS \(name)")
            } else {
                allPass = false
                print("FAIL \(name): \(failed.joined(separator: ", "))")
            }
        }
        func inside(_ f: CGRect, _ s: PanelScreen) -> Bool {
            s.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(f)
        }
        func str(_ f: CGRect) -> String {
            "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
        }

        // (a) Anchored under a status item at x≈1300 on the main display.
        let button = CGRect(x: 1300, y: 1055, width: 64, height: 25)
        let a = PanelLayout.anchoredFrame(size: CGSize(width: width, height: 522), button: button, screen: main)
        check("a anchored under item x≈1300 stays on main, under the menu bar \(str(a))", [
            ("inside main.visibleFrame", inside(a, main)),
            ("top ≤ menu bar bottom − gap", a.maxY <= 1055 - PanelLayout.anchorGap + 0.5),
            ("left edge under the item (x=1300)", a.minX == 1300),
            ("dominant screen is main", PanelLayout.dominantScreen(for: a, in: screens) == main),
        ])
        // (a') item near the right edge of main: pulled left, never onto the built-in.
        let a2 = PanelLayout.anchoredFrame(
            size: CGSize(width: width, height: 341),
            button: CGRect(x: 1880, y: 1055, width: 30, height: 25), screen: main)
        check("a' anchored item at x=1880 clamped inside main \(str(a2))", [
            ("inside main.visibleFrame", inside(a2, main)),
            ("right edge at 1920 − margin", a2.maxX == 1920 - PanelLayout.margin),
        ])

        // (b) Pinned saved on the built-in at x=1930; tab change 522 → 341 keeps it there.
        let saved = PinnedPosition(topLeft: CGPoint(x: 1930, y: 900), screenID: 2,
                                   screenName: builtIn.name)
        let b0 = PanelLayout.pinnedFrame(size: CGSize(width: width, height: 522), saved: saved,
                                         screens: screens, fallback: main)
        let b1 = PanelLayout.refitPinned(current: b0, size: CGSize(width: width, height: 341),
                                         screens: screens, fallback: main)
        check("b pinned on built-in x=1930, 522→341 stays on built-in \(str(b0))→\(str(b1))", [
            ("restored at x=1930, top 900", b0.minX == 1930 && b0.maxY == 900),
            ("after refit still x=1930", b1.minX == 1930),
            ("top edge kept", b1.maxY == b0.maxY),
            ("height 341", b1.height == 341),
            ("inside built-in", inside(b1, builtIn)),
        ])

        // (c) Saved display missing (and its point off every display) → top-right of
        // the status item's display. Same if the display exists but the point is off-screen.
        let gone = PinnedPosition(topLeft: CGPoint(x: 4000, y: 900), screenID: 99, screenName: "Gone")
        let c = PanelLayout.pinnedFrame(size: CGSize(width: width, height: 400), saved: gone,
                                        screens: screens, fallback: main)
        let offPoint = PinnedPosition(topLeft: CGPoint(x: 5000, y: 3000), screenID: 2,
                                      screenName: builtIn.name)
        let c2 = PanelLayout.pinnedFrame(size: CGSize(width: width, height: 400), saved: offPoint,
                                         screens: screens, fallback: main)
        let c3 = PanelLayout.pinnedFrame(size: CGSize(width: width, height: 400), saved: nil,
                                         screens: screens, fallback: builtIn)
        check("c saved screen missing → top-right of status item's screen \(str(c))", [
            ("x = 1920 − 420 − 16", c.minX == 1920 - width - 16),
            ("top = 1055 − 8", c.maxY == 1055 - 8),
            ("point off every display → same fallback", c2 == c),
            ("no saved position → top-right of the item's display", c3.maxX == builtIn.visibleFrame.maxX - 16 && inside(c3, builtIn)),
        ])

        // (d) Overhanging an edge by 16 px is pulled inside its own display.
        let dLeft = PanelLayout.refitPinned(current: CGRect(x: 1904, y: 300, width: width, height: 522),
                                            size: CGSize(width: width, height: 522),
                                            screens: screens, fallback: main)
        let dRight = PanelLayout.refitPinned(current: CGRect(x: 1920 - width + 16, y: 300, width: width, height: 522),
                                             size: CGSize(width: width, height: 341),
                                             screens: screens, fallback: builtIn)
        let dTop = PanelLayout.refitPinned(current: CGRect(x: 2200, y: 919 - 522 + 16, width: width, height: 522),
                                           size: CGSize(width: width, height: 522),
                                           screens: screens, fallback: main)
        check("d 16 px overhang pulled inside its own display \(str(dLeft)) \(str(dRight)) \(str(dTop))", [
            ("built-in left overhang → x=1920 on built-in", dLeft.minX == 1920 && inside(dLeft, builtIn)),
            ("main right overhang → x=1500 on main", dRight.maxX == 1920 && inside(dRight, main)),
            ("top overhang under built-in menu bar → top=919", dTop.maxY == 919 && inside(dTop, builtIn)),
        ])

        // (e) Height capped to visibleFrame height − margin (both modes).
        let eP = PanelLayout.refitPinned(current: CGRect(x: 2000, y: 100, width: width, height: 500),
                                         size: CGSize(width: width, height: 2000),
                                         screens: screens, fallback: main)
        let eA = PanelLayout.anchoredFrame(size: CGSize(width: width, height: 2000),
                                           button: CGRect(x: 2500, y: 919, width: 60, height: 37),
                                           screen: builtIn)
        check("e height capped to visible − margin \(str(eP)) \(str(eA))", [
            ("pinned height = 919 − 8", eP.height == 919 - PanelLayout.margin),
            ("pinned inside built-in", inside(eP, builtIn)),
            ("anchored height = 919 − 8", eA.height == 919 - PanelLayout.margin),
            ("anchored inside built-in", inside(eA, builtIn)),
        ])

        // (f) Menu bar hidden (fullscreen app): AppKit parks the item at the bottom of
        // main (here x 900, y 3). Trust only a rect in the menu bar strip;
        // else rebuild it at the click; else nil. Refit afterwards keeps the left edge.
        let parked = (CGRect(x: 900, y: 3, width: 74, height: 24), main)
        let live = (CGRect(x: 1240, y: 1055, width: 74, height: 25), main)
        let fLive = PanelLayout.menuBarAnchor(reported: live, mouse: CGPoint(x: 10, y: 10),
                                              screens: screens, barHeight: 24)
        let fClick = PanelLayout.menuBarAnchor(reported: parked, mouse: CGPoint(x: 1277, y: 1068),
                                               screens: screens, barHeight: 24)
        let fNone = PanelLayout.menuBarAnchor(reported: parked, mouse: CGPoint(x: 900, y: 500),
                                              screens: screens, barHeight: 24)
        let fBuilt = PanelLayout.menuBarAnchor(reported: nil, mouse: CGPoint(x: 3000, y: 940),
                                               screens: screens, barHeight: 24)
        let fPanel = fClick.map { PanelLayout.anchoredFrame(size: CGSize(width: width, height: 528),
                                                            button: $0.0, screen: $0.1) }
        let fRefit = fPanel.map { PanelLayout.refitPinned(current: $0, size: CGSize(width: width, height: 341),
                                                          screens: screens, fallback: main) }
        check("f parked item → anchor at the click, refit keeps x \(fPanel.map(str) ?? "nil")→\(fRefit.map(str) ?? "nil")", [
            ("item in the strip is trusted as reported", fLive?.0 == live.0 && fLive?.1 == main),
            ("parked + click in strip → item rebuilt at x = 1277 − 37", fClick?.0.minX == 1240 && fClick?.1 == main),
            ("parked + mouse off the strip → nil (top-right fallback)", fNone == nil),
            ("no item + click on built-in strip → built-in", fBuilt?.1 == builtIn),
            ("panel hangs from the top, not mid-screen", (fPanel?.maxY ?? 0) >= 1055 - 25 - PanelLayout.anchorGap - 0.5),
            ("refit keeps the left edge", fRefit?.minX == fPanel?.minX && fPanel?.minX == 1240),
            ("refit keeps the top", fRefit?.maxY == fPanel?.maxY),
        ])

        return allPass
    }
}
#endif
