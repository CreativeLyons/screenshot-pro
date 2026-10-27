import CoreGraphics
import CoreText
import Foundation
import ScreenshotProCore

/// Options for one render pass.
struct RenderOptions {
    /// Filter elements drawn as a dotted border only (while they are drawn or moved).
    var borderOnlyFilters: Set<UUID> = []
    /// Text/bubble elements whose text is not drawn (the inline editor shows it instead).
    var hiddenText: Set<UUID> = []
    /// Draw the base image (off when only the elements are wanted).
    var drawBaseImage = true
    /// Interpolation for bitmaps (nearest neighbor when zoomed in on screen).
    var interpolation: CGInterpolationQuality = .high
}

/// Draws a document into any Core Graphics context whose user space is image pixels with a
/// top-left origin (y down). Used for the screen and for the flattened export, so they match.
enum DocumentRenderer {
    /// MediumSeaGreen dotted border used for filters being edited.
    static let editBorderColor = CGColor(srgbRed: 60 / 255, green: 179 / 255, blue: 113 / 255, alpha: 1)

    // MARK: Entry points

    static func draw(_ doc: EditorDocument, in ctx: CGContext, options: RenderOptions = RenderOptions(),
                     cache: FilterCache? = nil) {
        ctx.saveGState()
        ctx.interpolationQuality = options.interpolation
        ctx.setShouldAntialias(true)
        if options.drawBaseImage {
            drawImage(doc.image, in: doc.bounds, context: ctx)
        }
        let numbers = doc.counterNumbers()
        let isOutside: (Element) -> Bool = { $0.type == .highlight && $0.style.highlightMode.affectsOutside }
        let outside = doc.elements.filter(isOutside).map { $0.rect }
        // Area and grayscale highlights repaint the whole base image outside their rectangles,
        // so they go first: drawn in z-order they would hide every annotation beneath them.
        for e in doc.elements.filter(isOutside) + doc.elements.filter({ !isOutside($0) }) {
            drawElement(e, document: doc, in: ctx, options: options, cache: cache,
                        counterNumber: numbers[e.id], outsideHighlightRects: outside)
        }
        ctx.restoreGState()
    }

    /// Base image plus elements at full pixel resolution, in the image's color space.
    static func flatten(_ doc: EditorDocument, cache: FilterCache? = nil) -> CGImage? {
        let w = doc.image.width, h = doc.image.height
        guard w > 0, h > 0, let ctx = makeContext(width: w, height: h, like: doc.image) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(doc, in: ctx, cache: cache)
        return ctx.makeImage()
    }

