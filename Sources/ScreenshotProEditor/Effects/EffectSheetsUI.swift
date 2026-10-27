import AppKit
import ScreenshotProCore

/// Runs one parameter sheet: builds the window around a content view, adds OK/Cancel
/// (Return/Esc) and resolves when the sheet ends.
@MainActor
final class EffectSheetRunner: NSObject {
    let sheet: NSWindow
    private weak var parent: NSWindow?
    /// Called before OK closes the sheet; returning false keeps it open.
    var validate: () -> Bool = { true }
    /// Helper objects (targets of controls) kept alive while the sheet is up.
    var retained: [AnyObject] = []

    init(title: String, content: NSView) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                         styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        sheet.title = title
        sheet.isReleasedWhenClosed = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed(_:)))
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [content, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        sheet.contentView = root
        sheet.setContentSize(root.fittingSize)
    }

    @objc private func okPressed(_ sender: Any?) {
        sheet.makeFirstResponder(nil)
        guard validate() else { NSSound.beep(); return }
        finish(.OK)
    }

    @objc private func cancelPressed(_ sender: Any?) { finish(.cancel) }

    private func finish(_ code: NSApplication.ModalResponse) {
        if let parent { parent.endSheet(sheet, returnCode: code) } else { sheet.orderOut(nil) }
    }

    /// Shows the sheet on `window`; true when the user pressed OK.
    func run(on window: NSWindow) async -> Bool {
        parent = window
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            window.beginSheet(sheet) { continuation.resume(returning: $0) }
        }
        sheet.orderOut(nil)
        return response == .OK
    }
}

/// A slider with a live value label; `onChange` receives the rounded integer value.
@MainActor
final class LabeledSlider: NSObject {
    let slider: NSSlider
    let valueLabel = NSTextField(labelWithString: "")
    private let format: (Int) -> String
    var onChange: (Int) -> Void = { _ in }

    init(range: ClosedRange<Int>, value: Int, format: @escaping (Int) -> String) {
        self.format = format
        slider = NSSlider(value: Double(min(max(value, range.lowerBound), range.upperBound)),
                          minValue: Double(range.lowerBound), maxValue: Double(range.upperBound),
                          target: nil, action: nil)
        super.init()
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        valueLabel.stringValue = format(value)
    }

    var value: Int { Int(slider.doubleValue.rounded()) }

    @objc private func changed(_ sender: Any?) {
        let v = value
        valueLabel.stringValue = format(v)
        onChange(v)
    }
}

/// Builders for the three effect parameter sheets.
@MainActor
enum EffectSheetsUI {
    static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    static func px(_ v: Int) -> String { "\(v) px" }

    // MARK: Drop shadow

    @MainActor
    struct DropShadowControls {
        let darkness: LabeledSlider, size: LabeledSlider, offsetX: LabeledSlider, offsetY: LabeledSlider
        var settings: DropShadowSettings {
            var s = DropShadowSettings()
            s.darkness = Double(darkness.value) / 40
            s.size = size.value
            s.offset = CGPoint(x: offsetX.value, y: offsetY.value)
            return s
        }
    }

    static func dropShadowControls(_ initial: DropShadowSettings) -> DropShadowControls {
        DropShadowControls(
            darkness: LabeledSlider(range: 1...40, value: Int((initial.darkness * 40).rounded()),
                                    format: { "\(Int((Double($0) / 40 * 100).rounded())) %" }),
            size: LabeledSlider(range: 1...20, value: initial.size, format: px),
            offsetX: LabeledSlider(range: -20...20, value: Int(initial.offset.x.rounded()), format: px),
            offsetY: LabeledSlider(range: -20...20, value: Int(initial.offset.y.rounded()), format: px))
    }

    static func dropShadow(on window: NSWindow, initial: DropShadowSettings) async -> DropShadowSettings? {
        let c = dropShadowControls(initial)
        let content = grid([
            [label("Darkness:"), c.darkness.slider, c.darkness.valueLabel],
            [label("Shadow size:"), c.size.slider, c.size.valueLabel],
            [label("Offset X:"), c.offsetX.slider, c.offsetX.valueLabel],
            [label("Offset Y:"), c.offsetY.slider, c.offsetY.valueLabel],
        ])
        let runner = EffectSheetRunner(title: "Drop Shadow", content: content)
        runner.retained = [c.darkness, c.size, c.offsetX, c.offsetY]
        guard await runner.run(on: window) else { return nil }
        return c.settings
    }

