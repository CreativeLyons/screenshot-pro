import CoreGraphics
import CoreText
import Foundation
import ScreenshotProCore

/// A property shown in the properties bar. Each element type exposes a subset, and some depend
/// on the element's mode (highlight and obfuscate).
enum ElementField: String, CaseIterable, Codable, Sendable {
    case lineThickness, lineColor, fillColor, shadow, sketchy, font, arrowHeads
    case highlightMode, brightness, blurRadius, magnification
    case obfuscateMode, pixelSize
    case cycleColors, counterStart

    /// Fields of `type` given its current style (for mode-dependent fields).
    static func fields(for type: ElementType, style: ElementStyle) -> [ElementField] {
        switch type {
        case .rectangle, .ellipse: return [.lineThickness, .lineColor, .fillColor, .shadow, .sketchy]
        case .line: return [.lineThickness, .lineColor, .shadow, .sketchy]
        case .arrow: return [.lineThickness, .lineColor, .shadow, .sketchy, .arrowHeads]
        case .freehand, .marker: return [.lineThickness, .lineColor]
        case .text, .speechBubble: return [.lineThickness, .lineColor, .fillColor, .shadow, .font]
        case .counter:
            return style.cycleColors ? [.lineColor, .cycleColors, .counterStart]
                : [.lineColor, .fillColor, .cycleColors, .counterStart]
        case .highlight:
            switch style.highlightMode {
            case .text: return [.highlightMode, .fillColor]
            case .area: return [.highlightMode, .brightness, .blurRadius]
            case .grayscale: return [.highlightMode]
            case .magnify: return [.highlightMode, .magnification]
            }
        case .obfuscate:
            return style.obfuscateMode == .pixelate ? [.obfuscateMode, .pixelSize] : [.obfuscateMode, .blurRadius]
        case .image: return []
        }
    }

    /// Fields shared by all `elements`, in a stable order.
    static func commonFields(of elements: [Element]) -> [ElementField] {
        guard let first = elements.first else { return [] }
        var common = fields(for: first.type, style: first.style)
        for e in elements.dropFirst() {
            let f = Set(fields(for: e.type, style: e.style))
            common.removeAll { !f.contains($0) }
        }
        return common
    }
}

extension ElementStyle {
    /// Factory defaults per element type (02 section 2.4) overridden by the editor defaults in
    /// the settings.
    static func defaults(for type: ElementType, settings: ScreenshotProSettings = ScreenshotProSettings()) -> ElementStyle {
        var s = ElementStyle()
        s.lineColor = settings.editorLineColor
        s.lineThickness = settings.editorLineThickness
        s.shadow = settings.editorShadow
        s.fillColor = .clear
        s.fontName = settings.editorFontName
        switch type {
        case .rectangle, .ellipse:
            s.fillColor = settings.editorFillColor
            s.sketchy = true
            s.shadow = false
        case .line, .arrow:
            // Sketched lines read better flat, the way Excalidraw draws them.
            s.sketchy = true
            s.shadow = false
        case .freehand:
            s.lineThickness = max(settings.editorLineThickness, 3)
            s.shadow = false
        case .marker:
            // A broad, faint highlighter pen; snapped to text it takes the line's height.
            s.lineThickness = 16
            s.lineColor = Palette.yellow
            s.shadow = false
        case .text:
            s.fontName = handDrawnFont(instead: s.fontName)
            s.lineColor = settings.editorTextColor
            s.fillColor = settings.editorFillColor
            s.fontSize = settings.editorFontSize
        case .speechBubble:
            s.fontName = handDrawnFont(instead: s.fontName)
            s.lineColor = Palette.blue
            s.fillColor = .white
            s.shadow = false
            s.fontSize = max(settings.editorFontSize, 20)
            s.bold = true
        case .counter:
            s.lineThickness = 0
            s.lineColor = .white
            s.fillColor = Palette.red
            s.shadow = false
            s.bold = true
            s.cycleColors = true
        case .highlight:
            s.lineThickness = 0
            s.fillColor = .yellow
            s.shadow = false
        case .obfuscate:
            s.lineThickness = 0
            s.shadow = false
            s.pixelSize = settings.pixelSize
            s.blurRadius = settings.blurRadius
        case .image:
            s.lineThickness = 0
            s.shadow = false
        }
        return s
    }
}

extension ElementStyle {
    /// Excalidraw's handwriting font when it is installed and the settings still name the
    /// factory font; a font the user chose is kept.
    static func handDrawnFont(instead name: String) -> String {
        guard name == ScreenshotProSettings().editorFontName else { return name }
        let font = CTFontCreateWithName("Excalifont" as CFString, 12, nil)
        return CTFontCopyFamilyName(font) as String == "Excalifont" ? "Excalifont" : name
    }

    /// The style with its size fields (line thickness, font size, pixel size, blur radius)
    /// multiplied by `factor`. The UI and remembered values use points; elements store pixels.
    func scaled(by factor: CGFloat) -> ElementStyle {
        guard factor != 1 else { return self }
        var s = self
        let f = Double(factor)
        s.lineThickness *= f
        s.fontSize *= f
        s.pixelSize *= f
        s.blurRadius *= f
        return s
    }
}

extension RGBAColor {
    /// Fully transparent colors are not drawn.
    var isVisible: Bool { alpha > 0.001 }

    /// Relative luminance in 0...1 (sRGB weights, no gamma), used to pick a contrasting
    /// background while editing bright text.
    var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
}

/// The colors counters take in turn when `cycleColors` is on: 1 red, 2 orange, 3 yellow...
enum CounterColors {
    static let palette = [Palette.red, Palette.orange, Palette.yellow, Palette.green,
                          Palette.teal, Palette.blue, Palette.violet, Palette.pink]

    /// The color of the counter at `index` (0 for the first number of its group).
    static func color(at index: Int) -> RGBAColor {
        let n = palette.count
        return palette[((index % n) + n) % n]
    }
}
