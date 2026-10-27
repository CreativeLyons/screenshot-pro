import AppKit
import ScreenshotProCore
import ScreenshotProOutput

// PUBLIC CONTRACT (owned by the architecture, see docs/ARCHITECTURE.md).
// Implementations may add API but must not change these signatures.

/// Opens captures in annotation editor windows.
@MainActor
public enum Editor {
    /// Opens a new editor window for `capture` and brings it forward.
    public static func open(_ capture: Capture) {
        openWindow(for: capture)
    }

    /// Number of open editor windows (the app uses this to decide whether to show in the Dock).
    public static var openWindowCount: Int { controllers.count }
}

/// The "Open in editor" destination (id `DestinationID.editor`).
@MainActor
public final class EditorDestination: CaptureDestination {
    public let id = DestinationID.editor
    public let displayName = "Open in Editor"
    public let symbolName = "pencil.and.outline"
    public let priority = 0
    public let isEditor = true

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        Editor.open(capture)
        return .exported(url: nil, message: "Opened in the editor")
    }
}
