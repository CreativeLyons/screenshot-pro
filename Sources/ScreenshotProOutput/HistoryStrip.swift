import AppKit
import Carbon.HIToolbox
import Combine
import ScreenshotProCore

/// The "Screenshot Filmstrip": a column of thumbnails, newest at the top, docked to the left
/// edge of the screen under the pointer at first. A click brings a screenshot back up in the
/// capture window (every destination), Command-click copies it, Shift-click adds it to (or takes
/// it out of) a selection, dragging drops its PNG file (or every selected one) into another
/// app, a right click offers every destination, the x on hover removes one and Clear All
/// removes them all. It updates as new captures arrive.
///
/// The grab bar at its top moves it anywhere. Dropped within `snapDistance` of the left or right
/// edge of the screen, it snaps flush to that edge and auto-hide turns on: it tucks into a small
/// translucent tab at the edge once the pointer leaves, and slides back out when the tab is
/// hovered or clicked, like the Dock. Dropped out in the open, it floats where it was let go and
/// auto-hide turns off (pinned). A faint green glow along the edge shows while a drop would snap.
/// The pin button (or Settings) toggles auto-hide: pinning a docked strip keeps it docked and
/// open, unpinning a floating one docks it to the nearer edge first, since only a docked strip
/// can tuck away. A pinned strip stays until closed (its x, Esc, or the hotkey). Dragging the tab
/// moves it along the edge or across to the other one. The place (edge and height, or the
/// floating corner) is remembered.
@MainActor
public enum HistoryStrip {
    /// Runs a destination for a history item. The app routes it through its capture flow for
    /// notifications and error alerts; without it the destination runs directly.
    public static var exportHandler: ((Capture, CaptureDestination) async -> ExportResult?)?
    /// Shows the capture window for a clicked history item and runs the choice. The app routes
    /// it through its capture flow; without it the picker's choice runs directly.
    public static var openHandler: ((Capture) async -> Void)?

    /// What a click on a thumbnail does: Shift-click toggles it in the selection, Command-click
    /// copies, a plain click opens the capture window.
    enum ClickAction: Equatable { case open, copy, toggleSelection }
    static func clickAction(for modifiers: NSEvent.ModifierFlags) -> ClickAction {
        if modifiers.contains(.shift) { return .toggleSelection }
        return modifiers.contains(.command) ? .copy : .open
    }

    private static var controller: HistoryStripController?
    private static var shared: HistoryStripController {
        if let controller { return controller }
        let made = HistoryStripController()
        controller = made
        return made
    }

    /// True while the sidebar or its tab is on screen.
    public static var isOpen: Bool { controller?.isOpen == true }

    /// The sidebar's panel while expanded (for the self-test).
    public static var window: NSWindow? { controller?.isExpanded == true ? controller?.panel : nil }

    /// The edge tab while the sidebar is tucked away (for the self-test).
    public static var tabWindow: NSWindow? { controller?.isOpen == true && controller?.isExpanded == false ? controller?.tab : nil }

    /// Opens the sidebar expanded (also from its tab).
    public static func show() {
        shared.open(expanded: true)
    }

    public static func close() {
        controller?.close()
    }

    /// The hotkey and menu item: opens it, slides a tucked-away sidebar out, or closes it.
    public static func toggle() {
        guard let controller, controller.isOpen else { return show() }
        controller.isExpanded ? controller.close() : controller.expand(byPointer: false)
    }

    /// Tucks the sidebar into its tab now (auto-hide only; for the self-test).
    public static func collapse() {
        controller?.collapse()
    }

    /// Moves the sidebar (or tab) to the saved place: the floating corner when one is saved,
    /// else the edge and height (for the self-test).
    public static func applyPlacement() {
        controller?.applyPlacement()
    }

    /// Clicks the thumbnail at `index` (for the self-test).
    public static func clickItem(at index: Int, modifiers: NSEvent.ModifierFlags = []) {
        controller?.clickItem(at: index, modifiers: modifiers)
    }

    /// Reopens the sidebar at launch when it was open at quit (tucked away with auto-hide on).
    public static func restore() {
        let s = SettingsStore.shared.settings
        guard s.historyStripOpen else { return }
        shared.open(expanded: !s.historyAutoHide)
    }
}

extension HistoryStripSize {
    var itemWidth: CGFloat {
        switch self {
        case .small: return 120
        case .medium: return 212
        case .large: return 300
        }
    }

    var maxThumbHeight: CGFloat {
        switch self {
        case .small: return 84
        case .medium: return 150
        case .large: return 210
        }
    }

    var segmentLabel: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }
}

/// Key-capable but non-activating, so clicking a thumbnail leaves the frontmost app in front.
final class HistoryStripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HistoryStripController: NSObject, NSMenuDelegate {
    static let inset: CGFloat = 12
    static let screenMargin: CGFloat = 10
    static let slide: CGFloat = 28
    static let animation: TimeInterval = 0.18
    /// How long the pointer may be away before an auto-hiding sidebar tucks itself away.
    static let hideDelay: TimeInterval = 0.45
    /// A strip dropped this close to the left or right edge of the visible screen snaps to it.
    nonisolated static let snapDistance: CGFloat = 60
    /// The brand green, for hover borders and the snap glow.
    static let accent = NSColor(srgbRed: 0.24, green: 0.80, blue: 0.40, alpha: 1)

