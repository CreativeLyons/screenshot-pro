import AppKit
import ScreenshotProCore

/// The live editing state of one editor window: the value document, the selection, snapshot
/// history and its `UndoManager` wiring. UI objects (canvas, bars) read from it and call its
/// operations; every document change goes through `perform` or a gesture so it is undoable.
@MainActor
final class EditorSession {
    /// Identifies this document on the element clipboard.
    let id = UUID()
    private(set) var document: EditorDocument
    /// Selected element ids.
    var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { onChange?() } }
    }
    let history: DocumentHistory
    /// The window's undo manager. Each history step registers one undo action; running it
    /// registers the inverse (redo), and redo registers undo again, so undo-redo-undo works.
    weak var undoManager: UndoManager?
    /// Called after any change to the document, selection or history.
    var onChange: (() -> Void)?
    /// Changed since the last export or save.
    private(set) var isModified = false

    /// Where remembered per-type property values go.
    let toolDefaults: ToolDefaults

    private var gestureStart: HistoryState?

    init(document: EditorDocument, history: DocumentHistory = DocumentHistory(),
         toolDefaults: ToolDefaults? = nil) {
        self.document = document
        self.history = history
        self.toolDefaults = toolDefaults ?? .shared
    }

    var state: HistoryState { HistoryState(document: document, selection: selection) }

    var selectedElements: [Element] { document.elements.filter { selection.contains($0.id) } }

    var isInGesture: Bool { gestureStart != nil }

    func markSaved() {
        isModified = false
        onChange?()
    }

    func markModified() {
        isModified = true
    }

    // MARK: Changes

    /// Applies an undoable change. Steps with the same non-nil `mergeKey` in a row merge.
    func perform(_ name: String, mergeKey: String? = nil, _ change: (inout EditorDocument, inout Set<UUID>) -> Void) {
        if isInGesture { endGesture(name: "Edit") }
        let before = state
        var doc = document
        var sel = selection
        change(&doc, &sel)
        guard doc != document else {
            selection = sel
            return
        }
        document = doc
        selection = pruned(sel)
        commit(before: before, name: name, mergeKey: mergeKey)
    }

    func perform(_ name: String, mergeKey: String? = nil, _ change: (inout EditorDocument) -> Void) {
        perform(name, mergeKey: mergeKey) { doc, _ in change(&doc) }
    }

    private func commit(before: HistoryState, name: String, mergeKey: String?) {
        let result = history.record(before: before, name: name, mergeKey: mergeKey, current: document.image)
        if case .pushed = result { registerUndo(name: name, undo: true) }
        isModified = true
        onChange?()
    }

    private func pruned(_ sel: Set<UUID>) -> Set<UUID> {
        let ids = Set(document.elements.map(\.id))
        return sel.intersection(ids)
    }

    // MARK: Gestures (drag, resize, text editing): one undo step each

    func beginGesture() {
        if gestureStart == nil { gestureStart = state }
    }

    /// Changes the document during a gesture without recording history.
    func updateGesture(_ change: (inout EditorDocument) -> Void) {
        beginGesture()
        change(&document)
        onChange?()
    }

    /// Ends the gesture, recording one step when the document changed.
    func endGesture(name: String, mergeKey: String? = nil) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        selection = pruned(selection)
        if start.document != document {
            commit(before: start, name: name, mergeKey: mergeKey)
        } else {
            onChange?()
        }
    }

    /// Ends the gesture and restores the state from before it.
    func cancelGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        document = start.document
        selection = start.selection
        onChange?()
    }

    // MARK: Undo / redo

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        if isInGesture { endGesture(name: "Edit") }
        guard let step = history.undo(current: state) else { return }
        restore(step.state)
        registerUndo(name: step.name, undo: false)
    }

    func redo() {
        if isInGesture { endGesture(name: "Edit") }
        guard let step = history.redo(current: state) else { return }
        restore(step.state)
        registerUndo(name: step.name, undo: true)
    }

    private func restore(_ s: HistoryState) {
        document = s.document
        selection = pruned(s.selection)
        isModified = true
        onChange?()
    }

    /// Registers the action that undoes (`undo == true`) or redoes the newest step. While the
    /// manager is undoing, a registration lands on its redo stack and vice versa.
    ///
    /// Every step is its own top-level undo group, so one Undo reverts exactly one action even
    /// when two actions run without an event in between (sheet results, scripted menu commands).
    /// With `groupsByEvent`, AppKit keeps one top-level group open until the next event is
    /// dispatched; a step registered while that group is open closes it and opens a fresh one,
    /// which AppKit then closes as usual. A deeper group (a caller's explicit grouping) is kept.
    private func registerUndo(name: String, undo: Bool) {
        guard let um = undoManager else { return }
        let replaying = um.isUndoing || um.isRedoing
        var opened = false
        if !replaying {
            if um.groupingLevel == 0 {
                // With groupsByEvent this may also open the event's group around ours.
                um.beginUndoGrouping()
                opened = true
            } else if um.groupingLevel == 1 && um.groupsByEvent {
                um.endUndoGrouping()
                um.beginUndoGrouping()
            }
        }
        um.registerUndo(withTarget: self) { session in
            if undo { session.undo() } else { session.redo() }
        }
        um.setActionName(name)
        if opened { um.endUndoGrouping() }
    }

    // MARK: Element operations

    /// Adds an element on top and selects it.
    @discardableResult
    func add(_ element: Element, name: String? = nil) -> Element {
        var added = element
        perform(name ?? "Add \(element.type.displayName)") { doc, sel in
            added = doc.add(element)
            sel = [added.id]
        }
        return added
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        perform("Delete") { doc, sel in
            doc.remove(sel)
            sel = []
        }
    }

    func selectAll() { selection = Set(document.elements.map(\.id)) }

    enum Arrange { case front, forward, backward, back }

    func arrange(_ how: Arrange) {
        guard !selection.isEmpty else { return }
        let ids = selection
        let names: [Arrange: String] = [.front: "Bring to Front", .forward: "Bring Forward",
                                        .backward: "Send Backward", .back: "Send to Back"]
        perform(names[how] ?? "Arrange") { doc in
            switch how {
            case .front: doc.bringToFront(ids)
            case .forward: doc.bringForward(ids)
            case .backward: doc.sendBackward(ids)
            case .back: doc.sendToBack(ids)
            }
        }
    }

    private var selectionKey: String { selection.map(\.uuidString).sorted().joined(separator: ",") }

    /// Moves the selection; consecutive nudges of the same selection merge into one step.
    func nudge(by delta: CGPoint) {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform("Move", mergeKey: "nudge:" + selectionKey) { $0.move(ids, by: delta) }
    }

    /// Grows or shrinks the selection's width and height (aspect-locked elements stay square).
    func resizeSelection(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform("Resize", mergeKey: "resize:" + selectionKey) { doc in
            doc.updateAll(ids) { e in
                let b = ElementGeometry.bounds(of: e)
                var size = CGSize(width: max(1, b.width + delta.width), height: max(1, b.height + delta.height))
                if e.type.locksAspect {
                    let side = max(1, max(b.width, b.height) + max(delta.width, delta.height))
                    size = CGSize(width: side, height: side)
                }
                e = ElementGeometry.withBounds(e, CGRect(origin: b.origin, size: size))
            }
        }
    }

    /// Changes one property of every selected element that has it and remembers the value
    /// for those element types. With nothing selected, only the default of `toolType` changes.
    func setStyle(_ field: ElementField, toolType: ElementType?, settings: ScreenshotProSettings,
                  _ change: @escaping (inout ElementStyle) -> Void) {
        let targets = selectedElements.filter { ElementField.fields(for: $0.type, style: $0.style).contains(field) }
        if targets.isEmpty {
            if let toolType { toolDefaults.remember(toolType, settings: settings, change: change) }
            onChange?()
            return
        }
        for type in Set(targets.map(\.type)) {
            toolDefaults.remember(type, settings: settings, change: change)
        }
        let ids = Set(targets.map(\.id))
        let scale = document.scale
        let apply: (inout EditorDocument) -> Void = { doc in
            doc.updateAll(ids) { e in
                // `change` works in points, as shown in the properties bar.
                var pointStyle = e.style.scaled(by: 1 / scale)
                change(&pointStyle)
                e.style = pointStyle.scaled(by: scale)
            }
        }
        if isInGesture {
            // E.g. the font changed while typing: part of the text editing step.
            updateGesture(apply)
        } else {
            perform("Change \(field.displayName)", mergeKey: "style:\(field.rawValue):" + selectionKey, apply)
        }
    }

    /// Style (remembered or default, in points) for a new element, converted to pixels.
    func newElementStyle(_ type: ElementType, settings: ScreenshotProSettings) -> ElementStyle {
        toolDefaults.style(for: type, settings: settings).scaled(by: document.scale)
    }

    func setCounterStart(_ value: Int) {
        perform("Change Counter Start", mergeKey: "counterStart") { $0.counterStart = max(0, value) }
    }

    func resetCounter() {
        perform("Reset Counter") { $0.resetCounter() }
    }

    /// Duplicates the selection with a (10, 10) offset and selects the copies.
    func duplicate() {
        let originals = selectedElements
        guard !originals.isEmpty else { return }
        perform("Duplicate") { doc, sel in
            let copies = doc.addCopies(of: originals, offset: CGPoint(x: 10, y: 10))
            sel = Set(copies.map(\.id))
        }
    }

    /// Adds elements from the clipboard: offset by 10 px when pasted into the same document,
    /// then shifted back inside the canvas if the group would not fit.
    func paste(_ clip: ElementClipboard) {
        guard !clip.elements.isEmpty else { return }
        var offset = clip.sourceDocument == id ? CGPoint(x: 10, y: 10) : .zero
        let group = clip.elements.map(ElementGeometry.bounds).reduce(CGRect.null) { $0.union($1) }
        let moved = group.offsetBy(dx: offset.x, dy: offset.y)
        let canvas = document.bounds
        if !canvas.contains(moved) {
            if clip.sourceDocument == id {
                offset = CGPoint(x: -10, y: -10)
            } else {
                offset.x += max(0, canvas.minX - moved.minX) - max(0, moved.maxX - canvas.maxX)
                offset.y += max(0, canvas.minY - moved.minY) - max(0, moved.maxY - canvas.maxY)
            }
        }
        perform("Paste") { doc, sel in
            let copies = doc.addCopies(of: clip.elements, offset: offset)
            sel = Set(copies.map(\.id))
        }
    }

    /// Replaces the base image (effects, rotate, resize...) mapping elements through `transform`.
    func applyImageChange(_ name: String, image: CGImage, transform: CGAffineTransform = .identity) {
        perform(name) { $0.replaceImage(image, transform: transform) }
    }

    /// Crops to `rect` using an already cropped image.
    func crop(to rect: CGRect, croppedImage: CGImage) {
        perform("Crop") { $0.crop(to: rect, croppedImage: croppedImage) }
    }

    /// Adds or replaces elements loaded from an element file; they become selected.
    func addLoaded(_ elements: [Element], name: String) {
        guard !elements.isEmpty else { return }
        perform(name) { doc, sel in
            let copies = doc.addCopies(of: elements)
            sel = Set(copies.map(\.id))
        }
    }
}

extension ElementField {
    var displayName: String {
        switch self {
        case .lineThickness: return "Line Thickness"
        case .lineColor: return "Line Color"
        case .fillColor: return "Fill Color"
        case .shadow: return "Shadow"
        case .sketchy: return "Hand-Drawn"
        case .font: return "Font"
        case .arrowHeads: return "Arrow Heads"
        case .highlightMode: return "Highlight Mode"
        case .brightness: return "Brightness"
        case .blurRadius: return "Blur Radius"
        case .magnification: return "Magnification"
        case .obfuscateMode: return "Obfuscate Mode"
        case .pixelSize: return "Pixel Size"
        case .cycleColors: return "Rainbow Numbers"
        case .counterStart: return "Counter Start"
        }
    }
}
