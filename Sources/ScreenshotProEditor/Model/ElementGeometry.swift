import CoreGraphics
import Foundation

// Small vector helpers used across the editor.
extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    var length: CGFloat { hypot(x, y) }
    func distance(to p: CGPoint) -> CGFloat { (self - p).length }
}

extension CGRect {
    /// Rectangle spanned by two corner points, normalized.
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Distance from `p` to the segment `a`-`b`.
func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let ab = b - a
    let len2 = ab.x * ab.x + ab.y * ab.y
    guard len2 > 0 else { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2))
    return p.distance(to: a + ab * t)
}

/// The 8 resize handles of a rectangle.
enum ResizeHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Position of this handle on `rect`.
    func position(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
        let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }
}

/// A grab point on a selected element.
enum ElementHandle: Equatable, Sendable {
    case resize(ResizeHandle)
    case lineStart
    case lineEnd
    case tail
}

enum ElementGeometry {
    /// A freehand stroke with the jitter taken out: a few passes of a 1-2-1 average that keep the
    /// end points where they were.
    static func smoothed(_ pts: [CGPoint], passes: Int = 2) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out = pts
        for _ in 0..<passes {
            var next = out
            for i in 1..<(out.count - 1) {
                next[i] = (out[i - 1] + out[i] * 2 + out[i + 1]) * 0.25
            }
            out = next
        }
        return out
    }

    /// Selection bounds of an element (image pixels).
    static func bounds(of e: Element) -> CGRect {
        switch e.type {
        case .line, .arrow:
            return CGRect(corner: e.start, e.end)
        case .freehand, .marker:
            guard let first = e.points.first else { return .zero }
            var minP = first, maxP = first
            for p in e.points {
                minP = CGPoint(x: min(minP.x, p.x), y: min(minP.y, p.y))
                maxP = CGPoint(x: max(maxP.x, p.x), y: max(maxP.y, p.y))
            }
            let r = CGRect(corner: minP, maxP)
            let pad = CGFloat(e.style.lineThickness) / 2
            return r.insetBy(dx: -pad, dy: -pad)
        default:
            return e.rect
        }
    }

    /// Handles a selected element offers, with their positions.
    static func handles(of e: Element) -> [(ElementHandle, CGPoint)] {
        switch e.type {
        case .line, .arrow:
            return [(.lineStart, e.start), (.lineEnd, e.end)]
        case .freehand, .marker:
            return []
        case .speechBubble:
            return ResizeHandle.allCases.map { (.resize($0), $0.position(in: e.rect)) } + [(.tail, e.tailTarget)]
        default:
            return ResizeHandle.allCases.map { (.resize($0), $0.position(in: e.rect)) }
        }
    }

    /// The handle of `e` within `radius` of `p`, preferring the tail and end points.
    static func handle(of e: Element, at p: CGPoint, radius: CGFloat) -> ElementHandle? {
        let all = handles(of: e)
        let ordered = all.filter { $0.0 == .tail } + all.filter { $0.0 != .tail }
        for (h, pos) in ordered where abs(pos.x - p.x) <= radius && abs(pos.y - p.y) <= radius {
            return h
        }
        return nil
    }

    /// Whether `p` hits `e`. `tolerance` is extra slack in image pixels (handle and zoom aware).
    static func hitTest(_ e: Element, at p: CGPoint, tolerance: CGFloat = 0) -> Bool {
        let half = CGFloat(e.style.lineThickness) / 2
        switch e.type {
        case .rectangle:
            let r = e.rect
            if e.style.fillColor.isVisible && r.contains(p) { return true }
            let slack = half + 5 + tolerance
            let outer = r.insetBy(dx: -slack, dy: -slack)
            let inner = r.insetBy(dx: slack, dy: slack)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .ellipse:
            let r = e.rect
            let a = max(r.width / 2, 0.5), b = max(r.height / 2, 0.5)
            let dx = (p.x - r.midX) / a, dy = (p.y - r.midY) / b
            let d = (dx * dx + dy * dy).squareRoot()
            if e.style.fillColor.isVisible && d <= 1 { return true }
            return abs(d - 1) * min(a, b) <= half + 5 + tolerance
        case .line:
            return distance(from: p, toSegment: e.start, e.end) <= half + 5 + tolerance
        case .arrow:
            return distance(from: p, toSegment: e.start, e.end) <= half + 10 + tolerance
        case .freehand, .marker:
            let pts = e.points
            guard let first = pts.first else { return false }
            let slack = half + 5 + tolerance
            if pts.count == 1 { return p.distance(to: first) <= slack }
            for i in 1..<pts.count where distance(from: p, toSegment: pts[i - 1], pts[i]) <= slack {
                return true
            }
            return false
        case .speechBubble:
            if e.rect.insetBy(dx: -5 - tolerance, dy: -5 - tolerance).contains(p) { return true }
            return distance(from: p, toSegment: e.rect.center, e.tailTarget) <= 5 + tolerance
        default:
            return e.rect.insetBy(dx: -5 - tolerance, dy: -5 - tolerance).contains(p)
        }
    }

    /// The topmost element hit at `p`, or nil.
    static func topmostHit(in elements: [Element], at p: CGPoint, tolerance: CGFloat = 0) -> Element? {
        elements.last { hitTest($0, at: p, tolerance: tolerance) }
    }

    /// Resizes `rect` by dragging `handle` to `p`. `keepAspect` keeps the original proportions
    /// (choosing the smaller fit), `fromCenter` resizes symmetrically around the center.
    /// Dragging past the opposite edge flips the rectangle (the result stays normalized).
    static func resize(_ rect: CGRect, handle: ResizeHandle, to p: CGPoint,
                       keepAspect: Bool = false, fromCenter: Bool = false) -> CGRect {
        let w0 = max(rect.width, 1), h0 = max(rect.height, 1)
        if handle.isCorner {
            let fixed = fromCenter ? rect.center
                : CGPoint(x: handle.movesLeft ? rect.maxX : rect.minX, y: handle.movesTop ? rect.maxY : rect.minY)
            var dx = p.x - fixed.x, dy = p.y - fixed.y
            if keepAspect {
                let fw = fromCenter ? w0 / 2 : w0, fh = fromCenter ? h0 / 2 : h0
                let s = min(abs(dx) / fw, abs(dy) / fh)
                dx = (dx < 0 ? -1 : 1) * fw * s
                dy = (dy < 0 ? -1 : 1) * fh * s
            }
            if fromCenter {
                return CGRect(corner: fixed - CGPoint(x: dx, y: dy), fixed + CGPoint(x: dx, y: dy))
            }
            return CGRect(corner: fixed, fixed + CGPoint(x: dx, y: dy))
        }
        var r = rect
        if handle.movesLeft || handle.movesRight {
            let fixedX = fromCenter ? rect.midX : (handle.movesLeft ? rect.maxX : rect.minX)
            let dx = p.x - fixedX
            let minX = fromCenter ? fixedX - abs(dx) : min(fixedX, fixedX + dx)
            let width = fromCenter ? abs(dx) * 2 : abs(dx)
            r.origin.x = minX
            r.size.width = width
            if keepAspect {
                let h = width * h0 / w0
                r.origin.y = rect.midY - h / 2
                r.size.height = h
            }
        } else {
            let fixedY = fromCenter ? rect.midY : (handle.movesTop ? rect.maxY : rect.minY)
            let dy = p.y - fixedY
            let minY = fromCenter ? fixedY - abs(dy) : min(fixedY, fixedY + dy)
            let height = fromCenter ? abs(dy) * 2 : abs(dy)
            r.origin.y = minY
            r.size.height = height
            if keepAspect {
                let w = height * w0 / h0
                r.origin.x = rect.midX - w / 2
                r.size.width = w
            }
        }
        return r
    }

    /// Rectangle drawn from `start` to `current`: `square` snaps to the nearest diagonal,
    /// `fromCenter` makes `start` the center.
    static func drawnRect(from start: CGPoint, to current: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = current.x - start.x, dy = current.y - start.y
        if square {
            let s = (abs(dx) + abs(dy)) / 2
            dx = (dx < 0 ? -1 : 1) * s
            dy = (dy < 0 ? -1 : 1) * s
        }
        if fromCenter {
            return CGRect(corner: start - CGPoint(x: dx, y: dy), start + CGPoint(x: dx, y: dy))
        }
        return CGRect(corner: start, start + CGPoint(x: dx, y: dy))
    }

    /// End point of a line from `start` toward `current`, snapped to 15 degree steps when
    /// `snap` is set (keeping the drag length).
    static func lineEnd(from start: CGPoint, to current: CGPoint, snap: Bool) -> CGPoint {
        guard snap else { return current }
        let d = current - start
        let len = d.length
        guard len > 0 else { return current }
        let step = CGFloat.pi / 12
        let angle = (atan2(d.y, d.x) / step).rounded() * step
        return start + CGPoint(x: cos(angle) * len, y: sin(angle) * len)
    }

    /// Applies an affine transform (move, scale, quarter-turn rotation) to an element's geometry.
    static func transform(_ e: Element, by t: CGAffineTransform) -> Element {
        var out = e
        out.rect = e.rect.applying(t).standardized
        out.points = e.points.map { $0.applying(t) }
        return out
    }

    /// Maps an element through a quarter-turn rotation of the image. Upright elements (text,
    /// speech bubbles, counters, images) move to the rotated position of their center and keep
    /// their size; a bubble's tail target rotates with the image. Everything else rotates.
    static func rotated(_ e: Element, by t: CGAffineTransform) -> Element {
        guard e.type.staysUpright else { return transform(e, by: t) }
        var out = e
        let center = e.rect.center.applying(t)
        out.rect = CGRect(x: center.x - e.rect.width / 2, y: center.y - e.rect.height / 2,
                          width: e.rect.width, height: e.rect.height)
        out.points = e.points.map { $0.applying(t) }
        return out
    }

    /// Moves an element by `delta`.
    static func moved(_ e: Element, by delta: CGPoint) -> Element {
        transform(e, by: CGAffineTransform(translationX: delta.x, y: delta.y))
    }

    /// Sets the selection bounds of an element to `newBounds`, scaling its points (used by
    /// keyboard resizing and paste fitting).
    static func withBounds(_ e: Element, _ newBounds: CGRect) -> Element {
        let old = bounds(of: e)
        guard e.type.isBoxed || old.width > 0 || old.height > 0 else { return e }
        if e.type.isBoxed {
            var out = e
            if e.type == .speechBubble {
                out.tailTarget = e.tailTarget + CGPoint(x: newBounds.midX - old.midX, y: newBounds.midY - old.midY)
            }
            out.rect = newBounds
            return out
        }
        let sx = old.width > 0 ? newBounds.width / old.width : 1
        let sy = old.height > 0 ? newBounds.height / old.height : 1
        let t = CGAffineTransform(translationX: newBounds.minX, y: newBounds.minY)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -old.minX, y: -old.minY)
        var out = e
        out.points = e.points.map { $0.applying(t) }
        return out
    }
}
