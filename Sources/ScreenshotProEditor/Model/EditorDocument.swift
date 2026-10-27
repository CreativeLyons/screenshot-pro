import CoreGraphics
import Foundation

/// The editable state of one editor window: the base image plus an ordered list of
/// annotations (drawn first to last). A value type: copies are cheap because the image and
/// element bitmaps are shared references, which makes snapshot undo inexpensive.
struct EditorDocument: Equatable, @unchecked Sendable {
    /// The unannotated background image.
    var image: CGImage
    /// Backing pixels per point (2 for Retina captures).
    var scale: CGFloat
    /// Annotations in z-order, bottom first.
    var elements: [Element] = []
    /// First number of the counter elements (per image, "Start value").
    var counterStart = 1
    /// Group new counters join; "Reset Counter" starts a new group.
    var counterGroup = 0
    /// Next creation sequence number.
    var nextSequence = 1

    init(image: CGImage, scale: CGFloat = 1, elements: [Element] = []) {
        self.image = image
        self.scale = max(scale, 0.1)
        for e in elements { add(e) }
    }

    /// Image size in pixels.
    var size: CGSize { CGSize(width: image.width, height: image.height) }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    static func == (a: EditorDocument, b: EditorDocument) -> Bool {
        a.image === b.image && a.scale == b.scale && a.elements == b.elements
            && a.counterStart == b.counterStart && a.counterGroup == b.counterGroup
            && a.nextSequence == b.nextSequence
    }

    // MARK: Elements

    func index(of id: UUID) -> Int? { elements.firstIndex { $0.id == id } }

    func element(_ id: UUID) -> Element? { elements.first { $0.id == id } }

    /// Adds `element` on top, giving it a creation sequence (and the current counter group).
    @discardableResult
    mutating func add(_ element: Element) -> Element {
        var e = element
        e.sequence = nextSequence
        nextSequence += 1
        if e.type == .counter { e.counterGroup = counterGroup }
        elements.append(e)
        return e
    }

    /// Adds copies of `elements` (given in z-order) on top with fresh ids, keeping their
    /// relative z-order and creation order. Returns the copies.
    mutating func addCopies(of originals: [Element], offset: CGPoint = .zero) -> [Element] {
        var newSequence: [UUID: Int] = [:]
        for o in originals.sorted(by: { $0.sequence < $1.sequence }) {
            newSequence[o.id] = nextSequence
            nextSequence += 1
        }
        let copies = originals.map { o -> Element in
            var copy = ElementGeometry.moved(o, by: offset)
            copy.id = UUID()
            copy.sequence = newSequence[o.id] ?? 0
            if copy.type == .counter { copy.counterGroup = counterGroup }
            return copy
        }
        elements.append(contentsOf: copies)
        return copies
    }

    mutating func remove(_ ids: Set<UUID>) {
        elements.removeAll { ids.contains($0.id) }
    }

    mutating func update(_ id: UUID, _ change: (inout Element) -> Void) {
        guard let i = index(of: id) else { return }
        change(&elements[i])
    }

    mutating func updateAll(_ ids: Set<UUID>, _ change: (inout Element) -> Void) {
        for i in elements.indices where ids.contains(elements[i].id) { change(&elements[i]) }
    }

    mutating func move(_ ids: Set<UUID>, by delta: CGPoint) {
        for i in elements.indices where ids.contains(elements[i].id) {
            elements[i] = ElementGeometry.moved(elements[i], by: delta)
        }
    }

    // MARK: Z-order

    mutating func bringToFront(_ ids: Set<UUID>) {
        let moving = elements.filter { ids.contains($0.id) }
        elements.removeAll { ids.contains($0.id) }
        elements.append(contentsOf: moving)
    }

    mutating func sendToBack(_ ids: Set<UUID>) {
        let moving = elements.filter { ids.contains($0.id) }
        elements.removeAll { ids.contains($0.id) }
        elements.insert(contentsOf: moving, at: 0)
    }

