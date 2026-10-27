import CoreGraphics
import XCTest
import ScreenshotProCore
@testable import ScreenshotProEditor

final class DocumentModelTests: XCTestCase {
    func testAddAssignsSequenceAndRemove() {
        var doc = makeDocument()
        let a = doc.add(box(.rectangle, rect(0, 0, 10, 10)))
        let b = doc.add(box(.ellipse, rect(5, 5, 10, 10)))
        XCTAssertEqual(doc.elements.map(\.id), [a.id, b.id])
        XCTAssertLessThan(a.sequence, b.sequence)
        doc.remove([a.id])
        XCTAssertEqual(doc.elements.map(\.id), [b.id])
        XCTAssertNil(doc.element(a.id))
    }

    func testMoveAndUpdate() {
        var doc = makeDocument()
        let r = doc.add(box(.rectangle, rect(10, 10, 20, 20)))
        let l = doc.add(line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)))
        doc.move([r.id, l.id], by: CGPoint(x: 5, y: -3))
        XCTAssertEqual(doc.element(r.id)?.rect, rect(15, 7, 20, 20))
        XCTAssertEqual(doc.element(l.id)?.points, [CGPoint(x: 5, y: -3), CGPoint(x: 15, y: 7)])
        doc.update(r.id) { $0.style.lineThickness = 7 }
        XCTAssertEqual(doc.element(r.id)?.style.lineThickness, 7)
    }

    func testZOrder() {
        var doc = makeDocument()
        let ids = (0..<4).map { i in doc.add(box(.rectangle, rect(CGFloat(i), 0, 5, 5))).id }
        func order() -> [UUID] { doc.elements.map(\.id) }

        doc.bringToFront([ids[0]])
        XCTAssertEqual(order(), [ids[1], ids[2], ids[3], ids[0]])
        doc.sendToBack([ids[0]])
        XCTAssertEqual(order(), ids)
        doc.bringForward([ids[1]])
        XCTAssertEqual(order(), [ids[0], ids[2], ids[1], ids[3]])
        doc.sendBackward([ids[1]])
        XCTAssertEqual(order(), ids)
        // A selection already on top cannot move further.
        doc.bringForward([ids[3]])
        XCTAssertEqual(order(), ids)
        XCTAssertFalse(doc.canBringForward([ids[3]]))
        XCTAssertTrue(doc.canBringForward([ids[2]]))
        XCTAssertFalse(doc.canSendBackward([ids[0]]))
        XCTAssertTrue(doc.canSendBackward([ids[1]]))
        // Multiple selection keeps its relative order.
        doc.bringToFront([ids[0], ids[1]])
        XCTAssertEqual(order(), [ids[2], ids[3], ids[0], ids[1]])
        doc.bringForward([ids[2], ids[3]])
        XCTAssertEqual(order(), [ids[0], ids[2], ids[3], ids[1]])
    }

    func testCounterNumbering() {
        var doc = makeDocument()
        doc.counterStart = 1
        let c1 = doc.add(box(.counter, rect(0, 0, 30, 30)))
        _ = doc.add(box(.rectangle, rect(0, 0, 5, 5)))
        let c2 = doc.add(box(.counter, rect(40, 0, 30, 30)))
        let c3 = doc.add(box(.counter, rect(80, 0, 30, 30)))
        XCTAssertEqual(doc.counterNumber(for: c1.id), 1)
        XCTAssertEqual(doc.counterNumber(for: c2.id), 2)
        XCTAssertEqual(doc.counterNumber(for: c3.id), 3)

        // Z-order does not change numbering (creation order does).
        doc.sendToBack([c3.id])
        XCTAssertEqual(doc.counterNumber(for: c3.id), 3)

        // Deleting one renumbers the later ones.
        doc.remove([c1.id])
        XCTAssertEqual(doc.counterNumber(for: c2.id), 1)
        XCTAssertEqual(doc.counterNumber(for: c3.id), 2)

        // Start value applies to all.
        doc.counterStart = 5
        XCTAssertEqual(doc.counterNumber(for: c2.id), 5)

        // Reset: the next counter starts again at the start value.
        doc.resetCounter()
        let c4 = doc.add(box(.counter, rect(0, 40, 30, 30)))
        let c5 = doc.add(box(.counter, rect(0, 40, 30, 30)))
        XCTAssertEqual(doc.counterNumber(for: c4.id), 5)
        XCTAssertEqual(doc.counterNumber(for: c5.id), 6)
        XCTAssertEqual(doc.counterNumber(for: c3.id), 6)
    }

    func testAddCopiesKeepsOrderAndOffsets() {
        var doc = makeDocument()
        let a = doc.add(box(.counter, rect(0, 0, 30, 30)))
        let b = doc.add(box(.counter, rect(40, 0, 30, 30)))
        let copies = doc.addCopies(of: [a, b], offset: CGPoint(x: 10, y: 10))
        XCTAssertEqual(copies.count, 2)
        XCTAssertNotEqual(copies[0].id, a.id)
        XCTAssertEqual(copies[0].rect, rect(10, 10, 30, 30))
        XCTAssertEqual(doc.elements.count, 4)
        XCTAssertEqual(doc.counterNumber(for: copies[0].id), 3)
        XCTAssertEqual(doc.counterNumber(for: copies[1].id), 4)
    }

    func testCropRemovesOutsideAndShifts() {
        var doc = makeDocument(width: 100, height: 100)
        let inside = doc.add(box(.rectangle, rect(30, 30, 10, 10)))
        let partly = doc.add(box(.rectangle, rect(15, 15, 10, 10)))
        let outside = doc.add(box(.rectangle, rect(0, 0, 10, 10)))
        let cropRect = rect(20, 20, 50, 50)
        doc.crop(to: cropRect, croppedImage: makeImage(width: 50, height: 50))
        XCTAssertEqual(doc.size, CGSize(width: 50, height: 50))
        XCTAssertNil(doc.element(outside.id))
        XCTAssertEqual(doc.element(inside.id)?.rect, rect(10, 10, 10, 10))
        XCTAssertEqual(doc.element(partly.id)?.rect, rect(-5, -5, 10, 10))
    }

    func testRotationTransformClockwise() {
        // 100 x 80 image rotated clockwise becomes 80 x 100: (x, y) -> (H - y, x).
        let t = EditorDocument.rotationTransform(quarterTurns: 1, size: CGSize(width: 100, height: 80))
        XCTAssertEqual(CGPoint(x: 0, y: 0).applying(t), CGPoint(x: 80, y: 0))
        XCTAssertEqual(CGPoint(x: 100, y: 80).applying(t), CGPoint(x: 0, y: 100))
        XCTAssertEqual(CGPoint(x: 10, y: 20).applying(t), CGPoint(x: 60, y: 10))
    }

    func testRotationTransformCounterclockwiseAndRoundTrip() {
        let size = CGSize(width: 100, height: 80)
        let ccw = EditorDocument.rotationTransform(quarterTurns: -1, size: size)
        XCTAssertEqual(CGPoint(x: 10, y: 20).applying(ccw), CGPoint(x: 20, y: 90))
        let cw = EditorDocument.rotationTransform(quarterTurns: 1, size: CGSize(width: 80, height: 100))
        let p = CGPoint(x: 10, y: 20).applying(ccw).applying(cw)
        XCTAssertEqual(p.x, 10, accuracy: 0.0001)
        XCTAssertEqual(p.y, 20, accuracy: 0.0001)
    }

    func testRotateElementsWithImage() {
        var doc = makeDocument(width: 100, height: 80)
        let r = doc.add(box(.rectangle, rect(10, 20, 30, 10)))
        let t = EditorDocument.rotationTransform(quarterTurns: 1, size: doc.size)
        doc.replaceImage(makeImage(width: 80, height: 100), transform: t)
        // The rect spans x 10...40, y 20...30 -> x 50...60, y 10...40.
        XCTAssertEqual(doc.element(r.id)?.rect, rect(50, 10, 10, 30))
    }

    func testRotateKeepsTextBubbleCounterAndImageUpright() {
        var doc = makeDocument(width: 100, height: 80)
        let r = doc.add(box(.rectangle, rect(10, 20, 30, 10)))
        var textBox = box(.text, rect(10, 10, 60, 20))
        textBox.text = "Upright"
        let t = doc.add(textBox)
        var bubble = box(.speechBubble, rect(50, 40, 40, 20))
        bubble.tailTarget = CGPoint(x: 90, y: 70)
        let b = doc.add(bubble)
        let c = doc.add(box(.counter, rect(0, 50, 20, 20)))
        let a = doc.add(line(.arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 50, y: 10)))
        let original = doc

        doc.rotate(quarterTurns: 1, rotatedImage: makeImage(width: 80, height: 100))
        XCTAssertEqual(doc.size, CGSize(width: 80, height: 100))
        // Shapes and lines rotate: (x, y) -> (H - y, x) with H = 80.
        XCTAssertEqual(doc.element(r.id)?.rect, rect(50, 10, 10, 30))
        XCTAssertEqual(doc.element(a.id)?.points, [CGPoint(x: 80, y: 0), CGPoint(x: 70, y: 50)])
        // Text keeps its 60 x 20 size; its center (40, 20) moves to (60, 40).
        XCTAssertEqual(doc.element(t.id)?.rect, rect(30, 30, 60, 20))
        // The bubble's center (70, 50) moves to (30, 70); its tail target rotates.
        XCTAssertEqual(doc.element(b.id)?.rect, rect(10, 60, 40, 20))
        XCTAssertEqual(doc.element(b.id)?.tailTarget, CGPoint(x: 10, y: 90))
        // The counter stays a 20 x 20 circle around its rotated center (10, 60) -> (20, 10).
        XCTAssertEqual(doc.element(c.id)?.rect, rect(10, 0, 20, 20))

        // A counterclockwise turn brings everything back exactly.
        doc.rotate(quarterTurns: -1, rotatedImage: original.image)
        XCTAssertEqual(doc.elements, original.elements)
    }

    func testEffectGeometryMovesElements() {
        var doc = makeDocument(width: 100, height: 80)
        let r = doc.add(box(.rectangle, rect(10, 10, 20, 20)))
        let l = doc.add(line(.arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 50, y: 40)))
        var bubble = box(.speechBubble, rect(60, 10, 20, 20))
        bubble.tailTarget = CGPoint(x: 90, y: 50)
        let b = doc.add(bubble)

        // A border of 2 px: everything shifts by 2.
        let border = EffectGeometry(offset: CGPoint(x: 2, y: 2))
        doc.replaceImage(makeImage(width: 104, height: 84), transform: EditorDocument.transform(for: border))
        XCTAssertEqual(doc.element(r.id)?.rect, rect(12, 12, 20, 20))
        XCTAssertEqual(doc.element(l.id)?.points, [CGPoint(x: 2, y: 2), CGPoint(x: 52, y: 42)])
        XCTAssertEqual(doc.element(b.id)?.tailTarget, CGPoint(x: 92, y: 52))

        // A resize to half: scale first, then offset.
        let half = EffectGeometry(offset: CGPoint(x: 1, y: 0), scale: CGSize(width: 0.5, height: 0.5))
        doc.replaceImage(makeImage(width: 52, height: 42), transform: EditorDocument.transform(for: half))
        XCTAssertEqual(doc.element(r.id)?.rect, rect(7, 6, 10, 10))
    }

    func testDocumentEqualityUsesImageIdentity() {
        let image = makeImage(width: 4, height: 4)
        let a = EditorDocument(image: image)
        var b = EditorDocument(image: image)
        XCTAssertEqual(a, b)
        b.image = makeImage(width: 4, height: 4)
        XCTAssertNotEqual(a, b)
    }

    func testFieldsPerTypeAndCommonFields() {
        let rectFields = ElementField.fields(for: .rectangle, style: ElementStyle())
        XCTAssertEqual(rectFields, [.lineThickness, .lineColor, .fillColor, .shadow, .sketchy])
        XCTAssertEqual(ElementField.fields(for: .marker, style: ElementStyle()), [.lineThickness, .lineColor])
        var cycling = ElementStyle()
        cycling.cycleColors = true
        XCTAssertFalse(ElementField.fields(for: .counter, style: cycling).contains(.fillColor),
                       "rainbow numbers pick their own fill")
        var hl = ElementStyle()
        hl.highlightMode = .area
        XCTAssertEqual(ElementField.fields(for: .highlight, style: hl), [.highlightMode, .brightness, .blurRadius])
        var ob = ElementStyle()
        ob.obfuscateMode = .blur
        XCTAssertEqual(ElementField.fields(for: .obfuscate, style: ob), [.obfuscateMode, .blurRadius])
        let common = ElementField.commonFields(of: [box(.rectangle, .zero), line(from: .zero, to: .zero)])
        XCTAssertEqual(common, [.lineThickness, .lineColor, .shadow, .sketchy])
    }

    func testDefaultsFollowSettings() {
        var settings = ScreenshotProSettings()
        settings.editorLineColor = .blue
        settings.editorLineThickness = 5
        settings.pixelSize = 9
        XCTAssertEqual(ElementStyle.defaults(for: .rectangle, settings: settings).lineColor, .blue)
        XCTAssertEqual(ElementStyle.defaults(for: .rectangle, settings: settings).lineThickness, 5)
        XCTAssertEqual(ElementStyle.defaults(for: .obfuscate, settings: settings).pixelSize, 9)
        let bubble = ElementStyle.defaults(for: .speechBubble, settings: settings)
        XCTAssertTrue(bubble.bold)
        XCTAssertEqual(bubble.fillColor, .white)
        XCTAssertFalse(ElementStyle.defaults(for: .counter, settings: settings).shadow)
    }

    func testStyleScaling() {
        var s = ElementStyle()
        s.lineThickness = 2
        s.fontSize = 11
        let px = s.scaled(by: 2)
        XCTAssertEqual(px.lineThickness, 4)
        XCTAssertEqual(px.fontSize, 22)
        XCTAssertEqual(px.scaled(by: 0.5), s)
    }

    func testZoomLevels() {
        XCTAssertEqual(ZoomLevels.next(after: 1), 2)
        XCTAssertEqual(ZoomLevels.previous(before: 1), 0.75)
        XCTAssertEqual(ZoomLevels.next(after: 6), 6)
        XCTAssertEqual(ZoomLevels.previous(before: 0.25), 0.25)
        XCTAssertEqual(ZoomLevels.previous(before: 0.75), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ZoomLevels.fit(content: CGSize(width: 2000, height: 1000), available: CGSize(width: 1000, height: 1000)), 0.5)
        XCTAssertEqual(ZoomLevels.fit(content: CGSize(width: 100, height: 100), available: CGSize(width: 1000, height: 1000)), 6)
        XCTAssertEqual(ZoomLevels.label(for: 2.0 / 3.0), "66.7 %")
        XCTAssertEqual(ZoomLevels.label(for: 1), "100 %")
    }

    func testToolKeys() {
        XCTAssertEqual(EditorTool.forKey("r"), .rectangle)
        XCTAssertEqual(EditorTool.forKey("n"), .counter)
        XCTAssertEqual(EditorTool.forKey("v"), .select)
        XCTAssertEqual(EditorTool.forKey("b"), .blur)
        XCTAssertEqual(EditorTool.forKey("p"), .pixelate)
        XCTAssertEqual(EditorTool.blur.obfuscateMode, .blur)
        XCTAssertEqual(EditorTool.pixelate.obfuscateMode, .pixelate)
        XCTAssertNil(EditorTool.forKey("q"))
        // Every tool letter is unique.
        XCTAssertEqual(Set(EditorTool.allCases.map(\.key)).count, EditorTool.allCases.count)
    }
}
