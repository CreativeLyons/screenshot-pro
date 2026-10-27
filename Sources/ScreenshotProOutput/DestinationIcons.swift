import AppKit
import ScreenshotProCore

/// Large, flat, two-tone icons for the destination picker, drawn in code: a clipboard, a floppy
/// disk, a scanned page, a cup of markers and a "more" disc. Each shape is lit on its left half
/// and a shade darker on its right, for a simple folded-paper look.
@MainActor
enum DestinationIcons {
    /// The icon for a destination id at `side` points, or nil when there is no drawn icon.
    static func image(for id: String, side: CGFloat = 48) -> NSImage? {
        let draw: ((CGFloat) -> Void)?
        switch id {
        case DestinationID.clipboard: draw = clipboard
        case DestinationID.file: draw = floppy
        case DestinationID.ocr: draw = scannedPage
        case DestinationID.editor: draw = markerCup
        default: draw = nil
        }
        guard let draw else { return nil }
        return make(side: side, draw)
    }

    /// The "More" button's icon.
    static func more(side: CGFloat = 48) -> NSImage { make(side: side, moreDisc) }

    // MARK: Drawing

    /// Draws in a 48 x 48 unit square with y running down.
    private static func make(side: CGFloat, _ draw: @escaping (CGFloat) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let k = side / 48
            NSGraphicsContext.current?.cgContext.scaleBy(x: k, y: k)
            draw(k)
            return true
        }
        image.accessibilityDescription = nil
        return image
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> NSBezierPath {
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
    }

