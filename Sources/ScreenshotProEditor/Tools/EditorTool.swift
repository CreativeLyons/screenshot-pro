import Foundation

/// The tools in the palette. Each drawing tool creates one element type.
enum EditorTool: String, CaseIterable, Sendable {
    case select, rectangle, ellipse, line, arrow, freehand, text, speechBubble, counter, highlight, blur, pixelate, crop

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .freehand: return "Freehand"
        case .text: return "Text"
        case .speechBubble: return "Speech Bubble"
        case .counter: return "Counter"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .crop: return "Crop"
        }
    }

    /// Single-key shortcut (no modifier).
    var key: String {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .line: return "l"
        case .arrow: return "a"
        case .freehand: return "f"
        case .text: return "t"
        case .speechBubble: return "s"
        case .counter: return "n"
        case .highlight: return "h"
        case .blur: return "b"
        case .pixelate: return "p"
        case .crop: return "c"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .freehand: return "pencil.tip"
        case .text: return "character.textbox"
        case .speechBubble: return "bubble.left"
        case .counter: return "1.circle"
        case .highlight: return "highlighter"
        case .blur: return "drop.halffull"
        case .pixelate: return "checkerboard.rectangle"
        case .crop: return "crop"
        }
    }

    /// Element created by this tool, nil for select and crop.
    var elementType: ElementType? {
        switch self {
        case .select, .crop: return nil
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .freehand: return .freehand
        case .text: return .text
        case .speechBubble: return .speechBubble
        case .counter: return .counter
        case .highlight: return .marker
        case .blur, .pixelate: return .obfuscate
        }
    }

    /// Hint for the status bar when text hints are on.
    var hint: String {
        switch self {
        case .select: return "Click to select, Shift-click to add, drag to move or to select several."
        case .rectangle, .ellipse:
            return "Drag to draw. Shift keeps a square or circle, Option draws from the center."
        case .line, .arrow: return "Drag to draw. Shift snaps to 15 degree steps."
        case .freehand: return "Drag to draw freehand. Shift draws a straight line."
        case .text: return "Click and type, or drag a box to wrap text. Command-Return confirms, Esc cancels."
        case .speechBubble: return "Drag a box, then type. Command-Return confirms, Esc cancels."
        case .counter: return "Click to place the next number."
        case .highlight: return "Drag over text like a highlighter: the mark lines up with the text. Shift draws straight."
        case .blur: return "Drag over the area to blur it."
        case .pixelate: return "Drag over the area to pixelate it."
        case .crop: return "Drag the area to keep. Return applies, Esc cancels."
        }
    }

    /// The obfuscate mode the blur and pixelate tools draw with.
    var obfuscateMode: ObfuscateMode? {
        switch self {
        case .blur: return .blur
        case .pixelate: return .pixelate
        default: return nil
        }
    }

    /// Where the toolbar puts a little gap after this tool, between groups.
    var endsGroup: Bool { self == .select || self == .counter || self == .pixelate }

    /// The tool for a key typed without modifiers.
    static func forKey(_ key: String) -> EditorTool? {
        allCases.first { $0.key == key }
    }
}
