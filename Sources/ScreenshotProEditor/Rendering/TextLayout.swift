import CoreGraphics
import CoreText
import Foundation
import ScreenshotProCore

/// Core Text helpers for drawing element text into a y-down (top-left origin) context.
enum TextLayout {
    /// The element font, falling back to an available bold/italic variant, then to the system font.
    static func font(name: String, size: Double, bold: Bool, italic: Bool) -> CTFont {
        let size = CGFloat(max(size, 1))
        let base = CTFontCreateWithName(name as CFString, size, nil)
        var wanted: CTFontSymbolicTraits = []
        if bold { wanted.insert(.traitBold) }
        if italic { wanted.insert(.traitItalic) }
        guard !wanted.isEmpty else { return base }
        if let f = CTFontCreateCopyWithSymbolicTraits(base, size, nil, wanted, wanted) { return f }
        if bold, let f = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { return f }
        if italic, let f = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) { return f }
        return base
    }

    static func font(for style: ElementStyle) -> CTFont {
        font(name: style.fontName, size: style.fontSize, bold: style.bold, italic: style.italic)
    }

    static func attributed(_ text: String, font: CTFont, color: CGColor,
                           alignment: HorizontalTextAlignment) -> NSAttributedString {
        var align: CTTextAlignment
        switch alignment {
        case .left: align = .left
        case .center: align = .center
        case .right: align = .right
        }
        let paragraph = withUnsafeBytes(of: &align) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// Height the text needs when wrapped to `width`.
    static func height(of text: String, style: ElementStyle, width: CGFloat) -> CGFloat {
        let s = attributed(text.isEmpty ? " " : text, font: font(for: style),
                           color: CGColor(gray: 0, alpha: 1), alignment: style.horizontalAlignment)
        return suggestedSize(s, width: width).height
    }

    /// Natural size of unwrapped text.
    static func naturalSize(of text: String, style: ElementStyle) -> CGSize {
        let s = attributed(text.isEmpty ? " " : text, font: font(for: style),
                           color: CGColor(gray: 0, alpha: 1), alignment: .left)
        return suggestedSize(s, width: .greatestFiniteMagnitude)
    }

    static func suggestedSize(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        let fs = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Draws `s` wrapped inside `rect` with the given vertical alignment. The context is y-down.
    static func draw(_ s: NSAttributedString, in rect: CGRect, vertical: VerticalTextAlignment, context ctx: CGContext) {
        guard rect.width > 0, s.length > 0 else { return }
        let needed = suggestedSize(s, width: rect.width).height
        let y: CGFloat
        switch vertical {
        case .top: y = rect.minY
        case .middle: y = rect.midY - needed / 2
        case .bottom: y = rect.maxY - needed
        }
        let frameRect = CGRect(x: rect.minX, y: y, width: rect.width, height: needed + 1)
        let fs = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        ctx.saveGState()
        // Flip locally so Core Text (y-up) lays out top-down inside frameRect.
        ctx.translateBy(x: 0, y: frameRect.minY + frameRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let path = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
