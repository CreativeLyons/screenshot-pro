import AppKit
import ScreenshotProCore

// PUBLIC CONTRACT (owned by the architecture, see docs/ARCHITECTURE.md).
// Implementations may add API but must not change these signatures.

/// Stable ids of the standard destinations, used in settings.
public enum DestinationID {
    public static let editor = "editor"          // registered by ScreenshotProEditor
    public static let file = "file"              // save directly with the filename pattern
    public static let saveAs = "saveAs"          // save panel
    public static let clipboard = "clipboard"
    public static let printer = "printer"
    public static let mail = "mail"
    public static let share = "share"            // macOS share sheet
    public static let ocr = "ocr"                // recognized text to the clipboard
    public static let openWith = "openWith"      // open the saved file in another app
}

@MainActor
public enum StandardDestinations {
    /// Registers every destination this module provides (all ids above except editor).
    public static func registerAll(in registry: DestinationRegistry) {
        for destination in makeAll() {
            registry.register(destination)
        }
        TemporaryFiles.purgeStale()
    }
}

/// The "choose a destination" popup shown after a capture when `askForDestination` is on.
@MainActor
public enum DestinationPicker {
    public struct Choice {
        public var destination: CaptureDestination
        /// Chosen with "Always use this destination" ticked: the app saves it as the default and
        /// turns off askForDestination.
        public var remember: Bool
        public init(destination: CaptureDestination, remember: Bool) {
            self.destination = destination
            self.remember = remember
        }
    }

    /// Shows the picker with a preview of `capture` near the mouse; nil when dismissed.
    public static func pick(for capture: Capture, from destinations: [CaptureDestination]) async -> Choice? {
        await DestinationPickerController.present(for: capture, destinations: destinations)
    }
}

/// Expands filename patterns such as "Screenshot ${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss}".
public enum FilenamePattern {
    /// The expanded file name without extension, made safe for the file system.
    public static func expand(_ pattern: String, details: CaptureDetails, counter: Int = 1) -> String {
        expand(pattern, details: details, counter: counter, environment: .current)
    }

    /// A full URL in `folder` with the format's extension. With `avoidOverwrite`, appends
    /// " (2)", " (3)"... until the name is free. `${NUM}` expands to 1 here; the file
    /// destination uses the overload that takes the stored counter.
    public static func uniqueURL(folder: URL, pattern: String, details: CaptureDetails,
                                 format: ImageFormat, avoidOverwrite: Bool) -> URL {
        uniqueURL(folder: folder, pattern: pattern, details: details, format: format,
                  avoidOverwrite: avoidOverwrite, counter: 1)
    }
}
