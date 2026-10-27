import CoreGraphics
import Foundation

/// Every conversion between the coordinate spaces the capture module deals with, in one place
/// (docs/ARCHITECTURE.md "Coordinates"):
///
/// - Quartz global points: origin top-left of the primary display, y down. Used for
///   `CaptureDetails.screenRect`, `CGDisplayBounds`, `SCWindow.frame`, window list bounds.
/// - AppKit global points: origin bottom-left of the primary display, y up. Used by
///   `NSScreen.frame`, `NSEvent.mouseLocation` and window frames.
/// - Overlay view points: a non-flipped view covering one display, origin at that display's
///   bottom-left corner (AppKit global minus the screen origin).
/// - Display image pixels: origin top-left of one display's frozen image, points times scale.
///
/// All functions are pure; the primary display height is passed in.
enum CoordinateSpace {
    /// Height of the primary display (the one whose top-left is the Quartz origin).
    static var primaryDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    // MARK: Quartz <-> AppKit (global)

    static func quartzPoint(fromAppKit p: CGPoint, primaryHeight h: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: h - p.y)
    }

    static func appKitPoint(fromQuartz p: CGPoint, primaryHeight h: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: h - p.y)
    }

    static func quartzRect(fromAppKit r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func appKitRect(fromQuartz r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Quartz <-> overlay view (one display)

    /// A Quartz global point in the coordinates of a non-flipped view that covers the display
    /// whose Quartz frame is `display`.
    static func viewPoint(fromQuartz p: CGPoint, display: CGRect) -> CGPoint {
        CGPoint(x: p.x - display.minX, y: display.maxY - p.y)
    }

    static func viewRect(fromQuartz r: CGRect, display: CGRect) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX - display.minX, y: display.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func quartzPoint(fromView p: CGPoint, display: CGRect) -> CGPoint {
        CGPoint(x: p.x + display.minX, y: display.maxY - p.y)
    }

    // MARK: Points <-> pixels

    /// A Quartz global rect in the pixel space of one display image (top-left origin, unrounded).
    static func pixelRect(fromQuartz r: CGRect, display: CGRect, scale: CGFloat) -> CGRect {
        let r = r.standardized
        return CGRect(x: (r.minX - display.minX) * scale, y: (r.minY - display.minY) * scale,
                      width: r.width * scale, height: r.height * scale)
    }

    /// The pixel (column, row) of a display image that lies under a Quartz global point.
    static func pixel(atQuartz p: CGPoint, display: CGRect, scale: CGFloat) -> (x: Int, y: Int) {
        (Int(((p.x - display.minX) * scale).rounded(.down)), Int(((p.y - display.minY) * scale).rounded(.down)))
    }

    /// Rounds each edge to the nearest whole pixel, so neighbouring rects never leave gaps.
    static func integral(_ r: CGRect) -> CGRect {
        let r = r.standardized
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        let x1 = r.maxX.rounded(), y1 = r.maxY.rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Whole-pixel size of a point rect at `scale`.
    static func pixelSize(of r: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        let p = integral(CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale))
        return (Int(p.width), Int(p.height))
    }

    /// The selection between two Quartz points with inclusive corners: the pixel under each
    /// point belongs to the selection, so a zero-length drag selects one pixel. The result is
    /// aligned to the pixel grid of `scale`.
    static func selectionRect(from a: CGPoint, to b: CGPoint, scale: CGFloat) -> CGRect {
        let s = max(scale, 1)
        let x0 = (min(a.x, b.x) * s).rounded(.down)
        let y0 = (min(a.y, b.y) * s).rounded(.down)
        let x1 = (max(a.x, b.x) * s).rounded(.down) + 1
        let y1 = (max(a.y, b.y) * s).rounded(.down) + 1
        return CGRect(x: x0 / s, y: y0 / s, width: (x1 - x0) / s, height: (y1 - y0) / s)
    }

    /// Clamps a point into `rect` (the far edges are kept just inside, half a point in).
    static func clamp(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, rect.minX), rect.maxX - 0.5), y: min(max(p.y, rect.minY), rect.maxY - 0.5))
    }

    /// Backing scale (pixels per point) for an image file's DPI. Only screen-like values
    /// (144 dpi = 2x, 216 dpi = 3x) count; print resolutions such as 300 dpi open at 1x so
    /// scans and photos are not shown tiny.
    static func scale(fromDPI dpi: Double?) -> CGFloat {
        guard let dpi, dpi > 0 else { return 1 }
        let ratio = dpi / 72
        for candidate in [2.0, 3.0] where abs(ratio - candidate) < 0.02 {
            return CGFloat(candidate)
        }
        return 1
    }
}
