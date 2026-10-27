import CoreGraphics
import XCTest
import ScreenshotProCore
@testable import ScreenshotProEditor

final class DocumentHistoryTests: XCTestCase {
    private func state(_ doc: EditorDocument) -> HistoryState { HistoryState(document: doc, selection: []) }

    func testUndoRedoStacks() {
        let history = DocumentHistory()
        var doc = makeDocument()
        let s0 = state(doc)
        doc.add(box(.rectangle, rect(0, 0, 5, 5)))
        history.record(before: s0, name: "Add")
        let s1 = state(doc)
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undoName, "Add")

        let undone = history.undo(current: s1)
        XCTAssertEqual(undone?.state, s0)
        XCTAssertTrue(history.canRedo)
        let redone = history.redo(current: s0)
        XCTAssertEqual(redone?.state, s1)
        XCTAssertFalse(history.canRedo)
    }

    func testNewStepClearsRedo() {
        let history = DocumentHistory()
        let doc = makeDocument()
        history.record(before: state(doc), name: "A")
        _ = history.undo(current: state(doc))
        XCTAssertTrue(history.canRedo)
        history.record(before: state(doc), name: "B")
        XCTAssertFalse(history.canRedo)
    }

    func testMergeKeyFoldsConsecutiveSteps() {
        let history = DocumentHistory()
        let doc = makeDocument()
        XCTAssertEqual(history.record(before: state(doc), name: "Move", mergeKey: "nudge"), .pushed(dropped: 0))
        XCTAssertEqual(history.record(before: state(doc), name: "Move", mergeKey: "nudge"), .merged)
        XCTAssertEqual(history.undoStack.count, 1)
        // A different key starts a new step, and so does the same key after an undo.
        history.record(before: state(doc), name: "Color", mergeKey: "color")
        XCTAssertEqual(history.undoStack.count, 2)
        _ = history.undo(current: state(doc))
        XCTAssertEqual(history.record(before: state(doc), name: "Color", mergeKey: "color"), .pushed(dropped: 0))
    }

    func testByteBudgetDropsOldestImageSteps() {
        var doc = makeDocument(width: 10, height: 10)
        // Allow two and a half retained images.
        let bytes = doc.imageByteCount
        let history = DocumentHistory(byteBudget: bytes * 5 / 2)
        for i in 0..<5 {
            let before = state(doc)
            doc.replaceImage(makeImage(width: 10, height: 10))
            history.record(before: before, name: "Effect \(i)", current: doc.image)
        }
        XCTAssertLessThanOrEqual(history.retainedImageBytes(current: doc.image), bytes * 5 / 2)
        XCTAssertEqual(history.undoStack.count, 2)
        XCTAssertEqual(history.undoStack.last?.name, "Effect 4")
    }

    func testAnnotationStepsShareTheImage() {
        let history = DocumentHistory(byteBudget: 1)
        var doc = makeDocument(width: 10, height: 10)
        for _ in 0..<10 {
            let before = state(doc)
            doc.add(box(.rectangle, rect(0, 0, 5, 5)))
            history.record(before: before, name: "Add", current: doc.image)
        }
        XCTAssertEqual(history.retainedImageBytes(current: doc.image), 0)
        XCTAssertEqual(history.undoStack.count, 10)
    }
}

@MainActor
final class EditorSessionUndoTests: XCTestCase {
    private func makeSession() -> (EditorSession, UndoManager) {
        let session = EditorSession(document: makeDocument(), toolDefaults: ToolDefaults(defaults: nil))
        let um = UndoManager()
        um.groupsByEvent = false
        session.undoManager = um
        return (session, um)
    }

    func testUndoRedoUndoThroughUndoManager() {
        let (session, um) = makeSession()
        session.add(box(.rectangle, rect(0, 0, 10, 10)))
        XCTAssertEqual(session.document.elements.count, 1)
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(um.undoActionName, "Add Rectangle")

        um.undo()
        XCTAssertEqual(session.document.elements.count, 0)
        XCTAssertTrue(um.canRedo)

        um.redo()
        XCTAssertEqual(session.document.elements.count, 1)
        XCTAssertTrue(um.canUndo, "redo must register a new undo")

        um.undo()
        XCTAssertEqual(session.document.elements.count, 0)
        um.redo()
        XCTAssertEqual(session.document.elements.count, 1)
    }

