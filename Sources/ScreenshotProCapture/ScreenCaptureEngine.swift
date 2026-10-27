import AppKit
import ScreenshotProCore
import ScreenCaptureKit

/// One display frozen at the start of a capture.
struct FrozenDisplay {
    let displayID: CGDirectDisplayID
    /// Frame in Quartz global points.
    let frame: CGRect
    /// Pixels per point of `image`.
    let scale: CGFloat
    let image: CGImage

    var layout: DisplayLayout { DisplayLayout(frame: frame, scale: scale) }
}

/// The ScreenCaptureKit calls: enumeration, per-display stills, single windows.
@MainActor
enum ScreenCaptureEngine {
    /// Current shareable content. Throws `screenRecordingPermissionDenied` when declined.
    static func shareableContent(onScreenOnly: Bool = true) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)
        } catch {
            throw mapError(error)
        }
    }

    /// Captures every display (or only those in `only`) at full pixel resolution, before any
    /// overlay exists, so the overlay and the result show the same frozen moment.
    static func freezeDisplays(only: Set<CGDirectDisplayID>? = nil, includeCursor: Bool) async throws -> [FrozenDisplay] {
        if let make = CaptureSelfTestHook.syntheticDisplayImage {
            return try syntheticDisplays(only: only, make)
        }
        let content = try await shareableContent()
        let displays = content.displays.filter { only?.contains($0.displayID) ?? true }
        guard !displays.isEmpty else { throw ScreenshotProError.noDisplays }

        var frozen: [FrozenDisplay] = []
        for display in displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1
            let frame = CGDisplayBounds(display.displayID)
            let size = filter.contentRect.isEmpty ? frame.size : filter.contentRect.size
            let config = SCStreamConfiguration()
            config.width = max(Int((size.width * scale).rounded()), 1)
            config.height = max(Int((size.height * scale).rounded()), 1)
            config.showsCursor = includeCursor
            config.captureResolution = .best
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                throw mapError(error)
            }
            // The image size is authoritative for the scale (it can differ from the request).
            let actualScale = frame.width > 0 ? CGFloat(image.width) / frame.width : scale
            frozen.append(FrozenDisplay(displayID: display.displayID, frame: frame, scale: actualScale, image: image))
        }
        return frozen
    }

    /// Test-only displays from `CaptureSelfTestHook.syntheticDisplayImage`, one per screen.
    private static func syntheticDisplays(only: Set<CGDirectDisplayID>?,
                                          _ make: (CGRect, CGFloat) -> CGImage?) throws -> [FrozenDisplay] {
        let h = CoordinateSpace.primaryDisplayHeight
        let frozen = NSScreen.screens.compactMap { screen -> FrozenDisplay? in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = CGDirectDisplayID(number?.uint32Value ?? 0)
            guard only?.contains(id) ?? true else { return nil }
            let frame = CoordinateSpace.quartzRect(fromAppKit: screen.frame, primaryHeight: h)
            guard let image = make(frame, screen.backingScaleFactor) else { return nil }
            return FrozenDisplay(displayID: id, frame: frame, scale: CGFloat(image.width) / max(frame.width, 1), image: image)
        }
        guard !frozen.isEmpty else { throw ScreenshotProError.noDisplays }
        return frozen
    }

    /// Captures one window by itself (covered parts included, other windows excluded).
    /// - Returns: the image and its pixels per point.
    static func captureWindow(_ window: SCWindow, includeCursor: Bool, includeShadow: Bool) async throws -> (CGImage, CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1
        do {
            if #available(macOS 26.0, *) {
                // Width and height default to the content size, which includes the shadow
                // when it is kept, so nothing is scaled down.
                let config = SCScreenshotConfiguration()
                config.showsCursor = includeCursor
                config.ignoreShadows = !includeShadow
                config.dynamicRange = .sdr
                config.displayIntent = .local
                let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
                guard let image = output.sdrImage else {
                    throw ScreenshotProError.captureFailed("the window image was empty")
                }
                return (image, scale)
            } else {
                let rect = filter.contentRect.isEmpty ? window.frame : filter.contentRect
                let config = SCStreamConfiguration()
                config.width = max(Int((rect.width * scale).rounded()), 1)
                config.height = max(Int((rect.height * scale).rounded()), 1)
                config.showsCursor = includeCursor
                config.ignoreShadowsSingleWindow = !includeShadow
                config.captureResolution = .best
                config.shouldBeOpaque = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                return (image, scale)
            }
        } catch let error as ScreenshotProError {
            throw error
        } catch {
            throw mapError(error)
        }
    }

    /// The shareable window with this id, or nil when it is gone.
    static func shareableWindow(id: CGWindowID) async throws -> SCWindow? {
        let content = try await shareableContent(onScreenOnly: false)
        return content.windows.first { $0.windowID == id }
    }

    /// SCStreamError.userDeclined becomes `screenRecordingPermissionDenied`; anything else
    /// becomes `captureFailed`.
    static func mapError(_ error: Error) -> Error {
        if let error = error as? ScreenshotProError { return error }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.Code.userDeclined.rawValue {
            ScreenRecordingPermission.probeSucceeded = false
            return ScreenshotProError.screenRecordingPermissionDenied
        }
        return ScreenshotProError.captureFailed(error.localizedDescription)
    }
}

/// Runs an async operation with a time limit. The operation is not cancelled when the limit
/// hits (ScreenCaptureKit calls cannot be); its late result is dropped.
@MainActor
func withTimeout<T>(seconds: Double, _ operation: @escaping @MainActor () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce(continuation)
        Task { @MainActor in
            let value = await operation()
            once.resume(value)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(nil)
        }
    }
}

/// Resumes a continuation at most once (main actor only).
@MainActor
private final class ResumeOnce<T> {
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
