import CoreGraphics
import XCTest
import ScreenshotProCore
@testable import ScreenshotProEditor

final class GeometryTests: XCTestCase {
    func testRectangleHitOutlineOnlyWithoutFill() {
        var e = box(.rectangle, rect(10, 10, 100, 50))
        e.style.fillColor = .clear
        XCTAssertTrue(ElementGeometry.hitTest(e, at: CGPoint(x: 10, y: 30)))
        XCTAssertTrue(ElementGeometry.hitTest(e, at: CGPoint(x: 60, y: 14)), "near the top edge")
        XCTAssertFalse(ElementGeometry.hitTest(e, at: CGPoint(x: 60, y: 35)), "the empty middle is not a hit")
        XCTAssertFalse(ElementGeometry.hitTest(e, at: CGPoint(x: 200, y: 200)))
        e.style.fillColor = .yellow
        XCTAssertTrue(ElementGeometry.hitTest(e, at: CGPoint(x: 60, y: 35)), "filled shapes hit inside")
    }

    func testEllipseHit() {
        var e = box(.ellipse, rect(0, 0, 100, 100))
        e.style.fillColor = .clear
        XCTAssertTrue(ElementGeometry.hitTest(e, at: CGPoint(x: 50, y: 1)))
        XCTAssertFalse(ElementGeometry.hitTest(e, at: CGPoint(x: 50, y: 50)))
        XCTAssertFalse(ElementGeometry.hitTest(e, at: CGPoint(x: 2, y: 2)), "corner of the bounds is outside")
    }

