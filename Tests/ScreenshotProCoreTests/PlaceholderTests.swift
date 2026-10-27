import XCTest
@testable import ScreenshotProCore

final class CoreTests: XCTestCase {
    func testFormatFromExtension() {
        XCTAssertEqual(ImageFormat(fileExtension: "JPEG"), .jpg)
        XCTAssertEqual(ImageFormat(fileExtension: "tif"), .tiff)
        XCTAssertNil(ImageFormat(fileExtension: "webp"))
    }

    func testOldDefaultColorsMoveToThePalette() throws {
        var old = ScreenshotProSettings()
        old.editorQuickColors = [.red, .green, .blue, .yellow, .black, .white]
        old.editorLineColor = .red
        let migrated = try JSONDecoder().decode(ScreenshotProSettings.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(migrated.editorQuickColors, Palette.quickColors)
        XCTAssertEqual(migrated.editorLineColor, Palette.red)
        var picked = ScreenshotProSettings()
        picked.editorQuickColors = [.black, .white]
        let kept = try JSONDecoder().decode(ScreenshotProSettings.self, from: JSONEncoder().encode(picked))
        XCTAssertEqual(kept.editorQuickColors, [.black, .white], "colors the user chose stay")
    }

    func testSettingsRoundTripAndTolerantDecoding() throws {
        var s = ScreenshotProSettings()
        s.filenamePattern = "x-${NUM}"
        s.hotkeys[.region] = KeyCombo(keyCode: 0, modifiers: [.control])
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ScreenshotProSettings.self, from: data), s)
        // Unknown and missing keys fall back to defaults instead of failing.
        let partial = try JSONDecoder().decode(ScreenshotProSettings.self, from: Data(#"{"jpegQuality": 40, "bogus": 1}"#.utf8))
        XCTAssertEqual(partial.jpegQuality, 40)
        XCTAssertEqual(partial.filenamePattern, ScreenshotProSettings().filenamePattern)
    }

    func testKeyComboDisplay() {
        XCTAssertEqual(ScreenshotProSettings.defaultHotkeys[.window]?.displayString, "⇧⌘F12")
    }

    func testPNGEncodeRoundTrip() throws {
        let ctx = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let data = try ImageEncoder.data(for: image, format: .png, scale: 2)
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 4)
        XCTAssertEqual((props[kCGImagePropertyDPIWidth] as? Double) ?? 0, 144, accuracy: 0.5)
    }
}
