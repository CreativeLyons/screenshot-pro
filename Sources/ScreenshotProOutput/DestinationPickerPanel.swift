import AppKit
import Carbon.HIToolbox
import ScreenshotProCore

/// The floating picker panel. Non-activating so it can take key focus without pulling the
/// accessory app's other windows forward.
final class DestinationPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns one picker session: builds the panel, routes keys and clicks, resumes the caller once.
///
/// The panel is a clean preview: the screenshot (drag it into another app, double-click to
/// edit) above a row of large drawn icons for the common destinations, "More" for the rest, and
/// an "Always use this destination" box. Every destination keeps its
/// picker letter. Esc, the close button, or a click elsewhere (left or right) dismisses it;
/// the capture stays in the screenshot filmstrip.
@MainActor
final class DestinationPickerController: NSObject, NSWindowDelegate, NSDraggingSource {
    static let maxPreviewSize = CGSize(width: 400, height: 260)
    static let minContentWidth: CGFloat = 400
    static let inset: CGFloat = 14
    /// Clicks outside are ignored this long after showing, so the click that ended the
    /// capture cannot dismiss the picker.
    static let armingDelay: TimeInterval = 0.3
    /// The big buttons, in order; the first is the default (Return). Short labels by id.
    static let primary: [(id: String, label: String)] = [
        (DestinationID.clipboard, "Copy"),
        (DestinationID.file, "Save"),
        (DestinationID.ocr, "Copy Text"),
        (DestinationID.editor, "Edit"),
    ]

    private static var current: DestinationPickerController?

    private let capture: Capture
    private let destinations: [CaptureDestination]
    private let panel: DestinationPickerPanel
    private var continuation: CheckedContinuation<DestinationPicker.Choice?, Never>?
    private var monitors: [Any] = []
    private var shownAt = Date.distantPast
    /// True while the More menu is open (its clicks must not dismiss the picker).
    private var menuOpen = false
    private var moreButton: NSButton?
    private let alwaysBox = NSButton(checkboxWithTitle: "Always use this destination (change it in Settings)",
                                     target: nil, action: nil)
    private var dragFile: URL?

    /// Shows a picker and waits for a choice; a picker already on screen is dismissed first.
    static func present(for capture: Capture, destinations: [CaptureDestination]) async -> DestinationPicker.Choice? {
        current?.finish(nil)
        let available = destinations.filter(\.isAvailable)
        guard !available.isEmpty else { return nil }
        let controller = DestinationPickerController(capture: capture, destinations: available)
        current = controller
        return await withCheckedContinuation { continuation in
            controller.continuation = continuation
            controller.show()
        }
    }

    private init(capture: Capture, destinations: [CaptureDestination]) {
        self.capture = capture
        self.destinations = destinations
        panel = DestinationPickerPanel(contentRect: .zero,
                                       styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
        super.init()
        panel.title = "Choose Destination"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = makeContent()
    }

    // MARK: Layout

    /// The preview size: the capture's point size scaled down to fit `maxPreviewSize`.
    static func previewSize(for pointSize: CGSize) -> CGSize {
        guard pointSize.width > 0, pointSize.height > 0 else { return CGSize(width: maxPreviewSize.width, height: 1) }
        let scale = min(1, maxPreviewSize.width / pointSize.width, maxPreviewSize.height / pointSize.height)
        return CGSize(width: max(1, (pointSize.width * scale).rounded()), height: max(1, (pointSize.height * scale).rounded()))
    }

    /// Indexes into `destinations` of the big buttons, in `primary` order.
    var primaryIndexes: [Int] {
        Self.primary.compactMap { p in destinations.firstIndex { $0.id == p.id } }
    }

    private func makeContent() -> NSView {
        let previewSize = Self.previewSize(for: capture.pointSize)
        let contentWidth = max(previewSize.width, Self.minContentWidth)

        let preview = PickerPreviewView(image: OutputSupport.nsImage(for: capture))
        preview.onDrag = { [weak self] view, event in self?.beginDrag(from: view, event: event) }
        preview.onDoubleClick = { [weak self] in
            guard let self, let index = self.destinations.firstIndex(where: \.isEditor) else { return }
            self.choose(at: index)
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: previewSize.width),
            preview.heightAnchor.constraint(equalToConstant: previewSize.height),
        ])

