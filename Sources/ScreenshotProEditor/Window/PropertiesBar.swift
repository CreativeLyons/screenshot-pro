import AppKit
import ScreenshotProCore

/// The context-sensitive properties bar above the canvas. It shows only the fields of the
/// selected elements (or of the current tool's next element) and reports edits in points.
/// Controls that do not fit the window's width wrap into further rows (at most `maxRows`), so a
/// narrow window never clips them and the bar never makes the window wider.
@MainActor
final class PropertiesBar: NSView {
    nonisolated static let rowHeight: CGFloat = 34
    nonisolated static let maxRows = 3
    nonisolated private static let rowSpacing: CGFloat = 12
    nonisolated private static let rowInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

    struct Content {
        var fields: [ElementField] = []
        /// Values to show, in points.
        var style = ElementStyle()
        var counterStart = 1
        var showsCrop = false
        var title = ""
    }

    var onStyleChange: ((ElementField, @escaping (inout ElementStyle) -> Void) -> Void)?
    var onCounterStart: ((Int) -> Void)?
    var onResetCounter: (() -> Void)?
    var onCropApply: (() -> Void)?
    var onCropCancel: (() -> Void)?
    var onAutoCrop: (() -> Void)?

    /// Rows of controls, top to bottom, inside a vertical stack.
    private let rowStack = NSStackView()
    private var rows: [NSStackView] = []
    private var heightConstraint: NSLayoutConstraint!
    /// Every control group in display order, and which of them the current content shows.
    private var items: [NSView] = []
    private var shown: Set<ObjectIdentifier> = []
    private var laidOutWidth: CGFloat = -1
    private let titleLabel = NSTextField(labelWithString: "")
    private var groups: [ElementField: [NSView]] = [:]
    private let cropGroup = NSStackView()