    let panel: HistoryStripPanel
    let tab: EdgeTabPanel
    private let glow = SnapGlowPanel()
    private(set) var isOpen = false
    private(set) var isExpanded = false

    private let history = CaptureHistory.shared
    private let store = SettingsStore.shared
    private var list = NSStackView()
    private var scroll = NSScrollView()
    private var clearButton = NSButton()
    private var pinButton = NSButton()
    private var sizeControl = NSSegmentedControl()
    private var clearArmedUntil = Date.distantPast
    private var keyMonitor: Any?
    private var observer: NSObjectProtocol?
    private var settingsWatch: AnyCancellable?
    private var hoverTimer: Timer?
    /// Screenshots picked with Shift-click; dragging any of them drags them all.
    private var selected: Set<UUID> = []
    private var scrollObserver: NSObjectProtocol?
    /// The pointer was last over the sidebar at this time (may be in the future for a grace period).
    private var lastInside = Date()
    private var dragging = false
    private var menuOpen = false
    /// The usable area (visible frame inset by the margin) of the screen the sidebar is on,
    /// chosen when it opens or where it was last dropped.
    private var screenArea: CGRect?

    private var size: HistoryStripSize { store.settings.historyStripSize }
    private var autoHide: Bool { store.settings.historyAutoHide }
    private var width: CGFloat { size.itemWidth + 2 * Self.inset }
    private var edge: HistoryStripEdge { store.settings.historyStripEdge }
    /// The saved floating corner, when it is on a connected screen and auto-hide is off.
    /// Otherwise the strip docks at the saved edge.
    private var floatingTopLeft: CGPoint? {
        guard !autoHide, let point = store.settings.historyStripFloatingTopLeft,
              Self.screen(near: point) != nil else { return nil }
        return point
    }
    private var isFloating: Bool { floatingTopLeft != nil }
    /// Horizontal offset for the slide in and out, away from the screen edge (none while
    /// floating: it just fades).
    private var slideOffset: CGFloat {
        if isFloating { return 0 }
        return edge == .left ? -Self.slide : Self.slide
    }

