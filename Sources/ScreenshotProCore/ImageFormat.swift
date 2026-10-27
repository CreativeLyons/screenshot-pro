import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Output file formats. All are written with ImageIO, so only formats ImageIO can encode on
/// macOS 14+ are listed (ImageIO reads WebP but cannot write it).
public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png, jpg, gif, tiff, bmp, heic, avif, pdf

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpg: return "JPEG"
        case .gif: return "GIF"
        case .tiff: return "TIFF"
        case .bmp: return "BMP"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .pdf: return "PDF"
        }
    }

    public var fileExtension: String { rawValue }

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .gif: return .gif
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .heic: return .heic
        case .avif: return UTType("public.avif") ?? .heic
        case .pdf: return .pdf
        }
    }

    /// Lossy formats honour the quality setting.
    public var supportsQuality: Bool { self == .jpg || self == .heic || self == .avif }

    /// Formats without an alpha channel get transparency flattened onto white.
    public var supportsAlpha: Bool { self != .jpg && self != .bmp }

    /// Maps a file extension (any case, "jpeg" included) to a format.
    public init?(fileExtension ext: String) {
        let e = ext.lowercased()
        if e == "jpeg" { self = .jpg; return }
        if e == "tif" { self = .tiff; return }
        self.init(rawValue: e)
    }
}

public enum ImageEncoder {
    /// Encodes `image` in `format`. `quality` is 0...100 and only used by lossy formats.
    /// `scale` (pixels per point) is written as DPI (72 x scale) so apps show the right size.
    public static func data(for image: CGImage, format: ImageFormat, quality: Int = 90,
                            scale: CGFloat = 1) throws -> Data {
        let source = format.supportsAlpha ? image : flattened(image) ?? image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ScreenshotProError.writeFailed("\(format.displayName) is not supported on this Mac")
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * max(scale, 1),
            kCGImagePropertyDPIHeight: 72 * max(scale, 1),
        ]
        if format.supportsQuality {
            props[kCGImageDestinationLossyCompressionQuality] = Double(min(max(quality, 0), 100)) / 100
        }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenshotProError.writeFailed("encoding \(format.displayName) failed")
        }
        return data as Data
    }

    /// Writes atomically to `url`, creating the parent folder if needed.
    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Int = 90,
                             scale: CGFloat = 1) throws {
        let data = try data(for: image, format: format, quality: quality, scale: scale)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScreenshotProError.writeFailed(error.localizedDescription)
        }
    }

    /// Loads the first image in a file, or nil.
    public static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Draws the image onto an opaque white background (for JPEG/BMP).
    public static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
