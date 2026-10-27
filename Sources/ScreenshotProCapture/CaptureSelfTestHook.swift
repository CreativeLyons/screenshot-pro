import AppKit

/// TEST-ONLY. Lets the app's self-test mode (launch with SCREENSHOTPRO_SELFTEST_DIR set, see the
/// app's SelfTest.swift) drive captures without touching anything outside the app. The app never
/// calls this in normal use. Captures still run through `CaptureService` and the real overlay.
@MainActor
public enum CaptureSelfTestHook {
    /// When set, `.clipboard` captures read this pasteboard instead of the general one, so a
    /// test can use a private pasteboard and leave the user's clipboard alone.
    public static var pasteboard: NSPasteboard?

    /// When set, captures freeze synthetic display images made by this function (Quartz frame
    /// in points, pixels per point) instead of the screen: one per `NSScreen`. Lets the self-test
    /// drive the overlay and the composition when ScreenCaptureKit has no active display (screen
    /// locked or asleep). Results built this way are not screenshots.
    public static var syntheticDisplayImage: ((_ frame: CGRect, _ scale: CGFloat) -> CGImage?)?

    /// The selection overlay's panels (one per display) while an overlay is up, else empty.
    /// Tests deliver synthetic mouse and key events to them with `NSWindow.sendEvent`.
    public static var overlayPanels: [NSWindow] { SelectionOverlay.active?.panelWindows ?? [] }

    /// True while an overlay is up and draws the magnifier.
    public static var magnifierShown: Bool { SelectionOverlay.active?.isMagnifierShown ?? false }

    /// Closes a visible selection overlay as Esc would (its capture returns nil). For watchdogs.
    public static func cancelOverlay() {
        SelectionOverlay.active?.cancel()
    }
}
