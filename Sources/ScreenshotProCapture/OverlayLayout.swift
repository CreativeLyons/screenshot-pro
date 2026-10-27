import CoreGraphics
import Foundation

/// Placement rules for the overlay's floating parts. Pure, in overlay view coordinates
/// (bottom-left origin, points) of one display.
enum OverlayLayout {
    /// Distance between the cursor and the magnifier.
    static let magnifierOffset: CGFloat = 20
    /// Source pixels across the magnifier (odd, so the cursor pixel is centered).
    static let magnifierSamples = 25
    /// Space kept from the display edges.
    static let margin: CGFloat = 8

    /// Magnifier diameter in points: a fifth of the display's shorter side, within limits,
    /// rounded so every source pixel is a whole number of device pixels wide.
    static func magnifierDiameter(displaySize: CGSize, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        let wanted = min(max(min(displaySize.width, displaySize.height) / 5, 110), 180)
        let cellPixels = max((wanted * s / CGFloat(magnifierSamples)).rounded(), 3)
        return cellPixels / s * CGFloat(magnifierSamples)
    }

    /// Origin for a box of `size` beside the cursor. Tries bottom-right, bottom-left,
    /// top-right, top-left (screen sense: "bottom" is below the cursor), and keeps the first
    /// that fits inside `bounds`; when none fits, the first is clamped into `bounds`.
    static func magnifierOrigin(cursor c: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        let o = magnifierOffset
        let candidates = [
            CGPoint(x: c.x + o, y: c.y - o - size.height),
            CGPoint(x: c.x - o - size.width, y: c.y - o - size.height),
            CGPoint(x: c.x + o, y: c.y + o),
            CGPoint(x: c.x - o - size.width, y: c.y + o),
        ]
        let inner = bounds.insetBy(dx: margin, dy: margin)
        if let fit = candidates.first(where: { inner.contains(CGRect(origin: $0, size: size)) }) {
            return fit
        }
        return clamp(origin: candidates[0], size: size, into: inner)
    }

    /// Origin for the size label of a selection: centered below it, else above it, else
    /// inside its bottom edge; always kept on the display.
    static func sizeLabelOrigin(selection: CGRect, size: CGSize, bounds: CGRect) -> CGPoint {
        let gap: CGFloat = 6
        let inner = bounds.insetBy(dx: margin, dy: margin)
        let x = selection.midX - size.width / 2
        var y = selection.minY - gap - size.height
        if y < inner.minY {
            y = selection.maxY + gap
            if y + size.height > inner.maxY { y = selection.minY + gap }
        }
        return clamp(origin: CGPoint(x: x, y: y), size: size, into: inner)
    }

    /// Origin for a window's title label: just above its top-left corner, else inside it.
    static func windowLabelOrigin(window: CGRect, size: CGSize, bounds: CGRect) -> CGPoint {
        let gap: CGFloat = 6
        let inner = bounds.insetBy(dx: margin, dy: margin)
        var y = window.maxY + gap
        if y + size.height > inner.maxY { y = window.maxY - gap - size.height }
        return clamp(origin: CGPoint(x: window.minX, y: y), size: size, into: inner)
    }

    /// Origin for the hint: centered near the top (below the menu bar), or near the bottom
    /// when the cursor is close to the top position.
    static func hintOrigin(size: CGSize, bounds: CGRect, cursor: CGPoint?) -> CGPoint {
        let top = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 48 - size.height)
        let topRect = CGRect(origin: top, size: size).insetBy(dx: -40, dy: -40)
        if let cursor, topRect.contains(cursor) {
            return CGPoint(x: top.x, y: bounds.minY + 48)
        }
        return top
    }

    /// The square of source pixels the magnifier shows, centered on the cursor pixel, and
    /// the part of it that lies inside the image (to place the visible part correctly).
    static func magnifierSource(pixel: (x: Int, y: Int), imageWidth: Int, imageHeight: Int)
        -> (wanted: CGRect, visible: CGRect) {
        let half = magnifierSamples / 2
        let wanted = CGRect(x: pixel.x - half, y: pixel.y - half, width: magnifierSamples, height: magnifierSamples)
        let visible = wanted.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        return (wanted, visible.isNull ? .zero : visible)
    }

    static func clamp(origin: CGPoint, size: CGSize, into rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, rect.minX), max(rect.maxX - size.width, rect.minX)),
                y: min(max(origin.y, rect.minY), max(rect.maxY - size.height, rect.minY)))
    }
}