    func testMultipleStepsAndRedoClearedByNewChange() {
        let (session, um) = makeSession()
        let a = session.add(box(.rectangle, rect(0, 0, 10, 10)))
        session.selection = [a.id]
        session.deleteSelection()
        XCTAssertTrue(session.document.elements.isEmpty)
        um.undo()
        XCTAssertEqual(session.document.elements.map(\.id), [a.id])
        XCTAssertEqual(session.selection, [a.id], "undo restores the selection")
        um.undo()
        XCTAssertTrue(session.document.elements.isEmpty)
        XCTAssertFalse(um.canUndo)
        um.redo()
        session.add(box(.ellipse, rect(0, 0, 5, 5)))
        XCTAssertFalse(um.canRedo)
        XCTAssertEqual(session.document.elements.count, 2)
    }

    func testNudgesMergeIntoOneStep() {
        let (session, um) = makeSession()
        let a = session.add(box(.rectangle, rect(0, 0, 10, 10)))
        session.selection = [a.id]
        for _ in 0..<5 { session.nudge(by: CGPoint(x: 1, y: 0)) }
        XCTAssertEqual(session.document.element(a.id)?.rect.minX, 5)
        um.undo()
        XCTAssertEqual(session.document.element(a.id)?.rect.minX, 0)
        um.undo()
        XCTAssertNil(session.document.element(a.id))
    }

    func testGestureIsOneStepAndCancelRestores() {
        let (session, um) = makeSession()
        let a = session.add(box(.rectangle, rect(0, 0, 10, 10)))
        session.selection = [a.id]
        session.beginGesture()
        for _ in 0..<10 { session.updateGesture { $0.move([a.id], by: CGPoint(x: 1, y: 1)) } }
        session.endGesture(name: "Move")
        XCTAssertEqual(session.document.element(a.id)?.rect.origin, CGPoint(x: 10, y: 10))
        XCTAssertEqual(um.undoActionName, "Move")
        um.undo()
        XCTAssertEqual(session.document.element(a.id)?.rect.origin, .zero)

        session.beginGesture()
        session.updateGesture { $0.move([a.id], by: CGPoint(x: 3, y: 3)) }
        session.cancelGesture()
        XCTAssertEqual(session.document.element(a.id)?.rect.origin, .zero)
    }

    func testGestureWithoutChangeRecordsNothing() {
        let (session, _) = makeSession()
        session.beginGesture()
        session.endGesture(name: "Move")
        XCTAssertFalse(session.canUndo)
    }

    func testStyleChangeAppliesToSelectionAndMerges() {
        let (session, um) = makeSession()
        let r = session.add(box(.rectangle, rect(0, 0, 10, 10)))
        let c = session.add(box(.counter, rect(20, 0, 30, 30)))
        session.selection = [r.id, c.id]
        let settings = ScreenshotProSettings()
        session.setStyle(.lineThickness, toolType: nil, settings: settings) { $0.lineThickness = 5 }
        // Counters have no line thickness field, so only the rectangle changes.
        XCTAssertEqual(session.document.element(r.id)?.style.lineThickness, 5)
        XCTAssertEqual(session.document.element(c.id)?.style.lineThickness, 0)
        session.setStyle(.lineThickness, toolType: nil, settings: settings) { $0.lineThickness = 6 }
        um.undo()
        XCTAssertEqual(session.document.element(r.id)?.style.lineThickness, 2)
        // The value is remembered for new rectangles.
        XCTAssertEqual(session.toolDefaults.style(for: .rectangle, settings: settings).lineThickness, 6)
    }

    func testStyleChangeIsInPointsOnRetina() {
        let session = EditorSession(document: makeDocument(scale: 2), toolDefaults: ToolDefaults(defaults: nil))
        let style = session.newElementStyle(.rectangle, settings: ScreenshotProSettings())
        XCTAssertEqual(style.lineThickness, 4, "2 pt default is 4 px at 2x")
        let r = session.add(Element(type: .rectangle, rect: rect(0, 0, 10, 10), style: style))
        session.selection = [r.id]
        session.setStyle(.lineThickness, toolType: nil, settings: ScreenshotProSettings()) { $0.lineThickness = 3 }
        XCTAssertEqual(session.document.element(r.id)?.style.lineThickness, 6)
    }

