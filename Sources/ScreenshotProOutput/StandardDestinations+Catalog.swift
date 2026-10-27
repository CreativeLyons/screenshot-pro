import AppKit
import ScreenshotProCore

public extension StandardDestinations {
    /// Fresh instances of every destination this module provides, in menu order.
    static func makeAll() -> [CaptureDestination] {
        [
            FileDestination(),
            SaveAsDestination(),
            ClipboardDestination(),
            PrinterDestination(),
            MailDestination(),
            ShareDestination(),
            OCRDestination(),
            OpenWithDestination(),
        ]
    }

    /// Picker shortcut letters by destination id (editor included), as in the SPEC table.
    static let shortcutKeys: [String: Character] = [
        DestinationID.editor: "E",
        DestinationID.file: "S",
        DestinationID.saveAs: "A",
        DestinationID.clipboard: "C",
        DestinationID.printer: "P",
        DestinationID.mail: "M",
        DestinationID.share: "H",
        DestinationID.ocr: "O",
        DestinationID.openWith: "V",
    ]

    /// The picker letter for a destination id, or nil when it has none.
    static func shortcutKey(for id: String) -> Character? {
        shortcutKeys[id]
    }
}

/// Small shared helpers for the destinations.
@MainActor
enum OutputSupport {
    /// An NSImage whose point size is pixels / scale, so it pastes and prints at true size.
    static func nsImage(for capture: Capture) -> NSImage {
        NSImage(cgImage: capture.image, size: capture.pointSize)
    }

    /// The expanded file name (last path component only) for temp files and save panels.
    static func baseName(for capture: Capture, settings: ScreenshotProSettings) -> String {
        let expanded = FilenamePattern.expand(settings.filenamePattern, details: capture.details,
                                              counter: settings.outputFileCounter)
        return (expanded as NSString).lastPathComponent
    }

    /// Writes the capture as a PNG into the app's temporary folder and returns its URL.
    static func writeTemporaryPNG(_ capture: Capture) throws -> URL {
        let name = baseName(for: capture, settings: SettingsStore.shared.settings)
        let url = try TemporaryFiles.makeURL(name: name, fileExtension: ImageFormat.png.fileExtension)
        try ImageEncoder.write(capture.image, to: url, format: .png, scale: capture.details.scale)
        return url
    }

    /// Brings the accessory app forward so an app-modal panel gets keyboard focus.
    static func activateForModal() {
        NSApp.activate()
    }
}
