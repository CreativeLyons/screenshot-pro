import CoreGraphics
import XCTest
@testable import ScreenshotProCapture

final class OverlayLayoutTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let box = CGSize(width: 150, height: 170)

    func testMagnifierPrefersBelowRightOfCursor() {
        let origin = OverlayLayout.magnifierOrigin(cursor: CGPoint(x: 400, y: 500), size: box, bounds: bounds)
        XCTAssertEqual(origin, CGPoint(x: 420, y: 500 - 20 - 170))
    }

    func testMagnifierFlipsLeftNearRightEdge() {
        let origin = OverlayLayout.magnifierOrigin(cursor: CGPoint(x: 1400, y: 500), size: box, bounds: bounds)
        XCTAssertEqual(origin, CGPoint(x: 1400 - 20 - 150, y: 500 - 20 - 170))
    }

    func testMagnifierFlipsAboveNearBottomEdge() {
        let origin = OverlayLayout.magnifierOrigin(cursor: CGPoint(x: 400, y: 60), size: box, bounds: bounds)
        XCTAssertEqual(origin, CGPoint(x: 420, y: 80))
    }

    func testMagnifierInBottomRightCornerGoesTopLeft() {
        let origin = OverlayLayout.magnifierOrigin(cursor: CGPoint(x: 1430, y: 10), size: box, bounds: bounds)
        XCTAssertEqual(origin, CGPoint(x: 1430 - 20 - 150, y: 30))
    }

    func testMagnifierDiameterUsesWholeDevicePixelsPerSample() {
        let d = OverlayLayout.magnifierDiameter(displaySize: CGSize(width: 1440, height: 900), scale: 2)
        let cellPixels = d * 2 / CGFloat(OverlayLayout.magnifierSamples)
        XCTAssertEqual(cellPixels, cellPixels.rounded(), accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(d, 100)
        XCTAssertLessThanOrEqual(d, 190)
    }

    func testMagnifierSourceIsCenteredAndClippedAtEdges() {
        let centered = OverlayLayout.magnifierSource(pixel: (100, 100), imageWidth: 400, imageHeight: 400)
        XCTAssertEqual(centered.wanted, CGRect(x: 88, y: 88, width: 25, height: 25))
        XCTAssertEqual(centered.visible, centered.wanted)

        let corner = OverlayLayout.magnifierSource(pixel: (2, 0), imageWidth: 400, imageHeight: 400)
        XCTAssertEqual(corner.wanted, CGRect(x: -10, y: -12, width: 25, height: 25))
        XCTAssertEqual(corner.visible, CGRect(x: 0, y: 0, width: 15, height: 13))
    }

    func testSizeLabelSitsBelowSelectionThenAboveThenInside() {
        let label = CGSize(width: 80, height: 20)
        let middle = OverlayLayout.sizeLabelOrigin(selection: CGRect(x: 100, y: 300, width: 200, height: 100), size: label, bounds: bounds)
        XCTAssertEqual(middle, CGPoint(x: 160, y: 274))

        let low = OverlayLayout.sizeLabelOrigin(selection: CGRect(x: 100, y: 5, width: 200, height: 100), size: label, bounds: bounds)
        XCTAssertEqual(low, CGPoint(x: 160, y: 111))

        let full = OverlayLayout.sizeLabelOrigin(selection: bounds, size: label, bounds: bounds)
        XCTAssertEqual(full, CGPoint(x: 680, y: 8))
    }

    func testWindowLabelAboveTopLeftOrInside() {
        let label = CGSize(width: 120, height: 20)
        let above = OverlayLayout.windowLabelOrigin(window: CGRect(x: 50, y: 100, width: 400, height: 300), size: label, bounds: bounds)
        XCTAssertEqual(above, CGPoint(x: 50, y: 406))
        let inside = OverlayLayout.windowLabelOrigin(window: CGRect(x: 0, y: 0, width: 1440, height: 900), size: label, bounds: bounds)
        // Inside the top edge, clamped to the display margin.
        XCTAssertEqual(inside, CGPoint(x: 8, y: 900 - 8 - 20))
    }

    func testHintMovesAwayFromCursor() {
        let size = CGSize(width: 400, height: 24)
        let top = OverlayLayout.hintOrigin(size: size, bounds: bounds, cursor: CGPoint(x: 100, y: 100))
        XCTAssertEqual(top, CGPoint(x: 520, y: 900 - 48 - 24))
        let moved = OverlayLayout.hintOrigin(size: size, bounds: bounds, cursor: CGPoint(x: 720, y: 840))
        XCTAssertEqual(moved, CGPoint(x: 520, y: 48))
    }
}
