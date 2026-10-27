import CoreGraphics
import Foundation

/// One display in the global layout: its Quartz frame in points and its pixels per point.
struct DisplayLayout: Equatable, Sendable {
    var frame: CGRect
    var scale: CGFloat
}

/// One display's contribution to a composed image.
struct CompositionPiece: Equatable, Sendable {
    /// Index into the displays passed to `DisplayComposition.plan`.
    var displayIndex: Int
    /// Source rect in that display's image pixels (top-left origin, whole pixels).
    var source: CGRect
    /// Destination rect in the output image's pixels (top-left origin, whole pixels).
    var destination: CGRect
}

/// How to build the image for a Quartz rect out of per-display frozen images.
struct CompositionPlan: Equatable, Sendable {
    /// Output pixels per point: the highest scale among the displays the rect touches.
    var scale: CGFloat
    var pixelWidth: Int
    var pixelHeight: Int
    var pieces: [CompositionPiece]
}

/// Multi-display composition math (pure) plus the drawing step.
enum DisplayComposition {
    /// Bounding box of all displays.
    static func bounds(of displays: [DisplayLayout]) -> CGRect {
        displays.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// The highest scale among displays that overlap `rect` (1 when none do).
    static func outputScale(for rect: CGRect, displays: [DisplayLayout]) -> CGFloat {
        let scales = displays.filter { overlapArea($0.frame, rect) > 0 }.map(\.scale)
        return max(scales.max() ?? 1, 1)
    }

    /// Plans the composition of `rect` (Quartz points). Returns nil when the rect does not
    /// overlap any display. Parts of the rect outside every display stay transparent.
    static func plan(rect: CGRect, displays: [DisplayLayout]) -> CompositionPlan? {
        let rect = rect.standardized
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = outputScale(for: rect, displays: displays)
        let size = CoordinateSpace.pixelSize(of: CGRect(origin: .zero, size: rect.size), scale: scale)
        guard size.width > 0, size.height > 0 else { return nil }
        let output = CGRect(x: 0, y: 0, width: size.width, height: size.height)

        var pieces: [CompositionPiece] = []
        for (index, display) in displays.enumerated() {
            let overlap = rect.intersection(display.frame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let imageBounds = CGRect(x: 0, y: 0, width: (display.frame.width * display.scale).rounded(),
                                     height: (display.frame.height * display.scale).rounded())
            let source = CoordinateSpace.integral(
                CoordinateSpace.pixelRect(fromQuartz: overlap, display: display.frame, scale: display.scale)
            ).intersection(imageBounds)
            let destination = CoordinateSpace.integral(
                CoordinateSpace.pixelRect(fromQuartz: overlap, display: rect, scale: scale)
            ).intersection(output)
            guard !source.isNull, !destination.isNull, source.width > 0, source.height > 0,
                  destination.width > 0, destination.height > 0 else { continue }
            pieces.append(CompositionPiece(displayIndex: index, source: source, destination: destination))
        }
        guard !pieces.isEmpty else { return nil }
        return CompositionPlan(scale: scale, pixelWidth: size.width, pixelHeight: size.height, pieces: pieces)
    }

    /// Draws a plan from `images` (same order as the displays given to `plan`).
    /// A rect inside one display at its own scale is a plain crop (no resampling).
    static func render(_ plan: CompositionPlan, images: [CGImage]) -> CGImage? {
        let output = CGRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight)
        if plan.pieces.count == 1, let piece = plan.pieces.first, piece.destination == output,
           piece.source.size == piece.destination.size, images.indices.contains(piece.displayIndex) {
            return images[piece.displayIndex].cropping(to: piece.source)
        }

        let first = images.first
        let space = first?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: plan.pixelWidth, height: plan.pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        for piece in plan.pieces where images.indices.contains(piece.displayIndex) {
            guard let part = images[piece.displayIndex].cropping(to: piece.source) else { continue }
            let ratio = piece.destination.width / piece.source.width
            // Whole-number upscales (1x next to 2x) stay sharp with nearest neighbour.
            ctx.interpolationQuality = abs(ratio - ratio.rounded()) < 0.001 ? .none : .high
            // CGContext has a bottom-left origin; the plan uses top-left.
            let d = piece.destination
            ctx.draw(part, in: CGRect(x: d.minX, y: CGFloat(plan.pixelHeight) - d.maxY, width: d.width, height: d.height))
        }
        return ctx.makeImage()
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
