import CoreGraphics
import ScreenshotProCore
import XCTest
@testable import ScreenshotProEditor

/// Pixel-level checks of the image effects and region filters on small synthetic images.
final class EffectsTests: XCTestCase {
    typealias Pixel = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    // MARK: Helpers

    /// Builds a premultiplied sRGB image; `pixel(x, y)` uses top-left coordinates.
    private func makeImage(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> Pixel) -> CGImage {
        let ctx = EffectsBitmap.makeContext(width: w, height: h)!
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixel(x, y), o = y * ctx.bytesPerRow + x * 4
                data[o] = p.r; data[o + 1] = p.g; data[o + 2] = p.b; data[o + 3] = p.a
            }
        }
        return ctx.makeImage()!
    }

    private func solid(_ w: Int, _ h: Int, _ p: Pixel) -> CGImage { makeImage(w, h) { _, _ in p } }

    /// All pixels as RGBA bytes, rows top to bottom.
    private func pixels(_ image: CGImage) -> (bytes: [UInt8], rowBytes: Int) {
        let ctx = EffectsBitmap.context(copying: image)!
        let n = ctx.bytesPerRow * ctx.height
        let bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: n))
        return (bytes, ctx.bytesPerRow)
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> Pixel {
        let (b, row) = pixels(image)
        let o = y * row + x * 4
        return (b[o], b[o + 1], b[o + 2], b[o + 3])
    }

    private func assertPixel(_ p: Pixel, _ e: Pixel, accuracy: Int = 1,
                             file: StaticString = #filePath, line: UInt = #line) {
        let pairs = [(p.r, e.r), (p.g, e.g), (p.b, e.b), (p.a, e.a)]
        for (got, want) in pairs where abs(Int(got) - Int(want)) > accuracy {
            XCTFail("pixel \(p) != expected \(e)", file: file, line: line)
            return
        }
    }

    /// Four distinct quadrant colors: red TL, green TR, blue BL, white BR.
    private func quadrants(_ w: Int, _ h: Int) -> CGImage {
        makeImage(w, h) { x, y in
            switch (x < w / 2, y < h / 2) {
            case (true, true): return (255, 0, 0, 255)
            case (false, true): return (0, 255, 0, 255)
            case (true, false): return (0, 0, 255, 255)
            default: return (255, 255, 255, 255)
            }
        }
    }

    // MARK: Color effects

    func testInvert() {
        let img = makeImage(4, 2) { x, _ in x < 2 ? (200, 100, 50, 255) : (0, 0, 0, 0) }
        let out = ImageEffects.invert(img)
        assertPixel(pixel(out, 0, 0), (55, 155, 205, 255), accuracy: 0)
        assertPixel(pixel(out, 3, 1), (0, 0, 0, 0), accuracy: 0)
        assertPixel(pixel(img, 0, 0), (200, 100, 50, 255), accuracy: 0) // input untouched
    }

    func testGrayscale() {
        let img = makeImage(2, 1) { x, _ in x == 0 ? (200, 100, 50, 255) : (128, 0, 0, 128) }
        let out = ImageEffects.grayscale(img)
        // 0.30 * 200 + 0.59 * 100 + 0.11 * 50 = 124.5
        assertPixel(pixel(out, 0, 0), (125, 125, 125, 255))
        let half = pixel(out, 1, 0)
        XCTAssertEqual(half.a, 128)
        XCTAssertEqual(Int(half.r), 38, accuracy: 1) // 0.30 * 128 premultiplied
        XCTAssertEqual(half.r, half.g)
    }

    func testRemoveTransparency() {
        let img = makeImage(2, 1) { x, _ in x == 0 ? (0, 0, 0, 0) : (255, 0, 0, 255) }
        let out = ImageEffects.removeTransparency(img, color: .white)
        assertPixel(pixel(out, 0, 0), (255, 255, 255, 255), accuracy: 0)
        assertPixel(pixel(out, 1, 0), (255, 0, 0, 255), accuracy: 0)
    }

    // MARK: Geometry effects

    func testBorder() {
        let img = solid(10, 6, (255, 255, 255, 255))
        let (out, geo) = ImageEffects.border(img, width: 2, color: .black)
        XCTAssertEqual(out.width, 14)
        XCTAssertEqual(out.height, 10)
        XCTAssertEqual(geo.offset, CGPoint(x: 2, y: 2))
        XCTAssertEqual(geo.scale, CGSize(width: 1, height: 1))
        assertPixel(pixel(out, 7, 0), (0, 0, 0, 255))
        assertPixel(pixel(out, 7, 1), (0, 0, 0, 255))
        assertPixel(pixel(out, 0, 5), (0, 0, 0, 255))
        assertPixel(pixel(out, 13, 5), (0, 0, 0, 255))
        assertPixel(pixel(out, 7, 9), (0, 0, 0, 255))
        assertPixel(pixel(out, 2, 2), (255, 255, 255, 255))
        assertPixel(pixel(out, 7, 5), (255, 255, 255, 255))
    }

    func testDropShadow() {
        let img = solid(20, 10, (255, 0, 0, 255))
        let settings = DropShadowSettings()
        let (out, geo) = ImageEffects.dropShadow(img, settings)
        XCTAssertEqual(out.width, 20 + 14)
        XCTAssertEqual(out.height, 10 + 14)
        XCTAssertEqual(geo.offset, CGPoint(x: 5, y: 5)) // size - 1 + offset
        assertPixel(pixel(out, 5, 5), (255, 0, 0, 255))
        assertPixel(pixel(out, 24, 14), (255, 0, 0, 255))
        // Shadow beyond the image's bottom-right, fading out toward the canvas edge.
        let near = pixel(out, 26, 16), far = pixel(out, 33, 23)
        XCTAssertGreaterThan(near.a, 0)
        XCTAssertEqual(near.r, 0)
        XCTAssertGreaterThan(near.a, far.a)
        XCTAssertLessThanOrEqual(Int(near.a), Int((0.6 * 255).rounded()) + 1)
        assertPixel(pixel(out, 0, 0), (0, 0, 0, 0), accuracy: 2)
    }

    func testRotateClockwiseAndCounterClockwise() {
        let img = quadrants(6, 4)
        let cw = ImageEffects.rotate(img, quarterTurns: 1)
        XCTAssertEqual(cw.width, 4)
        XCTAssertEqual(cw.height, 6)
        // Clockwise: top-left goes to top-right, bottom-left to top-left.
        assertPixel(pixel(cw, 3, 0), (255, 0, 0, 255), accuracy: 0)
        assertPixel(pixel(cw, 0, 0), (0, 0, 255, 255), accuracy: 0)
        assertPixel(pixel(cw, 3, 5), (0, 255, 0, 255), accuracy: 0)
        assertPixel(pixel(cw, 0, 5), (255, 255, 255, 255), accuracy: 0)

        let ccw = ImageEffects.rotate(img, quarterTurns: -1)
        XCTAssertEqual(ccw.width, 4)
        XCTAssertEqual(ccw.height, 6)
        assertPixel(pixel(ccw, 0, 5), (255, 0, 0, 255), accuracy: 0)
        assertPixel(pixel(ccw, 0, 0), (0, 255, 0, 255), accuracy: 0)

        let half = ImageEffects.rotate(img, quarterTurns: 2)
        XCTAssertEqual(half.width, 6)
        assertPixel(pixel(half, 5, 3), (255, 0, 0, 255), accuracy: 0)
        assertPixel(pixel(half, 0, 0), (255, 255, 255, 255), accuracy: 0)

        let full = ImageEffects.rotate(img, quarterTurns: 4)
        XCTAssertEqual(pixels(full).bytes, pixels(img).bytes)
    }

    func testExpandCanvas() {
        let img = solid(4, 3, (10, 20, 30, 255))
        let (out, geo) = ImageEffects.expandCanvas(img, top: 1, left: 2, bottom: 3, right: 4)
        XCTAssertEqual(out.width, 10)
        XCTAssertEqual(out.height, 7)
        XCTAssertEqual(geo.offset, CGPoint(x: 2, y: 1))
        assertPixel(pixel(out, 0, 0), (0, 0, 0, 0), accuracy: 0)
        assertPixel(pixel(out, 9, 6), (0, 0, 0, 0), accuracy: 0)
        assertPixel(pixel(out, 1, 1), (0, 0, 0, 0), accuracy: 0)
        assertPixel(pixel(out, 2, 1), (10, 20, 30, 255), accuracy: 0)
        assertPixel(pixel(out, 5, 3), (10, 20, 30, 255), accuracy: 0)
        assertPixel(pixel(out, 6, 3), (0, 0, 0, 0), accuracy: 0)
    }

    func testResize() {
        let img = solid(40, 20, (0, 128, 255, 255))
        let out = ImageEffects.resize(img, to: CGSize(width: 10, height: 30))
        XCTAssertEqual(out.width, 10)
        XCTAssertEqual(out.height, 30)
        assertPixel(pixel(out, 5, 15), (0, 128, 255, 255), accuracy: 2)
    }

    func testCrop() {
        let img = quadrants(8, 6)
        let out = ImageEffects.crop(img, to: CGRect(x: 4, y: 0, width: 4, height: 3))!
        XCTAssertEqual(out.width, 4)
        XCTAssertEqual(out.height, 3)
        for (x, y) in [(0, 0), (3, 2)] { assertPixel(pixel(out, x, y), (0, 255, 0, 255), accuracy: 0) }
        let bottomLeft = ImageEffects.crop(img, to: CGRect(x: 0, y: 3, width: 4, height: 3))!
        assertPixel(pixel(bottomLeft, 0, 0), (0, 0, 255, 255), accuracy: 0)
        XCTAssertNil(ImageEffects.crop(img, to: CGRect(x: 20, y: 20, width: 4, height: 4)))
        let clipped = ImageEffects.crop(img, to: CGRect(x: 6, y: 4, width: 10, height: 10))!
        XCTAssertEqual(clipped.width, 2)
        XCTAssertEqual(clipped.height, 2)
    }

    func testClear() {
        let out = ImageEffects.clear(solid(5, 4, (255, 255, 255, 255)))
        XCTAssertEqual(out.width, 5)
        XCTAssertEqual(out.height, 4)
        XCTAssertTrue(pixels(out).bytes.allSatisfy { $0 == 0 })
    }

    // MARK: Auto crop

    func testAutoCropRectWithUniformMargin() {
        let img = makeImage(30, 20) { x, y in
            (5..<25).contains(x) && (3..<15).contains(y) ? (200, 10, 10, 255) : (255, 255, 255, 255)
        }
        XCTAssertEqual(ImageEffects.autoCropRect(img), CGRect(x: 5, y: 3, width: 20, height: 12))
    }

    func testAutoCropRespectsToleranceAndImpossibleCases() {
        // Content barely differs from the margin: inside the tolerance, nothing to keep.
        let faint = makeImage(10, 10) { x, y in
            (3..<7).contains(x) && (3..<7).contains(y) ? (250, 250, 250, 255) : (255, 255, 255, 255)
        }
        XCTAssertNil(ImageEffects.autoCropRect(faint, tolerance: 10))
        XCTAssertEqual(ImageEffects.autoCropRect(faint, tolerance: 0), CGRect(x: 3, y: 3, width: 4, height: 4))
        XCTAssertNil(ImageEffects.autoCropRect(solid(8, 8, (1, 2, 3, 255))))
        XCTAssertNil(ImageEffects.autoCropRect(quadrants(8, 8)))
    }

    func testAutoCropTransparentMargin() {
        let img = makeImage(12, 12) { x, y in
            (2..<9).contains(x) && (4..<10).contains(y) ? (0, 0, 0, 255) : (0, 0, 0, 0)
        }
        XCTAssertEqual(ImageEffects.autoCropRect(img), CGRect(x: 2, y: 4, width: 7, height: 6))
    }

    // MARK: Torn edges

    func testTornEdgesDeterministicWithSeed() {
        let img = solid(120, 80, (0, 200, 0, 255))
        var settings = TornEdgeSettings()
        settings.seed = 42
        settings.generateShadow = false
        let (a, geoA) = ImageEffects.tornEdges(img, settings)
        let (b, _) = ImageEffects.tornEdges(img, settings)
        XCTAssertEqual(a.width, 120)
        XCTAssertEqual(a.height, 80)
        XCTAssertEqual(geoA, .identity)
        XCTAssertEqual(pixels(a).bytes, pixels(b).bytes)
        assertPixel(pixel(a, 0, 0), (0, 0, 0, 0), accuracy: 0)
        assertPixel(pixel(a, 119, 79), (0, 0, 0, 0), accuracy: 0)
        assertPixel(pixel(a, 60, 40), (0, 200, 0, 255), accuracy: 0)

        settings.seed = 43
        let (c, _) = ImageEffects.tornEdges(img, settings)
        XCTAssertNotEqual(pixels(a).bytes, pixels(c).bytes)
    }

    func testTornEdgesOnlyTornSidesChange() {
        let img = solid(100, 60, (255, 255, 255, 255))
        var settings = TornEdgeSettings()
        settings.seed = 7
        settings.generateShadow = false
        settings.top = false; settings.left = false; settings.right = false
        let (out, _) = ImageEffects.tornEdges(img, settings)
        // Top edge and left/right edges stay straight and opaque; the bottom row is torn.
        for x in [0, 50, 99] { assertPixel(pixel(out, x, 0), (255, 255, 255, 255), accuracy: 0) }
        assertPixel(pixel(out, 0, 30), (255, 255, 255, 255), accuracy: 0)
        assertPixel(pixel(out, 99, 30), (255, 255, 255, 255), accuracy: 0)
        let bottomAlpha = (0..<100).map { Int(pixel(out, $0, 59).a) }
        XCTAssertTrue(bottomAlpha.allSatisfy { $0 < 255 })
    }

    func testTornEdgesWithShadowAndBackground() {
        let img = solid(80, 60, (255, 255, 255, 255))
        var settings = TornEdgeSettings()
        settings.seed = 99
        settings.backgroundColor = .black
        let (out, geo) = ImageEffects.tornEdges(img, settings)
        XCTAssertEqual(out.width, 80 + 14)
        XCTAssertEqual(out.height, 60 + 14)
        XCTAssertEqual(geo.offset, CGPoint(x: 5, y: 5))
        assertPixel(pixel(out, 0, 0), (0, 0, 0, 255), accuracy: 0)
    }

    // MARK: Region filters

    func testPixelateCellsUniformAndAligned() {
        // Gradient so every cell has a different average.
        let img = makeImage(40, 30) { x, y in (UInt8(x * 6), UInt8(y * 8), 100, 255) }
        let rect = CGRect(x: 3, y: 2, width: 22, height: 17)
        let out = RegionFilters.pixelate(img, rect: rect, cellSize: 5)!
        XCTAssertEqual(out.width, 22)
        XCTAssertEqual(out.height, 17)
        let (bytes, row) = pixels(out)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * row + x * 4)..<(y * row + x * 4 + 4)]) }
        for cy in stride(from: 0, to: 17, by: 5) {
            for cx in stride(from: 0, to: 22, by: 5) {
                let first = px(cx, cy)
                for y in cy..<min(cy + 5, 17) {
                    for x in cx..<min(cx + 5, 22) {
                        XCTAssertEqual(px(x, y), first, "cell (\(cx), \(cy)) not uniform at (\(x), \(y))")
                    }
                }
            }
        }
        XCTAssertNotEqual(px(0, 0), px(5, 0))
        // The first cell averages source pixels x 3...7, y 2...6 (centered values 5 and 4).
        let c = px(0, 0)
        XCTAssertEqual(Int(c[0]), 5 * 6, accuracy: 2)
        XCTAssertEqual(Int(c[1]), 4 * 8, accuracy: 2)
    }

    func testPixelateSmallCellSizeIsPlainCrop() {
        let img = quadrants(8, 8)
        let out = RegionFilters.pixelate(img, rect: CGRect(x: 4, y: 4, width: 4, height: 4), cellSize: 1)!
        assertPixel(pixel(out, 0, 0), (255, 255, 255, 255), accuracy: 0)
        XCTAssertNil(RegionFilters.pixelate(img, rect: CGRect(x: 50, y: 50, width: 4, height: 4), cellSize: 4))
    }

    func testBlurKeepsEdgesAndSize() {
        let img = solid(40, 30, (100, 150, 200, 255))
        let out = RegionFilters.blur(img, rect: CGRect(x: 0, y: 0, width: 20, height: 15), radius: 5)!
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 15)
        // A uniform image blurred with clamped edges must stay uniform (no dark or faded border).
        assertPixel(pixel(out, 0, 0), (100, 150, 200, 255), accuracy: 2)
        assertPixel(pixel(out, 19, 14), (100, 150, 200, 255), accuracy: 2)
    }

    func testBlurMixesNeighbors() {
        let img = makeImage(40, 20) { x, _ in x < 20 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let out = RegionFilters.blur(img, rect: CGRect(x: 10, y: 5, width: 20, height: 10), radius: 3)!
        let mid = pixel(out, 10, 5)
        XCTAssertGreaterThan(mid.r, 60)
        XCTAssertLessThan(mid.r, 200)
        assertPixel(pixel(out, 0, 5), (0, 0, 0, 255), accuracy: 2)
    }

    func testRegionGrayscale() {
        let img = quadrants(8, 8)
        let out = RegionFilters.grayscale(img, rect: CGRect(x: 0, y: 0, width: 4, height: 4))!
        XCTAssertEqual(out.width, 4)
        assertPixel(pixel(out, 1, 1), (77, 77, 77, 255)) // 0.30 * 255
    }

    func testMagnifyCentered() {
        // A 2 x 2 red dot in the center of a white 20 x 20 image.
        let img = makeImage(20, 20) { x, y in
            (9...10).contains(x) && (9...10).contains(y) ? (255, 0, 0, 255) : (255, 255, 255, 255)
        }
        let out = RegionFilters.magnify(img, rect: CGRect(x: 4, y: 4, width: 12, height: 12), factor: 2)!
        XCTAssertEqual(out.width, 12)
        XCTAssertEqual(out.height, 12)
        // The dot doubles to 4 x 4 pixels around the output center.
        for (x, y) in [(4, 4), (7, 7), (4, 7)] { assertPixel(pixel(out, x, y), (255, 0, 0, 255), accuracy: 0) }
        for (x, y) in [(3, 4), (8, 7), (0, 0)] { assertPixel(pixel(out, x, y), (255, 255, 255, 255), accuracy: 0) }
    }

    func testAreaHighlight() {
        let img = solid(40, 30, (200, 200, 200, 255))
        let keep = CGRect(x: 10, y: 10, width: 10, height: 5)
        let out = RegionFilters.areaHighlight(img, keep: keep, brightness: 0.5, blurRadius: 3)!
        XCTAssertEqual(out.width, 40)
        XCTAssertEqual(out.height, 30)
        assertPixel(pixel(out, 12, 12), (200, 200, 200, 255), accuracy: 0)
        assertPixel(pixel(out, 2, 2), (100, 100, 100, 255), accuracy: 2)
        assertPixel(pixel(out, 39, 29), (100, 100, 100, 255), accuracy: 2)
        assertPixel(pixel(out, 25, 12), (100, 100, 100, 255), accuracy: 2)
    }

    // MARK: Performance smoke test

    func testLargeImageEffectsComplete() {
        let img = solid(5120, 2880, (30, 60, 90, 255))
        XCTAssertEqual(ImageEffects.grayscale(img).width, 5120)
        XCTAssertEqual(ImageEffects.invert(img).height, 2880)
        XCTAssertEqual(ImageEffects.dropShadow(img, DropShadowSettings()).0.width, 5134)
        XCTAssertNotNil(RegionFilters.pixelate(img, rect: CGRect(x: 0, y: 0, width: 5120, height: 2880), cellSize: 12))
        XCTAssertNotNil(RegionFilters.areaHighlight(img, keep: CGRect(x: 100, y: 100, width: 500, height: 500),
                                                    brightness: 0.9, blurRadius: 3))
    }
}
