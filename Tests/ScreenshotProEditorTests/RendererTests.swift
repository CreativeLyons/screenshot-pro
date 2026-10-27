import CoreGraphics
import XCTest
import ScreenshotProCore
@testable import ScreenshotProEditor

final class RendererTests: XCTestCase {
    private func flatten(_ doc: EditorDocument, options: RenderOptions = RenderOptions()) -> Pixels {
        let ctx = DocumentRenderer.makeContext(width: doc.image.width, height: doc.image.height)!
        ctx.translateBy(x: 0, y: CGFloat(doc.image.height))
        ctx.scaleBy(x: 1, y: -1)
        DocumentRenderer.draw(doc, in: ctx, options: options)
        return Pixels(ctx.makeImage()!)
    }

    private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 250 && p.g > 250 && p.b > 250
    }

    func testRectangleOutline() throws {
        var doc = makeDocument(width: 20, height: 20)
        var e = box(.rectangle, rect(5, 5, 10, 10))
        e.style.lineColor = .red
        e.style.lineThickness = 2
        e.style.fillColor = .clear
        e.style.shadow = false
        doc.add(e)
        let image = try XCTUnwrap(DocumentRenderer.flatten(doc))
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 20)
        let px = Pixels(image)
        let edge = px[5, 10]
        XCTAssertEqual(edge.r, 255)
        XCTAssertLessThan(edge.g, 30)
        XCTAssertLessThan(edge.b, 30)
        XCTAssertTrue(isWhite(px[10, 10]), "unfilled inside stays white")
        XCTAssertTrue(isWhite(px[1, 1]))
        XCTAssertTrue(isWhite(px[18, 18]))
    }

    func testTopLeftOrigin() {
        var doc = makeDocument(width: 20, height: 20)
        var e = box(.rectangle, rect(0, 0, 10, 4))
        e.style.lineThickness = 0
        e.style.fillColor = RGBAColor(red: 0, green: 0, blue: 1)
        e.style.shadow = false
        doc.add(e)
        let px = flatten(doc)
        XCTAssertEqual(px[2, 1].b, 255, "element y = 0 is the top row")
        XCTAssertLessThan(px[2, 1].r, 10)
        XCTAssertTrue(isWhite(px[2, 18]))
    }

    func testShadowDarkensBelowRight() {
        var doc = makeDocument(width: 30, height: 30)
        var e = box(.rectangle, rect(5, 5, 12, 12))
        e.style.lineThickness = 2
        e.style.fillColor = .clear
        e.style.shadow = true
        doc.add(e)
        let withShadow = flatten(doc)
        let below = withShadow[11, 20]
        XCTAssertFalse(isWhite(below), "shadow under the bottom edge")
        XCTAssertEqual(below.r, below.g, "the shadow is gray")
        XCTAssertTrue(isWhite(withShadow[11, 2]), "no shadow above")

        doc.update(doc.elements[0].id) { $0.style.shadow = false }
        XCTAssertTrue(isWhite(flatten(doc)[11, 20]))
    }

    func testFilledEllipse() {
        var doc = makeDocument(width: 20, height: 20)
        var e = box(.ellipse, rect(0, 0, 20, 20))
        e.style.lineThickness = 0
        e.style.fillColor = .black
        e.style.shadow = false
        doc.add(e)
        let px = flatten(doc)
        XCTAssertLessThan(px[10, 10].r, 5)
        XCTAssertTrue(isWhite(px[0, 0]), "corners outside the ellipse")
    }

    func testLineAndArrowDraw() {
        var doc = makeDocument(width: 40, height: 20)
        var l = line(.arrow, from: CGPoint(x: 2, y: 10), to: CGPoint(x: 38, y: 10))
        l.style.lineThickness = 2
        l.style.shadow = false
        l.style.sketchy = false
        l.style.lineColor = .black
        doc.add(l)
        let px = flatten(doc)
        XCTAssertLessThan(px[10, 10].r, 30, "shaft")
        XCTAssertLessThan(px[29, 12].r, 80, "the head is wider than the line")
        XCTAssertTrue(isWhite(px[10, 14]), "the shaft is thin")
    }

    func testTextHighlightDarkens() {
        var doc = makeDocument(width: 20, height: 20)
        var h = box(.highlight, rect(2, 2, 10, 10))
        h.style.highlightMode = .text
        h.style.fillColor = .yellow
        doc.add(h)
        let px = flatten(doc)
        XCTAssertEqual(px[5, 5].r, 255)
        XCTAssertEqual(px[5, 5].g, 255)
        XCTAssertLessThan(px[5, 5].b, 5)
        XCTAssertTrue(isWhite(px[15, 15]))
    }

    func testOutsideHighlightDoesNotHideEarlierElements() {
        var doc = makeDocument(width: 30, height: 30)
        var r = box(.rectangle, rect(2, 2, 8, 8))
        r.style.lineThickness = 0
        r.style.fillColor = .red
        r.style.shadow = false
        doc.add(r)
        var h = box(.highlight, rect(18, 18, 8, 8))
        h.style.highlightMode = .grayscale
        doc.add(h)
        let px = flatten(doc)
        XCTAssertEqual(px[5, 5].r, 255, "the rectangle under a later grayscale highlight stays visible")
        XCTAssertLessThan(px[5, 5].g, 10)
    }

    func testFilterDrawnAsBorderOnlyWhileEditing() {
        // Border-only mode must not run the region filter (it is a stub in this module's tests).
        var doc = makeDocument(width: 30, height: 30)
        let o = doc.add(box(.obfuscate, rect(5, 5, 20, 20)))
        var options = RenderOptions()
        options.borderOnlyFilters = [o.id]
        let px = flatten(doc, options: options)
        XCTAssertTrue(isWhite(px[15, 15]), "inside untouched")
        XCTAssertFalse(isWhite(px[5, 15]) && isWhite(px[5, 16]) && isWhite(px[5, 17]), "dotted border drawn")
    }

    func testCounterCircleAndHiddenFilterlessElements() {
        var doc = makeDocument(width: 40, height: 40)
        doc.add(box(.counter, rect(5, 5, 30, 30)))
        let px = flatten(doc)
        let ring = px[9, 20]
        XCTAssertGreaterThan(ring.r, 200)
        XCTAssertLessThan(ring.g, 140, "the first rainbow number is red")
        XCTAssertTrue(isWhite(px[1, 1]))
    }

    func testRainbowCountersTakeTheNextColor() {
        var doc = makeDocument(width: 80, height: 40)
        doc.add(box(.counter, rect(0, 5, 30, 30)))
        doc.add(box(.counter, rect(40, 5, 30, 30)))
        let px = flatten(doc)
        let first = px[4, 20], second = px[44, 20]
        XCTAssertNotEqual(first.g, second.g, "1 and 2 differ")
        XCTAssertGreaterThan(second.g, 140, "the second is orange")
        XCTAssertEqual(CounterColors.color(at: 8), CounterColors.color(at: 0), "the colors repeat")
    }

    func testSketchyLinesAreStableAndWobble() {
        var doc = makeDocument(width: 60, height: 60)
        var r = box(.rectangle, rect(10, 10, 40, 40))
        r.style.lineColor = .black
        r.style.lineThickness = 2
        doc.add(r)
        XCTAssertTrue(r.style.sketchy, "new rectangles are hand-drawn")
        let a = flatten(doc), b = flatten(doc)
        XCTAssertEqual(a[10, 30].r, b[10, 30].r, "the same element draws the same way every time")
        var dark = 0
        for y in 0..<60 { for x in 0..<60 where a[x, y].r < 128 { dark += 1 } }
        XCTAssertGreaterThan(dark, 100, "the outline is drawn")
    }

    func testMarkerIsTranslucent() {
        var doc = makeDocument(width: 40, height: 20)
        var m = Element(type: .marker, points: [CGPoint(x: 4, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 36, y: 10)])
        m.style.lineColor = .black
        m.style.lineThickness = 8
        doc.add(m)
        let px = flatten(doc)
        let mid = px[20, 10].r
        XCTAssertGreaterThan(mid, 100, "not opaque")
        XCTAssertLessThan(mid, 200, "but visible")
    }

    func testMarkerBandCoversTouchedWords() {
        let line = MarkerSnap.TextLine(rect: CGRect(x: 0, y: 100, width: 300, height: 20),
                                       words: [CGRect(x: 0, y: 100, width: 80, height: 20),
                                               CGRect(x: 100, y: 100, width: 80, height: 20),
                                               CGRect(x: 200, y: 100, width: 100, height: 20)])
        let stroke = CGRect(x: 110, y: 104, width: 140, height: 8)
        let band = MarkerSnap.band(over: line, stroke: stroke, seed: UUID())
        XCTAssertEqual(band.thickness, 22, accuracy: 0.01)
        let xs = band.points.map(\.x)
        let reach = band.thickness / 2
        XCTAssertEqual(xs.min()! - reach, 100 - 4, accuracy: 0.5, "starts at the second word")
        XCTAssertEqual(xs.max()! + reach, 300 + 4, accuracy: 0.5, "ends after the third word")
        for p in band.points { XCTAssertEqual(p.y, 110, accuracy: 3) }
        let picked = MarkerSnap.bestLine(for: stroke, points: [CGPoint(x: 110, y: 108), CGPoint(x: 230, y: 108)],
                                         in: [line, MarkerSnap.TextLine(rect: CGRect(x: 0, y: 140, width: 300, height: 20), words: [])])
        XCTAssertEqual(picked?.rect.minY, 100)
    }

    func testImageElementDraws() {
        var doc = makeDocument(width: 20, height: 20)
        var e = Element(type: .image, rect: rect(10, 10, 5, 5))
        e.image = EmbeddedImage(makeImage(width: 5, height: 5, color: .black))
        doc.add(e)
        let px = flatten(doc)
        XCTAssertLessThan(px[12, 12].r, 5)
        XCTAssertTrue(isWhite(px[5, 5]))
    }

    func testFilterCacheReusesResults() {
        let cache = FilterCache(capacity: 2)
        let source = makeImage(width: 4, height: 4)
        var calls = 0
        let make: () -> CGImage? = {
            calls += 1
            return source
        }
        _ = cache.result(source: source, kind: "blur", rect: rect(0, 0, 2, 2), p1: 3, make: make)
        _ = cache.result(source: source, kind: "blur", rect: rect(0, 0, 2, 2), p1: 3, make: make)
        XCTAssertEqual(calls, 1)
        _ = cache.result(source: source, kind: "blur", rect: rect(0, 0, 2, 2), p1: 4, make: make)
        XCTAssertEqual(calls, 2, "different parameters recompute")
        _ = cache.result(source: source, kind: "pixelate", rect: rect(0, 0, 2, 2), make: make)
        XCTAssertEqual(cache.count, 2, "capacity is respected")
    }

    func testTextIsClippedToItsBox() {
        var doc = makeDocument(width: 120, height: 120)
        var e = box(.text, rect(40, 50, 40, 20))
        e.text = "Much more text than fits into this small box, wrapping onto many lines"
        e.style.lineThickness = 0
        e.style.fillColor = .clear
        e.style.shadow = false
        e.style.lineColor = .black
        e.style.fontSize = 14
        doc.add(e)
        let px = flatten(doc)
        var inside = 0
        for y in 0..<px.height {
            for x in 0..<px.width where !isWhite(px[x, y]) {
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                XCTAssertTrue(e.rect.contains(p), "text pixel at \(x), \(y) lies outside the box")
                if e.rect.contains(p) { inside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 20, "the text is drawn inside its box")
    }

    func testBubblePathIncludesTail() {
        var e = box(.speechBubble, rect(0, 0, 100, 50))
        e.tailTarget = CGPoint(x: 150, y: 120)
        let path = DocumentRenderer.bubblePath(e)
        XCTAssertTrue(path.contains(CGPoint(x: 50, y: 25)))
        XCTAssertTrue(path.contains(CGPoint(x: 100, y: 72.5)), "on the tail")
        XCTAssertFalse(path.contains(CGPoint(x: 140, y: 10)))
    }
}