    override init() {
        panel = HistoryStripPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 400),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        tab = EdgeTabPanel()
        super.init()
        panel.title = "Screenshot Filmstrip"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = makeContent()
        tab.onReveal = { [weak self] in self?.expand(byPointer: true) }
        tab.onMoveStarted = { [weak self] in self?.dragging = true }
        tab.onMoved = { [weak self] in self?.tabDropped() }
        tab.menuProvider = { [weak self] in self?.placementMenu(includeShow: true) }
        tab.edge = edge
    }

    // MARK: Building

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let mark = NSImageView(image: ScreenshotProMark.image(height: 13))
        mark.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Screenshot Filmstrip")
        title.font = .systemFont(ofSize: size == .small ? 11 : 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinButton = NSButton(image: NSImage(), target: self, action: #selector(pinClicked))
        pinButton.isBordered = false
        updatePinButton()

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Close (Esc)"

        let grip = GripView()
        grip.onDragStarted = { [weak self] in self?.dragging = true }
        grip.onDragMoved = { [weak self] in self?.sidebarMoved() }
        grip.onDropped = { [weak self] in self?.sidebarDropped() }
        grip.menuProvider = { [weak self] in self?.placementMenu(includeShow: false) }

        let header = NSStackView(views: [mark, title, NSView(), pinButton, close])
        header.orientation = .horizontal
        header.spacing = 5

        clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearClicked))
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.toolTip = "Remove every screenshot from the history"
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        sizeControl = NSSegmentedControl(labels: HistoryStripSize.allCases.map(\.segmentLabel), trackingMode: .selectOne,
                                         target: self, action: #selector(sizeChanged(_:)))
        sizeControl.controlSize = .small
        sizeControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        for (i, s) in HistoryStripSize.allCases.enumerated() {
            sizeControl.setToolTip("\(s.displayName) thumbnails", forSegment: i)
            sizeControl.setWidth(size == .small ? 14 : 18, forSegment: i)
        }
        sizeControl.selectedSegment = HistoryStripSize.allCases.firstIndex(of: size) ?? 0

        sizeControl.setContentHuggingPriority(.required, for: .horizontal)
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        gap.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let tools = NSStackView(views: [clearButton, gap, sizeControl])
        tools.orientation = .horizontal
        tools.spacing = 2

        list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = size == .small ? 8 : 12
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        // Thumbnails sliding under a still pointer get no exit event, so hover is worked out
        // again from the pointer whenever the list scrolls.
        scroll.contentView.postsBoundsChangedNotifications = true
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHover() }
        }
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        var rows: [NSView] = [grip, header, tools, scroll]
        if size != .small {
            let hint = NSTextField(wrappingLabelWithString:
                "Click for options, \u{2318}-click to copy, Shift-click to pick several. Drag into any app.")
            hint.font = .systemFont(ofSize: 10.5)
            hint.textColor = .secondaryLabelColor
            rows.append(hint)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: tools)
        stack.setCustomSpacing(2, after: grip)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalToConstant: size.itemWidth).isActive = true
        }
        return background
    }

    private func updatePinButton() {
        let symbol = autoHide ? "pin.slash" : "pin.fill"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: autoHide ? "Auto-hide on" : "Auto-hide off")
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.toolTip = autoHide
            ? "Auto-hide is on: the filmstrip tucks away when the pointer leaves. Click to keep it open."
            : "Auto-hide is off: the filmstrip stays open. Click to dock it at the screen edge and auto-hide it like the Dock."
    }

    private func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resetClearButton()
        clearButton.isEnabled = !history.entries.isEmpty
        tab.count = history.entries.count
        if history.entries.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No screenshots yet. Screen captures you take appear here.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: size == .small ? 11 : 13)
            empty.widthAnchor.constraint(equalToConstant: size.itemWidth).isActive = true
            list.addArrangedSubview(empty)
        }
        selected.formIntersection(history.entries.map(\.id))
        for entry in history.entries {
            let item = HistoryItemView(entry: entry, thumbnail: history.thumbnail(for: entry),
                                       fileURL: history.fileURL(for: entry), size: size)
            item.isSelected = selected.contains(entry.id)
            item.onClick = { [weak self, weak item] modifiers in
                guard let self, let item else { return }
                switch HistoryStrip.clickAction(for: modifiers) {
                case .open:
                    self.clearSelection()
                    self.open(entry, item)
                case .copy: self.copy(entry, item)
                case .toggleSelection: self.toggleSelection(entry, item)
                }
            }
            item.onHover = { [weak self] in self?.refreshHover() }
            item.dragFiles = { [weak self] in self?.dragFiles(from: entry) ?? [] }
            item.onDelete = { [weak self] in self?.history.remove(entry.id) }
            item.onDragging = { [weak self] active in
                self?.dragging = active
                if !active { self?.lastInside = Date() }
            }
            item.menuProvider = { [weak self, weak item] in
                guard let self, let item else { return nil }
                return self.menu(for: entry, item)
            }
            list.addArrangedSubview(item)
        }
        list.layoutSubtreeIfNeeded()
        if isExpanded { panel.setFrame(expandedFrame(), display: true) }
    }

    /// Rebuilds the content after the size changed.
    private func rebuild() {
        panel.contentView = makeContent()
        reload()
    }

    // MARK: Geometry

    /// The sidebar's frame: fitted to its content, up to the full height of the usable area.
    /// Floating, its top-left corner sits at the saved corner, kept on that screen; docked, it is
    /// against the chosen screen edge with its top at the saved position.
    private func expandedFrame() -> CGRect {
        let floating = floatingTopLeft
        let area = floating.map { Self.area(of: Self.screen(near: $0)) } ?? currentArea()
        let listHeight = list.fittingSize.height
        let hint: CGFloat = size == .small ? 0 : 36
        let chrome: CGFloat = 4 + GripView.height + 2 + 20 + 8 + 22 + 10 + Self.inset + hint
        let height = min(area.height, max(listHeight + chrome, 160))
        if let floating {
            let frame = CGRect(x: floating.x, y: floating.y - height, width: width, height: height)
            return Self.clamp(frame, to: area)
        }
        let top = clampedTop(height: height, in: area)
        let x = edge == .left ? area.minX : area.maxX - width
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The tab: flush with the screen edge, level with the top of the sidebar.
    private func tabFrame() -> CGRect {
        let area = currentArea()
        let full = area.insetBy(dx: -Self.screenMargin, dy: -Self.screenMargin)
        let size = EdgeTabPanel.size
        let top = clampedTop(height: size.height, in: area)
        let x = edge == .left ? full.minX : full.maxX - size.width
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// The saved top, kept so a box of `height` stays on screen.
    private func clampedTop(height: CGFloat, in area: CGRect) -> CGFloat {
        let wanted = area.maxY - CGFloat(store.settings.historyStripTop) * area.height
        return min(area.maxY, max(wanted, area.minY + height)).rounded()
    }

    private func currentArea() -> CGRect {
        if let screenArea { return screenArea }
        let area = Self.area(of: Self.screen(containing: NSEvent.mouseLocation))
        screenArea = area
        return area
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The connected screen at `point` (edges included), or nil when it is on none.
    private static func screen(near point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// `frame` moved (not resized, unless it is larger) so it lies inside `area`.
    static func clamp(_ frame: CGRect, to area: CGRect) -> CGRect {
        let w = min(frame.width, area.width), h = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - w)
        let y = min(max(frame.minY, area.minY), area.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    /// The edge a strip at `frame` snaps to when dropped: the left or right edge of `visible`
    /// (the screen's visible frame) within `distance`, the nearer one if both; nil out in the open.
    static func snapEdge(for frame: CGRect, in visible: CGRect, distance: CGFloat = snapDistance) -> HistoryStripEdge? {
        let left = frame.minX - visible.minX, right = visible.maxX - frame.maxX
        guard min(left, right) < distance else { return nil }
        return left <= right ? .left : .right
    }

    /// The top of a box as a fraction of the usable height below the top of `area`.
    private static func topFraction(_ top: CGFloat, in area: CGRect) -> Double {
        area.height > 0 ? Double(min(max((area.maxY - top) / area.height, 0), 1)) : 0
    }

    private static func area(of screen: NSScreen?) -> CGRect {
        (screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600))
            .insetBy(dx: screenMargin, dy: screenMargin)
    }

    // MARK: Moving

    /// The grab bar is being dragged: glow along the edge a drop here would snap to.
    private func sidebarMoved() {
        let screen = Self.screen(containing: NSEvent.mouseLocation)
        let visible = screen?.visibleFrame ?? .zero
        guard let snap = Self.snapEdge(for: panel.frame, in: visible) else { return glow.hide() }
        glow.show(along: snap, of: visible, level: panel.frame)
    }

    /// The grab bar was released. Near the left or right edge of the screen under the pointer, it
    /// snaps flush to that edge and turns auto-hide on; out in the open it floats where it was
    /// dropped (kept on that screen) and turns auto-hide off.
    private func sidebarDropped() {
        dragging = false
        lastInside = Date()
        glow.hide()
        let screen = Self.screen(containing: NSEvent.mouseLocation)
        let area = Self.area(of: screen)
        screenArea = area
        let frame = panel.frame
        if let snap = Self.snapEdge(for: frame, in: screen?.visibleFrame ?? area) {
            store.update {
                $0.historyStripFloatingTopLeft = nil
                $0.historyStripEdge = snap
                $0.historyStripTop = Self.topFraction(frame.maxY, in: area)
                $0.historyAutoHide = true
            }
            tab.edge = snap
        } else {
            let kept = Self.clamp(frame, to: area)
            store.update {
                $0.historyStripFloatingTopLeft = CGPoint(x: kept.minX, y: kept.maxY)
                $0.historyAutoHide = false
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.animation
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(expandedFrame(), display: true)
        }
    }

    /// The tab was dragged and released.
    private func tabDropped() {
        place(top: tab.frame.maxY)
        dragging = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.animation
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tab.animator().setFrame(tabFrame(), display: true)
        }
    }

    /// Saves the edge nearer the pointer and `top` as the new place, on the pointer's screen.
    private func place(top: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = Self.screen(containing: mouse)
        let area = Self.area(of: screen)
        screenArea = area
        let newEdge: HistoryStripEdge = mouse.x < (screen?.frame.midX ?? area.midX) ? .left : .right
        store.update {
            $0.historyStripFloatingTopLeft = nil
            $0.historyStripEdge = newEdge
            $0.historyStripTop = Self.topFraction(top, in: area)
        }
        tab.edge = newEdge
    }

    /// Docks a floating strip to the nearer edge of its screen, at its current height
    /// (auto-hide was turned on while it floated).
    private func dockAtNearerEdge() {
        let frame = panel.frame
        let screen = Self.screen(containing: CGPoint(x: frame.midX, y: frame.midY))
        let area = Self.area(of: screen)
        screenArea = area
        let newEdge: HistoryStripEdge = frame.midX < (screen?.frame.midX ?? area.midX) ? .left : .right
        store.update {
            $0.historyStripFloatingTopLeft = nil
            $0.historyStripEdge = newEdge
            $0.historyStripTop = Self.topFraction(frame.maxY, in: area)
        }
        tab.edge = newEdge
        if isExpanded {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animation
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(expandedFrame(), display: true)
            }
        }
    }

    func applyPlacement() {
        move(to: nil)
    }

    /// Docks at an edge (leaving the floating place), back at the top-left corner, or with
    /// neither, re-applies the saved place. Auto-hide stays as it is.
    private func move(to newEdge: HistoryStripEdge?, resetTop: Bool = false) {
        store.update {
            if let newEdge {
                $0.historyStripEdge = newEdge
                $0.historyStripFloatingTopLeft = nil
            }
            if resetTop {
                $0.historyStripEdge = .left
                $0.historyStripTop = 0
                $0.historyStripFloatingTopLeft = nil
            }
        }
        tab.edge = edge
        if isExpanded {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animation
                panel.animator().setFrame(expandedFrame(), display: true)
            }
        } else if isOpen {
            tab.setFrame(tabFrame(), display: true)
        }
    }

    /// Right click on the grab bar or the tab.
    private func placementMenu(includeShow: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        if includeShow {
            menu.addItem(MenuAction(title: "Show Screenshot Filmstrip", symbol: "photo.stack") { [weak self] in
                self?.expand(byPointer: true)
            }.item)
            menu.addItem(.separator())
        }
        // Floating, either edge docks it; docked, the other edge moves it across.
        let edges: [HistoryStripEdge] = isFloating ? [.left, .right] : [edge == .left ? .right : .left]
        for target in edges {
            let verb = isFloating ? "Dock" : "Move"
            let title = target == .left ? "\(verb) to Left Edge" : "\(verb) to Right Edge"
            menu.addItem(MenuAction(title: title, symbol: target == .left ? "arrow.left.to.line" : "arrow.right.to.line") { [weak self] in
                self?.move(to: target)
            }.item)
        }
        menu.addItem(MenuAction(title: "Reset Position", symbol: "arrow.up.left") { [weak self] in
            self?.move(to: nil, resetTop: true)
        }.item)
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: "Close", symbol: "xmark") { [weak self] in
            self?.close()
        }.item)
        return menu
    }

    // MARK: Opening and closing

    func open(expanded: Bool) {
        let wasOpen = isOpen
        isOpen = true
        if !wasOpen {
            store.update { $0.historyStripOpen = true }
            startObserving()
            reload()
        }
        if expanded {
            expand(byPointer: false)
        } else if !isExpanded {
            showTab()
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        isExpanded = false
        stopHoverTimer()
        panel.orderOut(nil)
        tab.orderOut(nil)
        glow.hide()
        screenArea = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        settingsWatch = nil
        store.update { $0.historyStripOpen = false }
    }

    /// Slides the sidebar out. `byPointer` is a hover or click on the tab; otherwise (hotkey,
    /// menu) the pointer gets a moment to reach the sidebar before auto-hide can tuck it away.
    func expand(byPointer: Bool) {
        guard isOpen else { return }
        lastInside = byPointer ? Date() : Date().addingTimeInterval(2)
        if !isExpanded {
            isExpanded = true
            let target = expandedFrame()
            if !panel.isVisible {
                panel.setFrame(target.offsetBy(dx: slideOffset, dy: 0), display: false)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animation
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
            tab.hide()
        }
        scroll.documentView?.scroll(.zero)
        if autoHide { startHoverTimer() }
    }

    /// Tucks the sidebar into its tab (auto-hide).
    func collapse() {
        guard isOpen, isExpanded else { return }
        isExpanded = false
        stopHoverTimer()
        let away = panel.frame.offsetBy(dx: slideOffset, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animation
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(away, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExpanded else { return }
                self.panel.orderOut(nil)
            }
        })
        showTab()
    }

    private func showTab() {
        tab.count = history.entries.count
        tab.edge = edge
        tab.show(at: tabFrame())
    }

    private func startObserving() {
        observer = NotificationCenter.default.addObserver(forName: CaptureHistory.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return event }
            let window = event.window
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, window === self.panel else { return false }
                self.close()
                return true
            }
            return consumed ? nil : event
        }
        var last = (size, autoHide)
        settingsWatch = store.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = (s.historyStripSize, s.historyAutoHide)
                    defer { last = now }
                    if now.0 != last.0 { self.rebuild() }
                    if now.1 != last.1 { self.autoHideChanged() }
                }
            }
    }

    private func autoHideChanged() {
        updatePinButton()
        guard isOpen else { return }
        if autoHide {
            // Only a docked strip can tuck away: a floating one docks to the nearer edge first.
            if store.settings.historyStripFloatingTopLeft != nil { dockAtNearerEdge() }
            // Stays out while the pointer is over it; tucks away once it leaves.
            lastInside = Date()
            if isExpanded { startHoverTimer() }
        } else {
            stopHoverTimer()
            if !isExpanded { expand(byPointer: true) }
        }
    }

    // MARK: Auto-hide

    private func startHoverTimer() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
    }

    private func stopHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func checkPointer() {
        guard autoHide, isExpanded else { return stopHoverTimer() }
        let inside = panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        if inside || dragging || menuOpen || panel.attachedSheet != nil {
            lastInside = max(lastInside, Date())
        } else if Date().timeIntervalSince(lastInside) > Self.hideDelay {
            collapse()
        }
    }

    // MARK: Actions

    @objc private func closeClicked() {
        close()
    }

    @objc private func pinClicked() {
        store.update { $0.historyAutoHide.toggle() }
    }

    @objc private func sizeChanged(_ sender: NSSegmentedControl) {
        let all = HistoryStripSize.allCases
        guard all.indices.contains(sender.selectedSegment) else { return }
        store.update { $0.historyStripSize = all[sender.selectedSegment] }
    }

    /// Clear All asks once: the first click turns the button into "Confirm" for a few seconds.
    @objc private func clearClicked() {
        if Date() < clearArmedUntil {
            history.clear()
            return
        }
        clearArmedUntil = Date().addingTimeInterval(3)
        clearButton.attributedTitle = NSAttributedString(string: "Confirm", attributes: [
            .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        ])
        clearButton.toolTip = "Click again to remove every screenshot"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) { [weak self] in
            guard let self, Date() >= self.clearArmedUntil else { return }
            self.resetClearButton()
        }
    }

    private func resetClearButton() {
        clearArmedUntil = .distantPast
        clearButton.title = "Clear All"
        clearButton.toolTip = "Remove every screenshot from the history"
    }

    /// Brings the screenshot back up in the capture window, as right after the capture.
    private func open(_ entry: HistoryEntry, _ item: HistoryItemView) {
        guard let capture = history.capture(for: entry) else {
            item.flash("File is missing")
            return
        }
        Task { @MainActor [weak self, weak item] in
            if let handler = HistoryStrip.openHandler {
                await handler(capture)
            } else if let choice = await DestinationPicker.pick(for: capture, from: DestinationRegistry.shared.available),
                      let self, let item {
                self.run(choice.destination, entry, item)
            }
        }
    }

    func clickItem(at index: Int, modifiers: NSEvent.ModifierFlags) {
        let items = list.arrangedSubviews.compactMap { $0 as? HistoryItemView }
        guard items.indices.contains(index) else { return }
        items[index].onClick?(modifiers)
    }

    private var itemViews: [HistoryItemView] { list.arrangedSubviews.compactMap { $0 as? HistoryItemView } }

    /// Only the thumbnail under the pointer shows its hover state.
    private func refreshHover() {
        guard panel.isVisible else { return }
        let location = panel.mouseLocationOutsideOfEventStream
        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        for item in itemViews {
            let p = item.convert(location, from: nil)
            item.isHovering = item.bounds.contains(p) && visible.contains(location)
        }
    }

    private func toggleSelection(_ entry: HistoryEntry, _ item: HistoryItemView) {
        if selected.remove(entry.id) == nil { selected.insert(entry.id) }
        item.isSelected = selected.contains(entry.id)
    }

    private func clearSelection() {
        selected.removeAll()
        itemViews.forEach { $0.isSelected = false }
    }

    /// The files a drag from `entry` carries: every selected screenshot when `entry` is one of
    /// them, else just `entry`. Newest first, as listed.
    private func dragFiles(from entry: HistoryEntry) -> [ImageFileDrag.File] {
        let entries = selected.contains(entry.id) ? history.entries.filter { selected.contains($0.id) } : [entry]
        return entries.map {
            ImageFileDrag.File(url: history.fileURL(for: $0), preview: history.thumbnail(for: $0))
        }
    }

    private func copy(_ entry: HistoryEntry, _ item: HistoryItemView) {
        guard let capture = history.capture(for: entry) else {
            item.flash("File is missing")
            return
        }
        do {
            try ClipboardDestination.copy(capture, to: .general)
            item.flash("Copied")
        } catch {
            item.flash("Copy failed")
        }
    }

    private func menu(for entry: HistoryEntry, _ item: HistoryItemView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let copy = MenuAction(title: "Copy", symbol: "doc.on.clipboard") { [weak self, weak item] in
            guard let item else { return }
            self?.copy(entry, item)
        }
        menu.addItem(copy.item)
        let skip: Set<String> = [DestinationID.clipboard]
        for destination in DestinationRegistry.shared.available where !skip.contains(destination.id) {
            let action = MenuAction(title: destination.displayName, symbol: destination.symbolName) { [weak self, weak item] in
                guard let self, let item else { return }
                self.run(destination, entry, item)
            }
            menu.addItem(action.item)
        }
        menu.addItem(.separator())
        let url = history.fileURL(for: entry)
        menu.addItem(MenuAction(title: "Show in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }.item)
        menu.addItem(MenuAction(title: "Remove from History", symbol: "trash") { [weak self] in
            self?.history.remove(entry.id)
        }.item)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        lastInside = Date()
    }

    private func run(_ destination: CaptureDestination, _ entry: HistoryEntry, _ item: HistoryItemView) {
        guard let capture = history.capture(for: entry) else {
            item.flash("File is missing")
            return
        }
        if destination.id == DestinationID.ocr { item.flash("Reading text...") }
        Task { @MainActor [weak item] in
            let result: ExportResult?
            if let handler = HistoryStrip.exportHandler {
                result = await handler(capture, destination)
            } else {
                result = try? await destination.export(capture, context: ExportContext())
            }
            if case .exported(_, let message) = result, !destination.isEditor {
                item?.flash(message)
            }
        }
    }
}

/// The tucked-away sidebar: a slim translucent tab at the screen edge with the app mark and an
/// arrow. Hovering or clicking it slides the sidebar out; dragging it moves it along the edge or
/// across to the other edge.
@MainActor
final class EdgeTabPanel: NSPanel {
    static let size = CGSize(width: 22, height: 86)
    var onReveal: (() -> Void)?
    var onMoveStarted: (() -> Void)?
    var onMoved: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var count = 0 { didSet { tabView.count = count } }
    var edge: HistoryStripEdge = .left { didSet { tabView.edge = edge } }
    private let tabView = EdgeTabView()

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        title = "Screenshot Filmstrip Tab"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        tabView.onReveal = { [weak self] in self?.onReveal?() }
        tabView.onMoveStarted = { [weak self] in self?.onMoveStarted?() }
        tabView.onMoved = { [weak self] in self?.onMoved?() }
        tabView.menuProvider = { [weak self] in self?.menuProvider?() }
        contentView = tabView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(at frame: CGRect) {
        setFrame(frame, display: true)
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HistoryStripController.animation
            animator().alphaValue = 1
        }
    }

    func hide() {
        orderOut(nil)
    }
}

