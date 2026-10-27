import AppKit
import ScreenshotProCore

// PUBLIC CONTRACT (owned by the architecture, see docs/ARCHITECTURE.md).
// Implementations may add API but must not change these signatures.

/// Options for one capture, taken from settings by the app.
public struct CaptureOptions: Sendable {
    public var includeCursor: Bool
    /// Magnifier on from the start; otherwise it shows while Shift is held.
    public var showMagnifier: Bool
    public var windowShadow: Bool
    public var delay: TimeInterval
    public var showHints: Bool
    /// Last region in global Quartz points (top-left origin), for `.lastRegion`.
    public var lastRegion: CGRect?

    public init(includeCursor: Bool = false, showMagnifier: Bool = false, windowShadow: Bool = false,
                delay: TimeInterval = 0, showHints: Bool = true, lastRegion: CGRect? = nil) {
        self.includeCursor = includeCursor
        self.showMagnifier = showMagnifier
        self.windowShadow = windowShadow
        self.delay = delay
        self.showHints = showHints
        self.lastRegion = lastRegion
    }
}

/// Takes screenshots. One shared instance; captures never overlap.
@MainActor
public final class CaptureService {
    public static let shared = CaptureService()

    /// True while an overlay or capture is in progress (hotkeys during a capture are ignored).
    public private(set) var isCapturing = false

    public init() {}

    /// Runs a capture in the given mode.
    /// - Returns: the capture, or nil when the user cancelled (Esc, closed the list, ...).
    /// - Throws: `ScreenshotProError.screenRecordingPermissionDenied` when permission is missing,
    ///   other `ScreenshotProError`s on failure.
    /// For `.region` and `.window` the selected area is reported in `details.screenRect`;
    /// the app stores it as the new last region.
    public func capture(_ mode: CaptureMode, options: CaptureOptions) async throws -> Capture? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        return try await performCapture(mode, options: options)
    }

    /// Capturable on-screen windows, front to back (normal layer, our own windows excluded),
    /// for the "Capture Window from List" submenu.
    public func listWindows() async throws -> [CapturableWindow] {
        try await capturableWindows()
    }

    /// Loads an image file as a capture (title = file name, scale from the file's DPI), for files
    /// opened with the app from Finder.
    public func importImage(at url: URL) throws -> Capture {
        try ImageImport.fromFile(url)
    }

    /// Captures one window by id (as listed by `listWindows`).
    /// Throws `ScreenshotProError.captureFailed` while another capture is in progress.
    public func captureWindow(id: CGWindowID, options: CaptureOptions) async throws -> Capture {
        guard !isCapturing else { throw ScreenshotProError.captureFailed("another capture is in progress") }
        isCapturing = true
        defer { isCapturing = false }
        return try await performWindowCapture(id: id, options: options)
    }
}

/// A window that can be captured, for menus.
public struct CapturableWindow: Sendable, Hashable {
    public let windowID: CGWindowID
    public let title: String
    public let appName: String
    public let bundleIdentifier: String?
    public let processID: pid_t
    /// Frame in global Quartz points.
    public let frame: CGRect

    public init(windowID: CGWindowID, title: String, appName: String, bundleIdentifier: String?,
                processID: pid_t, frame: CGRect) {
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.frame = frame
    }
}

/// Screen Recording (TCC) permission helpers.
@MainActor
public enum ScreenRecordingPermission {
    /// Non-prompting check (CGPreflightScreenCaptureAccess).
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS once (shows the system prompt only the first time), then probes ScreenCaptureKit,
    /// because a grant made while running may not show in the preflight check until relaunch.
    /// Returns true when capturing works.
    public static func requestAndProbe() async -> Bool {
        await probe()
    }

    /// Opens System Settings at Privacy & Security > Screen & System Audio Recording.
    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
