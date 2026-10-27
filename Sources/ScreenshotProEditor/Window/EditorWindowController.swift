import AppKit
import ScreenshotProCore
import ScreenshotProOutput

/// One editor window: a single toolbar row (destinations, tools, colors), the properties bar,
/// canvas and status bar around an `EditorSession`.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let session: EditorSession
    /// Metadata of the original capture (title, app, date...), passed on to destinations.
    var details: CaptureDetails
    /// Where ⌘S writes: the file the image came from or was last saved to.
    var documentURL: URL?

    let canvas: CanvasView
    let scrollView = NSScrollView()
    let propertiesBar = PropertiesBar()
    let palette = ToolsPalette()
    let quickColors = QuickColorBar()
    let statusBar = StatusBar()
    let dragOut = DragOutView()
    let windowUndoManager = UndoManager()
    /// Closing proceeds without asking (after Save or Don't Save).
    var closeConfirmed = false
    /// The style fields the properties bar shows now (what a quick color can change).
    var shownFields: Set<ElementField> = []

    static let frameDefaultsKey = "ScreenshotPro.editor.lastFrame"

    var settings: ScreenshotProSettings { SettingsStore.shared.settings }

    init(document: EditorDocument, details: CaptureDetails, documentURL: URL?) {
        session = EditorSession(document: document)
        self.details = details
        self.documentURL = documentURL
        canvas = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        // Title above one full-width row of icons.
        window.toolbarStyle = .expanded
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        session.undoManager = windowUndoManager
        session.onChange = { [weak self] in self?.sessionChanged() }
        canvas.delegate = self
        buildContent()
        buildToolbar()
        updateTitle()
        sessionChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .underPageBackgroundColor
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder

        let topLine = NSBox(), bottomLine = NSBox()
        for b in [topLine, bottomLine] { b.boxType = .separator }
        let views: [NSView] = [propertiesBar, topLine, scrollView, bottomLine, statusBar]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            propertiesBar.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            propertiesBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            propertiesBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: propertiesBar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        palette.onSelect = { [weak self] tool in self?.selectTool(tool) }
        statusBar.onZoom = { [weak self] z in
            guard let self else { return }
            if let z { canvas.setZoom(z) } else { canvas.zoomToFit() }
        }
        quickColors.setColors(settings.editorQuickColors)
        quickColors.onPick = { [weak self] color, fill in self?.applyQuickColor(color, fill: fill) }
        propertiesBar.onStyleChange = { [weak self] field, change in
            guard let self else { return }
            session.setStyle(field, toolType: canvas.tool.elementType, settings: settings, change)
            refreshProperties()
        }
        propertiesBar.onCounterStart = { [weak self] v in self?.session.setCounterStart(v) }
        propertiesBar.onResetCounter = { [weak self] in self?.session.resetCounter() }
        propertiesBar.onCropApply = { [weak self] in self?.applyCrop() }
        propertiesBar.onCropCancel = { [weak self] in
            self?.canvas.cropRect = nil
            self?.selectTool(.select)
        }
        propertiesBar.onAutoCrop = { [weak self] in self?.autoCrop() }
        dragOut.provideImage = { [weak self] in
            guard let self, let image = flattenedImage(), let data = PNGCoding.encode(image) else { return nil }
            return (data, baseFileName)
        }
        window.initialFirstResponder = canvas
    }

    /// Sizes the window to the capture (limited to the visible screen), places it at the
    /// remembered position and picks the initial zoom.
    func placeWindow(cascadeFrom other: NSWindow?) {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let doc = session.document
        let imagePoints = CGSize(width: doc.size.width / doc.scale, height: doc.size.height / doc.scale)
        let chrome = CGSize(width: 18, height: 34 + 24 + 2 + 18)
        let titleAndToolbar: CGFloat = 80
        let available = CGSize(width: visible.width - chrome.width,
                               height: visible.height - chrome.height - titleAndToolbar)
        let zoom = min(1, ZoomLevels.fit(content: imagePoints, available: available))
        var size = CGSize(width: imagePoints.width * zoom + chrome.width,
                          height: imagePoints.height * zoom + chrome.height)
        size.width = min(max(size.width, 760), visible.width)
        size.height = min(max(size.height, 380), visible.height - titleAndToolbar)
        window.setContentSize(size)
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        if let other {
            let topLeft = window.cascadeTopLeft(from: CGPoint(x: other.frame.minX, y: other.frame.maxY))
            frame.origin = CGPoint(x: topLeft.x, y: topLeft.y - frame.height)
        } else if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let old = NSRectFromString(saved)
            frame.origin = CGPoint(x: old.minX, y: old.maxY - frame.height)
        } else {
            frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        }
        // Keep it on the visible screen.
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
        canvas.setZoom(zoom)
        statusBar.showZoom(canvas.zoom)
    }

    var baseFileName: String {
        let t = details.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = t.isEmpty ? "Screenshot" : t
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    func updateTitle() {
        let name = documentURL?.lastPathComponent ?? details.title ?? "Screenshot"
        window?.title = "\(name) - Screenshot Pro"
        window?.representedURL = documentURL
    }

    // MARK: Refresh

    func sessionChanged() {
        canvas.documentDidChange()
        refreshProperties()
        let size = session.document.size
        statusBar.sizeLabel.stringValue = "\(Int(size.width)) x \(Int(size.height)) px"
        window?.isDocumentEdited = session.isModified
        window?.toolbar?.validateVisibleItems()
    }

    func refreshProperties() {
        var content = PropertiesBar.Content()
        let scale = session.document.scale
        let selected = session.selectedElements
        if canvas.tool == .crop {
            content.showsCrop = true
            content.title = "Crop"
        } else if let last = selected.last {
            content.fields = ElementField.commonFields(of: selected)
            content.style = last.style.scaled(by: 1 / scale)
            content.title = selected.count == 1 ? last.type.displayName : "\(selected.count) Elements"
        } else if let type = canvas.tool.elementType {
            let style = session.toolDefaults.style(for: type, settings: settings)
            content.fields = ElementField.fields(for: type, style: style)
            // The blur and pixelate tools each stand for one mode.
            if canvas.tool.obfuscateMode != nil { content.fields.removeAll { $0 == .obfuscateMode } }
            content.style = style
            content.title = canvas.tool.displayName
        }
        content.counterStart = session.document.counterStart
        propertiesBar.update(content)
        shownFields = Set(content.fields)
        let canColor = shownFields.contains(.lineColor) || shownFields.contains(.fillColor)
        let current = shownFields.contains(.lineColor) ? content.style.lineColor : content.style.fillColor
        quickColors.show(current: current, enabled: canColor)
    }

    /// A quick color sets the line color, or the fill when asked (Option) or when there is no line.
    func applyQuickColor(_ color: RGBAColor, fill: Bool) {
        let field: ElementField
        if (fill || !shownFields.contains(.lineColor)) && shownFields.contains(.fillColor) {
            field = .fillColor
        } else if shownFields.contains(.lineColor) {
            field = .lineColor
        } else {
            return
        }
        session.setStyle(field, toolType: canvas.tool.elementType, settings: settings) { style in
            if field == .fillColor { style.fillColor = color } else { style.lineColor = color }
        }
        refreshProperties()
    }

    func showMessage(_ message: String) {
        statusBar.messageLabel.stringValue = message
    }

    func selectTool(_ tool: EditorTool) {
        canvas.tool = tool
        palette.select(tool)
        window?.makeFirstResponder(canvas)
        refreshProperties()
        if settings.showTextHints { showMessage(tool.hint) }
    }

    // MARK: Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { windowUndoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.finishTextEditing(commit: true)
        if closeConfirmed || !session.isModified { return true }
        askToSaveBeforeClosing()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        windowUndoManager.removeAllActions()
        Editor.windowDidClose(self)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
    }
}

// MARK: Canvas delegate

extension EditorWindowController: CanvasViewDelegate {
    func canvasDidChangeTool(_ canvas: CanvasView) {
        palette.select(canvas.tool)
        refreshProperties()
        if settings.showTextHints { showMessage(canvas.tool.hint) }
    }

    func canvasDidChangeZoom(_ canvas: CanvasView) {
        statusBar.showZoom(canvas.zoom)
    }

    func canvasDidChangeCrop(_ canvas: CanvasView) {
        if let r = canvas.cropRect {
            showMessage("Crop to \(Int(r.width)) x \(Int(r.height)) px. Return applies, Esc cancels.")
        }
    }

    func canvasApplyCrop(_ canvas: CanvasView) { applyCrop() }

    func canvasContextMenu(_ canvas: CanvasView) -> NSMenu? { contextMenu() }

    func canvas(_ canvas: CanvasView, showMessage message: String) { showMessage(message) }

    func canvas(_ canvas: CanvasView, insertImages images: [CGImage], at point: CGPoint) {
        insertImages(images, at: point)
    }
}