    /// Moves each selected element one place up, past the next unselected element.
    mutating func bringForward(_ ids: Set<UUID>) {
        guard elements.count > 1 else { return }
        for i in stride(from: elements.count - 2, through: 0, by: -1)
        where ids.contains(elements[i].id) && !ids.contains(elements[i + 1].id) {
            elements.swapAt(i, i + 1)
        }
    }

    /// Moves each selected element one place down.
    mutating func sendBackward(_ ids: Set<UUID>) {
        guard elements.count > 1 else { return }
        for i in 1..<elements.count where ids.contains(elements[i].id) && !ids.contains(elements[i - 1].id) {
            elements.swapAt(i, i - 1)
        }
    }

    func canBringForward(_ ids: Set<UUID>) -> Bool {
        guard let top = elements.lastIndex(where: { !ids.contains($0.id) }) else { return false }
        return elements[..<top].contains { ids.contains($0.id) }
    }

    func canSendBackward(_ ids: Set<UUID>) -> Bool {
        guard let bottom = elements.firstIndex(where: { !ids.contains($0.id) }) else { return false }
        return elements[(bottom + 1)...].contains { ids.contains($0.id) }
    }

    // MARK: Counters

    /// Number shown by every counter element: the start value plus the number of counters of
    /// the same group created before it. Deleting one renumbers the later ones.
    func counterNumbers() -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        let counters = elements.filter { $0.type == .counter }.sorted { $0.sequence < $1.sequence }
        var seen: [Int: Int] = [:]
        for c in counters {
            let n = seen[c.counterGroup, default: 0]
            result[c.id] = counterStart + n
            seen[c.counterGroup] = n + 1
        }
        return result
    }

    func counterNumber(for id: UUID) -> Int? { counterNumbers()[id] }

    /// The next counter placed starts again at the start value.
    mutating func resetCounter() { counterGroup += 1 }

    // MARK: Image changes

    /// Replaces the base image and maps every element through `transform` (from old image
    /// pixels to new ones).
    mutating func replaceImage(_ newImage: CGImage, transform: CGAffineTransform = .identity) {
        image = newImage
        if !transform.isIdentity {
            elements = elements.map { ElementGeometry.transform($0, by: transform) }
        }
    }

    /// Crops to `rect` (already applied to `croppedImage`): elements entirely outside are
    /// removed, the others move with the image.
    mutating func crop(to rect: CGRect, croppedImage: CGImage) {
        elements.removeAll { e in
            let b = ElementGeometry.bounds(of: e)
            return !b.insetBy(dx: -0.5, dy: -0.5).intersects(rect)
        }
        replaceImage(croppedImage, transform: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Replaces the base image with `rotatedImage` (the old image turned by `quarterTurns`,
    /// positive = clockwise) and moves the elements with it; see `ElementGeometry.rotated`.
    mutating func rotate(quarterTurns: Int, rotatedImage: CGImage) {
        let t = EditorDocument.rotationTransform(quarterTurns: quarterTurns, size: size)
        image = rotatedImage
        if !t.isIdentity {
            elements = elements.map { ElementGeometry.rotated($0, by: t) }
        }
    }

    /// Transform mapping old pixel coordinates when the image (of size `size`) is rotated by
    /// `quarterTurns` (positive = clockwise).
    static func rotationTransform(quarterTurns: Int, size: CGSize) -> CGAffineTransform {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)  // (x,y) -> (H - y, x)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)   // (x,y) -> (y, W - x)
        default: return .identity
        }
    }

    /// Transform for an effect's reported geometry (scale first, then offset).
    static func transform(for geometry: EffectGeometry) -> CGAffineTransform {
        CGAffineTransform(a: geometry.scale.width, b: 0, c: 0, d: geometry.scale.height,
                          tx: geometry.offset.x, ty: geometry.offset.y)
    }

    /// Bytes held by the base image (for the undo budget).
    var imageByteCount: Int { image.bytesPerRow * image.height }
}
