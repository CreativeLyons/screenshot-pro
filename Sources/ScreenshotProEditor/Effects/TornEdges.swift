import CoreGraphics
import ScreenshotProCore

/// Torn edges: a random jagged outline clips the image, then optional shadow and background.
enum TornEdges {
    /// The closed outline (image pixels, top-left origin, clockwise from the top-left corner).
    static func outline(width: Int, height: Int, settings: TornEdgeSettings, rng: inout SplitMix64) -> [CGPoint] {
        let w = CGFloat(width), h = CGFloat(height)
        // Teeth deeper than a third of the short side would make opposite edges cross.
        let maxDepth = max(0, min(settings.toothHeight, min(width, height) / 3))
        let hRange = max(2, settings.horizontalToothRange)
        let vRange = max(2, settings.verticalToothRange)
        func depth(_ torn: Bool) -> CGFloat {
            guard torn, maxDepth > 0 else { return 0 }
            return CGFloat(rng.int(in: 1...maxDepth))
        }
        let s = settings
        var points: [CGPoint] = []

        points.append(CGPoint(x: depth(s.left), y: depth(s.top)))
        if s.top {
            for x in stride(from: hRange, to: width, by: hRange) {
                points.append(CGPoint(x: CGFloat(x), y: depth(true)))
            }
        }
        points.append(CGPoint(x: w - depth(s.right), y: depth(s.top)))
        if s.right {
            for y in stride(from: vRange, to: height, by: vRange) {
                points.append(CGPoint(x: w - depth(true), y: CGFloat(y)))
            }
        }
        points.append(CGPoint(x: w - depth(s.right), y: h - depth(s.bottom)))
        if s.bottom {
            for x in stride(from: hRange, to: width, by: hRange).reversed() {
                points.append(CGPoint(x: CGFloat(x), y: h - depth(true)))
            }
        }
        points.append(CGPoint(x: depth(s.left), y: h - depth(s.bottom)))
        if s.left {
            for y in stride(from: vRange, to: height, by: vRange).reversed() {
                points.append(CGPoint(x: depth(true), y: CGFloat(y)))
            }
        }
        return points
    }

    static func apply(_ image: CGImage, _ settings: TornEdgeSettings) -> (CGImage, EffectGeometry) {
        let w = image.width, h = image.height
        let seed = settings.seed != 0 ? settings.seed : UInt64.random(in: 1...UInt64.max)
        var rng = SplitMix64(seed: seed)
        let points = outline(width: w, height: h, settings: settings, rng: &rng)

        guard let ctx = EffectsBitmap.makeContext(width: w, height: h) else {
            return (ImageEffectsEngine.standardized(image), .identity)
        }
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) })
        path.closeSubpath()
        ctx.setShouldAntialias(true)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: EffectsBitmap.bounds(of: image))
        guard var result = ctx.makeImage() else { return (ImageEffectsEngine.standardized(image), .identity) }

        var geometry = EffectGeometry.identity
        if settings.generateShadow {
            (result, geometry) = ImageEffectsEngine.dropShadow(result, settings.shadow)
        }
        if settings.backgroundColor.alpha > 0,
           let bg = EffectsBitmap.makeContext(width: result.width, height: result.height) {
            EffectsBitmap.fill(bg, color: settings.backgroundColor)
            bg.draw(result, in: EffectsBitmap.bounds(of: result))
            if let flattened = bg.makeImage() { result = flattened }
        }
        return (result, geometry)
    }
}
