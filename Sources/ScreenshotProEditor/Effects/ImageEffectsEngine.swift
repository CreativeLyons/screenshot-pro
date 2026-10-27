import Accelerate
import CoreGraphics
import CoreImage
import ScreenshotProCore

/// Implementations behind `ImageEffects`. All coordinates are image pixels, top-left origin.
enum ImageEffectsEngine {
    typealias B = EffectsBitmap

    /// A copy of `image` in the standard pixel format (falls back to the input if drawing fails).
    static func standardized(_ image: CGImage) -> CGImage {
        B.context(copying: image)?.makeImage() ?? image
    }

    // MARK: Border

    static func border(_ image: CGImage, width: Int, color: RGBAColor) -> (CGImage, EffectGeometry) {
        let b = max(0, width)
        guard b > 0,
              let ctx = B.makeContext(width: image.width + 2 * b, height: image.height + 2 * b)
        else { return (standardized(image), .identity) }
        B.draw(image, in: ctx, atTopLeft: CGPoint(x: b, y: b))
        let inset = CGFloat(b) / 2
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(CGFloat(b))
        ctx.setLineJoin(.round)
        ctx.stroke(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height).insetBy(dx: inset, dy: inset))
        guard let out = ctx.makeImage() else { return (standardized(image), .identity) }
        return (out, EffectGeometry(offset: CGPoint(x: b, y: b)))
    }

    // MARK: Drop shadow

    static func dropShadow(_ image: CGImage, _ settings: DropShadowSettings) -> (CGImage, EffectGeometry) {
        let w = image.width, h = image.height
        let s = min(max(settings.size, 1), 100)
        let ox = Int(settings.offset.x.rounded()), oy = Int(settings.offset.y.rounded())
        var imageX = s - 1 + ox, imageY = s - 1 + oy
        var shadowX = s, shadowY = s
        // Keep the original fully on the canvas even for extreme offsets.
        let shiftX = max(0, -imageX), shiftY = max(0, -imageY)
        imageX += shiftX; shadowX += shiftX
        imageY += shiftY; shadowY += shiftY
        let canvasW = max(w + 2 * s + shiftX, imageX + w)
        let canvasH = max(h + 2 * s + shiftY, imageY + h)
        guard let ctx = B.makeContext(width: canvasW, height: canvasH) else { return (standardized(image), .identity) }

        let darkness = min(max(settings.darkness, 0), 1)
        if darkness > 0 {
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            let silhouette = CIImage(cgImage: image)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": zero, "inputGVector": zero, "inputBVector": zero,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(darkness)),
                    "inputBiasVector": zero,
                ])
                .transformed(by: CGAffineTransform(translationX: CGFloat(shadowX),
                                                   y: CGFloat(canvasH - shadowY - h)))
                .applyingGaussianBlur(sigma: Double(s) / 2)
            let canvas = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
            if let shadow = B.render(silhouette.cropped(to: canvas), rect: canvas) {
                ctx.draw(shadow, in: canvas)
            }
        }
        B.draw(image, in: ctx, atTopLeft: CGPoint(x: imageX, y: imageY))
        guard let out = ctx.makeImage() else { return (standardized(image), .identity) }
        return (out, EffectGeometry(offset: CGPoint(x: imageX, y: imageY)))
    }

    // MARK: Color

    /// Applies a 4x4 vImage color matrix (row = source channel R,G,B,A; column = destination channel).
    private static func colorMatrix(_ image: CGImage, matrix: [Int16], divisor: Int32) -> CGImage {
        guard let ctx = B.context(copying: image), var buf = B.buffer(of: ctx) else { return standardized(image) }
        let half = divisor / 2
        let postBias: [Int32] = [half, half, half, half]
        vImageMatrixMultiply_ARGB8888(&buf, &buf, matrix, divisor, nil, postBias, vImage_Flags(kvImageNoFlags))
        return ctx.makeImage() ?? standardized(image)
    }

    static func grayscale(_ image: CGImage) -> CGImage {
        // Weights act on premultiplied values, which keeps the result correctly premultiplied.
        colorMatrix(image, matrix: [
            300, 300, 300, 0,
            590, 590, 590, 0,
            110, 110, 110, 0,
            0, 0, 0, 1000,
        ], divisor: 1000)
    }

    static func invert(_ image: CGImage) -> CGImage {
        // Premultiplied: (1 - c) * a = a - c'.
        colorMatrix(image, matrix: [
            -256, 0, 0, 0,
            0, -256, 0, 0,
            0, 0, -256, 0,
            256, 256, 256, 256,
        ], divisor: 256)
    }

    static func removeTransparency(_ image: CGImage, color: RGBAColor) -> CGImage {
        guard let ctx = B.makeContext(width: image.width, height: image.height, opaque: true) else {
            return standardized(image)
        }
        var opaque = color
        opaque.alpha = 1
        B.fill(ctx, color: opaque)
        ctx.draw(image, in: B.bounds(of: image))
        return ctx.makeImage() ?? standardized(image)
    }

    // MARK: Geometry

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage {
        let tw = max(1, Int(size.width.rounded())), th = max(1, Int(size.height.rounded()))
        guard tw != image.width || th != image.height else { return standardized(image) }
        guard let src = B.context(copying: image), var srcBuf = B.buffer(of: src),
              let dst = B.makeContext(width: tw, height: th), var dstBuf = B.buffer(of: dst)
        else { return standardized(image) }
        let err = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
        if err != kvImageNoError {
            dst.interpolationQuality = .high
            dst.clear(CGRect(x: 0, y: 0, width: tw, height: th))
            dst.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        } else {
            // Lanczos ringing can push color above alpha, which is invalid premultiplied data.
            vImageClipToAlpha_RGBA8888(&dstBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
        }
        return dst.makeImage() ?? standardized(image)
    }

    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return standardized(image) }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swap = turns % 2 == 1
        guard let ctx = B.makeContext(width: swap ? image.height : image.width,
                                      height: swap ? image.width : image.height)
        else { return standardized(image) }
        // Core Graphics is y-up, so a clockwise turn on screen is a negative angle.
        switch turns {
        case 1:
            ctx.translateBy(x: 0, y: w)
            ctx.rotate(by: -.pi / 2)
        case 2:
            ctx.translateBy(x: w, y: h)
            ctx.rotate(by: .pi)
        default:
            ctx.translateBy(x: h, y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? standardized(image)
    }

    static func expandCanvas(_ image: CGImage, top: Int, left: Int, bottom: Int, right: Int,
                             color: RGBAColor) -> (CGImage, EffectGeometry) {
        let t = max(0, top), l = max(0, left), b = max(0, bottom), r = max(0, right)
        guard let ctx = B.makeContext(width: image.width + l + r, height: image.height + t + b) else {
            return (standardized(image), .identity)
        }
        B.fill(ctx, color: color)
        B.draw(image, in: ctx, atTopLeft: CGPoint(x: l, y: t))
        guard let out = ctx.makeImage() else { return (standardized(image), .identity) }
        return (out, EffectGeometry(offset: CGPoint(x: l, y: t)))
    }

    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let r = B.pixelRect(rect).intersection(B.bounds(of: image))
        guard !r.isNull, r.width >= 1, r.height >= 1, let sub = image.cropping(to: r) else { return nil }
        return standardized(sub)
    }

    static func clear(_ image: CGImage) -> CGImage {
        B.makeContext(width: image.width, height: image.height)?.makeImage() ?? image
    }

    // MARK: Auto crop

    static func autoCropRect(_ image: CGImage, tolerance: Int) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = B.context(copying: image), var buf = B.buffer(of: ctx) else { return nil }
        vImageUnpremultiplyData_RGBA8888(&buf, &buf, vImage_Flags(kvImageNoFlags))
        let base = buf.data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = buf.rowBytes
        let tol = max(0, tolerance)

        func pixel(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> { base + y * rowBytes + x * 4 }
        func packed(_ p: UnsafeMutablePointer<UInt8>) -> UInt32 {
            UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
        }

        var corners: [UInt32] = []
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
            let c = packed(pixel(x, y))
            if !corners.contains(c) { corners.append(c) }
        }

        var best: CGRect?
        for c in corners {
            let r = Int(c & 0xFF), g = Int((c >> 8) & 0xFF), bl = Int((c >> 16) & 0xFF), a = Int(c >> 24)
            @inline(__always) func differs(_ x: Int, _ y: Int) -> Bool {
                let p = pixel(x, y)
                let rgb = abs(Int(p[0]) - r) + abs(Int(p[1]) - g) + abs(Int(p[2]) - bl)
                return rgb > 3 * tol || abs(Int(p[3]) - a) > tol
            }
            func rowDiffers(_ y: Int) -> Bool {
                for x in 0..<w where differs(x, y) { return true }
                return false
            }
            func columnDiffers(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
                for y in y0...y1 where differs(x, y) { return true }
                return false
            }
            guard let top = (0..<h).first(where: rowDiffers) else { continue }
            let bottom = (top..<h).reversed().first(where: rowDiffers) ?? top
            let left = (0..<w).first(where: { columnDiffers($0, top, bottom) }) ?? 0
            let right = (left..<w).reversed().first(where: { columnDiffers($0, top, bottom) }) ?? left
            let box = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
            if best == nil || box.width * box.height > best!.width * best!.height { best = box }
        }
        guard let box = best, box != B.bounds(of: image) else { return nil }
        return box
    }
}