    func testLineAndArrowTolerance() {
        let l = line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        XCTAssertTrue(ElementGeometry.hitTest(l, at: CGPoint(x: 50, y: 5)))
        XCTAssertFalse(ElementGeometry.hitTest(l, at: CGPoint(x: 50, y: 8)))
        let a = line(.arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        XCTAssertTrue(ElementGeometry.hitTest(a, at: CGPoint(x: 50, y: 10)), "arrows are easier to hit")
        XCTAssertFalse(ElementGeometry.hitTest(l, at: CGPoint(x: 120, y: 0)))
    }

    func testFreehandHitAndBounds() {
        var f = Element(type: .freehand, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)])
        f.style.lineThickness = 4
        XCTAssertTrue(ElementGeometry.hitTest(f, at: CGPoint(x: 15, y: 5)))
        XCTAssertFalse(ElementGeometry.hitTest(f, at: CGPoint(x: 10, y: 0)))
        XCTAssertEqual(ElementGeometry.bounds(of: f), rect(-2, -2, 24, 14))
    }

    func testTopmostHitPrefersLastElement() {
        var a = box(.rectangle, rect(0, 0, 50, 50))
        a.style.fillColor = .white
        var b = box(.rectangle, rect(10, 10, 50, 50))
        b.style.fillColor = .white
        XCTAssertEqual(ElementGeometry.topmostHit(in: [a, b], at: CGPoint(x: 20, y: 20))?.id, b.id)
        XCTAssertEqual(ElementGeometry.topmostHit(in: [a, b], at: CGPoint(x: 2, y: 2))?.id, a.id)
        XCTAssertNil(ElementGeometry.topmostHit(in: [a, b], at: CGPoint(x: 90, y: 90)))
    }

    func testHandlePositions() {
        let r = rect(10, 20, 100, 50)
        let handles = ElementGeometry.handles(of: box(.rectangle, r))
        XCTAssertEqual(handles.count, 8)
        let positions = Dictionary(uniqueKeysWithValues: handles.compactMap { h, p -> (ResizeHandle, CGPoint)? in
            if case .resize(let rh) = h { return (rh, p) }
            return nil
        })
        XCTAssertEqual(positions[.topLeft], CGPoint(x: 10, y: 20))
        XCTAssertEqual(positions[.top], CGPoint(x: 60, y: 20))
        XCTAssertEqual(positions[.bottomRight], CGPoint(x: 110, y: 70))
        XCTAssertEqual(positions[.left], CGPoint(x: 10, y: 45))
        // Lines get two end point handles; bubbles add the tail; freehand has none.
        XCTAssertEqual(ElementGeometry.handles(of: line(from: .zero, to: CGPoint(x: 5, y: 5))).map(\.0),
                       [.lineStart, .lineEnd])
        XCTAssertEqual(ElementGeometry.handles(of: box(.speechBubble, r)).count, 9)
        XCTAssertTrue(ElementGeometry.handles(of: Element(type: .freehand, points: [.zero])).isEmpty)
    }

    func testHandleHitRadius() {
        let e = box(.rectangle, rect(10, 10, 100, 100))
        XCTAssertEqual(ElementGeometry.handle(of: e, at: CGPoint(x: 112, y: 108), radius: 4), .resize(.bottomRight))
        XCTAssertNil(ElementGeometry.handle(of: e, at: CGPoint(x: 60, y: 60), radius: 4))
        var bubble = box(.speechBubble, rect(0, 0, 50, 50))
        bubble.tailTarget = CGPoint(x: 50, y: 50)
        XCTAssertEqual(ElementGeometry.handle(of: bubble, at: CGPoint(x: 50, y: 50), radius: 4), .tail,
                       "the tail wins over the corner under it")
    }

    func testResizeCornerAndEdge() {
        let r = rect(10, 10, 100, 50)
        XCTAssertEqual(ElementGeometry.resize(r, handle: .bottomRight, to: CGPoint(x: 130, y: 80)), rect(10, 10, 120, 70))
        XCTAssertEqual(ElementGeometry.resize(r, handle: .topLeft, to: CGPoint(x: 0, y: 0)), rect(0, 0, 110, 60))
        XCTAssertEqual(ElementGeometry.resize(r, handle: .right, to: CGPoint(x: 150, y: 999)), rect(10, 10, 140, 50))
        XCTAssertEqual(ElementGeometry.resize(r, handle: .top, to: CGPoint(x: 999, y: 0)), rect(10, 0, 100, 60))
    }

    func testResizePastOppositeEdgeFlips() {
        let r = rect(10, 10, 100, 50)
        XCTAssertEqual(ElementGeometry.resize(r, handle: .right, to: CGPoint(x: 0, y: 30)), rect(0, 10, 10, 50))
        XCTAssertEqual(ElementGeometry.resize(r, handle: .bottomRight, to: CGPoint(x: 0, y: 0)), rect(0, 0, 10, 10))
    }

    func testResizeKeepAspectChoosesSmallerFit() {
        let r = rect(0, 0, 100, 50)
        // Width would double, height triple: the smaller factor (2) wins.
        XCTAssertEqual(ElementGeometry.resize(r, handle: .bottomRight, to: CGPoint(x: 200, y: 150), keepAspect: true),
                       rect(0, 0, 200, 100))
        // Edge handle keeps aspect around the other axis' center.
        XCTAssertEqual(ElementGeometry.resize(r, handle: .right, to: CGPoint(x: 200, y: 0), keepAspect: true),
                       rect(0, -25, 200, 100))
    }

    func testResizeFromCenter() {
        let r = rect(50, 50, 100, 100)  // center (100, 100)
        XCTAssertEqual(ElementGeometry.resize(r, handle: .bottomRight, to: CGPoint(x: 160, y: 130), fromCenter: true),
                       rect(40, 70, 120, 60))
        XCTAssertEqual(ElementGeometry.resize(r, handle: .left, to: CGPoint(x: 80, y: 0), fromCenter: true),
                       rect(80, 50, 40, 100))
    }

    func testDrawnRectConstraints() {
        let s = CGPoint(x: 10, y: 10)
        XCTAssertEqual(ElementGeometry.drawnRect(from: s, to: CGPoint(x: 0, y: 30), square: false, fromCenter: false),
                       rect(0, 10, 10, 20), "dragging left works (normalized)")
        XCTAssertEqual(ElementGeometry.drawnRect(from: s, to: CGPoint(x: 30, y: 50), square: true, fromCenter: false),
                       rect(10, 10, 30, 30), "shift makes a square")
        XCTAssertEqual(ElementGeometry.drawnRect(from: s, to: CGPoint(x: 20, y: 15), square: false, fromCenter: true),
                       rect(0, 5, 20, 10), "option draws from the center")
    }

    func testLineSnapsTo15Degrees() {
        let start = CGPoint.zero
        let end = ElementGeometry.lineEnd(from: start, to: CGPoint(x: 100, y: 3), snap: true)
        XCTAssertEqual(end.y, 0, accuracy: 0.001)
        XCTAssertEqual(end.x, hypot(100, 3), accuracy: 0.001, "keeps the drag length")
        let diag = ElementGeometry.lineEnd(from: start, to: CGPoint(x: 50, y: 52), snap: true)
        XCTAssertEqual(diag.x, diag.y, accuracy: 0.001)
        XCTAssertEqual(ElementGeometry.lineEnd(from: start, to: CGPoint(x: 5, y: 3), snap: false), CGPoint(x: 5, y: 3))
    }

    func testWithBoundsScalesPointElements() {
        let l = line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 20))
        let out = ElementGeometry.withBounds(l, rect(5, 5, 20, 40))
        XCTAssertEqual(out.points, [CGPoint(x: 5, y: 5), CGPoint(x: 25, y: 45)])
    }
}

@MainActor
final class PropertiesBarRowsTests: XCTestCase {
    func testEverythingFitsInOneRow() {
        // 20 pt of insets plus 100 + 12 + 100.
        XCTAssertEqual(PropertiesBar.rows(widths: [100, 100], available: 232), [[0, 1]])
    }

    func testWrapsIntoRowsInOrder() {
        XCTAssertEqual(PropertiesBar.rows(widths: [100, 100, 100], available: 300), [[0, 1], [2]])
        XCTAssertEqual(PropertiesBar.rows(widths: [150, 150, 150, 150], available: 340), [[0, 1], [2, 3]])
    }

    func testWideGroupGetsItsOwnRowAndRowsAreCapped() {
        XCTAssertEqual(PropertiesBar.rows(widths: [50, 400, 50], available: 300), [[0], [1], [2]])
        XCTAssertEqual(PropertiesBar.rows(widths: [200, 200, 200, 200], available: 230, maxRows: 3), [[0], [1], [2, 3]])
    }
}
