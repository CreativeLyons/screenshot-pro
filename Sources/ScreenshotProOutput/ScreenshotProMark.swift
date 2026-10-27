import AppKit

/// The app's mark: four viewfinder corner brackets framing a small camera, as a template image.
/// The menu bar icon and the recent screenshots tab use it.
@MainActor
public enum ScreenshotProMark {
    /// The mark at `height` points (width is 22/18 of it).
    public static func image(height: CGFloat = 18) -> NSImage {
        let k = height / 18
        let size = CGSize(width: 22 * k, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let frame = CGRect(x: 2 * k, y: 1 * k, width: 18 * k, height: 16 * k)
            corners(in: frame, k: k).stroke()
            drawCamera(center: CGPoint(x: frame.midX, y: frame.midY), k: k, in: size)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Screenshot Pro"
        return image
    }

    private static func corners(in rect: CGRect, k: CGFloat) -> NSBezierPath {
        let lineWidth = 1.6 * k
        let arm = 4.5 * k
        let radius = 2.4 * k
        let p = NSBezierPath()
        p.lineWidth = lineWidth
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        let b = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        // Each corner: start on the horizontal arm, round the corner, end on the vertical arm.
        for (corner, dx, dy) in [
            (CGPoint(x: b.minX, y: b.maxY), 1.0, -1.0),
            (CGPoint(x: b.maxX, y: b.maxY), -1.0, -1.0),
            (CGPoint(x: b.minX, y: b.minY), 1.0, 1.0),
            (CGPoint(x: b.maxX, y: b.minY), -1.0, 1.0),
        ] {
            let end = CGPoint(x: corner.x, y: corner.y + dy * arm)
            p.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            p.appendArc(from: corner, to: end, radius: radius)
            p.line(to: end)
        }
        return p
    }

    /// A filled camera body with a raised viewfinder hump and the lens punched out.
    private static func drawCamera(center c: CGPoint, k: CGFloat, in size: CGSize) {
        let body = CGRect(x: c.x - 4.6 * k, y: c.y - 3.3 * k, width: 9.2 * k, height: 6.2 * k)
        let lens = CGRect(x: c.x - 1.8 * k, y: body.midY - 1.8 * k, width: 3.6 * k, height: 3.6 * k)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: CGRect(origin: .zero, size: size))
        clip.append(NSBezierPath(ovalIn: lens))
        clip.windingRule = .evenOdd
        clip.addClip()
        NSBezierPath(roundedRect: body, xRadius: 1.4 * k, yRadius: 1.4 * k).fill()
        NSBezierPath(roundedRect: CGRect(x: c.x - 1.9 * k, y: body.maxY - 0.8 * k, width: 3.8 * k, height: 2 * k),
                     xRadius: 0.6 * k, yRadius: 0.6 * k).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
