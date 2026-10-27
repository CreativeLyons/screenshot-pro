import AppKit
import ScreenshotProCore
import ScreenshotProOutput
import UniformTypeIdentifiers

/// Menu, toolbar and context menu actions. Everything that changes the document goes through
/// the session, so it is undoable.
extension EditorWindowController: NSMenuItemValidation {
    private var doc: EditorDocument { session.document }
    private var elementsType: NSPasteboard.PasteboardType { .init(ElementClipboard.pasteboardType) }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        switch action {
        case #selector(undo(_:)):
            item.title = windowUndoManager.undoMenuItemTitle
        case #selector(redo(_:)):
            item.title = windowUndoManager.redoMenuItemTitle
        default:
            break
        }
        return validate(action: action)
    }

    func validate(action: Selector) -> Bool {
        let editing = canvas.isEditingText
        let hasSelection = !session.selection.isEmpty
        switch action {
        case #selector(undo(_:)): return !editing && windowUndoManager.canUndo
        case #selector(redo(_:)): return !editing && windowUndoManager.canRedo
        case #selector(cut(_:)), #selector(copy(_:)), #selector(delete(_:)), #selector(editorDuplicate(_:)):
            return !editing && hasSelection
        case #selector(paste(_:)):
            let pb = NSPasteboard.general
            return !editing && (pb.availableType(from: [elementsType, .string]) != nil || NSImage.canInit(with: pb))
        case #selector(selectAll(_:)): return !editing && !doc.elements.isEmpty
        case #selector(editorBringToFront(_:)), #selector(editorBringForward(_:)):
            return !editing && doc.canBringForward(session.selection)
        case #selector(editorSendToBack(_:)), #selector(editorSendBackward(_:)):
            return !editing && doc.canSendBackward(session.selection)
        case #selector(editorEditText(_:)):
            let sel = session.selectedElements
            return !editing && sel.count == 1 && sel[0].type.hasText
        case #selector(editorSave(_:)):
            return documentURL != nil || isDestinationAvailable(DestinationID.file)
        case #selector(editorSaveAs(_:)): return isDestinationAvailable(DestinationID.saveAs)
        case #selector(editorCopyToClipboard(_:)): return isDestinationAvailable(DestinationID.clipboard)
        case #selector(editorPrint(_:)): return isDestinationAvailable(DestinationID.printer)
        case #selector(editorMail(_:)): return isDestinationAvailable(DestinationID.mail)
        case #selector(editorShare(_:)): return isDestinationAvailable(DestinationID.share)
        case #selector(editorOCR(_:)): return isDestinationAvailable(DestinationID.ocr)
        case #selector(editorRemoveTransparency(_:)): return imageHasAlpha
        case #selector(editorShowSettings(_:)): return Editor.settingsHandler != nil
        default: return true
        }
    }

    private func isDestinationAvailable(_ id: String) -> Bool {
        DestinationRegistry.shared.destination(id: id)?.isAvailable ?? false
    }

    private var imageHasAlpha: Bool {
        switch doc.image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: Edit

    @objc func undo(_ sender: Any?) {
        canvas.finishTextEditing(commit: true)
        windowUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        canvas.finishTextEditing(commit: true)
        windowUndoManager.redo()
    }

    @objc func copy(_ sender: Any?) { writeSelectionToPasteboard() }

    @objc func cut(_ sender: Any?) {
        guard writeSelectionToPasteboard() else { return }
        session.perform("Cut") { doc, sel in
            doc.remove(sel)
            sel = []
        }
    }

    @objc func delete(_ sender: Any?) { session.deleteSelection() }

    @objc override func selectAll(_ sender: Any?) {
        session.selectAll()
        selectTool(.select)
    }

    @objc func editorDuplicate(_ sender: Any?) { session.duplicate() }

    @discardableResult
    private func writeSelectionToPasteboard() -> Bool {
        let selected = session.selectedElements
        guard !selected.isEmpty,
              let data = try? JSONEncoder().encode(ElementClipboard(sourceDocument: session.id, elements: selected))
        else { return false }
        let pb = NSPasteboard.general
        pb.declareTypes([elementsType], owner: nil)
        return pb.setData(data, forType: elementsType)
    }

    /// Pastes elements, else an image (as an image element), else text (as a text box).
    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: elementsType),
           let clip = try? JSONDecoder().decode(ElementClipboard.self, from: data) {
            session.paste(clip)
            selectTool(.select)
            return
        }
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            let cgImages = images.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            insertImages(cgImages, at: pastePoint(fraction: 0.1))
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            insertText(text, at: pastePoint(fraction: 0.4))
        }
    }

    /// The mouse position when it is over the canvas, else a point `fraction` into the view.
    private func pastePoint(fraction: CGFloat) -> CGPoint {
        if let window {
            let p = canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if canvas.visibleRect.contains(p) { return canvas.imagePoint(p) }
        }
        let v = canvas.visibleImageRect.isEmpty ? doc.bounds : canvas.visibleImageRect
        return CGPoint(x: v.minX + v.width * fraction, y: v.minY + v.height * fraction)
    }

    func insertImages(_ images: [CGImage], at point: CGPoint) {
        guard !images.isEmpty else { return }
        session.perform(images.count == 1 ? "Insert Image" : "Insert Images") { doc, sel in
            sel = []
            for (i, img) in images.enumerated() {
                let origin = point + CGPoint(x: CGFloat(i) * 10, y: CGFloat(i) * 10)
                var e = Element(type: .image, rect: CGRect(origin: origin, size: CGSize(width: img.width, height: img.height)))
                e.style = ElementStyle.defaults(for: .image)
                e.image = EmbeddedImage(img)
                sel.insert(doc.add(e).id)
            }
        }
        selectTool(.select)
    }

    private func insertText(_ text: String, at point: CGPoint) {
        var style = ElementStyle.defaults(for: .text)
        style.fontName = "Helvetica"
        style.fontSize = 12
        style.lineColor = .black
        style.lineThickness = 2
        style.shadow = false
        style.fillColor = .clear
        style.horizontalAlignment = .left
        style = style.scaled(by: doc.scale)
        let natural = TextLayout.naturalSize(of: text, style: style)
        let pad = CGFloat(style.lineThickness) + 6
        var e = Element(type: .text, rect: CGRect(origin: point, size: CGSize(width: natural.width + 2 * pad,
                                                                              height: natural.height + 2 * pad)))
        e.style = style
        e.text = text
        session.add(e, name: "Paste Text")
        selectTool(.select)
    }

    @objc func editorCopyImage(_ sender: Any?) {
        guard let image = flattenedImage(), let png = PNGCoding.encode(image) else { return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let ns = NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / doc.scale,
                                                      height: CGFloat(image.height) / doc.scale))
        if let tiff = ns.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        showMessage("Image copied to the clipboard")
    }

    // MARK: Object

    @objc func editorBringToFront(_ sender: Any?) { session.arrange(.front) }
    @objc func editorBringForward(_ sender: Any?) { session.arrange(.forward) }
    @objc func editorSendBackward(_ sender: Any?) { session.arrange(.backward) }
    @objc func editorSendToBack(_ sender: Any?) { session.arrange(.back) }
    @objc func editorResetCounter(_ sender: Any?) { session.resetCounter() }

    @objc func editorEditText(_ sender: Any?) {
        guard let e = session.selectedElements.first, e.type.hasText else { return }
        canvas.beginTextEditing(e.id, isNew: false)
    }

    @objc func editorInsertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let images = panel.urls.compactMap { ImageEncoder.load($0) }
            if images.isEmpty {
                showErrorSheet(ScreenshotProError.unreadableImage(panel.urls.first?.lastPathComponent ?? "the file"))
            } else {
                insertImages(images, at: pastePoint(fraction: 0.1))
            }
        }
    }

    @objc func editorShowSettings(_ sender: Any?) { Editor.settingsHandler?() }

    // MARK: Image

    @objc func editorCrop(_ sender: Any?) { selectTool(.crop) }

    @objc func editorAutoCrop(_ sender: Any?) { autoCrop() }

    /// Shows the auto crop rectangle (searched inside the current crop rectangle if any) for
    /// confirmation with the crop tool.
    func autoCrop() {
        canvas.finishTextEditing(commit: true)
        guard let flat = flattenedImage() else { return }
        var origin = CGPoint.zero
        var source = flat
        if let r = canvas.cropRect, let sub = ImageEffects.crop(flat, to: r) {
            source = sub
            origin = r.origin
        }
        guard let found = ImageEffects.autoCropRect(source, tolerance: settings.autoCropTolerance) else {
            showMessage("Auto crop not possible")
            return
        }
        selectTool(.crop)
        canvas.cropRect = found.offsetBy(dx: origin.x, dy: origin.y)
    }

    func applyCrop() {
        guard let pending = canvas.cropRect else {
            if canvas.tool == .crop { canvas.cropRect = canvas.defaultCropRect() }
            return
        }
        let r = pending.integral.intersection(doc.bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else {
            canvas.cropRect = nil
            return
        }
        if r != doc.bounds, let cropped = ImageEffects.crop(doc.image, to: r) {
            session.crop(to: r, croppedImage: cropped)
        }
        canvas.cropRect = nil
        selectTool(.select)
    }

    @objc func editorResize(_ sender: Any?) {
        guard let window else { return }
        canvas.finishTextEditing(commit: true)
        let current = doc.size
        Task { @MainActor [weak self] in
            guard let newSize = await EffectSheets.resize(on: window, current: current), let self,
                  newSize.width >= 1, newSize.height >= 1, newSize != current else { return }
            let image = ImageEffects.resize(session.document.image, to: newSize)
            let sx = newSize.width / current.width, sy = newSize.height / current.height
            // Line widths, fonts and filter sizes scale too, so annotations keep their look.
            let styleScale = (sx * sy).squareRoot()
            session.perform("Resize") { doc in
                doc.replaceImage(image, transform: CGAffineTransform(scaleX: sx, y: sy))
                for i in doc.elements.indices { doc.elements[i].style = doc.elements[i].style.scaled(by: styleScale) }
            }
        }
    }

    @objc func editorRotateClockwise(_ sender: Any?) { rotate(quarterTurns: 1) }
    @objc func editorRotateCounterclockwise(_ sender: Any?) { rotate(quarterTurns: -1) }

    private func rotate(quarterTurns: Int) {
        canvas.finishTextEditing(commit: true)
        let image = ImageEffects.rotate(doc.image, quarterTurns: quarterTurns)
        session.perform(quarterTurns > 0 ? "Rotate Clockwise" : "Rotate Counterclockwise") {
            $0.rotate(quarterTurns: quarterTurns, rotatedImage: image)
        }
    }

    @objc func editorExpandCanvas(_ sender: Any?) {
        let a = min(max(settings.expandCanvasAmount, 1), 1000)
        applyEffect("Expand Canvas") { ImageEffects.expandCanvas($0, top: a, left: a, bottom: a, right: a) }
    }

    @objc func editorClear(_ sender: Any?) { applyFilter("Clear") { ImageEffects.clear($0) } }

    @objc func editorRemoveTransparency(_ sender: Any?) {
        applyFilter("Remove Transparency") { ImageEffects.removeTransparency($0, color: .white) }
    }

    // MARK: Effects

    @objc func editorBorder(_ sender: Any?) { applyEffect("Border") { ImageEffects.border($0) } }

    @objc func editorDropShadow(_ sender: Any?) {
        let s = EffectDefaults.dropShadow
        applyEffect("Drop Shadow") { ImageEffects.dropShadow($0, s) }
    }

    @objc func editorDropShadowSettings(_ sender: Any?) {
        guard let window else { return }
        Task { @MainActor [weak self] in
            guard let s = await EffectSheets.dropShadow(on: window, initial: EffectDefaults.dropShadow),
                  let self else { return }
            EffectDefaults.dropShadow = s
            applyEffect("Drop Shadow") { ImageEffects.dropShadow($0, s) }
        }
    }

    @objc func editorTornEdges(_ sender: Any?) {
        let s = EffectDefaults.tornEdges
        applyEffect("Torn Edges") { ImageEffects.tornEdges($0, s) }
    }

    @objc func editorTornEdgesSettings(_ sender: Any?) {
        guard let window else { return }
        Task { @MainActor [weak self] in
            guard let s = await EffectSheets.tornEdges(on: window, initial: EffectDefaults.tornEdges),
                  let self else { return }
            EffectDefaults.tornEdges = s
            applyEffect("Torn Edges") { ImageEffects.tornEdges($0, s) }
        }
    }

    @objc func editorGrayscale(_ sender: Any?) { applyFilter("Grayscale") { ImageEffects.grayscale($0) } }
    @objc func editorInvert(_ sender: Any?) { applyFilter("Invert") { ImageEffects.invert($0) } }

    /// Applies an effect that may change the geometry, moving elements with the image.
    private func applyEffect(_ name: String, _ op: (CGImage) -> (CGImage, EffectGeometry)) {
        canvas.finishTextEditing(commit: true)
        let (image, geometry) = op(doc.image)
        session.applyImageChange(name, image: image, transform: EditorDocument.transform(for: geometry))
    }

    private func applyFilter(_ name: String, _ op: (CGImage) -> CGImage) {
        canvas.finishTextEditing(commit: true)
        session.applyImageChange(name, image: op(doc.image))
    }

    // MARK: View

    @objc func editorZoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func editorZoomOut(_ sender: Any?) { canvas.zoomOut() }
    @objc func editorActualSize(_ sender: Any?) { canvas.setZoom(1) }
    @objc func editorZoomToFit(_ sender: Any?) { canvas.zoomToFit() }

    // MARK: Context menu

    func contextMenu() -> NSMenu {
        let m = NSMenu(title: "Element")
        func add(_ title: String, _ action: Selector) {
            if validate(action: action) { m.addItem(NSMenuItem(title: title, action: action, keyEquivalent: "")) }
        }
        add("Bring to Front", #selector(editorBringToFront(_:)))
        add("Bring Forward", #selector(editorBringForward(_:)))
        add("Send Backward", #selector(editorSendBackward(_:)))
        add("Send to Back", #selector(editorSendToBack(_:)))
        m.addItem(.separator())
        add("Edit Text", #selector(editorEditText(_:)))
        add("Duplicate", #selector(editorDuplicate(_:)))
        add("Copy", #selector(copy(_:)))
        add("Cut", #selector(cut(_:)))
        m.addItem(.separator())
        add("Delete", #selector(delete(_:)))
        return m
    }
}
