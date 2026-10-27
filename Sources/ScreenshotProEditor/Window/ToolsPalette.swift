import AppKit
import ScreenshotProCore

/// The row of drawing tools in the editor's toolbar, in small groups.
@MainActor
final class ToolsPalette: NSView {
    var onSelect: ((EditorTool) -> Void)?
    private var buttons: [EditorTool: ToolbarIconButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (i, tool) in EditorTool.allCases.enumerated() {
            let b = ToolbarIconButton(symbol: tool.symbolName, label: tool.displayName,
                                      target: self, action: #selector(clicked(_:)))
            b.tag = i
            b.toolTip = "\(tool.displayName) (\(tool.key.uppercased()))"
            buttons[tool] = b
            stack.addArrangedSubview(b)
            if tool.endsGroup { stack.setCustomSpacing(10, after: b) }
        }
        select(.select)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `tool` as the active one.
    func select(_ tool: EditorTool) {
        for (t, b) in buttons { b.isActive = t == tool }
    }

    /// The tools as menu items, for the toolbar's overflow menu in a narrow window.
    func menuRepresentation() -> NSMenuItem {
        let item = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Tools")
        for (i, tool) in EditorTool.allCases.enumerated() {
            let m = NSMenuItem(title: tool.displayName, action: #selector(clicked(_:)), keyEquivalent: "")
            m.target = self
            m.tag = i
            m.image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil)
            menu.addItem(m)
        }
        item.submenu = menu
        return item
    }

    @objc private func clicked(_ sender: Any) {
        guard let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag else { return }
        let tool = EditorTool.allCases[tag]
        select(tool)
        onSelect?(tool)
    }
}

/// A flat toolbar icon: no bezel, a soft rounded wash on hover and a green one while active.
@MainActor
final class ToolbarIconButton: NSButton {
    static let size = NSSize(width: 30, height: 26)

    var isActive = false { didSet { if isActive != oldValue { updateLook() } } }
    private var hovering = false { didSet { if hovering != oldValue { updateLook() } } }
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        image = (NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: label)!)
            .withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        self.target = target
        self.action = action
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 6
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        let wash: NSColor? = isActive ? NSColor.systemGreen.withAlphaComponent(0.28)
            : hovering ? NSColor.labelColor.withAlphaComponent(0.08) : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = wash?.cgColor
        }
        contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        setAccessibilityValue(isActive ? "selected" : nil)
    }
}

/// The quick colors as round dots in the toolbar. A click sets the line color (Option-click:
/// the fill); the dot matching the current color is ringed.
@MainActor
final class QuickColorBar: NSView {
    var onPick: ((RGBAColor, _ fill: Bool) -> Void)?
    private let stack = NSStackView()
    private var colors: [RGBAColor] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setColors(_ colors: [RGBAColor]) {
        self.colors = colors
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, c) in colors.enumerated() {
            let b = NSButton(image: c.swatch(size: 13), target: self, action: #selector(picked(_:)))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.tag = i
            b.toolTip = "Line color (Option-click: fill color)"
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(b)
        }
    }

    /// Rings the dot of `color`, if it is one of the quick colors; nil disables the dots.
    func show(current color: RGBAColor?, enabled: Bool) {
        for case let b as NSButton in stack.arrangedSubviews {
            let match = enabled && colors.indices.contains(b.tag) && colors[b.tag] == color
            b.layer?.backgroundColor = match ? NSColor.systemGreen.withAlphaComponent(0.28).cgColor : nil
            b.isEnabled = enabled
        }
    }

    func menuRepresentation() -> NSMenuItem {
        let item = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Colors")
        for (i, c) in colors.enumerated() {
            let m = NSMenuItem(title: "Color \(i + 1)", action: #selector(picked(_:)), keyEquivalent: "")
            m.target = self
            m.tag = i
            m.image = c.swatch(size: 13)
            menu.addItem(m)
        }
        item.submenu = menu
        return item
    }

    @objc private func picked(_ sender: Any) {
        guard let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag,
              colors.indices.contains(tag) else { return }
        onPick?(colors[tag], NSEvent.modifierFlags.contains(.option))
    }
}

/// The status bar under the canvas: image size, a message and the zoom popup.
@MainActor
final class StatusBar: NSView {
    let sizeLabel = NSTextField(labelWithString: "")
    let messageLabel = NSTextField(labelWithString: "")
    let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onZoom: ((CGFloat?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in [sizeLabel, messageLabel] {
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
        }
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        zoomPopup.controlSize = .small
        zoomPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        zoomPopup.isBordered = false
        for z in ZoomLevels.levels {
            zoomPopup.addItem(withTitle: ZoomLevels.label(for: z))
        }
        zoomPopup.menu?.addItem(.separator())
        zoomPopup.addItem(withTitle: "Zoom to Fit")
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChosen)
        let stack = NSStackView(views: [sizeLabel, messageLabel, zoomPopup])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showZoom(_ zoom: CGFloat) {
        if let i = ZoomLevels.levels.firstIndex(where: { abs($0 - zoom) < 0.001 }) {
            zoomPopup.selectItem(at: i)
        }
    }

    @objc private func zoomChosen() {
        let i = zoomPopup.indexOfSelectedItem
        onZoom?(i < ZoomLevels.levels.count ? ZoomLevels.levels[i] : nil)
    }
}

/// Keeps the canvas centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    /// Frames the image with a thin light line, one point wide, just outside its edge.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let doc = documentView, !doc.frame.isEmpty else { return }
        let line: CGFloat = 1
        let frame = doc.frame.insetBy(dx: -line / 2, dy: -line / 2)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.18)).setStroke()
        let path = NSBezierPath(rect: frame)
        path.lineWidth = line
        path.stroke()
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
