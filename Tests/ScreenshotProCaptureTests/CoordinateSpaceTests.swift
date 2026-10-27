import CoreGraphics
import XCTest
@testable import ScreenshotProCapture

final class CoordinateSpaceTests: XCTestCase {
    func testQuartzAndAppKitPointsMirrorAroundPrimaryHeight() {
        let appKit = CGPoint(x: 100, y: 800)
        let quartz = CoordinateSpace.quartzPoint(fromAppKit: appKit, primaryHeight: 900)
        XCTAssertEqual(quartz, CGPoint(x: 100, y: 100))
        XCTAssertEqual(CoordinateSpace.appKitPoint(fromQuartz: quartz, primaryHeight: 900), appKit)
    }

    func testPrimaryScreenFrameMapsToQuartzOrigin() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(CoordinateSpace.quartzRect(fromAppKit: primary, primaryHeight: 900), primary)
    }

    func testDisplayAbovePrimaryHasNegativeQuartzY() {
        // AppKit: a 1920x1080 display sitting on top of a 1440x900 primary.
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let quartz = CoordinateSpace.quartzRect(fromAppKit: above, primaryHeight: 900)
        XCTAssertEqual(quartz, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(CoordinateSpace.appKitRect(fromQuartz: quartz, primaryHeight: 900), above)
    }

    func testDisplayLeftOfAndBelowPrimary() {
        let left = CGRect(x: -1280, y: -400, width: 1280, height: 1024)
        let quartz = CoordinateSpace.quartzRect(fromAppKit: left, primaryHeight: 900)
        XCTAssertEqual(quartz, CGRect(x: -1280, y: 276, width: 1280, height: 1024))
    }

    func testViewCoordinatesAreBottomLeftOfTheDisplay() {
        let display = CGRect(x: 1440, y: -200, width: 1000, height: 800) // Quartz
        let p = CoordinateSpace.viewPoint(fromQuartz: CGPoint(x: 1450, y: -190), display: display)
        XCTAssertEqual(p, CGPoint(x: 10, y: 790))
        XCTAssertEqual(CoordinateSpace.quartzPoint(fromView: p, display: display), CGPoint(x: 1450, y: -190))

        let r = CoordinateSpace.viewRect(fromQuartz: CGRect(x: 1440, y: -200, width: 100, height: 50), display: display)
        XCTAssertEqual(r, CGRect(x: 0, y: 750, width: 100, height: 50))
    }

    func testPixelRectAndPixelUnderPoint() {
        let display = CGRect(x: -500, y: 0, width: 500, height: 400)
        let r = CoordinateSpace.pixelRect(fromQuartz: CGRect(x: -490, y: 5, width: 20, height: 10), display: display, scale: 2)
        XCTAssertEqual(r, CGRect(x: 20, y: 10, width: 40, height: 20))
        let px = CoordinateSpace.pixel(atQuartz: CGPoint(x: -489.75, y: 5.6), display: display, scale: 2)
        XCTAssertEqual(px.x, 20)
        XCTAssertEqual(px.y, 11)
    }

    func testSelectionIsInclusiveAndPixelAligned() {
        // A click selects exactly the pixel under the pointer.
        let click = CoordinateSpace.selectionRect(from: CGPoint(x: 10.2, y: 10.7), to: CGPoint(x: 10.2, y: 10.7), scale: 2)
        XCTAssertEqual(click, CGRect(x: 10, y: 10.5, width: 0.5, height: 0.5))

        // Dragging up-left normalizes and includes both end pixels.
        let drag = CoordinateSpace.selectionRect(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 10, y: 10), scale: 1)
        XCTAssertEqual(drag, CGRect(x: 10, y: 10, width: 11, height: 21))
        XCTAssertEqual(CoordinateSpace.pixelSize(of: drag, scale: 1).width, 11)
    }

    func testIntegralRoundsEdgesNotSize() {
        let r = CoordinateSpace.integral(CGRect(x: 0.4, y: 0.6, width: 10.2, height: 9.8))
        XCTAssertEqual(r, CGRect(x: 0, y: 1, width: 11, height: 9))
    }

    func testPixelSize() {
        let size = CoordinateSpace.pixelSize(of: CGRect(x: 0, y: 0, width: 100.5, height: 50), scale: 2)
        XCTAssertEqual(size.width, 201)
        XCTAssertEqual(size.height, 100)
    }

    func testClampKeepsPointInside() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(CoordinateSpace.clamp(CGPoint(x: -5, y: 150), to: rect), CGPoint(x: 0, y: 99.5))
    }

    func testScaleFromDPI() {
        XCTAssertEqual(CoordinateSpace.scale(fromDPI: 144), 2)
        XCTAssertEqual(CoordinateSpace.scale(fromDPI: 216), 3)
        XCTAssertEqual(CoordinateSpace.scale(fromDPI: 72), 1)
        XCTAssertEqual(CoordinateSpace.scale(fromDPI: 300), 1)
        XCTAssertEqual(CoordinateSpace.scale(fromDPI: nil), 1)
        XCTAssertEqual(CoordinateSpace.scale(fromDPI: 0), 1)
    }
}
