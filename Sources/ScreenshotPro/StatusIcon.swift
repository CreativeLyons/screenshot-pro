import AppKit
import ScreenshotProOutput

/// The menu bar icon: the app mark at the full menu bar icon height (18 pt), so it reads as
/// clearly as the system's own icons.
@MainActor
enum StatusIcon {
    static func make() -> NSImage {
        ScreenshotProMark.image(height: 18)
    }
}