@MainActor
final class EdgeTabView: NSVisualEffectView {
    var onReveal: (() -> Void)?
    var onMoveStarted: (() -> Void)?
    var onMoved: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var count = 0 { didSet { countLabel.stringValue = count > 0 ? "\(count)" : "" } }
    var edge: HistoryStripEdge = .left { didSet { updateEdge() } }
    private let countLabel = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    private var hoverWork: DispatchWorkItem?
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var moved = false

    init() {
        super.init(frame: CGRect(origin: .zero, size: EdgeTabPanel.size))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        alphaValue = 0.6

        let mark = NSImageView(image: ScreenshotProMark.image(height: 12))
        mark.contentTintColor = .secondaryLabelColor
        arrow.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        arrow.contentTintColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        let stack = NSStackView(views: [mark, arrow, countLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Screenshot Filmstrip: point or click to open, drag to move"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show Screenshot Filmstrip")
        updateEdge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rounds the side facing the screen and points the arrow into it.
    private func updateEdge() {
        layer?.maskedCorners = edge == .left
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let symbol = edge == .left ? "chevron.compact.right" : "chevron.compact.left"
        arrow.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = 1
        guard drag == nil else { return }
        // A brief pause, so sweeping past the tab does not open the sidebar.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag == nil else { return }
            self.onReveal?()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        hoverWork = nil
        if drag == nil { animator().alphaValue = 0.6 }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        hoverWork?.cancel()
        drag = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - drag.mouse.x, dy = mouse.y - drag.mouse.y
        if !moved {
            guard hypot(dx, dy) > 3 else { return }
            moved = true
            NSCursor.closedHand.push()
            onMoveStarted?()
        }
        window.setFrameOrigin(CGPoint(x: drag.origin.x + dx, y: drag.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard drag != nil else { return }
        if moved {
            NSCursor.pop()
            onMoved?()
        } else {
            onReveal?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        hoverWork?.cancel()
        return menuProvider?()
    }
}

/// The grab bar at the top of the sidebar: a small pill. Dragging it moves the sidebar anywhere;
/// the controller decides on release whether it snaps to an edge or floats.
@MainActor
final class GripView: NSView {
    static let height: CGFloat = 12
    var onDragStarted: (() -> Void)?
    /// After each move while dragging.
    var onDragMoved: (() -> Void)?
    var onDropped: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let pill = CALayer()
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var moved = false
    private var hovering = false { didSet { updatePill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(pill)
        pill.cornerRadius = 2.5
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        toolTip = "Drag to move the filmstrip: drop it near a screen edge to dock and auto-hide it, anywhere else to pin it there"
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Move Screenshot Filmstrip")
        updatePill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w: CGFloat = hovering ? 44 : 36
        pill.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - 5) / 2, width: w, height: 5)
        CATransaction.commit()
    }

    private func updatePill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(hovering || drag != nil ? 0.9 : 0.45).cgColor
        }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        drag = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        moved = false
        updatePill()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - drag.mouse.x, dy = mouse.y - drag.mouse.y
        if !moved {
            guard hypot(dx, dy) > 2 else { return }
            moved = true
            NSCursor.closedHand.push()
            onDragStarted?()
        }
        window.setFrameOrigin(CGPoint(x: drag.origin.x + dx, y: drag.origin.y + dy))
        onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            updatePill()
        }
        guard drag != nil, moved else { return }
        NSCursor.pop()
        onDropped?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

/// A faint green bar along the screen edge while a dragged strip is close enough to snap to it.
@MainActor
final class SnapGlowPanel: NSPanel {
    static let width: CGFloat = 4
    private var shown = false

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = HistoryStripController.accent.withAlphaComponent(0.6).cgColor
        bar.layer?.cornerRadius = Self.width / 2
        contentView = bar
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the bar on `edge` of `visible`, level with `frame` (the dragged strip).
    func show(along edge: HistoryStripEdge, of visible: CGRect, level frame: CGRect) {
        let bottom = max(frame.minY, visible.minY), top = min(frame.maxY, visible.maxY)
        let x = edge == .left ? visible.minX : visible.maxX - Self.width
        setFrame(CGRect(x: x, y: bottom, width: Self.width, height: max(top - bottom, 40)), display: true)
        guard !shown else { return }
        shown = true
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HistoryStripController.animation
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = HistoryStripController.animation
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.orderOut(nil)
            }
        })
    }
}

