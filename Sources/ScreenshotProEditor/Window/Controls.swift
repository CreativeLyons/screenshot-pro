import AppKit
import ScreenshotProCore

/// A labelled numeric field with a stepper.
@MainActor
final class NumberControl: NSStackView {
    let field = NSTextField()
    let stepper = NSStepper()
    var onChange: ((Double) -> Void)?

    init(label: String, min: Double, max: Double, step: Double = 1, suffix: String? = nil, tooltip: String? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: min)
        formatter.maximum = NSNumber(value: max)
        formatter.maximumFractionDigits = 1
        field.formatter = formatter
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 40).isActive = true
        field.target = self
        field.action = #selector(fieldChanged)
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = step
        stepper.valueWraps = false
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        addArrangedSubview(l)
        addArrangedSubview(field)
        addArrangedSubview(stepper)
        if let suffix {
            let s = NSTextField(labelWithString: suffix)
            s.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            addArrangedSubview(s)
        }
        toolTip = tooltip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var value: Double {
        get { stepper.doubleValue }
        set {
            stepper.doubleValue = newValue
            field.doubleValue = stepper.doubleValue
        }
    }

    @objc private func fieldChanged() {
        stepper.doubleValue = field.doubleValue
        field.doubleValue = stepper.doubleValue
        onChange?(stepper.doubleValue)
    }

    @objc private func stepperChanged() {
        field.doubleValue = stepper.doubleValue
        onChange?(stepper.doubleValue)
    }
}

/// A small label plus a color well.
@MainActor
final class ColorControl: NSStackView {
    let label: NSTextField
    let well = NSColorWell(style: .minimal)
    var onChange: ((RGBAColor) -> Void)?

    init(label text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        well.widthAnchor.constraint(equalToConstant: 34).isActive = true
        well.heightAnchor.constraint(equalToConstant: 20).isActive = true
        well.target = self
        well.action = #selector(changed)
        well.supportsAlpha = true
        addArrangedSubview(label)
        addArrangedSubview(well)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var settingColor = false

    var color: RGBAColor {
        get { RGBAColor(well.color) }
        set {
            guard RGBAColor(well.color) != newValue else { return }
            // An active well updates the color panel, which may echo the change back.
            settingColor = true
            well.color = newValue.nsColor
            settingColor = false
        }
    }

    @objc private func changed() {
        guard !settingColor else { return }
        onChange?(RGBAColor(well.color))
    }
}

extension RGBAColor {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.genericRGB) ?? .black
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent),
                  alpha: Double(c.alphaComponent))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// A round swatch image for quick color buttons.
    func swatch(size: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            self.nsColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}

/// A popup button filled with the titles of `cases`.
@MainActor
func makePopup(_ titles: [String], target: AnyObject, action: Selector) -> NSPopUpButton {
    let p = NSPopUpButton(frame: .zero, pullsDown: false)
    p.controlSize = .small
    p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    p.addItems(withTitles: titles)
    p.target = target
    p.action = action
    return p
}
