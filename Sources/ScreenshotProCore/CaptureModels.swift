import CoreGraphics
import Foundation

/// How a capture was produced. Raw values are stable: they appear in settings and filenames.
public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case region
    case lastRegion
    case window
    case windowFromList
    case fullScreen      // the display under the mouse pointer
    case allScreens      // every display stitched into one image
    case clipboard       // an image taken from the clipboard
    case file            // an image opened from disk

    public var displayName: String {
        switch self {
        case .region: return "Region"
        case .lastRegion: return "Last Region"
        case .window: return "Window"
        case .windowFromList: return "Window from List"
        case .fullScreen: return "Full Screen"
        case .allScreens: return "All Screens"
        case .clipboard: return "Clipboard"
        case .file: return "File"
        }
    }
}

/// Metadata that travels with a captured image: used by filename patterns, the editor title,
/// destinations and notifications.
public struct CaptureDetails: Sendable, Equatable {
    public var mode: CaptureMode
    public var date: Date
    /// Window title for window captures, otherwise the frontmost app or a mode name.
    public var title: String?
    /// Owning application name, when known.
    public var appName: String?
    /// Captured area in global screen points, top-left origin (Core Graphics display space).
    public var screenRect: CGRect
    /// Backing pixels per point of the captured content (2 on Retina).
    public var scale: CGFloat
    /// Set when the image came from a file, so "Save" can offer the original location.
    public var sourceURL: URL?

    public init(mode: CaptureMode, date: Date = Date(), title: String? = nil, appName: String? = nil,
                screenRect: CGRect = .zero, scale: CGFloat = 1, sourceURL: URL? = nil) {
        self.mode = mode
        self.date = date
        self.title = title
        self.appName = appName
        self.screenRect = screenRect
        self.scale = scale
        self.sourceURL = sourceURL
    }
}

/// A captured (or opened) image plus its metadata.
public struct Capture: @unchecked Sendable {
    public var image: CGImage
    public var details: CaptureDetails

    public init(image: CGImage, details: CaptureDetails) {
        self.image = image
        self.details = details
    }

    /// Image size in points (pixels divided by scale), the size the editor shows at 100%.
    public var pointSize: CGSize {
        let s = max(details.scale, 1)
        return CGSize(width: CGFloat(image.width) / s, height: CGFloat(image.height) / s)
    }
}

public enum ScreenshotProError: LocalizedError, Equatable {
    case screenRecordingPermissionDenied
    case noDisplays
    case captureFailed(String)
    case noImageOnClipboard
    case unreadableImage(String)
    case writeFailed(String)
    case destinationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Screenshot Pro needs Screen Recording permission to take screenshots."
        case .noDisplays: return "No displays were found to capture."
        case .captureFailed(let why): return "The capture failed: \(why)"
        case .noImageOnClipboard: return "There is no image on the clipboard."
        case .unreadableImage(let what): return "Could not read an image from \(what)."
        case .writeFailed(let why): return "Could not save the image: \(why)"
        case .destinationUnavailable(let name): return "\(name) is not available."
        }
    }
}
