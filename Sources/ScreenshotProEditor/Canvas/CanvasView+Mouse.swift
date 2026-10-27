import AppKit
import ScreenshotProCore

/// Mouse handling: drawing with the tools, selecting, moving, resizing and cropping.
extension CanvasView {
    /// Elements smaller than this after drawing become `clickSize` (a click still makes a shape).
    static let minimumDrawnSize: CGFloat = 5
    static let clickSize: CGFloat = 25
    /// Freehand keeps a point once the pointer moved this many view points; the finished stroke
    /// is smoothed, so a fine spacing follows the hand closely without looking shaky.
    static let freehandSpacing: CGFloat = 3

    override func mouseDown(with event: NSEvent) {
        if textView != nil {
            // A click outside the text editor finishes editing.
            finishTextEditing(commit: true)
            return
        }
        window?.makeFirstResponder(self)
        let p = imagePoint(for: event)
        let shift = event.modifierFlags.contains(.shift)

        if tool == .crop {
            cropMouseDown(at: p)
            return
        }

        if event.clickCount == 2, tool == .select,
           let hit = ElementGeometry.topmostHit(in: document.elements, at: p, tolerance: hitTolerance),
           hit.type.hasText {
            session.selection = [hit.id]
            beginTextEditing(hit.id, isNew: false)
            return
        }

        // A handle of a selected element resizes, whatever the tool.
        for e in session.selectedElements.reversed() {
            if let h = ElementGeometry.handle(of: e, at: p, radius: handleRadius) {
                session.beginGesture()
                drag = .resizing(id: e.id, handle: h, original: e)
                if e.type.isFilter { borderOnlyFilters = [e.id] }
                return
            }
        }

        guard let type = tool.elementType else {
            selectMouseDown(at: p, shift: shift)
            return
        }
        beginDrawing(type, at: p)
    }

    private func selectMouseDown(at p: CGPoint, shift: Bool) {
        if let hit = ElementGeometry.topmostHit(in: document.elements, at: p, tolerance: hitTolerance) {
            if shift {
                if session.selection.contains(hit.id) {
                    session.selection.remove(hit.id)
                    return
                }
                session.selection.insert(hit.id)
            } else if !session.selection.contains(hit.id) {
                session.selection = [hit.id]
            }
            session.beginGesture()
            drag = .moving(last: p)
            borderOnlyFilters = Set(session.selectedElements.filter { $0.type.isFilter }.map(\.id))
        } else {
            let base = shift ? session.selection : []
            if !shift { session.selection = [] }
            drag = .rubberBand(start: p, current: p, base: base)
        }
    }

