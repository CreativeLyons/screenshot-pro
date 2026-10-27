import CoreGraphics
import Foundation

/// Hand-drawn outlines in the spirit of rough.js (the look of Excalidraw): every edge is drawn
/// twice as a slightly bowed curve whose ends wander a little, so corners cross and lines look
/// sketched. The wobble comes from a generator seeded with the element's id, so an element looks
/// the same every time it is drawn, on screen and in the export.
enum SketchPath {
    /// A small deterministic random source (SplitMix64).
    struct Random {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        /// Seeded from a UUID's bytes (FNV-1a), stable across launches.
        init(_ id: UUID) {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            withUnsafeBytes(of: id.uuid) { bytes in
                for b in bytes {
                    h ^= UInt64(b)
                    h = h &* 0x100_0000_01B3
                }
            }
            state = h
        }

        /// In 0..<1.
        mutating func next() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return CGFloat(z >> 11) / CGFloat(1 << 53)
        }

        /// In -amount...amount.
        mutating func offset(_ amount: CGFloat) -> CGFloat { (next() * 2 - 1) * amount }
    }

    /// How far the ends of a stroke may wander, in image pixels, for a line `width` wide.
    static func roughness(width: CGFloat) -> CGFloat { 1.2 + width * 0.45 }

    /// A sketched straight line from `a` to `b`.
    static func line(from a: CGPoint, to b: CGPoint, width: CGFloat, random: inout Random) -> CGPath {
        let path = CGMutablePath()
        addLine(from: a, to: b, width: width, random: &random, to: path)
        return path
    }

    /// A sketched rectangle: four lines, each drawn twice.
    static func rectangle(_ r: CGRect, width: CGFloat, random: inout Random) -> CGPath {
        let path = CGMutablePath()
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        for i in 0..<4 {
            addLine(from: corners[i], to: corners[(i + 1) % 4], width: width, random: &random, to: path)
        }
        return path
    }

    /// A sketched ellipse: two loose loops that start at a random angle and overshoot a little.
    static func ellipse(in r: CGRect, width: CGFloat, random: inout Random) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = r.width / 2, ry = r.height / 2
        guard rx > 0.5, ry > 0.5 else { return CGPath(ellipseIn: r, transform: nil) }
        let wander = min(roughness(width: width), min(rx, ry) * 0.2)
        let steps = 10
        let step = 2 * CGFloat.pi / CGFloat(steps)
        for pass in 0..<2 {
            let scale: CGFloat = pass == 0 ? 1 : 0.6
            let start = random.next() * 2 * .pi
            let prx = rx + random.offset(wander * scale), pry = ry + random.offset(wander * scale)
            let overshoot = step * (0.15 + random.next() * 0.35)
            var points: [CGPoint] = []
            var angle = start
            while angle <= start + 2 * .pi + overshoot {
                let jitter = 1 + random.offset(0.025 * scale)
                points.append(CGPoint(x: c.x + cos(angle) * prx * jitter, y: c.y + sin(angle) * pry * jitter))
                angle += step + random.offset(step * 0.08)
            }
            path.addPath(DocumentRenderer.freehandPath(points))
        }
        return path
    }

    /// The two passes of one sketched line, appended to `path`.
    private static func addLine(from a: CGPoint, to b: CGPoint, width: CGFloat, random: inout Random,
                                to path: CGMutablePath) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.5 else {
            path.move(to: a)
            path.addLine(to: b)
            return
        }
        // Short lines wander less, so a small box keeps its shape.
        let wander = min(roughness(width: width), len * 0.08)
        let normal = CGPoint(x: -dy / len, y: dx / len)
        let bow = min(len * 0.012, wander * 2)
        for pass in 0..<2 {
            let scale: CGFloat = pass == 0 ? 1 : 0.5
            let start = CGPoint(x: a.x + random.offset(wander * scale), y: a.y + random.offset(wander * scale))
            let end = CGPoint(x: b.x + random.offset(wander * scale), y: b.y + random.offset(wander * scale))
            let diverge = 0.2 + random.next() * 0.2
            let bend1 = random.offset(bow), bend2 = random.offset(bow)
            let c1 = CGPoint(x: start.x + (end.x - start.x) * diverge + normal.x * bend1,
                             y: start.y + (end.y - start.y) * diverge + normal.y * bend1)
            let c2 = CGPoint(x: start.x + (end.x - start.x) * 2 * diverge + normal.x * bend2,
                             y: start.y + (end.y - start.y) * 2 * diverge + normal.y * bend2)
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
        }
    }
}
