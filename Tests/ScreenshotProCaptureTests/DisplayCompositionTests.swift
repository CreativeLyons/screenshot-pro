import CoreGraphics
import XCTest
@testable import ScreenshotProCapture

final class DisplayCompositionTests: XCTestCase {
    // A: Retina 100x100 pt at the origin. B: 1x 100x100 pt to its right.
    let a = DisplayLayout(frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
    let b = DisplayLayout(frame: CGRect(x: 100, y: 0, width: 100, height: 100), scale: 1)

    func testBounds() {
        XCTAssertEqual(DisplayComposition.bounds(of: [a, b]), CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    func testOutputScaleIsHighestTouchedScale() {
        XCTAssertEqual(DisplayComposition.outputScale(for: CGRect(x: 120, y: 0, width: 10, height: 10), displays: [a, b]), 1)
        XCTAssertEqual(DisplayComposition.outputScale(for: CGRect(x: 90, y: 0, width: 20, height: 10), displays: [a, b]), 2)
        // Touching an edge is not overlapping.
        XCTAssertEqual(DisplayComposition.outputScale(for: CGRect(x: 100, y: 0, width: 10, height: 10), displays: [a, b]), 1)
    }

    func testPlanInsideOneDisplayIsACrop() throws {
        let plan = try XCTUnwrap(DisplayComposition.plan(rect: CGRect(x: 10, y: 20, width: 30, height: 40), displays: [a, b]))
        XCTAssertEqual(plan.scale, 2)
        XCTAssertEqual(plan.pixelWidth, 60)
        XCTAssertEqual(plan.pixelHeight, 80)
        XCTAssertEqual(plan.pieces, [CompositionPiece(displayIndex: 0, source: CGRect(x: 20, y: 40, width: 60, height: 80),
                                                      destination: CGRect(x: 0, y: 0, width: 60, height: 80))])
    }

    func testPlanAcrossMixedScales() throws {
        let plan = try XCTUnwrap(DisplayComposition.plan(rect: CGRect(x: 50, y: 10, width: 100, height: 20), displays: [a, b]))
        XCTAssertEqual(plan.scale, 2)
        XCTAssertEqual(plan.pixelWidth, 200)
        XCTAssertEqual(plan.pixelHeight, 40)
        XCTAssertEqual(plan.pieces.count, 2)
        XCTAssertEqual(plan.pieces[0], CompositionPiece(displayIndex: 0, source: CGRect(x: 100, y: 20, width: 100, height: 40),
                                                        destination: CGRect(x: 0, y: 0, width: 100, height: 40)))
        // The 1x part is upscaled into the 2x output.
        XCTAssertEqual(plan.pieces[1], CompositionPiece(displayIndex: 1, source: CGRect(x: 0, y: 10, width: 50, height: 20),
                                                        destination: CGRect(x: 100, y: 0, width: 100, height: 40)))
    }

    func testPlanWithNegativeOrigins() throws {
        let left = DisplayLayout(frame: CGRect(x: -100, y: -50, width: 100, height: 100), scale: 1)
        let plan = try XCTUnwrap(DisplayComposition.plan(rect: CGRect(x: -20, y: 0, width: 40, height: 10), displays: [left, a]))
        XCTAssertEqual(plan.scale, 2)
        XCTAssertEqual(plan.pieces.first { $0.displayIndex == 0 }?.source, CGRect(x: 80, y: 50, width: 20, height: 10))
        XCTAssertEqual(plan.pieces.first { $0.displayIndex == 0 }?.destination, CGRect(x: 0, y: 0, width: 40, height: 20))
        XCTAssertEqual(plan.pieces.first { $0.displayIndex == 1 }?.source, CGRect(x: 0, y: 0, width: 40, height: 20))
        XCTAssertEqual(plan.pieces.first { $0.displayIndex == 1 }?.destination, CGRect(x: 40, y: 0, width: 40, height: 20))
    }

    func testPlanOffAllDisplaysIsNil() {
        XCTAssertNil(DisplayComposition.plan(rect: CGRect(x: 500, y: 500, width: 10, height: 10), displays: [a, b]))
        XCTAssertNil(DisplayComposition.plan(rect: .zero, displays: [a, b]))
    }

    func testRenderPlacesEachDisplay() throws {
        let red = try solidImage(width: 200, height: 200, color: (255, 0, 0))
        let blue = try solidImage(width: 100, height: 100, color: (0, 0, 255))
        let plan = try XCTUnwrap(DisplayComposition.plan(rect: CGRect(x: 50, y: 10, width: 100, height: 20), displays: [a, b]))
        let image = try XCTUnwrap(DisplayComposition.render(plan, images: [red, blue]))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 40)
        let pixel = try reader(image)
        XCTAssertEqual(pixel(10, 5).r, 255)
        XCTAssertEqual(pixel(10, 5).b, 0)
        XCTAssertEqual(pixel(150, 30).b, 255)
        XCTAssertEqual(pixel(150, 30).r, 0)
    }

    func testRenderLeavesGapsTransparent() throws {
        // B sits lower than A, so the bottom left of the union is outside every display.
        let lowB = DisplayLayout(frame: CGRect(x: 100, y: 50, width: 100, height: 100), scale: 1)
        let red = try solidImage(width: 200, height: 200, color: (255, 0, 0))
        let blue = try solidImage(width: 100, height: 100, color: (0, 0, 255))
        let rect = DisplayComposition.bounds(of: [a, lowB])
        let plan = try XCTUnwrap(DisplayComposition.plan(rect: rect, displays: [a, lowB]))
        let image = try XCTUnwrap(DisplayComposition.render(plan, images: [red, blue]))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)
        let pixel = try reader(image)
        XCTAssertEqual(pixel(10, 10).r, 255)      // A, top left
        XCTAssertEqual(pixel(390, 10).a, 0)       // above B: gap
        XCTAssertEqual(pixel(390, 290).b, 255)    // B, bottom right
        XCTAssertEqual(pixel(10, 290).a, 0)       // below A: gap
    }

    func testSingleDisplayRenderIsExactCrop() throws {
        let red = try solidImage(width: 200, height: 200, color: (255, 0, 0))
        let plan = try XCTUnwrap(DisplayComposition.plan(rect: CGRect(x: 10, y: 10, width: 25, height: 5), displays: [a]))
        let image = try XCTUnwrap(DisplayComposition.render(plan, images: [red]))
        XCTAssertEqual(image.width, 50)
        XCTAssertEqual(image.height, 10)
    }

    // MARK: Helpers

    private func solidImage(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                                 blue: CGFloat(color.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Pixel reader with a top-left origin.
    private func reader(_ image: CGImage) throws -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let bytes = Array(UnsafeBufferPointer(start: base, count: w * h * 4))
        return { x, y in
            let i = (y * w + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }
}
