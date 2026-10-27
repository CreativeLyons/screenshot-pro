import CoreGraphics
import Foundation
import ScreenshotProCore
import ImageIO

/// The kinds of annotation the editor can place on an image.
enum ElementType: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, line, arrow, freehand, marker, text, speechBubble, counter, highlight, obfuscate, image

    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .freehand: return "Freehand"
        case .marker: return "Marker"
        case .text: return "Text"
        case .speechBubble: return "Speech Bubble"
        case .counter: return "Counter"
        case .highlight: return "Highlight"
        case .obfuscate: return "Obfuscate"
        case .image: return "Image"
        }
    }

    /// Elements defined by two end points (move handles instead of resize handles).
    var isLinear: Bool { self == .line || self == .arrow }
    /// Elements that hold editable text.
    var hasText: Bool { self == .text || self == .speechBubble }
    /// Highlight and obfuscate read the base image.
    var isFilter: Bool { self == .highlight || self == .obfuscate }
    /// Pen strokes: a path through kept points (freehand and the highlighter marker).
    var isStroke: Bool { self == .freehand || self == .marker }
    /// Elements whose geometry is the `rect` field.
    var isBoxed: Bool { !isLinear && !isStroke }
    /// Elements that get the 8 resize handles.
    var isResizable: Bool { isBoxed }
    /// Resizing keeps width == height.
    var locksAspect: Bool { self == .counter }
    /// Elements that stay upright when the image is rotated: they move with their center but
    /// keep their width and height, so text and bitmaps are not squeezed or turned sideways.
    var staysUpright: Bool { hasText || self == .counter || self == .image }
}

enum ArrowHeads: String, Codable, CaseIterable, Sendable {
    case none, start, end, both
    var displayName: String {
        switch self {
        case .none: return "None"
        case .start: return "Start"
        case .end: return "End"
        case .both: return "Both"
        }
    }
    var atStart: Bool { self == .start || self == .both }
    var atEnd: Bool { self == .end || self == .both }
}

enum HighlightMode: String, Codable, CaseIterable, Sendable {
    case text, area, grayscale, magnify
    var displayName: String {
        switch self {
        case .text: return "Text Highlight"
        case .area: return "Area Highlight"
        case .grayscale: return "Grayscale"
        case .magnify: return "Magnify"
        }
    }
    /// Modes that change everything outside the rectangle.
    var affectsOutside: Bool { self == .area || self == .grayscale }
}

enum ObfuscateMode: String, Codable, CaseIterable, Sendable {
    case pixelate, blur
    var displayName: String { self == .pixelate ? "Pixelate" : "Blur" }
}

enum HorizontalTextAlignment: String, Codable, CaseIterable, Sendable { case left, center, right }
enum VerticalTextAlignment: String, Codable, CaseIterable, Sendable { case top, middle, bottom }

/// Every visual property an element can have. Each element type uses a subset (see `ElementField`).
/// Sizes are image pixels.
struct ElementStyle: Codable, Equatable, Sendable {
    var lineThickness: Double = 2
    var lineColor: RGBAColor = .red
    var fillColor: RGBAColor = .clear
    var shadow = true
    var fontName = "Helvetica Neue"
    var fontSize: Double = 11
    var bold = false
    var italic = false
    var horizontalAlignment: HorizontalTextAlignment = .center
    var verticalAlignment: VerticalTextAlignment = .middle
    var arrowHeads: ArrowHeads = .end
    var highlightMode: HighlightMode = .text
    /// Area highlight: brightness of the area outside (1 = unchanged).
    var brightness: Double = 0.9
    var magnification: Double = 2
    var obfuscateMode: ObfuscateMode = .pixelate
    var pixelSize: Double = 5
    /// Blur radius for obfuscate blur and area highlight.
    var blurRadius: Double = 3
    /// Hand-drawn look: lines and outlines wobble a little, like a pen sketch (Excalidraw).
    /// Off for elements from files that predate it; new elements get it from their defaults.
    var sketchy = false
    /// Counters: each number takes the next color of `CounterColors.palette` instead of the fill.
    var cycleColors = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lineThickness, lineColor, fillColor, shadow, fontName, fontSize, bold, italic
        case horizontalAlignment, verticalAlignment, arrowHeads, highlightMode, brightness
        case magnification, obfuscateMode, pixelSize, blurRadius, sketchy, cycleColors
    }

    // Tolerant decoding so files written by later versions (or missing keys) still load.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ path: WritableKeyPath<ElementStyle, T>) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { self[keyPath: path] = v }
        }
        read(.lineThickness, \.lineThickness)
        read(.lineColor, \.lineColor)
        read(.fillColor, \.fillColor)
        read(.shadow, \.shadow)
        read(.fontName, \.fontName)
        read(.fontSize, \.fontSize)
        read(.bold, \.bold)
        read(.italic, \.italic)
        read(.horizontalAlignment, \.horizontalAlignment)
        read(.verticalAlignment, \.verticalAlignment)
        read(.arrowHeads, \.arrowHeads)
        read(.highlightMode, \.highlightMode)
        read(.brightness, \.brightness)
        read(.magnification, \.magnification)
        read(.obfuscateMode, \.obfuscateMode)
        read(.pixelSize, \.pixelSize)
        read(.blurRadius, \.blurRadius)
        read(.sketchy, \.sketchy)
        read(.cycleColors, \.cycleColors)
    }
}

/// A bitmap held by an image element. Compared by identity; encoded as base64 PNG.
struct EmbeddedImage: Codable, Equatable, @unchecked Sendable {
    let cgImage: CGImage

    init(_ image: CGImage) { cgImage = image }

    static func == (a: EmbeddedImage, b: EmbeddedImage) -> Bool { a.cgImage === b.cgImage }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let base64 = try c.decode(String.self)
        guard let data = Data(base64Encoded: base64), let image = PNGCoding.decode(data) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid embedded PNG")
        }
        cgImage = image
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        guard let data = PNGCoding.encode(cgImage) else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "PNG encoding failed"))
        }
        try c.encode(data.base64EncodedString())
    }
}

/// One annotation. A plain value: copying it copies the annotation (the bitmap of an image
/// element is shared). All geometry is in image pixels, top-left origin.
struct Element: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var type: ElementType
    /// Bounds of boxed elements (normalized: non-negative size). Unused for lines and freehand.
    var rect: CGRect = .zero
    /// Line/arrow: [start, end]. Freehand: the kept path points. Speech bubble: [tail target].
    var points: [CGPoint] = []
    var style = ElementStyle()
    var text = ""
    var image: EmbeddedImage?
    /// Creation order within the document, used for counter numbering.
    var sequence = 0
    /// Counter numbering restarts in each group ("Reset Counter" starts a new group).
    var counterGroup = 0

    init(type: ElementType, rect: CGRect = .zero, points: [CGPoint] = [], style: ElementStyle = ElementStyle()) {
        self.type = type
        self.rect = rect
        self.points = points
        self.style = style
    }

    var start: CGPoint {
        get { points.first ?? rect.origin }
        set { if points.isEmpty { points = [newValue, newValue] } else { points[0] = newValue } }
    }

    var end: CGPoint {
        get { points.count > 1 ? points[1] : start }
        set {
            if points.count < 2 { points = [start, newValue] } else { points[1] = newValue }
        }
    }

    /// Target point of a speech bubble's tail.
    var tailTarget: CGPoint {
        get { points.first ?? CGPoint(x: rect.midX, y: rect.maxY + 20) }
        set { points = [newValue] }
    }
}

/// PNG encode/decode with ImageIO (no AppKit).
enum PNGCoding {
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