/// A menu item that runs a closure.
@MainActor
final class MenuAction: NSObject {
    let item: NSMenuItem
    private let handler: () -> Void

    init(title: String, symbol: String?, handler: @escaping () -> Void) {
        self.handler = handler
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        super.init()
        item.target = self
        item.action = #selector(fire)
        item.representedObject = self  // the item keeps its action alive
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func fire() {
        handler()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One thumbnail in the strip with its caption, hover highlight, remove button and feedback.
@MainActor
final class HistoryItemView: NSView, NSDraggingSource {
    /// A click that was not a drag, with its modifier keys.
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDelete: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// True when a drag out starts, false when it ends.
    var onDragging: ((Bool) -> Void)?
    /// The pointer came in: the strip clears any hover left behind by scrolling.
    var onHover: (() -> Void)?
    /// The files a drag carries (this one, or the whole selection).
    var dragFiles: (() -> [ImageFileDrag.File])?
    var isHovering = false { didSet { if isHovering != oldValue { updateHover() } } }
    /// Picked with Shift-click: a green frame and a check mark.
    var isSelected = false { didSet { if isSelected != oldValue { updateHover() } } }

    private let entry: HistoryEntry
    private let fileURL: URL
    private let thumbnail: NSImage?
    private let box = NSView()
    private let imageLayer = CALayer()
    private let deleteButton: NSButton
    private let flashLabel = NSTextField(labelWithString: "")
    private let checkMark = NSImageView()
    private var downPoint: CGPoint?
    private var dragged = false
    private var flashGeneration = 0

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    init(entry: HistoryEntry, thumbnail: NSImage?, fileURL: URL, size: HistoryStripSize) {
        let width = size.itemWidth
        let maxThumbHeight = size.maxThumbHeight
        let small = size == .small
        self.entry = entry
        self.fileURL = fileURL
        self.thumbnail = thumbnail
        let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from history")!
        deleteButton = NSButton(image: symbol, target: nil, action: nil)
        super.init(frame: .zero)

        let aspect = entry.pixelWidth > 0 ? CGFloat(entry.pixelHeight) / CGFloat(entry.pixelWidth) : 0.6
        let thumbHeight = min(maxThumbHeight, max(small ? 32 : 48, (width * aspect).rounded()))

        box.wantsLayer = true
        box.layer?.cornerRadius = small ? 6 : 8
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        imageLayer.contents = thumbnail
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        box.layer?.addSublayer(imageLayer)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isBordered = false
        deleteButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: small ? 14 : 17, weight: .regular)
            .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.7)]))
        deleteButton.toolTip = "Remove from history"
        deleteButton.isHidden = true
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)

        checkMark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")
        checkMark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: small ? 14 : 17, weight: .semibold)
            .applying(.init(paletteColors: [.white, HistoryStripController.accent]))
        checkMark.isHidden = true
        checkMark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkMark)

        flashLabel.font = .systemFont(ofSize: small ? 10.5 : 12, weight: .semibold)
        flashLabel.textColor = .white
        flashLabel.alignment = .center
        flashLabel.wantsLayer = true
        flashLabel.drawsBackground = true
        flashLabel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        flashLabel.layer?.cornerRadius = 6
        flashLabel.layer?.masksToBounds = true
        flashLabel.alphaValue = 0
        flashLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flashLabel)

        let date = Self.dateFormatter.string(from: entry.date)
        // Small thumbnails get a short caption: the time today, else the date and time.
        let short = Calendar.current.isDateInToday(entry.date) ? Self.timeFormatter.string(from: entry.date) : date
        let caption = NSTextField(labelWithString: small ? short : "\(date)   \(entry.pixelWidth) x \(entry.pixelHeight)")
        caption.font = .monospacedDigitSystemFont(ofSize: small ? 9.5 : 10.5, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.heightAnchor.constraint(equalToConstant: thumbHeight),
            deleteButton.topAnchor.constraint(equalTo: box.topAnchor, constant: small ? 3 : 5),
            deleteButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: small ? -3 : -5),
            checkMark.topAnchor.constraint(equalTo: box.topAnchor, constant: small ? 3 : 5),
            checkMark.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: small ? 3 : 5),
            flashLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            flashLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            caption.topAnchor.constraint(equalTo: box.bottomAnchor, constant: small ? 2 : 4),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        var tip = entry.title ?? entry.mode.displayName
        if let app = entry.appName, app != tip { tip += " (\(app))" }
        toolTip = "\(tip)\n\(date), \(entry.pixelWidth) x \(entry.pixelHeight) px\nClick for options, \u{2318}-click to copy, Shift-click to pick several"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Screenshot \(date), \(tip)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = box.bounds.insetBy(dx: 1, dy: 1)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        onHover?()
    }

    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func updateHover() {
        deleteButton.isHidden = !isHovering
        checkMark.isHidden = !isSelected
        box.layer?.borderWidth = isSelected ? 3 : isHovering ? 2 : 1
        box.layer?.borderColor = isHovering || isSelected
            ? HistoryStripController.accent.cgColor
            : NSColor.separatorColor.cgColor
    }

    override func resetCursorRects() {
        addCursorRect(box.frame, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragged = true
        let files = dragFiles?() ?? [ImageFileDrag.File(url: fileURL, preview: thumbnail)]
        let size = ImageFileDrag.fitted(thumbnail?.size ?? box.frame.size, maxSide: 160)
        let frame = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        onDragging?(true)
        ImageFileDrag.begin(files, frame: frame, from: self, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard downPoint != nil, !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(event.modifierFlags)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    @objc private func deleteClicked() {
        onDelete?()
    }

    /// Shows `text` over the thumbnail for a moment.
    func flash(_ text: String) {
        flashLabel.stringValue = "  \(text)  "
        flashGeneration += 1
        let generation = flashGeneration
        flashLabel.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.flashLabel.animator().alphaValue = 0
            }
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        MainActor.assumeIsolated { onDragging?(false) }
    }
}
