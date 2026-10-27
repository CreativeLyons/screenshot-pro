import AppKit
import ScreenshotProCore

/// "Copy to Clipboard": PNG and TIFF on the general pasteboard, sized in points so it pastes at
/// true size.
@MainActor
public final class ClipboardDestination: CaptureDestination {
    public let id = DestinationID.clipboard
    public let displayName = "Copy to Clipboard"
    public let symbolName = "doc.on.clipboard"
    public let priority = 30

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        try Self.copy(capture, to: .general)
        return .exported(url: nil, message: "Copied to the clipboard")
    }

    /// Replaces the contents of `pasteboard` with the capture as PNG and TIFF.
    public static func copy(_ capture: Capture, to pasteboard: NSPasteboard) throws {
        let png = try ImageEncoder.data(for: capture.image, format: .png, scale: capture.details.scale)
        let rep = NSBitmapImageRep(cgImage: capture.image)
        rep.size = capture.pointSize
        guard let tiff = rep.tiffRepresentation else {
            throw ScreenshotProError.writeFailed("could not create TIFF data for the clipboard")
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ScreenshotProError.writeFailed("the clipboard refused the image")
        }
    }
}
