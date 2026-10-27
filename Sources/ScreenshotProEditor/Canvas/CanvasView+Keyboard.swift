import AppKit
import Carbon.HIToolbox
import ScreenshotProCore

/// Keyboard handling and in-place text editing.
extension CanvasView: NSTextViewDelegate {
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let shift = flags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Escape:
            escape()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            enter()
        case kVK_Delete, kVK_ForwardDelete:
            session.deleteSelection()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            let step: CGFloat = shift ? 10 : 1
            var d = CGPoint.zero
            switch Int(event.keyCode) {
            case kVK_LeftArrow: d.x = -step
            case kVK_RightArrow: d.x = step
            case kVK_UpArrow: d.y = -step
            default: d.y = step
            }
            if flags.contains(.option) {
                session.resizeSelection(by: CGSize(width: d.x, height: d.y))
            } else if flags.isDisjoint(with: [.command, .control]) {
                session.nudge(by: d)
            } else {
                super.keyDown(with: event)
            }
        case kVK_PageUp: session.arrange(.forward)
        case kVK_PageDown: session.arrange(.backward)
        case kVK_Home: session.arrange(.front)
        case kVK_End: session.arrange(.back)
        case kVK_Tab:
            selectNext(backward: shift)
        default:
            if flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
               let newTool = EditorTool.forKey(key) {
                let unchanged = tool == newTool
                tool = newTool
                if unchanged { delegate?.canvasDidChangeTool(self) }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func escape() {
        if tool == .crop {
            cropRect = nil
            tool = .select
        } else if tool != .select {
            tool = .select
        } else {
            session.selection = []
        }
    }

    func enter() {
        if tool == .crop {
            delegate?.canvasApplyCrop(self)
            return
        }
        if tool == .select {
            let sel = session.selectedElements
            if sel.count == 1, sel[0].type.hasText { beginTextEditing(sel[0].id, isNew: false) }
            return
        }
        keyboardDraw()
    }

    /// Enter with a drawing tool creates an element of the default shape mid-view.
    private func keyboardDraw() {
        guard let type = tool.elementType, !type.isStroke, let delegate else { return }
        let visible = visibleImageRect.isEmpty ? document.bounds : visibleImageRect
        let c = visible.center
        let s = document.scale
        var e = Element(type: type, style: session.newElementStyle(type, settings: delegate.settings))
        let w = min(160 * s, visible.width / 2), h = min(80 * s, visible.height / 2)
        switch type {
        case .line, .arrow:
            e.points = [CGPoint(x: c.x - w / 2, y: c.y), CGPoint(x: c.x + w / 2, y: c.y)]
        case .counter:
            e.rect = CGRect(x: c.x - 15 * s, y: c.y - 15 * s, width: 30 * s, height: 30 * s)
        default:
            e.rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            if type == .speechBubble { e.tailTarget = CGPoint(x: e.rect.minX - 20, y: e.rect.maxY + 20) }
        }
        if type.hasText {
            var added = e
            session.beginGesture()
            session.updateGesture { added = $0.add(e) }
            session.selection = [added.id]
            beginTextEditing(added.id, isNew: true)
        } else {
            session.add(e)
        }
    }

    /// Crop tool Enter without a rectangle: half the visible area.
    func defaultCropRect() -> CGRect {
        let v = visibleImageRect.isEmpty ? document.bounds : visibleImageRect
        return v.insetBy(dx: v.width / 4, dy: v.height / 4).integral
    }

    private func selectNext(backward: Bool) {
        let elements = document.elements
        guard !elements.isEmpty else { return }
        let indices = elements.indices.filter { session.selection.contains(elements[$0].id) }
        let next: Int?
        if backward {
            let i = indices.first ?? elements.count
            next = i - 1 >= 0 ? i - 1 : nil
        } else {
            let i = indices.last ?? -1
            next = i + 1 < elements.count ? i + 1 : nil
        }
        if let next {
            session.selection = [elements[next].id]
        } else {
            session.selection = []
            window?.selectKeyView(following: self)
        }
    }

    // MARK: Text editing

    /// Opens the in-place editor on a text box or bubble. For a new element the drawing
    /// gesture stays open, so creating and typing form one undo step.
    func beginTextEditing(_ id: UUID, isNew: Bool) {
        guard textView == nil, let e = document.element(id), e.type.hasText else { return }
        if !isNew { session.beginGesture() }
        editingID = id
        editingIsNew = isNew
        editingAutoWidth = false
        let tv = ElementTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.size = NSSize(width: 10, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.string = e.text
        tv.delegate = self
        tv.onCommit = { [weak self] in self?.finishTextEditing(commit: true) }
        tv.onCancel = { [weak self] in self?.finishTextEditing(commit: false) }
        textView = tv
        styleTextView(for: e)
        addSubview(tv)
        layoutTextView()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
    }

    private func styleTextView(for e: Element) {
        guard let tv = textView else { return }
        let size = CGFloat(e.style.fontSize) * viewScale
        var font = NSFont(name: e.style.fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        if e.style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if e.style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        tv.font = font
        let color = NSColor(cgColor: e.style.lineColor.cgColor) ?? .textColor
        tv.textColor = color
        tv.insertionPointColor = color
        switch e.style.horizontalAlignment {
        case .left: tv.alignment = .left
        case .center: tv.alignment = .center
        case .right: tv.alignment = .right
        }
        // Bright text gets a dark background for contrast while typing.
        if e.style.lineColor.luminance > 0.8 && !e.style.fillColor.isVisible {
            tv.drawsBackground = true
            tv.backgroundColor = NSColor(white: 0.15, alpha: 0.85)
        } else {
            tv.drawsBackground = false
        }
    }

    /// Positions the editor over the element's text area (after zoom or growth).
    func layoutTextView() {
        guard let tv = textView, let id = editingID, let e = document.element(id) else { return }
        styleTextView(for: e)
        let area = viewRect(DocumentRenderer.textRect(e))
        let needed = max(TextLayout.height(of: tv.string, style: e.style, width: area.width / viewScale) * viewScale,
                         (tv.font?.boundingRectForFont.height ?? 12))
        let h = min(max(needed, 1), max(area.height, needed))
        var y = area.minY
        switch e.style.verticalAlignment {
        case .top: break
        case .middle: y = area.midY - h / 2
        case .bottom: y = area.maxY - h
        }
        tv.frame = CGRect(x: area.minX, y: y, width: max(area.width, 10), height: h)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID, let e = document.element(id) else { return }
        let text = tv.string
        var area = DocumentRenderer.textRect(e)
        let inset = e.rect.height - area.height
        var width = e.rect.width
        if editingAutoWidth {
            // A clicked box widens to its longest line, up to the image's right edge.
            let natural = TextLayout.naturalSize(of: text + " ", style: e.style).width + inset
            width = min(max(e.rect.width, ceil(natural)), max(e.rect.width, document.size.width - e.rect.minX))
            area.size.width = width - inset
        }
        let needed = TextLayout.height(of: text, style: e.style, width: area.width)
        session.updateGesture { doc in
            doc.update(id) { el in
                el.text = text
                el.rect.size.width = width
                // The box grows to fit the text.
                if needed + inset > el.rect.height { el.rect.size.height = ceil(needed + inset) }
            }
        }
        layoutTextView()
    }

    func textDidEndEditing(_ notification: Notification) {
        finishTextEditing(commit: true)
    }

    /// Closes the editor. Committing an empty new box removes it; cancelling restores the
    /// state from before editing.
    func finishTextEditing(commit: Bool) {
        guard let tv = textView, let id = editingID else { return }
        textView = nil
        editingID = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        let isNew = editingIsNew
        let text = document.element(id)?.text ?? ""
        if !commit || (isNew && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            session.cancelGesture()
        } else {
            let type = document.element(id)?.type.displayName ?? "Text"
            session.endGesture(name: isNew ? "Add \(type)" : "Edit Text")
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    var isEditingText: Bool { textView != nil }
}