    private func beginDrawing(_ type: ElementType, at p: CGPoint) {
        guard let delegate else { return }
        var e = Element(type: type, style: session.newElementStyle(type, settings: delegate.settings))
        switch type {
        case .line, .arrow:
            e.points = [p, p]
        case .freehand, .marker:
            e.points = [p]
        case .counter:
            e.rect = CGRect(x: p.x - 15 * document.scale, y: p.y - 15 * document.scale,
                            width: 30 * document.scale, height: 30 * document.scale)
        default:
            e.rect = CGRect(origin: p, size: .zero)
            if type == .speechBubble { e.tailTarget = p }
        }
        var added = e
        session.beginGesture()
        session.updateGesture { added = $0.add(e) }
        session.selection = [added.id]
        if type.isFilter { borderOnlyFilters = [added.id] }
        switch type {
        case .freehand, .marker: drag = .freehand(id: added.id, lastKept: p)
        case .counter: drag = .placingCounter(id: added.id)
        default: drag = .drawing(id: added.id, start: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(for: event)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        switch drag {
        case .none:
            return
        case .drawing(let id, let start):
            session.updateGesture { doc in
                doc.update(id) { e in
                    if e.type.isLinear {
                        let end = ElementGeometry.lineEnd(from: start, to: p, snap: shift)
                        e.points = option ? [start - (end - start), end] : [start, end]
                    } else {
                        e.rect = ElementGeometry.drawnRect(from: start, to: p, square: shift, fromCenter: option)
                        if e.type == .speechBubble {
                            // The tail starts at the press point pushed 20 px away from the bubble.
                            let sx: CGFloat = p.x >= start.x ? -1 : 1, sy: CGFloat = p.y >= start.y ? -1 : 1
                            e.tailTarget = start + CGPoint(x: 20 * sx, y: 20 * sy)
                        }
                    }
                }
            }
        case .freehand(let id, let last):
            if shift {
                // Shift draws a straight line from where the stroke began, in 15 degree steps.
                session.updateGesture { doc in
                    doc.update(id) { e in
                        let start = e.points.first ?? p
                        e.points = [start, ElementGeometry.lineEnd(from: start, to: p, snap: true)]
                    }
                }
                drag = .freehand(id: id, lastKept: p)
                return
            }
            guard p.distance(to: last) * viewScale >= CanvasView.freehandSpacing else { return }
            drag = .freehand(id: id, lastKept: p)
            session.updateGesture { doc in doc.update(id) { $0.points.append(p) } }
        case .placingCounter(let id):
            session.updateGesture { doc in
                doc.update(id) { e in
                    e.rect.origin = CGPoint(x: p.x - e.rect.width / 2, y: p.y - e.rect.height / 2)
                }
            }
        case .moving(let last):
            let delta = p - last
            drag = .moving(last: p)
            let ids = session.selection
            session.updateGesture { $0.move(ids, by: delta) }
        case .resizing(let id, let handle, let original):
            session.updateGesture { doc in
                doc.update(id) { e in
                    switch handle {
                    case .resize(let h):
                        e.rect = ElementGeometry.resize(original.rect, handle: h, to: p,
                                                        keepAspect: shift || original.type.locksAspect,
                                                        fromCenter: option)
                    case .lineStart:
                        e.start = ElementGeometry.lineEnd(from: original.end, to: p, snap: shift)
                    case .lineEnd:
                        e.end = ElementGeometry.lineEnd(from: original.start, to: p, snap: shift)
                    case .tail:
                        e.tailTarget = p
                    }
                }
            }
        case .rubberBand(let start, _, let base):
            drag = .rubberBand(start: start, current: p, base: base)
            let band = CGRect(corner: start, p)
            let hits = document.elements.filter { ElementGeometry.bounds(of: $0).intersects(band) }.map(\.id)
            session.selection = base.union(hits)
            needsDisplay = true
        case .cropNew(let start):
            cropRect = ElementGeometry.drawnRect(from: start, to: p, square: shift, fromCenter: option)
                .intersection(document.bounds)
        case .cropMove(let last):
            guard var r = cropRect else { return }
            r.origin.x = min(max(0, r.minX + p.x - last.x), document.size.width - r.width)
            r.origin.y = min(max(0, r.minY + p.y - last.y), document.size.height - r.height)
            cropRect = r
            drag = .cropMove(last: p)
        case .cropResize(let h, let original):
            cropRect = ElementGeometry.resize(original, handle: h, to: p, keepAspect: shift, fromCenter: option)
                .intersection(document.bounds)
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let current = drag
        drag = .none
        let hadFilters = !borderOnlyFilters.isEmpty
        borderOnlyFilters = []
        defer { if hadFilters { needsDisplay = true } }
        switch current {
        case .none:
            return
        case .drawing(let id, let start):
            guard let e = document.element(id) else { session.cancelGesture(); return }
            finishDrawn(e, start: start)
        case .freehand(let id, _):
            let name = document.element(id).map { "Add \($0.type.displayName)" } ?? "Draw"
            session.updateGesture { doc in doc.update(id) { $0.points = ElementGeometry.smoothed($0.points) } }
            session.endGesture(name: name)
        case .placingCounter:
            session.endGesture(name: "Add Counter")
        case .moving:
            session.endGesture(name: "Move")
        case .resizing:
            session.endGesture(name: "Resize")
        case .rubberBand:
            needsDisplay = true
        case .cropNew, .cropMove, .cropResize:
            if let r = cropRect?.integral.intersection(document.bounds), !r.isNull, r.width >= 1, r.height >= 1 {
                cropRect = r
            } else {
                cropRect = nil
            }
        }
    }

    /// Applies the minimum size rule and ends the drawing gesture (or opens the text editor).
    private func finishDrawn(_ e: Element, start: CGPoint) {
        let size = CanvasView.clickSize * document.scale
        let small = CanvasView.minimumDrawnSize * document.scale
        let clickedText = e.type == .text && e.rect.width < small && e.rect.height < small
        session.updateGesture { doc in
            doc.update(e.id) { el in
                if el.type.isLinear {
                    if el.start.distance(to: el.end) < small { el.end = el.start + CGPoint(x: size, y: size) }
                } else if el.rect.width < small && el.rect.height < small {
                    if el.type == .text {
                        // A click with the text tool places a one-line box that grows as you type.
                        let line = TextLayout.naturalSize(of: " ", style: el.style)
                        let inset = 2 * (CGFloat(el.style.lineThickness) / 2 + 2)
                        let top = max(0, start.y - (line.height + inset) / 2)
                        el.rect = CGRect(x: start.x, y: top, width: line.width * 2 + inset, height: line.height + inset)
                    } else if el.type.hasText {
                        // A click with the bubble tool makes a box big enough to type into.
                        el.rect = CGRect(x: start.x, y: start.y, width: 8 * size, height: 2 * size)
                    } else {
                        el.rect = CGRect(x: start.x, y: start.y, width: size, height: size)
                    }
                    if el.type == .speechBubble { el.tailTarget = start + CGPoint(x: -20, y: -20) }
                }
            }
        }
        if e.type.hasText {
            beginTextEditing(e.id, isNew: true)
            editingAutoWidth = clickedText
        } else {
            session.endGesture(name: "Add \(e.type.displayName)")
        }
    }

    // MARK: Crop

    private func cropMouseDown(at p: CGPoint) {
        if let r = cropRect {
            if let h = ResizeHandle.allCases.first(where: {
                let pos = $0.position(in: r)
                return abs(pos.x - p.x) <= handleRadius && abs(pos.y - p.y) <= handleRadius
            }) {
                drag = .cropResize(handle: h, original: r)
                return
            }
            if r.contains(p) {
                drag = .cropMove(last: p)
                return
            }
        }
        cropRect = nil
        drag = .cropNew(start: p)
    }

    // MARK: Zoom gestures

    override func magnify(with event: NSEvent) {
        magnifyAccumulator += event.magnification
        if magnifyAccumulator > 0.25 {
            zoomIn()
            magnifyAccumulator = 0
        } else if magnifyAccumulator < -0.25 {
            zoomOut()
            magnifyAccumulator = 0
        }
        if event.phase == .ended || event.phase == .cancelled { magnifyAccumulator = 0 }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        // One zoom step per 100 ms at most.
        let now = Date()
        guard now.timeIntervalSince(lastScrollZoom) > 0.1, event.scrollingDeltaY != 0 else { return }
        lastScrollZoom = now
        if event.scrollingDeltaY > 0 { zoomIn() } else { zoomOut() }
    }
}