    func testDuplicateAndPaste() {
        let (session, um) = makeSession()
        let r = session.add(box(.rectangle, rect(10, 10, 10, 10)))
        session.selection = [r.id]
        session.duplicate()
        XCTAssertEqual(session.document.elements.count, 2)
        let copy = session.selectedElements.first
        XCTAssertEqual(copy?.rect, rect(20, 20, 10, 10))
        um.undo()
        XCTAssertEqual(session.document.elements.count, 1)

        // Paste into the same document offsets by 10; from another document keeps positions.
        session.paste(ElementClipboard(sourceDocument: session.id, elements: [r]))
        XCTAssertEqual(session.selectedElements.first?.rect, rect(20, 20, 10, 10))
        session.paste(ElementClipboard(sourceDocument: UUID(), elements: [r]))
        XCTAssertEqual(session.selectedElements.first?.rect, rect(10, 10, 10, 10))
        // A group that would not fit is moved back inside the canvas.
        session.paste(ElementClipboard(sourceDocument: UUID(), elements: [box(.rectangle, rect(95, 75, 10, 10))]))
        XCTAssertEqual(session.selectedElements.first?.rect, rect(90, 70, 10, 10))
    }

    func testImageChangeIsUndoable() {
        let (session, um) = makeSession()
        let original = session.document.image
        let r = session.add(box(.rectangle, rect(10, 10, 10, 10)))
        session.applyImageChange("Border", image: makeImage(width: 104, height: 84),
                                 transform: CGAffineTransform(translationX: 2, y: 2))
        XCTAssertEqual(session.document.size, CGSize(width: 104, height: 84))
        XCTAssertEqual(session.document.element(r.id)?.rect.origin, CGPoint(x: 12, y: 12))
        um.undo()
        XCTAssertTrue(session.document.image === original)
        XCTAssertEqual(session.document.element(r.id)?.rect.origin, CGPoint(x: 10, y: 10))
        um.redo()
        XCTAssertEqual(session.document.size, CGSize(width: 104, height: 84))
    }

    func testCounterResetIsUndoable() {
        let (session, um) = makeSession()
        let a = session.add(box(.counter, rect(0, 0, 30, 30)))
        session.resetCounter()
        let b = session.add(box(.counter, rect(40, 0, 30, 30)))
        XCTAssertEqual(session.document.counterNumber(for: b.id), 1)
        um.undo()
        um.undo()
        let c = session.add(box(.counter, rect(40, 0, 30, 30)))
        XCTAssertEqual(session.document.counterNumber(for: a.id), 1)
        XCTAssertEqual(session.document.counterNumber(for: c.id), 2)
    }

    func testEachActionIsOneUndoStepWithEventGrouping() {
        // AppKit's default: one top-level group per event. Two actions without an event in
        // between must still undo one at a time.
        let session = EditorSession(document: makeDocument(), toolDefaults: ToolDefaults(defaults: nil))
        let um = UndoManager()
        XCTAssertTrue(um.groupsByEvent)
        session.undoManager = um
        let original = session.document.image
        session.applyImageChange("Border", image: makeImage(width: 104, height: 84),
                                 transform: CGAffineTransform(translationX: 2, y: 2))
        session.add(box(.rectangle, rect(0, 0, 10, 10)))
        XCTAssertEqual(um.undoActionName, "Add Rectangle")
        um.undo()
        XCTAssertTrue(session.document.elements.isEmpty, "the first undo removes only the rectangle")
        XCTAssertEqual(session.document.size, CGSize(width: 104, height: 84))
        XCTAssertEqual(um.undoActionName, "Border")
        um.undo()
        XCTAssertTrue(session.document.image === original)
        XCTAssertFalse(um.canUndo)
        um.redo()
        XCTAssertEqual(session.document.size, CGSize(width: 104, height: 84))
        XCTAssertTrue(session.document.elements.isEmpty, "one redo restores only the border")
        um.redo()
        XCTAssertEqual(session.document.elements.count, 1)
        // A new action after undo/redo in the same run loop pass still records one step.
        session.deleteSelection()
        XCTAssertTrue(session.document.elements.isEmpty)
        um.undo()
        XCTAssertEqual(session.document.elements.count, 1)
    }

    func testCallerGroupIsKeptWithEventGrouping() {
        let session = EditorSession(document: makeDocument(), toolDefaults: ToolDefaults(defaults: nil))
        let um = UndoManager()
        session.undoManager = um
        um.beginUndoGrouping()
        session.add(box(.rectangle, rect(0, 0, 10, 10)))
        session.add(box(.ellipse, rect(0, 0, 10, 10)))
        um.endUndoGrouping()
        um.undo()
        XCTAssertTrue(session.document.elements.isEmpty, "an explicit caller group undoes as one")
    }

    func testModifiedFlag() {
        let (session, _) = makeSession()
        XCTAssertFalse(session.isModified)
        session.add(box(.rectangle, rect(0, 0, 5, 5)))
        XCTAssertTrue(session.isModified)
        session.markSaved()
        XCTAssertFalse(session.isModified)
    }
}
