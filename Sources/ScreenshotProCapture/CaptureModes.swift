import AppKit
import ScreenshotProCore
import ScreenCaptureKit

/// What is known about the moment a capture starts (after any delay).
@MainActor
struct CaptureContext {
    /// Name of the frontmost app, the default capture title.
    let appName: String?
    /// Pointer location in Quartz global points.
    let mouse: CGPoint

    static func current() -> CaptureContext {
        CaptureContext(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            mouse: CoordinateSpace.quartzPoint(fromAppKit: NSEvent.mouseLocation,
                                               primaryHeight: CoordinateSpace.primaryDisplayHeight)
        )
    }
}

extension CaptureService {
    func performCapture(_ mode: CaptureMode, options: CaptureOptions) async throws -> Capture? {
        switch mode {
        case .clipboard: return try ImageImport.fromPasteboard(CaptureSelfTestHook.pasteboard ?? .general)
        case .file: return try await ImageImport.fromOpenPanel()
        default: break
        }

        try ensurePermission()
        if options.delay > 0 {
            guard await CountdownHUD.run(seconds: options.delay) else { return nil }
        }
        let context = CaptureContext.current()

        switch mode {
        case .region:
            return try await interactive(.region, options: options, context: context)
        case .window, .windowFromList:
            // The app lists windows itself and calls captureWindow(id:); a plain request for
            // .windowFromList falls back to picking a window in the overlay.
            return try await interactive(.window, options: options, context: context)
        case .lastRegion:
            return try await lastRegion(options: options, context: context)
        case .fullScreen:
            return try await fullScreen(options: options, context: context)
        case .allScreens:
            return try await allScreens(options: options, context: context)
        case .clipboard, .file:
            return nil
        }
    }

    func ensurePermission() throws {
        guard ScreenRecordingPermission.isGranted || ScreenRecordingPermission.probeSucceeded else {
            throw ScreenshotProError.screenRecordingPermissionDenied
        }
    }

    // MARK: Modes

    private func interactive(_ mode: OverlayState.Mode, options: CaptureOptions, context: CaptureContext,
                             frozen: [FrozenDisplay]? = nil) async throws -> Capture? {
        let displays: [FrozenDisplay]
        if let frozen {
            displays = frozen
        } else {
            displays = try await ScreenCaptureEngine.freezeDisplays(includeCursor: options.includeCursor)
        }
        // Window list at the frozen moment, before our overlay exists.
        let windows = WindowHitTesting.selectable(WindowHitTesting.onScreenWindows(), excludingPID: getpid())
        let overlay = SelectionOverlay(displays: displays, windows: windows, mode: mode, options: options)

        switch await overlay.run() {
        case .cancelled:
            return nil
        case .region(let rect, let window):
            let (image, scale) = try compose(rect, from: displays)
            return Capture(image: image, details: CaptureDetails(
                mode: .region, title: window?.displayTitle ?? context.appName,
                appName: window?.ownerName ?? context.appName, screenRect: rect, scale: scale))
        case .window(let window):
            return try await captureLive(window, options: options, fallback: displays)
        }
    }

    private func lastRegion(options: CaptureOptions, context: CaptureContext) async throws -> Capture? {
        let displays = try await ScreenCaptureEngine.freezeDisplays(includeCursor: options.includeCursor)
        let layouts = displays.map(\.layout)
        guard let region = options.lastRegion?.standardized,
              DisplayComposition.plan(rect: region, displays: layouts) != nil else {
            return try await interactive(.region, options: options, context: context, frozen: displays)
        }
        // Keep only the part that is still on screen.
        let rect = region.intersection(DisplayComposition.bounds(of: layouts))
        let (image, scale) = try compose(rect, from: displays)
        return Capture(image: image, details: CaptureDetails(
            mode: .lastRegion, title: context.appName, appName: context.appName, screenRect: rect, scale: scale))
    }