    /// Fills `path` with `hex`, its right half a shade darker.
    private static func fill(_ path: NSBezierPath, _ hex: UInt32, shade: Bool = true) {
        let base = color(hex)
        base.setFill()
        path.fill()
        guard shade else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let b = path.bounds
        (base.shadow(withLevel: 0.12) ?? base).setFill()
        CGRect(x: b.midX, y: b.minY, width: b.width / 2, height: b.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func polygon(_ points: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: points[0])
        points.dropFirst().forEach(p.line(to:))
        p.close()
        return p
    }

    /// Copy: a clipboard with a page of lines and an amber clip.
    private static func clipboard(_ k: CGFloat) {
        fill(rect(9, 7, 30, 38, r: 3.5), 0xC9CDD2)
        fill(rect(13, 13, 22, 28, r: 1), 0xFAFAFA)
        for (i, w) in [15.0, 15, 15, 9].enumerated() {
            fill(rect(16.5, 18 + CGFloat(i) * 5, CGFloat(w), 2.2, r: 1.1), 0x9AA1A9, shade: false)
        }
        fill(rect(20, 3, 8, 5, r: 2), 0xDB9A12)
        fill(rect(16, 6, 16, 6, r: 2), 0xF5B82E)
    }

    /// Save: a floppy disk with a metal shutter and a white label with a yellow band.
    private static func floppy(_ k: CGFloat) {
        let body = NSBezierPath()
        body.move(to: CGPoint(x: 10, y: 6))
        body.line(to: CGPoint(x: 36, y: 6))
        body.line(to: CGPoint(x: 42, y: 12))
        body.line(to: CGPoint(x: 42, y: 39))
        body.appendArc(from: CGPoint(x: 42, y: 42), to: CGPoint(x: 39, y: 42), radius: 3)
        body.line(to: CGPoint(x: 9, y: 42))
        body.appendArc(from: CGPoint(x: 6, y: 42), to: CGPoint(x: 6, y: 39), radius: 3)
        body.line(to: CGPoint(x: 6, y: 9))
        body.appendArc(from: CGPoint(x: 6, y: 6), to: CGPoint(x: 9, y: 6), radius: 3)
        body.close()
        fill(body, 0x8A939C)
        fill(rect(14, 6, 19, 12, r: 1), 0xD9DDE1)
        fill(rect(27, 8.5, 3.5, 7, r: 0.8), 0x8A939C, shade: false)
        fill(rect(11, 23, 26, 19, r: 1.5), 0xFAFAFA)
        fill(rect(11, 23, 26, 5, r: 1.5), 0xF5C431)
        fill(rect(15, 32, 18, 2, r: 1), 0xB8BEC4, shade: false)
        fill(rect(15, 36.5, 12, 2, r: 1), 0xB8BEC4, shade: false)
    }

    /// Copy Text: a blue page of text inside green viewfinder corners.
    private static func scannedPage(_ k: CGFloat) {
        fill(rect(13, 8, 22, 32, r: 2.5), 0x4A8FE0)
        for (i, w) in [14.0, 14, 10, 14, 8].enumerated() {
            fill(rect(17, 13.5 + CGFloat(i) * 4.6, CGFloat(w), 2.2, r: 1.1), 0xF2F6FC, shade: false)
        }
        let corners = NSBezierPath()
        corners.lineWidth = 3
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        let (l, t, r, b, arm): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (6, 4, 42, 44, 8)
        for (x, y, dx, dy) in [(l, t, 1.0, 1.0), (r, t, -1, 1), (l, b, 1, -1), (r, b, -1, -1)] {
            corners.move(to: CGPoint(x: x, y: y + arm * dy))
            corners.line(to: CGPoint(x: x, y: y))
            corners.line(to: CGPoint(x: x + arm * dx, y: y))
        }
        color(0x34C759).setStroke()
        corners.stroke()
        // The scan line.
        fill(rect(9, 25, 30, 2.4, r: 1.2), 0x34C759, shade: false)
    }

    /// Edit: a dotted cup holding a yellow highlighter and a cyan pencil.
    private static func markerCup(_ k: CGFloat) {
        func tilted(_ degrees: CGFloat, around p: CGPoint, _ draw: () -> Void) {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: p.x, yBy: p.y)
            t.rotate(byDegrees: degrees)
            t.translateX(by: -p.x, yBy: -p.y)
            t.concat()
            draw()
            NSGraphicsContext.restoreGraphicsState()
        }
        // Highlighter, leaning left.
        tilted(-10, around: CGPoint(x: 18, y: 26)) {
            fill(polygon([CGPoint(x: 15, y: 9), CGPoint(x: 19, y: 4), CGPoint(x: 22, y: 6), CGPoint(x: 22, y: 9)]), 0x3A3F45)
            fill(rect(14, 9, 9, 6, r: 1), 0x4A5057)
            fill(rect(13, 14, 11, 14, r: 1.5), 0xF5C431)
        }
        // Pencil, leaning right.
        tilted(10, around: CGPoint(x: 30, y: 26)) {
            fill(polygon([CGPoint(x: 27, y: 11), CGPoint(x: 30, y: 3), CGPoint(x: 33, y: 11)]), 0xF0CFA0)
            fill(polygon([CGPoint(x: 29, y: 6.5), CGPoint(x: 30, y: 3), CGPoint(x: 31, y: 6.5)]), 0x3A3F45, shade: false)
            fill(rect(27, 11, 6, 17, r: 0.5), 0x2FBFD6)
        }
        fill(rect(10, 22, 28, 22, r: 3), 0xB4BAC0)
        fill(rect(10, 22, 28, 3, r: 1.5), 0x9CA3AA, shade: false)
        for row in 0..<2 {
            for col in 0..<3 {
                let c = CGPoint(x: 16 + CGFloat(col) * 8, y: 31 + CGFloat(row) * 7)
                fill(NSBezierPath(ovalIn: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)), 0xF4F5F6, shade: false)
            }
        }
    }

    /// More: a grey disc with three dots.
    private static func moreDisc(_ k: CGFloat) {
        fill(NSBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 32, height: 32)), 0xB4BAC0)
        for i in 0..<3 {
            let x = 16.5 + CGFloat(i) * 7.5
            fill(NSBezierPath(ovalIn: CGRect(x: x - 2.6, y: 21.4, width: 5.2, height: 5.2)), 0xFAFAFA, shade: false)
        }
    }
}
