import AppKit
import CoreGraphics
import ScreenshotProCore

// PUBLIC CONTRACT (owned by the architecture, see docs/ARCHITECTURE.md).
// Pure image operations used by the editor. Implementations may add API but must not change
// these signatures. Everything works in image pixels; results are new images (inputs untouched).

public struct DropShadowSettings: Codable, Equatable, Sendable {
    public var darkness: Double = 0.6        // 0...1
    public var size: Int = 7                 // 1...20 px
    public var offset: CGPoint = CGPoint(x: -1, y: -1)  // each -20...20 px
    public init() {}
}

public struct TornEdgeSettings: Codable, Equatable, Sendable {
    public var toothHeight: Int = 12         // 0...40 px
    public var horizontalToothRange: Int = 20 // 0...40 px
    public var verticalToothRange: Int = 20   // 0...40 px
    public var top = true, right = true, bottom = true, left = true
    public var generateShadow = true
    public var shadow = DropShadowSettings()
    public var backgroundColor: RGBAColor = .clear
    public var seed: UInt64 = 0               // 0 = new random seed each time
    public init() {}
}

/// A geometry change made by an effect, so the editor can move its elements along with the image.
public struct EffectGeometry: Equatable, Sendable {
    /// Translation to add to element coordinates (pixels), e.g. a border's width.
    public var offset: CGPoint
    /// Scale applied to element coordinates before the offset (1 when unchanged).
    public var scale: CGSize
    public init(offset: CGPoint = .zero, scale: CGSize = CGSize(width: 1, height: 1)) {
        self.offset = offset
        self.scale = scale
    }
    public static let identity = EffectGeometry()
}

public enum ImageEffects {
    public static func border(_ image: CGImage, width: Int = 2, color: RGBAColor = .black) -> (CGImage, EffectGeometry) {
        ImageEffectsEngine.border(image, width: width, color: color)
    }
    public static func dropShadow(_ image: CGImage, _ settings: DropShadowSettings) -> (CGImage, EffectGeometry) {
        ImageEffectsEngine.dropShadow(image, settings)
    }
    public static func tornEdges(_ image: CGImage, _ settings: TornEdgeSettings) -> (CGImage, EffectGeometry) {
        TornEdges.apply(image, settings)
    }
    public static func grayscale(_ image: CGImage) -> CGImage { ImageEffectsEngine.grayscale(image) }
    public static func invert(_ image: CGImage) -> CGImage { ImageEffectsEngine.invert(image) }
    public static func removeTransparency(_ image: CGImage, color: RGBAColor = .white) -> CGImage {
        ImageEffectsEngine.removeTransparency(image, color: color)
    }
    /// High-quality resample to an exact pixel size.
    public static func resize(_ image: CGImage, to size: CGSize) -> CGImage { ImageEffectsEngine.resize(image, to: size) }
    /// Rotates by 90 degree steps (positive = clockwise).
    public static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage {
        ImageEffectsEngine.rotate(image, quarterTurns: quarterTurns)
    }
    /// Adds transparent (or `color`) margins; insets are pixels per side.
    public static func expandCanvas(_ image: CGImage, top: Int, left: Int, bottom: Int, right: Int,
                                    color: RGBAColor = .clear) -> (CGImage, EffectGeometry) {
        ImageEffectsEngine.expandCanvas(image, top: top, left: left, bottom: bottom, right: right, color: color)
    }
    /// The rectangle (pixels, top-left origin) auto crop would keep, or nil when auto crop is not possible.
    public static func autoCropRect(_ image: CGImage, tolerance: Int = 10) -> CGRect? {
        ImageEffectsEngine.autoCropRect(image, tolerance: tolerance)
    }
    /// Crops to `rect` in pixels, top-left origin.
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? { ImageEffectsEngine.crop(image, to: rect) }
    /// Same size, fully transparent.
    public static func clear(_ image: CGImage) -> CGImage { ImageEffectsEngine.clear(image) }
}

/// Region filters the editor's highlight and obfuscate elements draw with. `rect` is in image
/// pixels, top-left origin; each returns an image the size of `rect` to draw over that area.
public enum RegionFilters {
    public static func pixelate(_ image: CGImage, rect: CGRect, cellSize: Int) -> CGImage? {
        RegionFiltersEngine.pixelate(image, rect: rect, cellSize: cellSize)
    }
    public static func blur(_ image: CGImage, rect: CGRect, radius: Double) -> CGImage? {
        RegionFiltersEngine.blur(image, rect: rect, radius: radius)
    }
    public static func grayscale(_ image: CGImage, rect: CGRect) -> CGImage? {
        RegionFiltersEngine.grayscale(image, rect: rect)
    }
    public static func magnify(_ image: CGImage, rect: CGRect, factor: Double) -> CGImage? {
        RegionFiltersEngine.magnify(image, rect: rect, factor: factor)
    }
    /// Area highlight: the whole image darkened/blurred everywhere except `rect` (returned full size).
    public static func areaHighlight(_ image: CGImage, keep rect: CGRect, brightness: Double, blurRadius: Double) -> CGImage? {
        RegionFiltersEngine.areaHighlight(image, keep: rect, brightness: brightness, blurRadius: blurRadius)
    }
}

/// Parameter sheets for the effects that have settings. Each returns nil when cancelled.
@MainActor
public enum EffectSheets {
    public static func dropShadow(on window: NSWindow, initial: DropShadowSettings) async -> DropShadowSettings? {
        await EffectSheetsUI.dropShadow(on: window, initial: initial)
    }
    public static func tornEdges(on window: NSWindow, initial: TornEdgeSettings) async -> TornEdgeSettings? {
        await EffectSheetsUI.tornEdges(on: window, initial: initial)
    }
    /// Resize dialog: width/height in pixels or percent, keep aspect ratio. Returns the new pixel size.
    public static func resize(on window: NSWindow, current: CGSize) async -> CGSize? {
        await EffectSheetsUI.resize(on: window, current: current)
    }
}