    // MARK: Torn edges

    @MainActor
    final class TornEdgeControls: NSObject {
        var settings: TornEdgeSettings
        let height: LabeledSlider, hRange: LabeledSlider, vRange: LabeledSlider
        let top = NSButton(checkboxWithTitle: "Top", target: nil, action: nil)
        let right = NSButton(checkboxWithTitle: "Right", target: nil, action: nil)
        let bottom = NSButton(checkboxWithTitle: "Bottom", target: nil, action: nil)
        let left = NSButton(checkboxWithTitle: "Left", target: nil, action: nil)
        let all = NSButton(checkboxWithTitle: "All sides", target: nil, action: nil)
        let shadow = NSButton(checkboxWithTitle: "Generate shadow", target: nil, action: nil)
        let reseed = NSButton(title: "New random pattern", target: nil, action: nil)
        let patternLabel = NSTextField(labelWithString: "")

        init(_ initial: TornEdgeSettings) {
            settings = initial
            height = LabeledSlider(range: 1...40, value: initial.toothHeight, format: EffectSheetsUI.px)
            hRange = LabeledSlider(range: 2...40, value: initial.horizontalToothRange, format: EffectSheetsUI.px)
            vRange = LabeledSlider(range: 2...40, value: initial.verticalToothRange, format: EffectSheetsUI.px)
            super.init()
            for (box, on) in [(top, initial.top), (right, initial.right), (bottom, initial.bottom),
                              (left, initial.left), (shadow, initial.generateShadow)] {
                box.state = on ? .on : .off
                box.target = self
                box.action = #selector(sideChanged(_:))
            }
            all.target = self
            all.action = #selector(allChanged(_:))
            reseed.target = self
            reseed.action = #selector(newPattern(_:))
            patternLabel.textColor = .secondaryLabelColor
            updateAll()
            updatePatternLabel()
        }

        private var sides: [NSButton] { [top, right, bottom, left] }

        private func updateAll() {
            all.state = sides.allSatisfy { $0.state == .on } ? .on : .off
        }

        private func updatePatternLabel() {
            patternLabel.stringValue = settings.seed == 0
                ? "Pattern: new each time"
                : "Pattern: #\(String(settings.seed % 100_000))"
        }

        @objc private func sideChanged(_ sender: Any?) { updateAll() }

        @objc private func allChanged(_ sender: Any?) {
            let on = all.state == .on
            sides.forEach { $0.state = on ? .on : .off }
        }

        @objc private func newPattern(_ sender: Any?) {
            settings.seed = UInt64.random(in: 1...UInt64.max)
            updatePatternLabel()
        }

        var result: TornEdgeSettings {
            var s = settings
            s.toothHeight = height.value
            s.horizontalToothRange = hRange.value
            s.verticalToothRange = vRange.value
            s.top = top.state == .on
            s.right = right.state == .on
            s.bottom = bottom.state == .on
            s.left = left.state == .on
            s.generateShadow = shadow.state == .on
            return s
        }
    }