        let size = NSTextField(labelWithString: "\(capture.image.width) x \(capture.image.height) px")
        size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.textColor = .secondaryLabelColor
        let dragHint = NSTextField(labelWithString: "Drag the image into any app")
        dragHint.font = .systemFont(ofSize: 11)
        dragHint.textColor = .tertiaryLabelColor
        let info = NSStackView(views: [size, NSView(), dragHint])
        info.orientation = .horizontal
        info.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        var tiles: [NSView] = []
        for index in primaryIndexes {
            let destination = destinations[index]
            let label = Self.primary.first { $0.id == destination.id }?.label ?? destination.displayName
            let icon = DestinationIcons.image(for: destination.id) ?? TileButton.symbolImage(destination.symbolName)
            let tile = TileButton(title: label, image: icon, target: self, action: #selector(tileClicked(_:)))
            tile.tag = index
            let key = StandardDestinations.shortcutKey(for: destination.id)
            tile.toolTip = destination.displayName + (key.map { "  (\($0))" } ?? "")
            if index == primaryIndexes.first { tile.keyEquivalent = "\r" }
            tiles.append(tile)
        }
        let more = TileButton(title: "More", image: DestinationIcons.more(), target: self, action: #selector(moreClicked(_:)))
        more.toolTip = "Save as, print, share and more"
        moreButton = more
        tiles.append(more)
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        alwaysBox.controlSize = .small
        alwaysBox.font = .systemFont(ofSize: 11)
        alwaysBox.contentTintColor = .systemGreen
        alwaysBox.toolTip = "Skips this window from now on and sends captures straight to the destination you pick."

        let stack = NSStackView(views: [preview, info, row, alwaysBox])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: info)
        stack.setCustomSpacing(10, after: row)
        // The transparent title bar overlaps the top: leave room for the close button.
        stack.edgeInsets = NSEdgeInsets(top: 30, left: Self.inset, bottom: Self.inset, right: Self.inset)

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let primaries = Set(primaryIndexes)
        for index in destinations.indices where !primaries.contains(index) {
            menu.addItem(destinationItem(index))
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }
        let filmstrip = NSMenuItem(title: "Screenshot Filmstrip", action: #selector(showHistory), keyEquivalent: "")
        filmstrip.target = self
        filmstrip.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)
        menu.addItem(filmstrip)
        return menu
    }

