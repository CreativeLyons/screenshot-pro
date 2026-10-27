import CoreGraphics
import XCTest
import ScreenshotProCore
@testable import ScreenshotProEditor

final class CodableTests: XCTestCase {
    func testElementRoundTrip() throws {
        var e = Element(type: .speechBubble, rect: rect(1, 2, 30, 40), style: ElementStyle.defaults(for: .speechBubble))
        e.text = "Hello\nWorld"
        e.tailTarget = CGPoint(x: 50, y: 60)
        e.style.arrowHeads = .both
        e.style.highlightMode = .magnify
        e.sequence = 7
        e.counterGroup = 2
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(Element.self, from: data)
        XCTAssertEqual(back, e)
    }

    func testImageElementRoundTrip() throws {
        var e = Element(type: .image, rect: rect(0, 0, 3, 2))
        e.image = EmbeddedImage(makeImage(width: 3, height: 2, color: .red))
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(Element.self, from: data)
        let img = try XCTUnwrap(back.image?.cgImage)
        XCTAssertEqual(img.width, 3)
        XCTAssertEqual(img.height, 2)
        let px = Pixels(img)
        XCTAssertEqual(px[1, 1].r, 255)
        XCTAssertEqual(px[1, 1].g, 0)
    }

    func testStyleDecodingIsTolerant() throws {
        let json = #"{"lineThickness": 9, "futureField": true}"#.data(using: .utf8)!
        let style = try JSONDecoder().decode(ElementStyle.self, from: json)
        XCTAssertEqual(style.lineThickness, 9)
        XCTAssertEqual(style.arrowHeads, ElementStyle().arrowHeads)
    }

    func testDocumentFileRoundTrip() throws {
        var doc = EditorDocument(image: makeImage(width: 8, height: 6, color: .blue), scale: 2)
        doc.counterStart = 3
        doc.add(box(.rectangle, rect(1, 1, 4, 3)))
        doc.add(line(.arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 7, y: 5)))
        doc.resetCounter()
        doc.add(box(.counter, rect(2, 2, 3, 3)))

        let data = try DocumentFile.encode(doc)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["format"] as? String, "sspro")
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertNotNil(json?["image"] as? String, "base image embedded as base64 PNG")

        let back = try DocumentFile.decode(data)
        XCTAssertEqual(back.elements, doc.elements)
        XCTAssertEqual(back.scale, 2)
        XCTAssertEqual(back.counterStart, 3)
        XCTAssertEqual(back.counterGroup, 1)
        XCTAssertEqual(back.nextSequence, doc.nextSequence)
        XCTAssertEqual(back.size, CGSize(width: 8, height: 6))
        XCTAssertEqual(Pixels(back.image)[0, 0].b, Pixels(doc.image)[0, 0].b)
    }

    func testDocumentFileRejectsOtherJSON() {
        XCTAssertThrowsError(try DocumentFile.decode(#"{"hello": 1}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try DocumentFile.decode(Data("not json".utf8)))
    }

    func testDocumentFileWriteAndRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-test-\(UUID().uuidString).sspro")
        defer { try? FileManager.default.removeItem(at: url) }
        var doc = makeDocument(width: 5, height: 5)
        doc.add(box(.ellipse, rect(0, 0, 5, 5)))
        try DocumentFile.write(doc, to: url)
        let back = try DocumentFile.read(url)
        XCTAssertEqual(back.elements, doc.elements)
    }

    func testClipboardPayloadRoundTrip() throws {
        let clip = ElementClipboard(sourceDocument: UUID(), elements: [box(.text, rect(0, 0, 10, 10))])
        let back = try JSONDecoder().decode(ElementClipboard.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(back.sourceDocument, clip.sourceDocument)
        XCTAssertEqual(back.elements, clip.elements)
    }
}
