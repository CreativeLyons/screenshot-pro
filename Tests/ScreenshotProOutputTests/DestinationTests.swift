import AppKit
import ScreenshotProCore
import XCTest
@testable import ScreenshotProOutput

/// A solid-color test image.
func makeImage(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@MainActor
final class DestinationTests: XCTestCase {
    // MARK: Registry

    func testRegisterAllAddsEveryStandardDestinationInTableOrder() {
        let registry = DestinationRegistry()
        StandardDestinations.registerAll(in: registry)
        XCTAssertEqual(registry.all.map(\.id), [
            DestinationID.file, DestinationID.saveAs, DestinationID.clipboard, DestinationID.printer,
            DestinationID.mail, DestinationID.share, DestinationID.ocr, DestinationID.openWith,
        ])
        XCTAssertNil(registry.destination(id: DestinationID.editor))
    }

    func testPrioritiesSortAfterTheEditor() {
        let priorities = StandardDestinations.makeAll().map(\.priority)
        XCTAssertEqual(priorities, priorities.sorted())
        XCTAssertEqual(Set(priorities).count, priorities.count)
        XCTAssertTrue(priorities.allSatisfy { $0 > 0 }, "the editor uses priority 0")
    }

    func testNamesSymbolsAndFlags() {
        let names = StandardDestinations.makeAll().map(\.displayName)
        XCTAssertEqual(names, ["Save", "Save as...", "Copy to Clipboard", "Print...", "Send as Mail", "Share...",
                               "Copy Text (OCR)", "Open in Preview"])
        for destination in StandardDestinations.makeAll() {
            XCTAssertNotNil(NSImage(systemSymbolName: destination.symbolName, accessibilityDescription: nil),
                            destination.symbolName)
            XCTAssertFalse(destination.isEditor)
        }
        // Evaluating availability must not crash, whatever mail setup this Mac has.
        _ = MailDestination().isAvailable
    }

    func testShortcutKeys() {
        let expected: [String: Character] = [
            "editor": "E", "file": "S", "saveAs": "A", "clipboard": "C", "printer": "P",
            "mail": "M", "share": "H", "ocr": "O", "openWith": "V",
        ]
        for (id, key) in expected {
            XCTAssertEqual(StandardDestinations.shortcutKey(for: id), key, id)
        }
        XCTAssertEqual(Set(StandardDestinations.shortcutKeys.values).count, StandardDestinations.shortcutKeys.count)
        XCTAssertNil(StandardDestinations.shortcutKey(for: "unknown"))
    }

    // MARK: Quality and format

    func testQualityPromptOnlyForLossyFormats() {
        for format in ImageFormat.allCases {
            XCTAssertFalse(QualityPolicy.needsPrompt(format: format, promptForQuality: false), format.rawValue)
            let lossy = format == .jpg || format == .heic || format == .avif
            XCTAssertEqual(QualityPolicy.needsPrompt(format: format, promptForQuality: true), lossy, format.rawValue)
        }
    }

    func testQualityIsClamped() {
        XCTAssertEqual(QualityPolicy.clamped(0), 1)
        XCTAssertEqual(QualityPolicy.clamped(-20), 1)
        XCTAssertEqual(QualityPolicy.clamped(1), 1)
        XCTAssertEqual(QualityPolicy.clamped(85), 85)
        XCTAssertEqual(QualityPolicy.clamped(100), 100)
        XCTAssertEqual(QualityPolicy.clamped(250), 100)
    }

    func testRenamingForFormatPopup() {
        XCTAssertEqual(QualityPolicy.renamed("shot.png", to: .jpg), "shot.jpg")
        XCTAssertEqual(QualityPolicy.renamed("shot.JPEG", to: .png), "shot.png")
        XCTAssertEqual(QualityPolicy.renamed("shot.tif", to: .heic), "shot.heic")
        XCTAssertEqual(QualityPolicy.renamed("Screenshot 10.11.12", to: .png), "Screenshot 10.11.12.png")
        XCTAssertEqual(QualityPolicy.renamed("notes.txt", to: .pdf), "notes.txt.pdf")
        XCTAssertEqual(QualityPolicy.renamed("shot", to: .gif), "shot.gif")
    }

    func testLossyQualityChangesEncodedSize() throws {
        // Noise compresses differently at different qualities.
        let width = 64, height = 64
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                ctx.setFillColor(CGColor(gray: CGFloat(generator.next() % 256) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = ctx.makeImage()!
        let low = try ImageEncoder.data(for: image, format: .jpg, quality: QualityPolicy.clamped(0))
        let high = try ImageEncoder.data(for: image, format: .jpg, quality: QualityPolicy.clamped(100))
        XCTAssertLessThan(low.count, high.count)
    }

    func testSaveAsStartFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotProOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026"), withIntermediateDirectories: true)
        XCTAssertEqual(SaveAsDestination.startFolder(output: root, expandedName: "shot").path, root.path)
        XCTAssertEqual(SaveAsDestination.startFolder(output: root, expandedName: "2026/shot").path,
                       root.appendingPathComponent("2026").path)
        XCTAssertEqual(SaveAsDestination.startFolder(output: root, expandedName: "1999/shot").path, root.path)
    }

    // MARK: Clipboard

    func testClipboardHasPNGAndTIFFAtPointSize() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotProOutputTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let capture = Capture(image: makeImage(width: 40, height: 20), details: CaptureDetails(mode: .region, scale: 2))
        try ClipboardDestination.copy(capture, to: pasteboard)

        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.png))
        XCTAssertTrue(types.contains(.tiff))
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, 40)
        let image = try XCTUnwrap(NSImage(pasteboard: pasteboard))
        XCTAssertEqual(image.size, CGSize(width: 20, height: 10))
        let tiffRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pasteboard.data(forType: .tiff))))
        XCTAssertEqual(tiffRep.pixelsWide, 40)
        XCTAssertEqual(tiffRep.size, CGSize(width: 20, height: 10))
    }

    // MARK: OCR

    func testOCRJoiningAndMessages() {
        XCTAssertNil(OCRDestination.joined([]))
        XCTAssertNil(OCRDestination.joined(["  ", "\n"]))
        XCTAssertEqual(OCRDestination.joined([" Hello ", "", "World"]), "Hello\nWorld")
        XCTAssertEqual(OCRDestination.message(lineCount: 1), "Copied 1 line of text")
        XCTAssertEqual(OCRDestination.message(lineCount: 3), "Copied 3 lines of text")
    }

    func testOCRRecognizesRenderedText() async throws {
        let width = 600, height = 160
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Screenshot Pro" as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let lines = try await OCRDestination.recognizeLines(in: ctx.makeImage()!)
        XCTAssertTrue(lines.joined(separator: " ").localizedCaseInsensitiveContains("Screenshot"), "\(lines)")
    }

    func testOCROnBlankImageFindsNothing() async throws {
        let lines = try await OCRDestination.recognizeLines(in: makeImage(width: 200, height: 100, gray: 1))
        XCTAssertNil(OCRDestination.joined(lines))
    }

    // MARK: Print layout

    private let letter = CGSize(width: 468, height: 648)   // US Letter minus 72 pt margins (portrait)
    private func options(fit: Bool = true, enlarge: Bool = false, center: Bool = true,
                         rotate: Bool = false) -> PrintLayout.Options {
        PrintLayout.Options(fitToPage: fit, allowEnlarge: enlarge, center: center, allowRotate: rotate)
    }

    func testSmallImageIsCenteredAtTrueSize() {
        let layout = PrintLayout.compute(imageSize: CGSize(width: 100, height: 50), area: letter, options: options())
        XCTAssertFalse(layout.rotated)
        XCTAssertEqual(layout.rect, CGRect(x: 184, y: 299, width: 100, height: 50))
    }

    func testSmallImageTopLeftWhenNotCentered() {
        let layout = PrintLayout.compute(imageSize: CGSize(width: 100, height: 50), area: letter,
                                         options: options(center: false))
        XCTAssertEqual(layout.rect.origin, .zero)
    }

    func testEnlargeOnlyWhenAllowed() {
        let small = CGSize(width: 100, height: 100)
        XCTAssertEqual(PrintLayout.compute(imageSize: small, area: letter, options: options()).rect.size, small)
        let enlarged = PrintLayout.compute(imageSize: small, area: letter, options: options(enlarge: true))
        XCTAssertEqual(enlarged.rect.size, CGSize(width: 468, height: 468))
    }

    func testLargeImageShrinksToFitKeepingAspect() {
        let layout = PrintLayout.compute(imageSize: CGSize(width: 936, height: 468), area: letter, options: options())
        XCTAssertEqual(layout.rect.size, CGSize(width: 468, height: 234))
        XCTAssertEqual(layout.rect.minX, 0)
    }

    func testLargeImageIsClippedWhenFitIsOff() {
        let layout = PrintLayout.compute(imageSize: CGSize(width: 936, height: 468), area: letter,
                                         options: options(fit: false))
        XCTAssertEqual(layout.rect.size, CGSize(width: 936, height: 468))
    }

    func testRotationMatchesPageOrientation() {
        let wide = CGSize(width: 900, height: 300)
        let rotated = PrintLayout.compute(imageSize: wide, area: letter, options: options(rotate: true))
        XCTAssertTrue(rotated.rotated)
        XCTAssertEqual(rotated.rect.width / rotated.rect.height, 300.0 / 900.0, accuracy: 0.001)
        XCTAssertEqual(rotated.rect.height, 648, accuracy: 0.001)

        XCTAssertFalse(PrintLayout.compute(imageSize: wide, area: letter, options: options(rotate: false)).rotated)
        XCTAssertFalse(PrintLayout.compute(imageSize: CGSize(width: 300, height: 900), area: letter,
                                           options: options(rotate: true)).rotated, "already matches")
        XCTAssertFalse(PrintLayout.compute(imageSize: CGSize(width: 500, height: 500), area: letter,
                                           options: options(rotate: true)).rotated, "square")
    }

    func testDegenerateSizes() {
        XCTAssertEqual(PrintLayout.compute(imageSize: .zero, area: letter, options: options()).rect, .zero)
        XCTAssertEqual(PrintLayout.compute(imageSize: CGSize(width: 10, height: 10), area: .zero, options: options()).rect, .zero)
    }

    func testFooterText() {
        let details = CaptureDetails(mode: .window, date: Fixture.date, title: "Report")
        let text = PrinterDestination.footerText(for: details, locale: Locale(identifier: "en_US"), timeZone: Fixture.utc)
        XCTAssertTrue(text.hasPrefix("October 25, 2026"), text)
        XCTAssertTrue(text.contains("10:11:12"), text)
        XCTAssertTrue(text.hasSuffix(" - Report"), text)
        let untitled = PrinterDestination.footerText(for: CaptureDetails(mode: .region, date: Fixture.date),
                                                     locale: Locale(identifier: "en_US"), timeZone: Fixture.utc)
        XCTAssertTrue(untitled.hasSuffix(" - Screenshot"), untitled)
    }

    // MARK: Picker geometry and keys

    func testPickerKeyLookup() {
        let ids = ["editor", "file", "clipboard", "ocr", "custom"]
        XCTAssertEqual(DestinationPickerController.index(forKey: "e", in: ids), 0)
        XCTAssertEqual(DestinationPickerController.index(forKey: "S", in: ids), 1)
        XCTAssertEqual(DestinationPickerController.index(forKey: "c", in: ids), 2)
        XCTAssertEqual(DestinationPickerController.index(forKey: "O", in: ids), 3)
        XCTAssertNil(DestinationPickerController.index(forKey: "M", in: ids), "mail is not in the list")
        XCTAssertNil(DestinationPickerController.index(forKey: "x", in: ids))
    }

    func testPickerPreviewSize() {
        XCTAssertEqual(DestinationPickerController.previewSize(for: CGSize(width: 100, height: 50)),
                       CGSize(width: 100, height: 50))
        XCTAssertEqual(DestinationPickerController.previewSize(for: CGSize(width: 1600, height: 800)),
                       CGSize(width: 400, height: 200))
        XCTAssertEqual(DestinationPickerController.previewSize(for: CGSize(width: 400, height: 1000)),
                       CGSize(width: 104, height: 260))
    }

    func testPickerStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 300, height: 400)
        let middle = DestinationPickerController.origin(for: size, mouse: CGPoint(x: 500, y: 600), screens: [screen])
        XCTAssertEqual(middle, CGPoint(x: 508, y: 192))
        let corner = DestinationPickerController.origin(for: size, mouse: CGPoint(x: 1430, y: 20), screens: [screen])
        XCTAssertEqual(corner, CGPoint(x: 1140, y: 0))
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let other = DestinationPickerController.origin(for: size, mouse: CGPoint(x: 1500, y: 1000),
                                                       screens: [screen, second])
        XCTAssertEqual(other, CGPoint(x: 1508, y: 592))
    }

    func testHistoryClickOpensAndCommandClickCopies() {
        XCTAssertEqual(HistoryStrip.clickAction(for: []), .open)
        XCTAssertEqual(HistoryStrip.clickAction(for: [.shift]), .toggleSelection)
        XCTAssertEqual(HistoryStrip.clickAction(for: [.command]), .copy)
        XCTAssertEqual(HistoryStrip.clickAction(for: [.command, .shift]), .toggleSelection)
    }

    func testFilmstripSnapsOnlyNearAnEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        func snap(_ x: CGFloat) -> HistoryStripEdge? {
            HistoryStripController.snapEdge(for: CGRect(x: x, y: 300, width: 144, height: 400), in: visible)
        }
        XCTAssertEqual(snap(10), .left)
        XCTAssertEqual(snap(-40), .left, "dragged partly off screen")
        XCTAssertEqual(snap(59), .left)
        XCTAssertNil(snap(60), "out in the open")
        XCTAssertNil(snap(600))
        XCTAssertNil(snap(1440 - 144 - 60))
        XCTAssertEqual(snap(1440 - 144 - 20), .right)
        XCTAssertEqual(snap(1400), .right, "dragged partly off screen")
        // A screen narrower than two snap distances picks the nearer edge.
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 600)
        XCTAssertEqual(HistoryStripController.snapEdge(for: CGRect(x: 10, y: 0, width: 144, height: 100), in: narrow), .left)
        XCTAssertEqual(HistoryStripController.snapEdge(for: CGRect(x: 50, y: 0, width: 144, height: 100), in: narrow), .right)
    }

    func testFloatingFilmstripIsKeptOnScreen() {
        let area = CGRect(x: 10, y: 10, width: 1420, height: 855)
        let inside = CGRect(x: 400, y: 200, width: 144, height: 300)
        XCTAssertEqual(HistoryStripController.clamp(inside, to: area), inside)
        XCTAssertEqual(HistoryStripController.clamp(CGRect(x: 1400, y: 700, width: 144, height: 300), to: area),
                       CGRect(x: 1286, y: 565, width: 144, height: 300))
        XCTAssertEqual(HistoryStripController.clamp(CGRect(x: -50, y: -20, width: 144, height: 2000), to: area),
                       CGRect(x: 10, y: 10, width: 144, height: 855))
    }

    func testOCRNoTextMessage() {
        XCTAssertEqual(OCRDestination.noTextMessage, "No text found")
    }

    func testStatusHUDCentersBelowPointerAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 200, height: 40)
        XCTAssertEqual(StatusHUD.origin(for: size, mouse: CGPoint(x: 700, y: 500), screens: [screen]),
                       CGPoint(x: 600, y: 436))
        XCTAssertEqual(StatusHUD.origin(for: size, mouse: CGPoint(x: 5, y: 10), screens: [screen]),
                       CGPoint(x: 8, y: 8))
        XCTAssertEqual(StatusHUD.origin(for: size, mouse: CGPoint(x: 1439, y: 874), screens: [screen]),
                       CGPoint(x: 1232, y: 810))
    }
}