    private func destinationItem(_ index: Int) -> NSMenuItem {
        let destination = destinations[index]
        let item = NSMenuItem(title: destination.displayName, action: #selector(menuChose(_:)), keyEquivalent: "")
        item.target = self
        item.tag = index
        item.image = NSImage(systemSymbolName: destination.symbolName, accessibilityDescription: nil)
        if let key = StandardDestinations.shortcutKey(for: destination.id) {
            item.keyEquivalent = String(key).lowercased()
            item.keyEquivalentModifierMask = []
        }
        return item
    }

    // MARK: Showing

    private func show() {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 360)
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, mouse: NSEvent.mouseLocation,
                                         screens: NSScreen.screens.map(\.visibleFrame)))
        // Accessory apps are not active after a capture; activate so letter keys reach the panel.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(nil)
        shownAt = Date()
        installMonitors()
    }

    /// Top-left corner just below-right of the mouse, kept inside the screen under the mouse.
    static func origin(for size: CGSize, mouse: CGPoint, screens: [CGRect]) -> CGPoint {
        let screen = screens.first { $0.contains(mouse) } ?? screens.first ?? CGRect(origin: .zero, size: size)
        var x = mouse.x + 8
        var y = mouse.y - 8 - size.height
        x = min(max(x, screen.minX), screen.maxX - size.width)
        y = min(max(y, screen.minY), screen.maxY - size.height)
        // A panel larger than the screen pins to the top-left of the visible frame.
        if size.width > screen.width { x = screen.minX }
        if size.height > screen.height { y = screen.maxY - size.height }
        return CGPoint(x: x, y: y)
    }

    private func installMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return consumed ? nil : event
        }) { monitors.append(keys) }
        if let localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let window = event.window
            // A right click on the picker itself dismisses it too (the escape hatch).
            let isRight = event.type == .rightMouseDown
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if window !== self.panel {
                    self.clickedOutside()
                    return false
                }
                if isRight {
                    self.finish(nil)
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }) { monitors.append(localClicks) }
        if let globalClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(globalClicks) }
    }

    // MARK: Input

    /// Handles a key typed while the picker is up; true when consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isVisible, !menuOpen else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(nil)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            choose(at: primaryIndexes.first ?? 0)
            return true
        default:
            break
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty || flags == .command,
              let typed = event.charactersIgnoringModifiers?.uppercased().first else { return false }
        if let index = Self.index(forKey: typed, in: destinations.map(\.id)) {
            choose(at: index)
            return true
        }
        return false
    }

    /// The destination index whose picker letter is `key`, or nil.
    static func index(forKey key: Character, in ids: [String]) -> Int? {
        let upper = Character(String(key).uppercased())
        return ids.firstIndex { StandardDestinations.shortcutKey(for: $0) == upper }
    }

    private func clickedOutside() {
        guard !menuOpen, Date().timeIntervalSince(shownAt) > Self.armingDelay else { return }
        finish(nil)
    }

    @objc private func tileClicked(_ sender: NSButton) {
        choose(at: sender.tag)
    }

    @objc private func moreClicked(_ sender: NSButton) {
        let menu = moreMenu()
        menuOpen = true
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        menuOpen = false
    }

    @objc private func menuChose(_ sender: NSMenuItem) {
        choose(at: sender.tag)
    }

    @objc private func showHistory() {
        finish(nil)
        HistoryStrip.show()
    }

    private func choose(at index: Int) {
        guard destinations.indices.contains(index) else { return }
        finish(DestinationPicker.Choice(destination: destinations[index], remember: alwaysBox.state == .on))
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    // MARK: Dragging the preview out

    private func beginDrag(from view: NSView, event: NSEvent) {
        guard let url = fileForDrag() else { return }
        let p = view.convert(event.locationInWindow, from: nil)
        let size = ImageFileDrag.fitted(view.bounds.size, maxSide: 200)
        let frame = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        ImageFileDrag.begin(fileURL: url, preview: OutputSupport.nsImage(for: capture), frame: frame,
                            from: view, event: event, source: self)
    }

    /// The history's copy of this capture when there is one, else a temporary PNG.
    private func fileForDrag() -> URL? {
        if let url = dragFile { return url }
        dragFile = CaptureHistory.shared.fileURL(forImage: capture.image) ?? (try? OutputSupport.writeTemporaryPNG(capture))
        return dragFile
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        // A drop into another app used the screenshot: the picker has done its job.
        guard operation != [] else { return }
        MainActor.assumeIsolated { finish(nil) }
    }

    // MARK: Finishing

    private func finish(_ choice: DestinationPicker.Choice?) {
        guard let continuation else { return }
        self.continuation = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.delegate = nil
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
        continuation.resume(returning: choice)
    }
}

/// The picker's screenshot: rounded, draggable, double-click to edit.
@MainActor
final class PickerPreviewView: NSView {
    var onDrag: ((NSView, NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var downPoint: CGPoint?

    init(image: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .trilinear
        toolTip = "Drag into another app, or double-click to edit"
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick?()
            return
        }
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downPoint = nil
        onDrag?(self, event)
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
    }
}

/// A large icon-over-label button that floats on the panel and shows a soft wash on hover.
/// Draws its own content: the standard image-above layout overlaps a large icon and its title.
@MainActor
final class TileButton: NSButton {
    private let symbol: NSImage?
    private var hovering = false { didSet { updateBackground() } }

    override var isHighlighted: Bool { didSet { updateBackground() } }
    /// The panel's blur would otherwise draw the colored icons vibrant, washing them out.
    override var allowsVibrancy: Bool { false }

    /// An SF Symbol at tile size, for destinations without a drawn icon.
    static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
                .applying(.init(hierarchicalColor: .labelColor)))
    }

    init(title: String, image: NSImage?, target: AnyObject, action: Selector) {
        symbol = image
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .noImage
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = 9
        heightAnchor.constraint(equalToConstant: 82).isActive = true
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        let labelSize = label.size()
        let gap: CGFloat = 6
        let iconSize = symbol?.size ?? .zero
        let total = iconSize.height + gap + labelSize.height
        // Flipped coordinates: content block centered vertically, icon on top.
        let top = isFlipped ? (b.height - total) / 2 : (b.height + total) / 2
        if let symbol {
            let y = isFlipped ? top : top - iconSize.height
            symbol.draw(in: CGRect(x: (b.width - iconSize.width) / 2, y: y, width: iconSize.width, height: iconSize.height))
        }
        let labelY = isFlipped ? top + iconSize.height + gap : top - iconSize.height - gap - labelSize.height
        label.draw(at: CGPoint(x: (b.width - labelSize.width) / 2, y: labelY))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = isHighlighted ? 0.18 : hovering ? 0.09 : 0
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}