    /// An RGBA bitmap context (premultiplied alpha) in the image's RGB color space, or sRGB.
    static func makeContext(width: Int, height: Int, like image: CGImage? = nil) -> CGContext? {
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let s = image?.colorSpace, s.model == .rgb, s.supportsOutput { space = s }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws a CGImage upright into `rect` of a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: Shadow

    /// The shadow convention (02 section 2.4): the outline drawn 5 extra times in black, each
    /// one pixel further down-right, opacity starting at 100/255 and decreasing evenly.
    static func shadowPasses(_ body: (_ offset: CGFloat, _ alpha: CGFloat) -> Void) {
        for i in 0..<5 {
            body(CGFloat(i + 1), CGFloat(100 - i * 20) / 255)
        }
    }

    private static func strokeShadow(_ path: CGPath, width: CGFloat, in ctx: CGContext,
                                     cap: CGLineCap = .butt, join: CGLineJoin = .miter, fill: CGPath? = nil) {
        shadowPasses { offset, alpha in
            ctx.saveGState()
            ctx.translateBy(x: offset, y: offset)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: alpha))
            ctx.setLineWidth(width)
            ctx.setLineCap(cap)
            ctx.setLineJoin(join)
            ctx.addPath(path)
            ctx.strokePath()
            if let fill {
                ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
                ctx.addPath(fill)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
    }

    // MARK: Elements

    static func drawElement(_ e: Element, document doc: EditorDocument, in ctx: CGContext,
                            options: RenderOptions = RenderOptions(), cache: FilterCache? = nil,
                            counterNumber: Int? = nil, outsideHighlightRects: [CGRect] = []) {
        let s = e.style
        let lineWidth = CGFloat(s.lineThickness)
        let lineVisible = lineWidth > 0 && s.lineColor.isVisible
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch e.type {
        case .rectangle, .ellipse:
            let path = e.type == .rectangle ? CGPath(rect: e.rect, transform: nil)
                : CGPath(ellipseIn: e.rect, transform: nil)
            var random = SketchPath.Random(e.id)
            let outline = !s.sketchy ? path : e.type == .rectangle
                ? SketchPath.rectangle(e.rect, width: lineWidth, random: &random)
                : SketchPath.ellipse(in: e.rect, width: lineWidth, random: &random)
            let cap: CGLineCap = s.sketchy ? .round : .butt
            if s.shadow && lineVisible { strokeShadow(outline, width: lineWidth, in: ctx, cap: cap) }
            if s.fillColor.isVisible {
                ctx.setFillColor(s.fillColor.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
            if lineVisible { stroke(outline, color: s.lineColor, width: lineWidth, in: ctx, cap: cap) }

        case .line:
            guard lineVisible else { return }
            var random = SketchPath.Random(e.id)
            let path = s.sketchy ? SketchPath.line(from: e.start, to: e.end, width: lineWidth, random: &random)
                : CGPath.line(e.start, e.end)
            if s.shadow { strokeShadow(path, width: lineWidth, in: ctx, cap: .round) }
            stroke(path, color: s.lineColor, width: lineWidth, in: ctx, cap: .round)

        case .arrow where s.sketchy:
            guard lineVisible else { return }
            let path = sketchedArrow(e)
            if s.shadow { strokeShadow(path, width: lineWidth, in: ctx, cap: .round, join: .round) }
            stroke(path, color: s.lineColor, width: lineWidth, in: ctx, cap: .round, join: .round)

        case .arrow:
            guard lineVisible else { return }
            let (line, heads) = arrowPaths(e)
            if s.shadow { strokeShadow(line, width: lineWidth, in: ctx, cap: .round, fill: heads) }
            stroke(line, color: s.lineColor, width: lineWidth, in: ctx, cap: .round)
            ctx.setFillColor(s.lineColor.cgColor)
            ctx.addPath(heads)
            ctx.fillPath()

        case .freehand:
            guard lineVisible else { return }
            stroke(freehandPath(e.points), color: s.lineColor, width: lineWidth, in: ctx, cap: .round, join: .round)

        case .marker:
            guard lineVisible else { return }
            // One translucent layer, so the stroke crossing itself does not get darker.
            ctx.setAlpha(markerOpacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            stroke(freehandPath(e.points), color: s.lineColor.opaque, width: lineWidth, in: ctx,
                   cap: .round, join: .round)
            ctx.endTransparencyLayer()

        case .text:
            let border = CGPath(rect: e.rect, transform: nil)
            if s.shadow && lineVisible { strokeShadow(border, width: lineWidth, in: ctx) }
            if s.fillColor.isVisible {
                ctx.setFillColor(s.fillColor.cgColor)
                ctx.fill(e.rect)
            }
            if lineVisible { stroke(border, color: s.lineColor, width: lineWidth, in: ctx) }
            if !options.hiddenText.contains(e.id) {
                drawText(e, in: textRect(e), shadow: s.shadow && !s.fillColor.isVisible, context: ctx)
            }

        case .speechBubble:
            let path = bubblePath(e)
            if s.shadow && lineVisible { strokeShadow(path, width: lineWidth, in: ctx, join: .round) }
            if s.fillColor.isVisible {
                ctx.setFillColor(s.fillColor.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
            if lineVisible { stroke(path, color: s.lineColor, width: lineWidth, in: ctx, join: .round) }
            if !options.hiddenText.contains(e.id) {
                drawText(e, in: textRect(e), shadow: s.shadow && !s.fillColor.isVisible, context: ctx)
            }

        case .counter:
            let number = counterNumber ?? doc.counterStart
            drawCounter(e, number: number, index: number - doc.counterStart, in: ctx)

        case .highlight, .obfuscate:
            if options.borderOnlyFilters.contains(e.id) {
                drawDottedBorder(e.rect, in: ctx)
            } else {
                drawFilter(e, document: doc, in: ctx, cache: cache, outsideRects: outsideHighlightRects)
            }

        case .image:
            if let img = e.image?.cgImage { drawImage(img, in: e.rect, context: ctx) }
        }
    }

    private static func stroke(_ path: CGPath, color: RGBAColor, width: CGFloat, in ctx: CGContext,
                               cap: CGLineCap = .butt, join: CGLineJoin = .miter) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineJoin(join)
        ctx.addPath(path)
        ctx.strokePath()
    }

    static func drawDottedBorder(_ rect: CGRect, in ctx: CGContext, width: CGFloat = 1) {
        ctx.saveGState()
        ctx.setStrokeColor(editBorderColor)
        ctx.setLineWidth(width)
        ctx.setLineDash(phase: 0, lengths: [width, 2 * width])
        ctx.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
        ctx.restoreGState()
    }

    // MARK: Arrow

    /// The arrow's shaft and its head triangles. A head is a filled triangle about 4 x the line
    /// thickness wide and 6 x long, with the tip on the end point.
    static func arrowPaths(_ e: Element) -> (line: CGPath, heads: CGPath) {
        let t = max(CGFloat(e.style.lineThickness), 1)
        let a = e.start, b = e.end
        let d = b - a
        let len = d.length
        let line = CGMutablePath()
        let heads = CGMutablePath()
        guard len > 0 else {
            line.move(to: a)
            line.addLine(to: b)
            return (line, heads)
        }
        let u = CGPoint(x: d.x / len, y: d.y / len)
        let n = CGPoint(x: -u.y, y: u.x)
        let headLen = min(6 * t, len * (e.style.arrowHeads == .both ? 0.5 : 1))
        let headHalf = 2 * t
        func addHead(tip: CGPoint, dir: CGPoint) {
            let base = tip - dir * headLen
            heads.move(to: tip)
            heads.addLine(to: base + n * headHalf)
            heads.addLine(to: base - n * headHalf)
            heads.closeSubpath()
        }
        var from = a, to = b
        if e.style.arrowHeads.atEnd {
            addHead(tip: b, dir: u)
            to = b - u * (headLen * 0.9)
        }
        if e.style.arrowHeads.atStart {
            addHead(tip: a, dir: u * -1)
            from = a + u * (headLen * 0.9)
        }
        line.move(to: from)
        line.addLine(to: to)
        return (line, heads)
    }

    // MARK: Sketched arrow

    /// A hand-drawn arrow: a sketched shaft with open "V" heads, like Excalidraw's.
    static func sketchedArrow(_ e: Element) -> CGPath {
        let t = max(CGFloat(e.style.lineThickness), 1)
        let a = e.start, b = e.end
        let d = b - a
        let len = d.length
        var random = SketchPath.Random(e.id)
        let path = CGMutablePath()
        path.addPath(SketchPath.line(from: a, to: b, width: t, random: &random))
        guard len > 0 else { return path }
        let u = CGPoint(x: d.x / len, y: d.y / len)
        let n = CGPoint(x: -u.y, y: u.x)
        let headLen = min(max(5 * t, 12), len * (e.style.arrowHeads == .both ? 0.4 : 0.6))
        func addHead(tip: CGPoint, dir: CGPoint) {
            let base = tip - dir * headLen
            path.addPath(SketchPath.line(from: tip, to: base + n * (headLen * 0.55), width: t, random: &random))
            path.addPath(SketchPath.line(from: tip, to: base - n * (headLen * 0.55), width: t, random: &random))
        }
        if e.style.arrowHeads.atEnd { addHead(tip: b, dir: u) }
        if e.style.arrowHeads.atStart { addHead(tip: a, dir: u * -1) }
        return path
    }

    // MARK: Freehand

    /// The marker (highlighter) draws its color at this opacity.
    static let markerOpacity: CGFloat = 0.4

    /// A smooth curve through the kept points (Catmull-Rom converted to cubic Beziers).
    static func freehandPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first)
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = p1 + (p2 - p0) * (1.0 / 6)
            let c2 = p2 - (p3 - p1) * (1.0 / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    // MARK: Text and speech bubble

    /// Text area of a text box or bubble: the rect inset by half the border.
    static func textRect(_ e: Element) -> CGRect {
        let inset = CGFloat(e.style.lineThickness) / 2 + (e.type == .speechBubble ? 4 : 2)
        return e.rect.insetBy(dx: inset, dy: inset)
    }

    /// Text that does not fit is clipped to the element's box instead of spilling over.
    private static func drawText(_ e: Element, in rect: CGRect, shadow: Bool, context ctx: CGContext) {
        guard !e.text.isEmpty, e.style.lineColor.isVisible else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: e.rect)
        let font = TextLayout.font(for: e.style)
        if shadow {
            shadowPasses { offset, alpha in
                let s = TextLayout.attributed(e.text, font: font, color: CGColor(gray: 0, alpha: alpha),
                                              alignment: e.style.horizontalAlignment)
                TextLayout.draw(s, in: rect.offsetBy(dx: offset, dy: offset), vertical: e.style.verticalAlignment,
                                context: ctx)
            }
        }
        let s = TextLayout.attributed(e.text, font: font, color: e.style.lineColor.cgColor,
                                      alignment: e.style.horizontalAlignment)
        TextLayout.draw(s, in: rect, vertical: e.style.verticalAlignment, context: ctx)
    }

    /// Rounded bubble (corner radius min(30, half the smaller side minus the line thickness))
    /// joined with a triangular tail from the center toward the tail target.
    static func bubblePath(_ e: Element) -> CGPath {
        let r = e.rect
        let t = CGFloat(e.style.lineThickness)
        let radius = min(30, min(r.width, r.height) / 2 - t)
        let body: CGPath = radius > 0
            ? CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            : CGPath(rect: r, transform: nil)
        let target = e.tailTarget
        let c = r.center
        let d = target - c
        let len = d.length
        guard len > 1, !r.contains(target) else { return body }
        let baseHalf = min((r.width + r.height) / 20, r.width / 2, r.height / 2) / 2
        let n = CGPoint(x: -d.y / len, y: d.x / len)
        let tail = CGMutablePath()
        tail.move(to: c + n * baseHalf)
        tail.addLine(to: target)
        tail.addLine(to: c - n * baseHalf)
        tail.closeSubpath()
        return body.union(tail)
    }

    // MARK: Counter

    private static func drawCounter(_ e: Element, number: Int, index: Int, in ctx: CGContext) {
        let r = e.rect
        var s = e.style
        if s.cycleColors {
            // Each number takes the next palette color, with dark ink on the light ones.
            s.fillColor = CounterColors.color(at: index)
            s.lineColor = s.fillColor.luminance > 0.68 ? Palette.ink : .white
        }
        if s.fillColor.isVisible {
            ctx.setFillColor(s.fillColor.cgColor)
            ctx.fillEllipse(in: r)
        }
        if s.lineThickness > 0 && s.lineColor.isVisible {
            ctx.setStrokeColor(s.lineColor.cgColor)
            ctx.setLineWidth(CGFloat(s.lineThickness))
            ctx.strokeEllipse(in: r)
        }
        guard s.lineColor.isVisible, r.width > 2, r.height > 2 else { return }
        let text = String(number)
        // Fit the number into about 70% of the circle.
        var size = Double(min(r.width, r.height)) * 0.7
        var font = TextLayout.font(name: s.fontName, size: size, bold: true, italic: false)
        var natural = TextLayout.suggestedSize(
            TextLayout.attributed(text, font: font, color: s.lineColor.cgColor, alignment: .center),
            width: .greatestFiniteMagnitude)
        let limit = min(r.width, r.height) * 0.7
        if natural.width > limit || natural.height > limit {
            size *= Double(min(limit / max(natural.width, 1), limit / max(natural.height, 1)))
            font = TextLayout.font(name: s.fontName, size: size, bold: true, italic: false)
            natural = TextLayout.suggestedSize(
                TextLayout.attributed(text, font: font, color: s.lineColor.cgColor, alignment: .center),
                width: .greatestFiniteMagnitude)
        }
        let attr = TextLayout.attributed(text, font: font, color: s.lineColor.cgColor, alignment: .center)
        let box = CGRect(x: r.midX - natural.width / 2 - 2, y: r.midY - natural.height / 2,
                         width: natural.width + 4, height: natural.height)
        TextLayout.draw(attr, in: box, vertical: .middle, context: ctx)
    }

    // MARK: Filters

    /// The filter area clipped to the image, in whole pixels.
    static func filterRect(_ e: Element, in doc: EditorDocument) -> CGRect {
        let r = e.rect.integral.intersection(doc.bounds)
        return r.isNull ? .zero : r
    }

    private static func drawFilter(_ e: Element, document doc: EditorDocument, in ctx: CGContext,
                                   cache: FilterCache?, outsideRects: [CGRect]) {
        let s = e.style
        let image = doc.image
        func cached(_ kind: String, _ rect: CGRect, _ p1: Double = 0, _ p2: Double = 0,
                    _ make: () -> CGImage?) -> CGImage? {
            if let cache { return cache.result(source: image, kind: kind, rect: rect, p1: p1, p2: p2, make: make) }
            return make()
        }
        if e.type == .highlight && s.highlightMode.affectsOutside {
            // Everything outside all outside-highlight rectangles changes.
            let full = doc.bounds
            let filtered: CGImage?
            if s.highlightMode == .area {
                filtered = cached("area", e.rect.integral, s.brightness, s.blurRadius) {
                    RegionFilters.areaHighlight(image, keep: e.rect.integral, brightness: s.brightness,
                                                blurRadius: s.blurRadius)
                }
            } else {
                filtered = cached("gray-all", full) { RegionFilters.grayscale(image, rect: full) }
            }
            guard let filtered else { return }
            var clip = CGPath(rect: full, transform: nil)
            for r in outsideRects { clip = clip.subtracting(CGPath(rect: r, transform: nil)) }
            ctx.addPath(clip)
            ctx.clip()
            drawImage(filtered, in: full, context: ctx)
            return
        }
        let rect = filterRect(e, in: doc)
        guard rect.width >= 1, rect.height >= 1 else { return }
        switch (e.type, s.highlightMode, s.obfuscateMode) {
        case (.highlight, .text, _):
            ctx.setBlendMode(.darken)
            ctx.setFillColor(s.fillColor.cgColor)
            ctx.fill(rect)
        case (.highlight, .magnify, _):
            if let img = cached("magnify", rect, s.magnification, 0, {
                RegionFilters.magnify(image, rect: rect, factor: max(s.magnification, 1))
            }) {
                ctx.interpolationQuality = .none
                drawImage(img, in: rect, context: ctx)
            }
        case (.obfuscate, _, .pixelate):
            let cell = Int(min(Double(min(rect.width, rect.height)), s.pixelSize.rounded()))
            guard cell > 1 else { return }
            if let img = cached("pixelate", rect, Double(cell), 0, {
                RegionFilters.pixelate(image, rect: rect, cellSize: cell)
            }) {
                drawImage(img, in: rect, context: ctx)
            }
        case (.obfuscate, _, .blur):
            guard s.blurRadius > 0 else { return }
            if let img = cached("blur", rect, s.blurRadius, 0, {
                RegionFilters.blur(image, rect: rect, radius: s.blurRadius)
            }) {
                drawImage(img, in: rect, context: ctx)
            }
        default:
            break
        }
    }
}

extension CGPath {
    static func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }
}

extension RGBAColor {
    /// The color with full alpha.
    var opaque: RGBAColor { RGBAColor(red: red, green: green, blue: blue) }
}
