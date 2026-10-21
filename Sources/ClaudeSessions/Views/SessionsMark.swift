import SwiftUI
import AppKit

/// The app glyph on a 24-unit grid: three session rows, each a status dot and a bar.
/// Same geometry as scripts/make-icon.py.
struct SessionsMarkShape: Shape {
    static let rows: [(y: CGFloat, barEnd: CGFloat)] = [(5, 22), (12, 18), (19, 20.5)]
    static let dotRadius: CGFloat = 2.4
    static let barHeight: CGFloat = 3.6

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = min(rect.width, rect.height) / 24.0
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        for row in Self.rows {
            let r = Self.dotRadius
            p.addEllipse(in: CGRect(x: ox + (4.2 - r) * s, y: oy + (row.y - r) * s, width: 2 * r * s, height: 2 * r * s))
            let h = Self.barHeight
            p.addRoundedRect(in: CGRect(x: ox + 9 * s, y: oy + (row.y - h / 2) * s, width: (row.barEnd - 9) * s, height: h * s),
                             cornerSize: CGSize(width: h / 2 * s, height: h / 2 * s))
        }
        return p
    }
}

struct SessionsMark: View {
    var color: Color = .primary
    var size: CGFloat = 14

    var body: some View {
        SessionsMarkShape()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
    }
}

/// Template NSImage wrapped as SwiftUI Image — auto-tints to match menu bar appearance.
struct SessionsMarkTemplateImage: View {
    var size: CGFloat = 15

    var body: some View {
        Image(nsImage: Self.make(size: size))
    }

    private static func make(size: CGFloat) -> NSImage {
        let dim = NSSize(width: size, height: size)
        let image = NSImage(size: dim, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let path = SessionsMarkShape().path(in: rect).cgPath
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }
}
