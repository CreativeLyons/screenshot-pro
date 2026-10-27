import AppKit
import ScreenshotProCore

/// What the canvas asks of its window controller.
@MainActor
protocol CanvasViewDelegate: AnyObject {
    var settings: ScreenshotProSettings { get }
    func canvasDidChangeTool(_ canvas: CanvasView)
    func canvasDidChangeZoom(_ canvas: CanvasView)
    func canvasDidChangeCrop(_ canvas: CanvasView)
    func canvasApplyCrop(_ canvas: CanvasView)
    func canvasContextMenu(_ canvas: CanvasView) -> NSMenu?
    func canvas(_ canvas: CanvasView, showMessage message: String)
    func canvas(_ canvas: CanvasView, insertImages images: [CGImage], at point: CGPoint)
}

/// The editing surface: draws the document at the current zoom and
/// handles tools, selection, handles, rubber-band selection, crop and inline text editing.
/// Flipped, so view coordinates run top-left down like image pixels.
@MainActor
final class CanvasView: NSView {
    let session: EditorSession
    weak var delegate: CanvasViewDelegate?
    let filterCache = FilterCache()

    /// The active tool. Changing it discards a pending crop rectangle.
    var tool: EditorTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .crop { cropRect = nil }
            if let mode = tool.obfuscateMode, let delegate {
                // Blur and pixelate are one element type; the tool picks the mode it draws.
                session.toolDefaults.remember(.obfuscate, settings: delegate.settings) { $0.obfuscateMode = mode }
            }
            if textView != nil { finishTextEditing(commit: true) }
            window?.invalidateCursorRects(for: self)
            delegate?.canvasDidChangeTool(self)
            needsDisplay = true
        }
    }

    /// 1 = 100% (true size: pixels / scale points).
    private(set) var zoom: CGFloat = 1

    /// The temporary crop rectangle (image pixels); not part of the document or history.
    var cropRect: CGRect? {
        didSet {
            needsDisplay = true
            delegate?.canvasDidChangeCrop(self)
        }
    }

    // Interaction state, shared with the mouse/keyboard extensions.
    enum Drag {
        case none
        case drawing(id: UUID, start: CGPoint)
        case freehand(id: UUID, lastKept: CGPoint)
        case placingCounter(id: UUID)
        case moving(last: CGPoint)
        case resizing(id: UUID, handle: ElementHandle, original: Element)
        case rubberBand(start: CGPoint, current: CGPoint, base: Set<UUID>)
        case cropNew(start: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(handle: ResizeHandle, original: CGRect)
    }

    var drag: Drag = .none
    /// Filter elements shown as a dotted border only while a gesture changes them.
    var borderOnlyFilters: Set<UUID> = []
    var textView: ElementTextView?
    var editingID: UUID?
    var editingIsNew = false
    /// The text box was placed with a click: it widens with the text instead of wrapping.
    var editingAutoWidth = false
    var lastScrollZoom = Date.distantPast
    var magnifyAccumulator: CGFloat = 0

    /// Handle squares are this many view points wide.
    static let handleSize: CGFloat = 8

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        updateFrameSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    var document: EditorDocument { session.document }

    /// View points per image pixel.
    var viewScale: CGFloat { zoom / document.scale }

    func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * viewScale, y: p.y * viewScale) }

    func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * viewScale, y: r.minY * viewScale, width: r.width * viewScale, height: r.height * viewScale)
    }

    func imagePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / viewScale, y: p.y / viewScale) }

    func imagePoint(for event: NSEvent) -> CGPoint { imagePoint(convert(event.locationInWindow, from: nil)) }

    /// The visible part of the image, in image pixels.
    var visibleImageRect: CGRect {
        let v = visibleRect
        let r = CGRect(x: v.minX / viewScale, y: v.minY / viewScale, width: v.width / viewScale, height: v.height / viewScale)
        return r.intersection(document.bounds)
    }

    /// Call after every session change.
    func documentDidChange() {
        updateFrameSize()
        if let id = editingID, document.element(id) == nil { finishTextEditing(commit: false) }
        layoutTextView()
        needsDisplay = true
    }

    func updateFrameSize() {
        let size = CGSize(width: (document.size.width * viewScale).rounded(.up),
                          height: (document.size.height * viewScale).rounded(.up))
        if frame.size != size {
            setFrameSize(size)
            superview?.needsDisplay = true
        }
    }

    // MARK: Zoom

    /// Sets the zoom, keeping the image point at the center of the visible area in place.
    func setZoom(_ newZoom: CGFloat) {
        let z = min(max(newZoom, ZoomLevels.levels.first!), ZoomLevels.levels.last!)
        guard abs(z - zoom) > 0.0001 else { return }
        let visible = visibleRect
        let center = imagePoint(CGPoint(x: visible.midX, y: visible.midY))
        zoom = z
        updateFrameSize()
        let c = viewPoint(center)
        scroll(CGPoint(x: c.x - visible.width / 2, y: c.y - visible.height / 2))
        layoutTextView()
        needsDisplay = true
        delegate?.canvasDidChangeZoom(self)
    }

    func zoomIn() { setZoom(ZoomLevels.next(after: zoom)) }
    func zoomOut() { setZoom(ZoomLevels.previous(before: zoom)) }

    /// Largest level at which the whole image fits the scroll view.
    func zoomToFit() {
        let available = enclosingScrollView?.contentSize ?? bounds.size
        let content = CGSize(width: document.size.width / document.scale, height: document.size.height / document.scale)
        setZoom(ZoomLevels.fit(content: content, available: available))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // No checkerboard: transparent pixels show the window behind, and the clip view frames
        // the image with a thin border (`CenteringClipView`).

        ctx.saveGState()
        ctx.scaleBy(x: viewScale, y: viewScale)
        var options = RenderOptions()
        options.borderOnlyFilters = borderOnlyFilters
        if let editingID { options.hiddenText = [editingID] }
        options.interpolation = zoom > 1.001 ? .none : .high
        DocumentRenderer.draw(document, in: ctx, options: options, cache: filterCache)
        ctx.restoreGState()

        drawSelection(in: ctx)
        if let cropRect { drawCrop(cropRect, in: ctx) }
        if case .rubberBand(let start, let current, _) = drag {
            let r = viewRect(CGRect(corner: start, current))
            ctx.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.selectedContentBackgroundColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawSelection(in ctx: CGContext) {
        for e in session.selectedElements {
            if !e.type.isLinear {
                let r = viewRect(ElementGeometry.bounds(of: e)).insetBy(dx: -1, dy: -1)
                DocumentRenderer.drawDottedBorder(r, in: ctx)
            }
            if editingID == e.id { continue }
            for (h, p) in ElementGeometry.handles(of: e) {
                drawHandle(at: viewPoint(p), tail: h == .tail, in: ctx)
            }
        }
    }

    func drawHandle(at p: CGPoint, tail: Bool = false, in ctx: CGContext) {
        let s = CanvasView.handleSize
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        if tail {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0.7, blue: 0, alpha: 1))
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        } else {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(r)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()
    }

    private func drawCrop(_ crop: CGRect, in ctx: CGContext) {
        let r = viewRect(crop)
        ctx.saveGState()
        // Olive tint outside the crop rectangle (ARGB 100, 150, 150, 100).
        ctx.setFillColor(CGColor(srgbRed: 150 / 255, green: 150 / 255, blue: 100 / 255, alpha: 100 / 255))
        ctx.addRect(bounds)
        ctx.addRect(r)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        DocumentRenderer.drawDottedBorder(r, in: ctx)
        for h in ResizeHandle.allCases { drawHandle(at: h.position(in: r), in: ctx) }
    }

    override func resetCursorRects() {
        let cursor: NSCursor = tool == .select ? .arrow : .crosshair
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if textView != nil { return nil }
        let p = imagePoint(for: event)
        if let hit = ElementGeometry.topmostHit(in: document.elements, at: p, tolerance: hitTolerance) {
            if !session.selection.contains(hit.id) { session.selection = [hit.id] }
        } else if session.selection.isEmpty {
            return nil
        }
        return delegate?.canvasContextMenu(self)
    }

    /// Extra hit slack so thin lines are easy to click at any zoom.
    var hitTolerance: CGFloat { 2 / viewScale }

    /// Handle grab radius in image pixels.
    var handleRadius: CGFloat { (CanvasView.handleSize / 2 + 2) / viewScale }

    // MARK: Drag and drop of images onto the canvas

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NSImage.canInit(with: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var images: [CGImage] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            images = urls.compactMap { ImageEncoder.load($0) }
        }
        if images.isEmpty, let objs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            images = objs.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }
        guard !images.isEmpty else { return false }
        let p = imagePoint(convert(sender.draggingLocation, from: nil))
        delegate?.canvas(self, insertImages: images, at: p)
        return true
    }
}
