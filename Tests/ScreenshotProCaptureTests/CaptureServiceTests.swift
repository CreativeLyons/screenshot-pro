import AppKit
import ScreenshotProCore
import ImageIO
import XCTest
@testable import ScreenshotProCapture

@MainActor
final class CaptureServiceTests: XCTestCase {
    func testServiceStartsIdle() {
        XCTAssertFalse(CaptureService().isCapturing)
    }

    func testDecodeReadsScaleFromDPI() throws {
        let image = try solidImage(width: 40, height: 20)
        let data = try ImageEncoder.data(for: image, format: .png, scale: 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(ImageImport.decode(source))
        XCTAssertEqual(decoded.image.width, 40)
        XCTAssertEqual(decoded.scale, 2)
    }

    func testPasteboardWithoutImageThrows() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotProCaptureTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("no image here", forType: .string)
        XCTAssertThrowsError(try ImageImport.fromPasteboard(pasteboard)) { error in
            XCTAssertEqual(error as? ScreenshotProError, .noImageOnClipboard)
        }
    }

    func testPasteboardPNGBecomesClipboardCapture() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotProCaptureTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let data = try ImageEncoder.data(for: try solidImage(width: 30, height: 10), format: .png, scale: 2)
        pasteboard.setData(data, forType: .png)

        let capture = try ImageImport.fromPasteboard(pasteboard)
        XCTAssertEqual(capture.details.mode, .clipboard)
        XCTAssertEqual(capture.details.title, "Clipboard")
        XCTAssertEqual(capture.details.scale, 2)
        XCTAssertEqual(capture.pointSize, CGSize(width: 15, height: 5))
    }

    func testFileCaptureUsesFileNameAndURL() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotProCaptureTests-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("Sample Shot.png")
        try ImageEncoder.write(try solidImage(width: 8, height: 8), to: url, format: .png)

        let capture = try ImageImport.fromFile(url)
        XCTAssertEqual(capture.details.mode, .file)
        XCTAssertEqual(capture.details.title, "Sample Shot")
        XCTAssertEqual(capture.details.sourceURL, url)
        XCTAssertEqual(capture.details.scale, 1)
    }

    func testUnreadableFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/ScreenshotProCaptureTests.png")
        XCTAssertThrowsError(try ImageImport.fromFile(url)) { error in
            XCTAssertEqual(error as? ScreenshotProError, .unreadableImage("ScreenshotProCaptureTests.png"))
        }
    }

    func testDisplayMatchingToleratesRounding() throws {
        let image = try solidImage(width: 4, height: 4)
        let displays = [
            FrozenDisplay(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, image: image),
            FrozenDisplay(displayID: 2, frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080), scale: 1, image: image),
        ]
        let match = SelectionOverlay.display(matching: CGRect(x: 1440.2, y: -180, width: 1920, height: 1080), in: displays)
        XCTAssertEqual(match?.displayID, 2)
        XCTAssertNil(SelectionOverlay.display(matching: CGRect(x: 0, y: 900, width: 100, height: 100), in: displays))
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }
}
