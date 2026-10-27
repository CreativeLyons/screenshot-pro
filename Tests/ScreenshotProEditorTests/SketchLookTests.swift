import CoreGraphics
import CoreText
import ImageIO
import XCTest
import ScreenshotProCore
@testable import ScreenshotProEditor

/// The hand-drawn annotations on a picture with real text. Set SCREENSHOTPRO_SAMPLE_PNG to a file
/// path to also write the rendered sample there for a look.
final class SketchLookTests: XCTestCase {
    /// A white image with two lines of black text, and where each line sits (y down).
    private func textImage() -> (CGImage, [CGRect]) {
        let w = 640, h = 220
        let ctx = DocumentRenderer.makeContext(width: w, height: h)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var lines: [CGRect] = []
        for (i, text) in ["Screenshots deserve friendly marks", "Highlight the words that matter"].enumerated() {
            let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let baselineFromTop = CGFloat(60 + i * 70)
            ctx.textPosition = CGPoint(x: 40, y: CGFloat(h) - baselineFromTop)
            CTLineDraw(line, ctx)
            lines.append(CGRect(x: 40, y: baselineFromTop - 22, width: CTLineGetTypographicBounds(line, nil, nil, nil),
                                height: 28))
        }
        return (ctx.makeImage()!, lines)
    }

    func testMarkerSnapsToTheTextLineItWasDrawnOver() throws {
        let (image, lines) = textImage()
        let target = lines[1]
        // A wobbly sweep a little below the middle of the second line, over its first two words.
        let points = stride(from: target.minX + 4, through: target.minX + 190, by: 6).map {
            CGPoint(x: $0, y: target.midY + 6 + sin($0 / 9) * 3)
        }
        let snapped = try XCTUnwrap(MarkerSnap.snap(points, width: 16, image: image, seed: UUID()),
                                    "Vision found the text under the stroke")
        let ys = snapped.points.map(\.y)
        XCTAssertEqual(ys.reduce(0, +) / CGFloat(ys.count), target.midY, accuracy: 6, "centered on the line")
        XCTAssertGreaterThan(snapped.thickness, 18, "as tall as the text")
        XCTAssertLessThan(snapped.thickness, 50)
        XCTAssertLessThan(snapped.points.first!.x - snapped.thickness / 2, target.minX + 4, "starts at the first word")
        XCTAssertLessThan(snapped.points.last!.x + snapped.thickness / 2, target.minX + 190,
                          "stops after the last whole word, not partway through the next")

        // A scribble in the empty margin does not snap.
        let empty = [CGPoint(x: 400, y: 190), CGPoint(x: 460, y: 192), CGPoint(x: 520, y: 189)]
        XCTAssertNil(MarkerSnap.snap(empty, width: 16, image: image, seed: UUID()))

        try writeSample(image: image, lines: lines, marker: snapped)
    }

    private func writeSample(image: CGImage, lines: [CGRect], marker: MarkerSnap.Result) throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOTPRO_SAMPLE_PNG"] else { return }
        var doc = EditorDocument(image: image, scale: 1)
        var m = Element(type: .marker, points: marker.points, style: ElementStyle.defaults(for: .marker))
        m.style.lineThickness = Double(marker.thickness)
        doc.add(m)
        var r = box(.rectangle, rect(24, 18, 560, 56))
        r.style.lineThickness = 3
        doc.add(r)
        var e = box(.ellipse, rect(30, 150, 140, 60))
        e.style.lineThickness = 3
        e.style.lineColor = Palette.blue
        doc.add(e)
        var a = line(.arrow, from: CGPoint(x: 600, y: 200), to: CGPoint(x: 460, y: 130))
        a.style.lineThickness = 3
        a.style.lineColor = Palette.violet
        doc.add(a)
        for i in 0..<4 { doc.add(box(.counter, rect(220 + CGFloat(i) * 46, 170, 36, 36))) }
        let flat = try XCTUnwrap(DocumentRenderer.flatten(doc))
        let url = URL(fileURLWithPath: path)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, flat, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
