import Accelerate
import CoreGraphics
import CoreImage

/// Implementations behind `RegionFilters`. Rects are image pixels, top-left origin; a region
/// partly outside the image yields transparent pixels there.
enum RegionFiltersEngine {
    typealias B = EffectsBitmap

    /// The whole-pixel region to work on, or nil when it misses the image.
    private static func region(_ rect: CGRect, in image: CGImage) -> CGRect? {
        let r = B.pixelRect(rect)
        guard !r.isNull, r.width >= 1, r.height >= 1, r.intersects(B.bounds(of: image)) else { return nil }
        return r
    }

    /// A context the size of `r` holding the image pixels under it.
    private static func cropContext(_ image: CGImage, _ r: CGRect) -> CGContext? {
        guard let ctx = B.makeContext(width: Int(r.width), height: Int(r.height)) else { return nil }
        B.draw(image, in: ctx, atTopLeft: CGPoint(x: -r.minX, y: -r.minY))
        return ctx
    }

    // MARK: Pixelate

    static func pixelate(_ image: CGImage, rect: CGRect, cellSize: Int) -> CGImage? {
        guard let r = region(rect, in: image), let crop = cropContext(image, r) else { return nil }
        let rw = crop.width, rh = crop.height
        guard cellSize > 1 else { return crop.makeImage() }
        let cell = min(cellSize, max(rw, rh))

        // A box blur of one cell makes every pixel the average of the cell around it, so sampling
        // each cell's center gives its average color without a per-pixel loop.
        func oddKernel(_ size: Int, limit: Int) -> UInt32 {
            var k = size | 1
            if k > limit { k = limit % 2 == 1 ? limit : limit - 1 }
            return UInt32(max(1, k))
        }
        guard var src = B.buffer(of: crop),
              let blurred = B.makeContext(width: rw, height: rh), var blurBuf = B.buffer(of: blurred)
        else { return nil }
        let err = vImageBoxConvolve_ARGB8888(&src, &blurBuf, nil, 0, 0,
                                             oddKernel(cell, limit: rh), oddKernel(cell, limit: rw),
                                             nil, vImage_Flags(kvImageEdgeExtend))
        guard err == kvImageNoError else { return nil }

        let cols = (rw + cell - 1) / cell, rows = (rh + cell - 1) / cell
        guard let small = B.makeContext(width: cols, height: rows), let smallData = small.data,
              let blurData = blurred.data
        else { return nil }
        let from = blurData.assumingMemoryBound(to: UInt32.self)
        let to = smallData.assumingMemoryBound(to: UInt32.self)
        let fromStride = blurred.bytesPerRow / 4, toStride = small.bytesPerRow / 4
        for j in 0..<rows {
            let y0 = j * cell, sy = min(y0 + min(cell, rh - y0) / 2, rh - 1)
            for i in 0..<cols {
                let x0 = i * cell, sx = min(x0 + min(cell, rw - x0) / 2, rw - 1)
                to[j * toStride + i] = from[sy * fromStride + sx]
            }
        }
        guard let cells = small.makeImage(), let out = B.makeContext(width: rw, height: rh) else { return nil }
        out.interpolationQuality = .none
        let scaled = CGRect(x: 0, y: 0, width: cols * cell, height: rows * cell)
        out.draw(cells, in: B.flip(scaled, canvasHeight: CGFloat(rh)))
        return out.makeImage()
    }

    // MARK: Blur

    static func blur(_ image: CGImage, rect: CGRect, radius: Double) -> CGImage? {
        guard let r = region(rect, in: image) else { return nil }
        guard radius > 0 else { return cropContext(image, r)?.makeImage() }
        let ci = CIImage(cgImage: image)
        // Clamping before the blur keeps image edges from fading toward transparent.
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ci.extent)
        return B.render(blurred, rect: B.ciRect(r, imageHeight: image.height))
    }

    // MARK: Grayscale

    static func grayscale(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard let r = region(rect, in: image), let crop = cropContext(image, r)?.makeImage() else { return nil }
        return ImageEffectsEngine.grayscale(crop)
    }

    // MARK: Magnify

    static func magnify(_ image: CGImage, rect: CGRect, factor: Double) -> CGImage? {
        guard let r = region(rect, in: image) else { return nil }
        let f = CGFloat(max(1, factor.isFinite ? factor : 1))
        let source = CGRect(x: r.midX - r.width / (2 * f), y: r.midY - r.height / (2 * f),
                            width: r.width / f, height: r.height / f)
        guard let out = B.makeContext(width: Int(r.width), height: Int(r.height)) else { return nil }
        let needed = B.pixelRect(source).intersection(B.bounds(of: image))
        guard !needed.isNull, needed.width >= 1, needed.height >= 1,
              let sub = image.cropping(to: needed) else { return out.makeImage() }
        out.interpolationQuality = .none
        let dest = CGRect(x: (needed.minX - source.minX) * f, y: (needed.minY - source.minY) * f,
                          width: needed.width * f, height: needed.height * f)
        out.draw(sub, in: B.flip(dest, canvasHeight: r.height))
        return out.makeImage()
    }

    // MARK: Area highlight

    static func areaHighlight(_ image: CGImage, keep rect: CGRect, brightness: Double, blurRadius: Double) -> CGImage? {
        let ci = CIImage(cgImage: image)
        var outside = ci
        if blurRadius > 0 {
            outside = ci.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: ci.extent)
        }
        let b = CGFloat(max(0, brightness))
        if b != 1 {
            outside = outside.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: b, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: b, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }
        var result = outside
        let kept = B.pixelRect(rect).intersection(B.bounds(of: image))
        if !kept.isNull, kept.width > 0, kept.height > 0 {
            result = ci.cropped(to: B.ciRect(kept, imageHeight: image.height)).composited(over: outside)
        }
        return B.render(result, rect: ci.extent)
    }
}
