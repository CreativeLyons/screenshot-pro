import CoreGraphics
import Foundation
import Vision

/// Lines a highlighter stroke up with the text under it. Vision reads the text near the stroke;
/// when the stroke runs along a line of text, it becomes a hand-drawn band over the words it
/// touched, as tall as the text.
enum MarkerSnap {
    struct Result: Equatable {
        var points: [CGPoint]
        var thickness: CGFloat
    }

    /// The snapped stroke for `points` (image pixels) drawn `width` wide over `image`, or nil
    /// when there is no text under it or the stroke does not follow a line of text.
    static func snap(_ points: [CGPoint], width: CGFloat, image: CGImage, seed: UUID) -> Result? {
        guard let stroke = bounds(of: points), stroke.width >= 4 else { return nil }
        // A highlighter runs along the text: a stroke much taller than wide is a scribble.
        guard stroke.height <= max(stroke.width * 0.6, width * 3) else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // A band of rows across the whole width: cut at the sides, Vision would read the words
        // at the edges as partial words.
        let margin = max(width * 2, 24)
        let rows = stroke.insetBy(dx: 0, dy: -margin)
        let roi = CGRect(x: 0, y: rows.minY, width: imageBounds.width, height: rows.height).integral
            .intersection(imageBounds)
        guard roi.width >= 8, roi.height >= 8, let crop = image.cropping(to: roi) else { return nil }
        let lines = textLines(in: crop, origin: roi.origin)
        guard let line = bestLine(for: stroke, points: points, in: lines) else { return nil }
        return band(over: line, stroke: stroke, seed: seed)
    }

    /// A line of text with the boxes of its words (image pixels, y down).
    struct TextLine {
        var rect: CGRect
        var words: [CGRect]
    }

    /// The text lines Vision finds in `image`, offset by `origin`.
    static func textLines(in image: CGImage, origin: CGPoint) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func toImage(_ box: CGRect) -> CGRect {
            CGRect(x: origin.x + box.minX * w, y: origin.y + (1 - box.maxY) * h,
                   width: box.width * w, height: box.height * h)
        }
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            var words: [CGRect] = []
            var index = text.startIndex
            while index < text.endIndex {
                guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = text[start...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
                if let box = try? candidate.boundingBox(for: start..<end)?.boundingBox {
                    words.append(toImage(box))
                }
                index = end
            }
            return TextLine(rect: toImage(observation.boundingBox), words: words)
        }
    }

    /// The line the stroke runs along: it overlaps the stroke sideways and the stroke's middle
    /// is within it (with some slack), nearest first.
    static func bestLine(for stroke: CGRect, points: [CGPoint], in lines: [TextLine]) -> TextLine? {
        let meanY = points.reduce(0) { $0 + $1.y } / CGFloat(max(points.count, 1))
        return lines.filter { line in
            let overlap = min(stroke.maxX, line.rect.maxX) - max(stroke.minX, line.rect.minX)
            let slack = line.rect.height * 0.6
            return overlap >= min(stroke.width, line.rect.width) * 0.3
                && meanY >= line.rect.minY - slack && meanY <= line.rect.maxY + slack
        }.min { abs($0.rect.midY - meanY) < abs($1.rect.midY - meanY) }
    }

    /// A slightly wavy band over the words of `line` that the stroke covered.
    static func band(over line: TextLine, stroke: CGRect, seed: UUID) -> Result {
        let covered = line.words.filter { word in
            let overlap = min(stroke.maxX, word.maxX) - max(stroke.minX, word.minX)
            return overlap >= word.width * 0.4
        }
        var x0 = max(stroke.minX, line.rect.minX), x1 = min(stroke.maxX, line.rect.maxX)
        if let first = covered.map(\.minX).min(), let last = covered.map(\.maxX).max() {
            x0 = first
            x1 = last
        }
        let height = line.rect.height
        let thickness = max(height * 1.1, 4)
        let pad = height * 0.2
        // Round caps reach half the thickness past the ends.
        let start = x0 - pad + thickness / 2, end = max(start, x1 + pad - thickness / 2)
        var random = SketchPath.Random(seed)
        let count = max(2, Int(((end - start) / max(height, 1)).rounded(.up)) + 1)
        let tilt = random.offset(height * 0.06)
        let points = (0..<count).map { i -> CGPoint in
            let f = count == 1 ? 0 : CGFloat(i) / CGFloat(count - 1)
            let wobble = (i == 0 || i == count - 1) ? 0 : random.offset(height * 0.04)
            return CGPoint(x: start + (end - start) * f, y: line.rect.midY + tilt * (f - 0.5) * 2 + wobble)
        }
        return Result(points: points, thickness: thickness)
    }

    static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var r = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }
}