    static func tornEdges(on window: NSWindow, initial: TornEdgeSettings) async -> TornEdgeSettings? {
        let c = TornEdgeControls(initial)
        let sideRow = NSStackView(views: [c.top, c.right, c.bottom, c.left])
        sideRow.orientation = .horizontal
        sideRow.spacing = 12
        let patternRow = NSStackView(views: [c.reseed, c.patternLabel])
        patternRow.orientation = .horizontal
        patternRow.spacing = 10
        let content = grid([
            [label("Tooth height:"), c.height.slider, c.height.valueLabel],
            [label("Horizontal range:"), c.hRange.slider, c.hRange.valueLabel],
            [label("Vertical range:"), c.vRange.slider, c.vRange.valueLabel],
            [label("Sides:"), c.all, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, sideRow, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, c.shadow, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, patternRow, NSGridCell.emptyContentView],
        ])
        for row in 3..<7 { content.cell(atColumnIndex: 1, rowIndex: row).xPlacement = .leading }
        for row in 4..<7 { content.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: row, length: 1)) }
        let runner = EffectSheetRunner(title: "Torn Edges", content: content)
        runner.retained = [c, c.height, c.hRange, c.vRange]
        guard await runner.run(on: window) else { return nil }
        return c.result
    }

    // MARK: Resize

    @MainActor
    final class ResizeControls: NSObject, NSTextFieldDelegate {
        let original: CGSize
        private(set) var pixelWidth: Double
        private(set) var pixelHeight: Double
        let widthField = NSTextField(string: "")
        let heightField = NSTextField(string: "")
        let unitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let keepAspect = NSButton(checkboxWithTitle: "Keep aspect ratio", target: nil, action: nil)
        private(set) var presetButtons: [NSButton] = []
        private let formatter: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.usesGroupingSeparator = false
            f.maximumFractionDigits = 2
            return f
        }()

        init(current: CGSize) {
            original = CGSize(width: max(1, current.width), height: max(1, current.height))
            pixelWidth = Double(original.width)
            pixelHeight = Double(original.height)
            super.init()
            unitPopup.addItems(withTitles: ["Pixels", "Percent"])
            unitPopup.target = self
            unitPopup.action = #selector(unitChanged(_:))
            keepAspect.state = .on
            keepAspect.target = self
            keepAspect.action = #selector(aspectChanged(_:))
            for field in [widthField, heightField] {
                field.delegate = self
                field.alignment = .right
                field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            }
            presetButtons = [25, 33, 50].map { pct in
                let b = NSButton(title: "\(pct) %", target: self, action: #selector(preset(_:)))
                b.tag = pct
                b.bezelStyle = .push
                return b
            }
            refreshFields()
        }

        private var percentMode: Bool { unitPopup.indexOfSelectedItem == 1 }

        private func display(_ pixels: Double, of originalValue: CGFloat) -> String {
            let value = percentMode ? pixels / Double(originalValue) * 100 : pixels.rounded()
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }

        private func parse(_ text: String) -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let n = formatter.number(from: trimmed) { return n.doubleValue }
            return Double(trimmed.replacingOccurrences(of: ",", with: "."))
        }

        private func refreshFields() {
            widthField.stringValue = display(pixelWidth, of: original.width)
            heightField.stringValue = display(pixelHeight, of: original.height)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let v = parse(field.stringValue), v > 0 else { return }
            let aspect = Double(original.height / original.width)
            if field === widthField {
                pixelWidth = percentMode ? Double(original.width) * v / 100 : v
                if keepAspect.state == .on {
                    pixelHeight = pixelWidth * aspect
                    heightField.stringValue = display(pixelHeight, of: original.height)
                }
            } else if field === heightField {
                pixelHeight = percentMode ? Double(original.height) * v / 100 : v
                if keepAspect.state == .on {
                    pixelWidth = pixelHeight / aspect
                    widthField.stringValue = display(pixelWidth, of: original.width)
                }
            }
        }

        @objc private func unitChanged(_ sender: Any?) { refreshFields() }

        @objc private func aspectChanged(_ sender: Any?) {
            guard keepAspect.state == .on else { return }
            pixelHeight = pixelWidth * Double(original.height / original.width)
            refreshFields()
        }

        @objc private func preset(_ sender: NSButton) {
            let f = Double(sender.tag) / 100
            pixelWidth = Double(original.width) * f
            pixelHeight = Double(original.height) * f
            refreshFields()
        }

        /// The chosen size in whole pixels, or nil when a field is invalid.
        var result: CGSize? {
            guard let w = parse(widthField.stringValue), let h = parse(heightField.stringValue), w > 0, h > 0
            else { return nil }
            let pw = (percentMode ? Double(original.width) * w / 100 : w).rounded()
            let ph = (percentMode ? Double(original.height) * h / 100 : h).rounded()
            guard pw >= 1, ph >= 1, pw <= 32_000, ph <= 32_000 else { return nil }
            return CGSize(width: pw, height: ph)
        }
    }

    static func resize(on window: NSWindow, current: CGSize) async -> CGSize? {
        let c = ResizeControls(current: current)
        let presets = NSStackView(views: c.presetButtons)
        presets.orientation = .horizontal
        presets.spacing = 8
        let info = NSTextField(labelWithString: "Current size: \(Int(c.original.width)) x \(Int(c.original.height)) px")
        info.textColor = .secondaryLabelColor
        let content = grid([
            [label("Units:"), c.unitPopup],
            [label("Width:"), c.widthField],
            [label("Height:"), c.heightField],
            [NSGridCell.emptyContentView, c.keepAspect],
            [label("Presets:"), presets],
            [NSGridCell.emptyContentView, info],
        ])
        let runner = EffectSheetRunner(title: "Resize", content: content)
        runner.retained = [c]
        runner.validate = { c.result != nil }
        runner.sheet.initialFirstResponder = c.widthField
        guard await runner.run(on: window) else { return nil }
        return c.result
    }
}
