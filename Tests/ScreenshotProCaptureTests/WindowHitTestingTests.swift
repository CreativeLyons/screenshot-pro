import CoreGraphics
import XCTest
@testable import ScreenshotProCapture

final class WindowHitTestingTests: XCTestCase {
    private func entry(_ id: Int, pid: Int = 100, layer: Int = 0, alpha: Double = 1,
                       x: Double, y: Double, w: Double, h: Double,
                       title: String? = "Doc", owner: String? = "App") -> [String: Any] {
        var e: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as NSDictionary,
        ]
        if let title { e[kCGWindowName as String] = title }
        if let owner { e[kCGWindowOwnerName as String] = owner }
        return e
    }

    private func info(_ id: CGWindowID, pid: pid_t = 100, layer: Int = 0, alpha: Double = 1,
                      _ rect: CGRect, title: String? = "Doc") -> WindowInfo {
        WindowInfo(id: id, processID: pid, layer: layer, alpha: alpha, bounds: rect, title: title, ownerName: "App")
    }

    func testParseKeepsOrderAndReadsFields() {
        let parsed = WindowHitTesting.parse([
            entry(7, pid: 42, layer: 3, alpha: 0.5, x: -10, y: 20, w: 300, h: 200, title: "Front", owner: "Safari"),
            entry(3, x: 0, y: 0, w: 50, h: 50, title: nil, owner: nil),
        ])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0], WindowInfo(id: 7, processID: 42, layer: 3, alpha: 0.5,
                                             bounds: CGRect(x: -10, y: 20, width: 300, height: 200),
                                             title: "Front", ownerName: "Safari"))
        XCTAssertEqual(parsed[1].id, 3)
        XCTAssertNil(parsed[1].title)
    }

    func testParseDropsEntriesWithoutBoundsOrNumber() {
        var noBounds = entry(1, x: 0, y: 0, w: 10, h: 10)
        noBounds[kCGWindowBounds as String] = nil
        var noNumber = entry(2, x: 0, y: 0, w: 10, h: 10)
        noNumber[kCGWindowNumber as String] = nil
        XCTAssertTrue(WindowHitTesting.parse([noBounds, noNumber]).isEmpty)
    }

    func testSelectableFiltersLayerAlphaSizeAndOwnProcess() {
        let windows = [
            info(1, CGRect(x: 0, y: 0, width: 400, height: 300)),
            info(2, layer: 25, CGRect(x: 0, y: 0, width: 400, height: 300)),     // status / overlay layer
            info(3, alpha: 0, CGRect(x: 0, y: 0, width: 400, height: 300)),      // invisible
            info(4, CGRect(x: 0, y: 0, width: 10, height: 300)),                 // tiny
            info(5, pid: 999, CGRect(x: 0, y: 0, width: 400, height: 300)),      // ours
            info(6, CGRect(x: 50, y: 50, width: 100, height: 100)),
        ]
        let ids = WindowHitTesting.selectable(windows, excludingPID: 999).map(\.id)
        XCTAssertEqual(ids, [1, 6])
    }

    func testHitTestReturnsFrontMostContainingWindow() {
        let windows = [
            info(1, CGRect(x: 100, y: 100, width: 100, height: 100)),
            info(2, CGRect(x: 0, y: 0, width: 500, height: 500)),
        ]
        XCTAssertEqual(WindowHitTesting.window(at: CGPoint(x: 150, y: 150), in: windows)?.id, 1)
        XCTAssertEqual(WindowHitTesting.window(at: CGPoint(x: 50, y: 50), in: windows)?.id, 2)
        XCTAssertNil(WindowHitTesting.window(at: CGPoint(x: 600, y: 50), in: windows))
    }

    func testListableNeedsATitle() {
        let windows = [
            info(1, CGRect(x: 0, y: 0, width: 400, height: 300), title: "Report"),
            info(2, CGRect(x: 0, y: 0, width: 400, height: 300), title: ""),
            info(3, CGRect(x: 0, y: 0, width: 400, height: 300), title: nil),
        ]
        XCTAssertEqual(WindowHitTesting.listable(windows, excludingPID: 0).map(\.id), [1])
    }

    func testSortedByZOrderPutsUnknownLast() {
        let ids: [CGWindowID] = [10, 20, 30, 40]
        let sorted = WindowHitTesting.sorted(ids, byZOrder: [30, 10, 99], id: { $0 })
        XCTAssertEqual(sorted, [30, 10, 20, 40])
    }

    func testDisplayTitleFallsBackToOwner() {
        var w = info(1, CGRect(x: 0, y: 0, width: 50, height: 50), title: "")
        XCTAssertEqual(w.displayTitle, "App")
        w.ownerName = nil
        XCTAssertNil(w.displayTitle)
    }
}
