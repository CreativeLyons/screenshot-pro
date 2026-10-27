import AppKit
import ScreenshotProCore
import ImageIO
import UniformTypeIdentifiers

/// Images that come from the clipboard or a file instead of the screen.
@MainActor
enum ImageImport {
    /// The best image on the pasteboard: an image file that was copied (Finder), else PNG,
    /// TIFF or any other image type, else whatever NSImage can read.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) throws -> Capture {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL])?.first,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let decoded = decode(source) {
            return capture(decoded.image, scale: decoded.scale, mode: .clipboard, title: "Clipboard")
        }

        var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in pasteboard.types ?? [] where !types.contains(type) {
            if let ut = UTType(type.rawValue), ut.conforms(to: .image) { types.append(type) }
        }
        for type in types {
            if let data = pasteboard.data(forType: type),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let decoded = decode(source) {
                return capture(decoded.image, scale: decoded.scale, mode: .clipboard, title: "Clipboard")
            }
        }

        if let nsImage = NSImage(pasteboard: pasteboard),
           let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = nsImage.size.width > 0 ? max(CGFloat(image.width) / nsImage.size.width, 1) : 1
            return capture(image, scale: scale, mode: .clipboard, title: "Clipboard")
        }
        throw ScreenshotProError.noImageOnClipboard
    }

    /// Asks for an image file. Returns nil when the panel is cancelled.
    static func fromOpenPanel() async throws -> Capture? {
        let panel = NSOpenPanel()
        panel.title = "Open Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // A menu bar app is usually inactive; bring the panel forward.
        NSApp.activate()
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return try fromFile(url)
    }

    /// Loads an image file as a capture: title is the file name without extension.
    static func fromFile(_ url: URL) throws -> Capture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let decoded = decode(source) else {
            throw ScreenshotProError.unreadableImage(url.lastPathComponent)
        }
        var result = capture(decoded.image, scale: decoded.scale, mode: .file, title: url.deletingPathExtension().lastPathComponent)
        result.details.sourceURL = url
        return result
    }

    /// First image of a source with EXIF orientation applied, plus its scale from the DPI.
    nonisolated static func decode(_ source: CGImageSource) -> (image: CGImage, scale: CGFloat)? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation != 1 {
            let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        return (image, CoordinateSpace.scale(fromDPI: dpi))
    }

    private static func capture(_ image: CGImage, scale: CGFloat, mode: CaptureMode, title: String) -> Capture {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return Capture(image: image, details: CaptureDetails(mode: mode, title: title,
                                                             screenRect: CGRect(origin: .zero, size: size), scale: scale))
    }
}