    private func fullScreen(options: CaptureOptions, context: CaptureContext) async throws -> Capture? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let found = CGGetDisplaysWithPoint(context.mouse, 1, &id, &count) == .success && count > 0
        let target = found ? id : CGMainDisplayID()
        let displays: [FrozenDisplay]
        do {
            displays = try await ScreenCaptureEngine.freezeDisplays(only: [target], includeCursor: options.includeCursor)
        } catch ScreenshotProError.noDisplays {
            // The display under the pointer is not shareable (rare): fall back to the first one.
            displays = Array(try await ScreenCaptureEngine.freezeDisplays(includeCursor: options.includeCursor).prefix(1))
        }
        guard let display = displays.first else { throw ScreenshotProError.noDisplays }
        return Capture(image: display.image, details: CaptureDetails(
            mode: .fullScreen, title: context.appName, appName: context.appName,
            screenRect: display.frame, scale: display.scale))
    }

    private func allScreens(options: CaptureOptions, context: CaptureContext) async throws -> Capture? {
        let displays = try await ScreenCaptureEngine.freezeDisplays(includeCursor: options.includeCursor)
        let rect = DisplayComposition.bounds(of: displays.map(\.layout))
        let (image, scale) = try compose(rect, from: displays)
        return Capture(image: image, details: CaptureDetails(
            mode: .allScreens, title: context.appName, appName: context.appName, screenRect: rect, scale: scale))
    }

    // MARK: Windows

    func capturableWindows() async throws -> [CapturableWindow] {
        try ensurePermission()
        let content = try await ScreenCaptureEngine.shareableContent()
        var byID: [CGWindowID: SCWindow] = [:]
        var infos: [WindowInfo] = []
        for window in content.windows where window.isOnScreen {
            byID[window.windowID] = window
            infos.append(WindowInfo(id: window.windowID, processID: window.owningApplication?.processID ?? 0,
                                    layer: window.windowLayer, alpha: 1, bounds: window.frame,
                                    title: window.title, ownerName: window.owningApplication?.applicationName))
        }
        let listed = WindowHitTesting.listable(infos, excludingPID: getpid())
        let ordered = WindowHitTesting.sorted(listed, byZOrder: WindowHitTesting.onScreenWindows().map(\.id), id: \.id)
        return ordered.map { info in
            let bundle = byID[info.id]?.owningApplication?.bundleIdentifier
            return CapturableWindow(windowID: info.id, title: info.title ?? "", appName: info.ownerName ?? "",
                                    bundleIdentifier: bundle?.isEmpty == false ? bundle : nil,
                                    processID: info.processID, frame: info.bounds)
        }
    }

    func performWindowCapture(id: CGWindowID, options: CaptureOptions) async throws -> Capture {
        try ensurePermission()
        if options.delay > 0 {
            // The contract has no "cancelled" result here, so the countdown cannot be cancelled.
            _ = await CountdownHUD.run(seconds: options.delay, cancellable: false)
        }
        guard let window = try await ScreenCaptureEngine.shareableWindow(id: id) else {
            throw ScreenshotProError.captureFailed("the window is no longer available")
        }
        return try await capture(window, mode: .windowFromList, options: options)
    }

    /// Captures a window picked in the overlay by itself. If it vanished meanwhile, crops it
    /// from the frozen displays instead.
    private func captureLive(_ window: WindowInfo, options: CaptureOptions, fallback displays: [FrozenDisplay]) async throws -> Capture {
        do {
            if let scWindow = try await ScreenCaptureEngine.shareableWindow(id: window.id) {
                return try await capture(scWindow, mode: .window, options: options)
            }
        } catch ScreenshotProError.screenRecordingPermissionDenied {
            throw ScreenshotProError.screenRecordingPermissionDenied
        } catch {
            // Fall back to the frozen picture below.
        }
        let rect = window.bounds.intersection(DisplayComposition.bounds(of: displays.map(\.layout)))
        let (image, scale) = try compose(rect, from: displays)
        return Capture(image: image, details: CaptureDetails(
            mode: .window, title: window.displayTitle, appName: window.ownerName, screenRect: rect, scale: scale))
    }

    private func capture(_ window: SCWindow, mode: CaptureMode, options: CaptureOptions) async throws -> Capture {
        let (image, scale) = try await ScreenCaptureEngine.captureWindow(window, includeCursor: options.includeCursor,
                                                                         includeShadow: options.windowShadow)
        let appName = window.owningApplication?.applicationName
        let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
        return Capture(image: image, details: CaptureDetails(
            mode: mode, title: title, appName: appName, screenRect: window.frame, scale: scale))
    }

    // MARK: Helpers

    private func compose(_ rect: CGRect, from displays: [FrozenDisplay]) throws -> (CGImage, CGFloat) {
        guard let plan = DisplayComposition.plan(rect: rect, displays: displays.map(\.layout)),
              let image = DisplayComposition.render(plan, images: displays.map(\.image)) else {
            throw ScreenshotProError.captureFailed("the selected area is not on any display")
        }
        return (image, plan.scale)
    }
}

extension ScreenRecordingPermission {
    /// Set when the last ScreenCaptureKit probe worked: a grant made while running may not show
    /// in `CGPreflightScreenCaptureAccess()` until relaunch (03 section 2.6.3).
    static var probeSucceeded = false
    /// `CGRequestScreenCaptureAccess()` is called at most once per run.
    static var requestedThisRun = false

    static func probe() async -> Bool {
        if !isGranted, !requestedThisRun {
            requestedThisRun = true
            _ = CGRequestScreenCaptureAccess()
        }
        let works = await withTimeout(seconds: 3) {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                return true
            } catch {
                return false
            }
        } ?? false
        probeSucceeded = works
        return works
    }
}

public extension CapturableWindow {
    /// The owning app's icon, for menus.
    @MainActor var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: processID)?.icon
    }
}