    private let thickness = NumberControl(label: "Line", min: 0, max: 100, tooltip: "Line thickness")
    private let lineColor = ColorControl(label: "Color")
    private let fillColor = ColorControl(label: "Fill")
    private let shadowBox = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    private let sketchyBox = NSButton(checkboxWithTitle: "Hand-drawn", target: nil, action: nil)
    private let cycleBox = NSButton(checkboxWithTitle: "Rainbow numbers", target: nil, action: nil)
    private let fontGroup = NSStackView()
    private let fontStyleGroup = NSStackView()
    private var fontPopup: NSPopUpButton!
    private let fontSize = NumberControl(label: "Size", min: 7, max: 500)
    private let bold = NSButton()
    private let italic = NSButton()
    private var alignH: NSSegmentedControl!
    private var alignV: NSSegmentedControl!
    private var arrowPopup: NSPopUpButton!
    private var highlightPopup: NSPopUpButton!
    private let brightness = NumberControl(label: "Brightness", min: 0, max: 200, step: 5, suffix: "%")
    private let blurRadius = NumberControl(label: "Blur", min: 0, max: 100, tooltip: "Blur radius")
    private let magnification = NumberControl(label: "Zoom", min: 2, max: 8, step: 1, suffix: "x",
                                              tooltip: "Magnification factor")
    private var obfuscatePopup: NSPopUpButton!
    private let pixelSize = NumberControl(label: "Pixel size", min: 2, max: 100)
    private let counterStart = NumberControl(label: "Start", min: 0, max: 100, tooltip: "Counter start value")
    private let counterGroup = NSStackView()
    private var current = Content()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        rowStack.orientation = .vertical
        // Rows span the full width; their groups sit at the leading edge at their own size.
        rowStack.alignment = .width
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            heightConstraint,
        ])
        titleLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.textColor = .secondaryLabelColor

        thickness.onChange = { [weak self] v in self?.onStyleChange?(.lineThickness) { $0.lineThickness = v } }
        lineColor.onChange = { [weak self] c in self?.onStyleChange?(.lineColor) { $0.lineColor = c } }
        fillColor.onChange = { [weak self] c in self?.onStyleChange?(.fillColor) { $0.fillColor = c } }
        for (box, action, tip) in [
            (shadowBox, #selector(shadowChanged), "Drop shadow"),
            (sketchyBox, #selector(sketchyChanged), "Wobbly, sketched lines like Excalidraw"),
            (cycleBox, #selector(cycleChanged), "Each number gets the next color: 1 red, 2 orange, 3 yellow..."),
        ] {
            box.target = self
            box.action = action
            box.controlSize = .small
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            box.toolTip = tip
        }

        fontPopup = makePopup(NSFontManager.shared.availableFontFamilies, target: self, action: #selector(fontChanged))
        // A fixed width: long family names truncate instead of resizing the row.
        fontPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        fontSize.onChange = { [weak self] v in self?.onStyleChange?(.font) { $0.fontSize = v } }
        for (b, symbol, tip) in [(bold, "bold", "Bold"), (italic, "italic", "Italic")] {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.controlSize = .small
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.toolTip = tip
            b.target = self
            b.action = #selector(traitsChanged)
        }
        alignH = NSSegmentedControl(images: ["text.alignleft", "text.aligncenter", "text.alignright"].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }, trackingMode: .selectOne, target: self, action: #selector(alignChanged))
        alignV = NSSegmentedControl(images: ["arrow.up.to.line", "arrow.up.and.down", "arrow.down.to.line"].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }, trackingMode: .selectOne, target: self, action: #selector(alignChanged))
        alignH.controlSize = .small
        alignV.controlSize = .small
        alignH.toolTip = "Horizontal alignment"
        alignV.toolTip = "Vertical alignment"
        // Two groups, so the font row can wrap between the face and the style controls.
        for (group, views) in [(fontGroup, [fontPopup!, fontSize] as [NSView]),
                               (fontStyleGroup, [bold, italic, alignH!, alignV!] as [NSView])] {
            group.orientation = .horizontal
            group.spacing = 4
            views.forEach(group.addArrangedSubview)
        }

        arrowPopup = makePopup(ArrowHeads.allCases.map { "Heads: " + $0.displayName }, target: self,
                               action: #selector(arrowChanged))
        highlightPopup = makePopup(HighlightMode.allCases.map(\.displayName), target: self,
                                   action: #selector(highlightChanged))
        obfuscatePopup = makePopup(ObfuscateMode.allCases.map(\.displayName), target: self,
                                   action: #selector(obfuscateChanged))
        brightness.onChange = { [weak self] v in self?.onStyleChange?(.brightness) { $0.brightness = v / 100 } }
        blurRadius.onChange = { [weak self] v in self?.onStyleChange?(.blurRadius) { $0.blurRadius = v } }
        magnification.onChange = { [weak self] v in self?.onStyleChange?(.magnification) { $0.magnification = v } }
        pixelSize.onChange = { [weak self] v in self?.onStyleChange?(.pixelSize) { $0.pixelSize = v } }

        counterStart.onChange = { [weak self] v in self?.onCounterStart?(Int(v)) }
        let reset = NSButton(title: "Reset Counter", target: self, action: #selector(resetCounter))
        reset.controlSize = .small
        reset.bezelStyle = .rounded
        counterGroup.orientation = .horizontal
        counterGroup.spacing = 6
        counterGroup.addArrangedSubview(counterStart)
        counterGroup.addArrangedSubview(reset)

        cropGroup.orientation = .horizontal
        cropGroup.spacing = 6
        for (title, symbol, action) in [("Apply", "checkmark", #selector(cropApply)),
                                        ("Cancel", "xmark", #selector(cropCancel)),
                                        ("Auto Crop", "crop", #selector(autoCrop))] {
            let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                             target: self, action: action)
            b.controlSize = .small
            b.bezelStyle = .rounded
            cropGroup.addArrangedSubview(b)
        }

        groups = [
            .lineThickness: [thickness], .lineColor: [lineColor], .fillColor: [fillColor], .shadow: [shadowBox],
            .sketchy: [sketchyBox], .cycleColors: [cycleBox],
            .font: [fontGroup, fontStyleGroup], .arrowHeads: [arrowPopup], .highlightMode: [highlightPopup],
            .brightness: [brightness], .blurRadius: [blurRadius], .magnification: [magnification],
            .obfuscateMode: [obfuscatePopup], .pixelSize: [pixelSize], .counterStart: [counterGroup],
        ]
        items = [titleLabel]
        for f in ElementField.allCases { items += groups[f] ?? [] }
        items.append(cropGroup)
        // Groups (and the stacks inside them) keep their natural width instead of absorbing a
        // row's free space; inner stacks hug tighter, so no two edges compete at one priority.
        func hug(_ view: NSView, _ priority: NSLayoutConstraint.Priority) {
            guard let stack = view as? NSStackView else { return }
            stack.setHuggingPriority(priority, for: .horizontal)
            stack.arrangedSubviews.forEach { hug($0, priority + 1) }
        }
        items.forEach { hug($0, .defaultHigh) }
    }

    /// Shows `content`. Setting values does not send change callbacks.
    func update(_ content: Content) {
        current = content
        titleLabel.stringValue = content.title
        let fields = Set(content.fields)
        var visible: [NSView] = content.title.isEmpty ? [] : [titleLabel]
        for (f, views) in groups where fields.contains(f) { visible += views }
        if content.showsCrop { visible.append(cropGroup) }
        shown = Set(visible.map(ObjectIdentifier.init))
        let s = content.style
        thickness.value = s.lineThickness
        lineColor.color = s.lineColor
        fillColor.color = s.fillColor
        fillColor.label.stringValue = fields.contains(.highlightMode) ? "Highlight" : "Fill"
        shadowBox.state = s.shadow ? .on : .off
        sketchyBox.state = s.sketchy ? .on : .off
        cycleBox.state = s.cycleColors ? .on : .off
        if fontPopup.itemTitles.contains(s.fontName) {
            fontPopup.selectItem(withTitle: s.fontName)
        } else if let family = NSFont(name: s.fontName, size: 12)?.familyName {
            fontPopup.selectItem(withTitle: family)
        }
        fontSize.value = s.fontSize
        bold.state = s.bold ? .on : .off
        italic.state = s.italic ? .on : .off
        alignH.selectedSegment = HorizontalTextAlignment.allCases.firstIndex(of: s.horizontalAlignment) ?? 1
        alignV.selectedSegment = VerticalTextAlignment.allCases.firstIndex(of: s.verticalAlignment) ?? 1
        arrowPopup.selectItem(at: ArrowHeads.allCases.firstIndex(of: s.arrowHeads) ?? 2)
        highlightPopup.selectItem(at: HighlightMode.allCases.firstIndex(of: s.highlightMode) ?? 0)
        obfuscatePopup.selectItem(at: ObfuscateMode.allCases.firstIndex(of: s.obfuscateMode) ?? 0)
        brightness.value = s.brightness * 100
        blurRadius.value = s.blurRadius
        magnification.value = s.magnification
        pixelSize.value = s.pixelSize
        counterStart.value = Double(content.counterStart)
        reflow(force: true)
    }

    // MARK: Rows

    override func layout() {
        super.layout()
        if abs(bounds.width - laidOutWidth) > 0.5 { reflow() }
    }

    /// The shown groups split into rows that fit `width` (pure, for tests): each row takes
    /// groups in order while they fit; a group wider than a whole row gets a row of its own;
    /// the last allowed row takes the rest (and clips).
    nonisolated static func rows(widths: [CGFloat], available width: CGFloat, maxRows: Int = maxRows) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var used = rowInsets.left + rowInsets.right
        for (i, w) in widths.enumerated() {
            let extra = (rows[rows.count - 1].isEmpty ? 0 : rowSpacing) + w
            if !rows[rows.count - 1].isEmpty, used + extra > width, rows.count < maxRows {
                rows.append([i])
                used = rowInsets.left + rowInsets.right + w
            } else {
                rows[rows.count - 1].append(i)
                used += extra
            }
        }
        return rows
    }

    /// Distributes the shown groups over rows for the current width and sets the bar's height.
    private func reflow(force: Bool = false) {
        let width = bounds.width
        guard width > 0 else { return }
        if !force, abs(width - laidOutWidth) <= 0.5 { return }
        laidOutWidth = width
        let visible = items.filter { shown.contains(ObjectIdentifier($0)) }
        let plan = Self.rows(widths: visible.map { ceil($0.fittingSize.width) }, available: width)
        let wanted = plan.map { $0.map { visible[$0] } }
        while rows.count < wanted.count { rows.append(makeRow()) }
        for v in items where !shown.contains(ObjectIdentifier(v)) && v.superview != nil {
            (v.superview as? NSStackView)?.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, row) in rows.enumerated() {
            let views = i < wanted.count ? wanted[i] : []
            if row.arrangedSubviews != views {
                for v in row.arrangedSubviews {
                    row.removeArrangedSubview(v)
                    v.removeFromSuperview()
                }
                for v in views {
                    (v.superview as? NSStackView)?.removeArrangedSubview(v)
                    row.addArrangedSubview(v)
                }
            }
            row.isHidden = views.isEmpty && i > 0
        }
        heightConstraint.constant = Self.rowHeight * CGFloat(max(1, wanted.count))
    }

    private func makeRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Self.rowSpacing
        row.alignment = .centerY
        row.edgeInsets = Self.rowInsets
        // The last row clips what still does not fit instead of making the window wider.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        rowStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        return row
    }

    // MARK: Actions

    @objc private func shadowChanged() {
        let on = shadowBox.state == .on
        onStyleChange?(.shadow) { $0.shadow = on }
    }

    @objc private func sketchyChanged() {
        let on = sketchyBox.state == .on
        onStyleChange?(.sketchy) { $0.sketchy = on }
    }

    @objc private func cycleChanged() {
        let on = cycleBox.state == .on
        onStyleChange?(.cycleColors) { $0.cycleColors = on }
    }

    @objc private func fontChanged() {
        guard let name = fontPopup.titleOfSelectedItem else { return }
        onStyleChange?(.font) { $0.fontName = name }
    }

    @objc private func traitsChanged() {
        let b = bold.state == .on, i = italic.state == .on
        onStyleChange?(.font) {
            $0.bold = b
            $0.italic = i
        }
    }

    @objc private func alignChanged() {
        let h = HorizontalTextAlignment.allCases[max(0, alignH.selectedSegment)]
        let v = VerticalTextAlignment.allCases[max(0, alignV.selectedSegment)]
        onStyleChange?(.font) {
            $0.horizontalAlignment = h
            $0.verticalAlignment = v
        }
    }

    @objc private func arrowChanged() {
        let heads = ArrowHeads.allCases[max(0, arrowPopup.indexOfSelectedItem)]
        onStyleChange?(.arrowHeads) { $0.arrowHeads = heads }
    }

    @objc private func highlightChanged() {
        let mode = HighlightMode.allCases[max(0, highlightPopup.indexOfSelectedItem)]
        onStyleChange?(.highlightMode) { $0.highlightMode = mode }
    }

    @objc private func obfuscateChanged() {
        let mode = ObfuscateMode.allCases[max(0, obfuscatePopup.indexOfSelectedItem)]
        onStyleChange?(.obfuscateMode) { $0.obfuscateMode = mode }
    }

    @objc private func resetCounter() { onResetCounter?() }
    @objc private func cropApply() { onCropApply?() }
    @objc private func cropCancel() { onCropCancel?() }
    @objc private func autoCrop() { onAutoCrop?() }
}
