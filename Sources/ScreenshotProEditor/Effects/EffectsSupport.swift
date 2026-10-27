import Accelerate
import CoreGraphics
import CoreImage
import ScreenshotProCore

/// Shared bitmap plumbing for the effects: one pixel format (sRGB, 8 bits per channel, RGBA in
/// memory, premultiplied alpha), one reusable Core Image context, and coordinate helpers.
enum EffectsBitmap {
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    static let opaqueBitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// Created once; Core Image contexts are thread safe and expensive to build.
    static let ciContext: CIContext = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false,
    ])

    /// A cleared bitmap context in the standard format. Memory row 0 is the top image row.
    static func makeContext(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: opaque ? opaqueBitmapInfo : bitmapInfo)
        ctx?.interpolationQuality = .none
        return ctx
    }

    /// Context of the same size holding a copy of `image` (converted to the standard format).
    static func context(copying image: CGImage) -> CGContext? {
        guard let ctx = makeContext(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    /// Converts a top-left origin rect in a canvas of `canvasHeight` to Core Graphics' bottom-left space.
    static func flip(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Draws `image` with its top-left corner at `origin` (top-left canvas coordinates).
    static func draw(_ image: CGImage, in ctx: CGContext, atTopLeft origin: CGPoint) {
        let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(image.width), height: CGFloat(image.height))
        ctx.draw(image, in: flip(rect, canvasHeight: CGFloat(ctx.height)))
    }

    static func fill(_ ctx: CGContext, color: RGBAColor) {
        guard color.alpha > 0 else { return }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }

    /// The context's pixels as a vImage buffer (valid while the context lives).
    static func buffer(of ctx: CGContext) -> vImage_Buffer? {
        guard let data = ctx.data else { return nil }
        return vImage_Buffer(data: data, height: vImagePixelCount(ctx.height),
                             width: vImagePixelCount(ctx.width), rowBytes: ctx.bytesPerRow)
    }

    /// Normalizes a pixel rect: standardized, rounded outward to whole pixels.
    static func pixelRect(_ rect: CGRect) -> CGRect {
        let r = rect.standardized
        guard r.width.isFinite, r.height.isFinite, !r.isNull else { return .null }
        let minX = (r.minX).rounded(.down), minY = (r.minY).rounded(.down)
        let maxX = (r.maxX).rounded(.up), maxY = (r.maxY).rounded(.up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func bounds(of image: CGImage) -> CGRect {
        CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    /// Renders a Core Image image (Core Image coordinates) for `rect` into a standard CGImage.
    static func render(_ ciImage: CIImage, rect: CGRect) -> CGImage? {
        ciContext.createCGImage(ciImage, from: rect, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Rect in image pixels (top-left origin) converted to Core Image space for an image of `height`.
    static func ciRect(_ rect: CGRect, imageHeight: Int) -> CGRect {
        flip(rect, canvasHeight: CGFloat(imageHeight))
    }
}

/// Small deterministic generator (SplitMix64) so a fixed seed always gives the same torn edge.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform integer in `range` without relying on the standard library's sampling algorithm.
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }
}
