import CoreGraphics
import Foundation
import ScreenshotProCore
@testable import ScreenshotProEditor

/// A solid RGBA image of the given size.
func makeImage(width: Int, height: Int, color: RGBAColor = .white) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// RGBA bytes of `image` in sRGB, row 0 at the top.
struct Pixels {
    let width: Int, height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = data
    }

    /// (r, g, b, a) at column x, row y (top-left origin).
    subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

func box(_ type: ElementType, _ r: CGRect) -> Element {
    Element(type: type, rect: r, style: ElementStyle.defaults(for: type))
}

func line(_ type: ElementType = .line, from a: CGPoint, to b: CGPoint) -> Element {
    Element(type: type, points: [a, b], style: ElementStyle.defaults(for: type))
}

func makeDocument(width: Int = 100, height: Int = 80, scale: CGFloat = 1) -> EditorDocument {
    EditorDocument(image: makeImage(width: width, height: height), scale: scale)
}
