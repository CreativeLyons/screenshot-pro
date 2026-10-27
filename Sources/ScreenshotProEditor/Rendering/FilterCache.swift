import CoreGraphics
import Foundation

/// Caches region filter results (pixelate, blur, highlight...) so repaints do not recompute
/// them. Keyed by the source image identity, the filter, its rectangle and parameters; the
/// source image is retained so its identity cannot be reused while an entry exists.
final class FilterCache {
    struct Key: Hashable {
        var image: ObjectIdentifier
        var kind: String
        var x: Double, y: Double, w: Double, h: Double
        var p1: Double, p2: Double
    }

    private struct Entry {
        var source: CGImage
        var result: CGImage?
        var lastUse: Int
    }

    private var entries: [Key: Entry] = [:]
    private var clock = 0
    let capacity: Int

    init(capacity: Int = 48) {
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func removeAll() { entries.removeAll() }

    /// The cached result for these inputs, computing it with `make` on a miss.
    func result(source: CGImage, kind: String, rect: CGRect, p1: Double = 0, p2: Double = 0,
                make: () -> CGImage?) -> CGImage? {
        clock += 1
        let key = Key(image: ObjectIdentifier(source), kind: kind,
                      x: Double(rect.minX), y: Double(rect.minY), w: Double(rect.width), h: Double(rect.height),
                      p1: p1, p2: p2)
        if var hit = entries[key], hit.source === source {
            hit.lastUse = clock
            entries[key] = hit
            return hit.result
        }
        let value = make()
        entries[key] = Entry(source: source, result: value, lastUse: clock)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries.removeValue(forKey: oldest)
        }
        return value
    }
}
