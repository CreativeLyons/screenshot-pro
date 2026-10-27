import AppKit
import Carbon.HIToolbox
import CoreText
import ScreenshotProCapture
import ScreenshotProCore
import ImageIO
import UniformTypeIdentifiers

/// The self-test's capture section: real screenshots through `CaptureService` (the app's own
/// Screen Recording grant), saved as PNGs with their sizes in report.txt.
///
/// The selection overlay is driven end to end with synthetic `NSEvent`s handed to its panels
/// with `NSWindow.sendEvent`, inside this process only: nothing is posted to the system event
/// stream, no other app is activated or clicked, and the user's clipboard is not touched (the
/// clipboard capture reads a private pasteboard through `CaptureSelfTestHook`). Every overlay
/// run has a watchdog that closes the overlay if it is still up.
extension SelfTestTour {
    /// Seconds an overlay may stay up before the watchdog cancels it.
    private static let overlayTimeout: Double = 8

    /// SCREENSHOTPRO_SELFTEST_SYNTHETIC=1 also runs the synthetic-display steps when the screen is live.
    static let syntheticKey = "SCREENSHOTPRO_SELFTEST_SYNTHETIC"
    /// Prefix for file names of the current pass ("" for real captures).
    private static var namePrefix = ""

    func runCaptureSteps() async {
        report.line("CAPTURE SECTION")
        for (i, screen) in NSScreen.screens.enumerated() {
            report.line("    display \(i): \(screen.localizedName), Quartz frame \(Self.quartzFrame(of: screen)), scale \(screen.backingScaleFactor)")
        }
        let blocked = Self.screenBlockReason
        report.line("    live screen: \(blocked.map { "NO (\($0))" } ?? "yes")")
        await step(11, "List windows and capture one window by id", needsScreen: true, captureWindowStep)
        await step(12, "Full screen and all screens", needsScreen: true, captureScreensStep)
        await step(13, "Last region", needsScreen: true, captureLastRegionStep)
        await step(14, "Region drag through the overlay", needsScreen: true, captureRegionDragStep)
        await step(15, "Overlay: Esc, click on a window, Space for window mode", needsScreen: true, captureOverlayModesStep)
        await step(16, "Clipboard capture from a private pasteboard", captureClipboardStep)

        if blocked != nil || ProcessInfo.processInfo.environment[Self.syntheticKey] == "1" {
            // The same capture paths on generated display images: verifies the overlay, the
            // selection math and the composition, not ScreenCaptureKit.
            report.line("SYNTHETIC DISPLAYS: the next steps freeze generated test images instead of the screen (CaptureSelfTestHook.syntheticDisplayImage); their results are not screenshots")
            CaptureSelfTestHook.syntheticDisplayImage = { frame, scale in Self.makeSyntheticDisplay(frame: frame, scale: scale) }
            Self.namePrefix = "synthetic-"
            await step(18, "SYNTHETIC displays: full screen and all screens", captureScreensStep)
            await step(19, "SYNTHETIC displays: last region", captureLastRegionStep)
            await step(20, "SYNTHETIC displays: region drag through the overlay", captureRegionDragStep)
            await step(21, "SYNTHETIC displays: Esc, click on a window, Space for window mode", captureOverlayModesStep)
            CaptureSelfTestHook.syntheticDisplayImage = nil
            Self.namePrefix = ""
        }
        await step(22, "Nothing left on screen", captureCleanupStep)
    }

    /// A display-sized test pattern: gradient, 50 pt grid with coordinates, colored blocks and
    /// a caption, at `scale` pixels per point (top-left origin like a screenshot).
    static func makeSyntheticDisplay(frame: CGRect, scale: CGFloat) -> CGImage? {
        let w = Int(frame.width * scale), h = Int(frame.height * scale)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Work in points with y down.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let colors = [CGColor(srgbRed: 0.20, green: 0.25, blue: 0.45, alpha: 1),
                      CGColor(srgbRed: 0.55, green: 0.75, blue: 0.70, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: frame.width, y: frame.height), options: [])
        }
        let blocks: [(CGRect, CGColor)] = [
            (CGRect(x: 340, y: 240, width: 160, height: 100), CGColor(srgbRed: 0.9, green: 0.25, blue: 0.2, alpha: 1)),
            (CGRect(x: 560, y: 360, width: 160, height: 100), CGColor(srgbRed: 0.95, green: 0.8, blue: 0.15, alpha: 1)),
            (CGRect(x: 900, y: 150, width: 220, height: 160), CGColor(srgbRed: 0.25, green: 0.7, blue: 0.35, alpha: 1)),
        ]
        for (r, c) in blocks {
            ctx.setFillColor(c)
            ctx.fill(r)
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(1 / scale)
        for x in stride(from: 0, through: frame.width, by: 50) {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: frame.height))
        }
        for y in stride(from: 0, through: frame.height, by: 50) {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: frame.width, y: y))
        }
        ctx.strokePath()
        func text(_ string: String, _ size: CGFloat, at p: CGPoint) {
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.9),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        for x in stride(from: 100, to: frame.width, by: 100) {
            for y in stride(from: 100, to: frame.height, by: 100) {
                text("\(Int(frame.minX + x)),\(Int(frame.minY + y))", 9, at: CGPoint(x: x + 2, y: y - 3))
            }
        }
        text("Synthetic display \(Int(frame.width))x\(Int(frame.height)) pt at \(scale)x (not a screenshot)", 22,
             at: CGPoint(x: 60, y: 80))
        return ctx.makeImage()
    }

    // MARK: Helpers

    private final class CaptureBox {
        var done = false
        var capture: Capture?
        var error: Error?
    }

    static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    static func quartzFrame(of screen: NSScreen) -> CGRect {
        quartzRect(fromAppKit: screen.frame)
    }

    static func quartzRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The main display (Quartz origin at its top-left corner).
    static var mainScreen: NSScreen? { NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first }

    static func describe(_ c: Capture) -> String {
        let d = c.details
        let r = d.screenRect
        return "\(c.image.width)x\(c.image.height) px, scale \(d.scale), mode \(d.mode.rawValue), "
            + "title \"\(d.title ?? "")\", app \"\(d.appName ?? "")\", "
            + "screenRect (\(r.minX), \(r.minY), \(r.width), \(r.height)) pt"
    }

    /// Saves a capture's image and checks it is not one flat color.
    @discardableResult
    private func save(_ c: Capture, _ name: String, _ o: Outcome) -> URL? {
        guard let url = writePNG(c.image, "capture-" + Self.namePrefix + name) else {
            o.check(false, "could not write capture-\(Self.namePrefix)\(name).png")
            return nil
        }
        o.note("saved \(url.lastPathComponent): \(Self.describe(c))")
        return url
    }

    private static func expectedPixels(_ rect: CGRect, scale: CGFloat) -> (Int, Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    private static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Number of distinct colors over every pixel, stopping at `limit`.
    private static func distinctColors(_ image: CGImage, limit: Int = 64) -> Int {
        guard let px = Pixels(image) else { return 0 }
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: px.height, by: 1) {
            for x in stride(from: 0, to: px.width, by: 1) {
                seen.insert(px.rgba(x: x, y: y))
                if seen.count >= limit { return seen.count }
            }
        }
        return seen.count
    }

    /// Runs a capture in a task so the step can drive the overlay meanwhile.
    private func beginCapture(_ mode: CaptureMode, options: CaptureOptions = CaptureOptions()) -> CaptureBox {
        let box = CaptureBox()
        Task { @MainActor in
            do {
                box.capture = try await CaptureService.shared.capture(mode, options: options)
            } catch {
                box.error = error
            }
            box.done = true
        }
        return box
    }

    /// Waits for the overlay to appear and arm (clicks right after showing are ignored).
    private func waitForOverlay(_ o: Outcome) async -> Bool {
        let shown = await wait(5) { !CaptureSelfTestHook.overlayPanels.isEmpty }
        o.check(shown, "overlay appeared with \(CaptureSelfTestHook.overlayPanels.count) panel(s)")
        await settle(450)
        return shown
    }

    /// Waits for the capture to finish; the watchdog cancels an overlay that is still up.
    private func finishCapture(_ box: CaptureBox, _ what: String, _ o: Outcome) async {
        if await wait(Self.overlayTimeout, { box.done }) { return }
        o.check(false, "watchdog: \(what) still running after \(Int(Self.overlayTimeout)) s, overlay cancelled")
        CaptureSelfTestHook.cancelOverlay()
        _ = await wait(3) { box.done }
    }

    private func panel(at q: CGPoint) -> NSWindow? {
        CaptureSelfTestHook.overlayPanels.first { Self.quartzRect(fromAppKit: $0.frame).contains(q) }
    }

    /// Delivers a synthetic mouse event at Quartz point `q` to the overlay panel under it.
    private func mouse(_ type: NSEvent.EventType, at q: CGPoint) {
        guard let panel = panel(at: q) else { return }
        let appKit = CGPoint(x: q.x, y: Self.primaryHeight - q.y)
        let local = CGPoint(x: appKit.x - panel.frame.minX, y: appKit.y - panel.frame.minY)
        let pressed = type == .leftMouseDown || type == .leftMouseDragged
        guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: type == .mouseMoved ? 0 : 1, pressure: pressed ? 1 : 0)
        else { return }
        // Mouse-moved events go to the first responder; the overlay makes its view that.
        if type == .mouseMoved, panel.firstResponder !== panel.contentView {
            panel.makeFirstResponder(panel.contentView)
        }
        panel.sendEvent(event)
    }

    /// Delivers a synthetic modifier change (Shift pressed or released) to the overlay panel under `q`.
    private func shift(_ down: Bool, at q: CGPoint) {
        guard let panel = panel(at: q) else { return }
        if panel.firstResponder !== panel.contentView { panel.makeFirstResponder(panel.contentView) }
        guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? [.shift] : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false,
                                           keyCode: UInt16(kVK_Shift)) else { return }
        panel.sendEvent(event)
    }

    /// Delivers a synthetic key down to the overlay panel under `q`.
    private func key(_ keyCode: Int, _ characters: String, at q: CGPoint) {
        guard let panel = panel(at: q) else { return }
        if panel.firstResponder !== panel.contentView { panel.makeFirstResponder(panel.contentView) }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false,
                                           keyCode: UInt16(keyCode)) else { return }
        panel.sendEvent(event)
    }

    /// Renders an overlay panel's own view to a PNG (cacheDisplay; the layer tree when that
    /// comes out blank, as it can for layer-hosting views). With `focus` (Quartz points) also
    /// writes a crop around it at full resolution.
    private func snapshotOverlay(_ panel: NSWindow, _ name: String, focus: CGRect?, _ o: Outcome) {
        guard let view = panel.contentView else {
            o.check(false, "overlay snapshot \(name): no content view")
            return
        }
        var image: CGImage?
        var method = "cacheDisplay"
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image = rep.cgImage
        }
        if image.map(Self.sampledColorCount) ?? 0 <= 3, let layer = view.layer {
            method = "CALayer.render (cacheDisplay was blank)"
            let scale = panel.backingScaleFactor
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                image = ctx.makeImage()
            }
        }
        guard let image, let url = writePNG(image, "overlay-" + Self.namePrefix + name) else {
            o.check(false, "overlay snapshot \(name) failed")
            return
        }
        let colors = Self.sampledColorCount(image)
        o.check(colors > 3, "overlay snapshot \(url.lastPathComponent) \(image.width)x\(image.height) px via \(method), \(colors) sampled colors")
        guard let focus else { return }
        // Quartz -> image pixels (the image's row 0 is the panel's top edge).
        let frame = Self.quartzRect(fromAppKit: panel.frame)
        let s = CGFloat(image.width) / max(frame.width, 1)
        let crop = focus.insetBy(dx: -230, dy: -150).intersection(frame)
        let px = CGRect(x: (crop.minX - frame.minX) * s, y: (crop.minY - frame.minY) * s,
                        width: crop.width * s, height: crop.height * s).integral
        if let part = image.cropping(to: px), let partURL = writePNG(part, "overlay-\(Self.namePrefix)\(name)-detail") {
            o.note("detail crop \(partURL.lastPathComponent) \(part.width)x\(part.height) px around \(focus)")
        }
    }

    /// The front-most window the overlay would select at Quartz point `p` (same rules as the
    /// overlay: normal layer, visible, at least 20 pt, not ours).
    private static func windowUnder(_ p: CGPoint) -> (id: CGWindowID, bounds: CGRect, title: String)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for entry in list {
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard layer == 0, alpha > 0.01, pid != getpid(), bounds.width >= 20, bounds.height >= 20,
                  bounds.contains(p) else { continue }
            let name = entry[kCGWindowName as String] as? String ?? ""
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            return (number, bounds, name.isEmpty ? owner : name)
        }
        return nil
    }

    /// A point on the main display over another app's window, for click and window-mode tests:
    /// the center of the front-most such window that is mostly on the main display.
    private func clickTarget() async -> CGPoint? {
        guard let main = Self.mainScreen else { return nil }
        let display = Self.quartzFrame(of: main)
        guard let windows = try? await CaptureService.shared.listWindows() else { return nil }
        for w in windows where w.frame.width >= 200 && w.frame.height >= 150 {
            let visible = w.frame.intersection(display)
            guard !visible.isNull, visible.width >= 150, visible.height >= 100 else { continue }
            let p = CGPoint(x: visible.midX.rounded(), y: visible.midY.rounded())
            if Self.windowUnder(p)?.id == w.windowID { return p }
        }
        return nil
    }

    // MARK: Steps

    private func captureWindowStep(_ o: Outcome) async throws {
        let windows = try await CaptureService.shared.listWindows()
        o.check(!windows.isEmpty, "listWindows returned \(windows.count) windows")
        for w in windows.prefix(6) {
            o.note("window \(w.windowID): \"\(w.title.prefix(50))\" | \(w.appName) | \(w.bundleIdentifier ?? "-") | frame \(w.frame)")
        }
        o.check(!windows.contains { $0.processID == getpid() }, "none of our own windows is listed")
        let candidates = windows.filter { $0.processID != getpid() && $0.frame.width >= 200 && $0.frame.height >= 150 }
        guard let pick = candidates.first(where: { $0.bundleIdentifier == "com.apple.finder" }) ?? candidates.first else {
            o.note("SKIPPED captureWindow: no visible window of another app is large enough")
            return
        }
        o.note("capturing window \(pick.windowID) \"\(pick.title.prefix(50))\" of \(pick.appName)")
        let c = try await CaptureService.shared.captureWindow(id: pick.windowID, options: CaptureOptions(windowShadow: false))
        save(c, "window", o)
        let (ew, eh) = Self.expectedPixels(pick.frame, scale: c.details.scale)
        o.check(abs(c.image.width - ew) <= 2 && abs(c.image.height - eh) <= 2,
                "window image \(c.image.width)x\(c.image.height) px = frame \(Int(pick.frame.width))x\(Int(pick.frame.height)) pt x \(c.details.scale) (expected \(ew)x\(eh))")
        o.check(c.details.mode == .windowFromList, "mode is windowFromList")
        o.check(Self.close(c.details.screenRect, pick.frame, tolerance: 1), "screenRect is the window frame")
        let colors = Self.distinctColors(c.image)
        o.check(colors > 1, "window image has \(colors)\(colors >= 64 ? "+" : "") colors")
    }

    private func captureScreensStep(_ o: Outcome) async throws {
        guard let full = try await CaptureService.shared.capture(.fullScreen, options: CaptureOptions()) else {
            throw StepError(message: "full screen capture returned nil")
        }
        save(full, "full-screen", o)
        let rect = full.details.screenRect
        let screen = NSScreen.screens.first { Self.close(Self.quartzFrame(of: $0), rect, tolerance: 1) }
        o.check(screen != nil, "screenRect \(rect) is a display's frame")
        if let screen {
            o.check(full.details.scale == screen.backingScaleFactor, "scale \(full.details.scale) = display backing scale \(screen.backingScaleFactor)")
        }
        var (ew, eh) = Self.expectedPixels(rect, scale: full.details.scale)
        o.check(full.image.width == ew && full.image.height == eh,
                "full screen \(full.image.width)x\(full.image.height) px = \(Int(rect.width))x\(Int(rect.height)) pt x \(full.details.scale)")
        o.check(Self.distinctColors(full.image) > 1, "full screen image is not one flat color")

        guard let all = try await CaptureService.shared.capture(.allScreens, options: CaptureOptions()) else {
            throw StepError(message: "all screens capture returned nil")
        }
        save(all, "all-screens", o)
        let union = NSScreen.screens.map(Self.quartzFrame(of:)).reduce(CGRect.null) { $0.union($1) }
        o.check(Self.close(all.details.screenRect, union, tolerance: 1), "screenRect \(all.details.screenRect) = union of \(NSScreen.screens.count) display(s) \(union)")
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
        o.check(all.details.scale == maxScale, "scale \(all.details.scale) = highest display scale \(maxScale)")
        (ew, eh) = Self.expectedPixels(all.details.screenRect, scale: all.details.scale)
        o.check(all.image.width == ew && all.image.height == eh,
                "all screens \(all.image.width)x\(all.image.height) px = \(Int(union.width))x\(Int(union.height)) pt x \(all.details.scale)")
    }

    private func captureLastRegionStep(_ o: Outcome) async throws {
        let region = CGRect(x: 100, y: 100, width: 640, height: 400)
        guard let main = Self.mainScreen, Self.quartzFrame(of: main).contains(region) else {
            throw StepError(message: "the main display does not contain \(region)")
        }
        guard let c = try await CaptureService.shared.capture(.lastRegion, options: CaptureOptions(lastRegion: region)) else {
            throw StepError(message: "last region capture returned nil")
        }
        save(c, "last-region", o)
        o.check(c.details.mode == .lastRegion, "mode is lastRegion")
        o.check(Self.close(c.details.screenRect, region), "screenRect \(c.details.screenRect) = \(region)")
        o.check(c.details.scale == main.backingScaleFactor, "scale \(c.details.scale) = main display scale")
        let (ew, eh) = Self.expectedPixels(region, scale: main.backingScaleFactor)
        o.check(c.image.width == ew && c.image.height == eh, "last region \(c.image.width)x\(c.image.height) px (expected \(ew)x\(eh))")
        let colors = Self.distinctColors(c.image)
        o.check(colors > 1, "last region is not one flat color (\(colors)\(colors >= 64 ? "+" : "") colors)")
    }

    private func captureRegionDragStep(_ o: Outcome) async throws {
        guard let main = Self.mainScreen else { throw StepError(message: "no display") }
        let scale = main.backingScaleFactor
        // The pixel under each end belongs to the selection, so ending half a point short of
        // (780, 500) selects exactly 300...780 x 200...500.
        let start = CGPoint(x: 300, y: 200)
        let end = CGPoint(x: 780 - 0.5 / scale, y: 500 - 0.5 / scale)
        let expected = CGRect(x: 300, y: 200, width: 480, height: 300)

        let box = beginCapture(.region, options: CaptureOptions(showMagnifier: false, showHints: true))
        defer { if !box.done { CaptureSelfTestHook.cancelOverlay() } }
        guard await waitForOverlay(o) else {
            await finishCapture(box, "region capture", o)
            return
        }
        guard let panel = panel(at: start) else { throw StepError(message: "no overlay panel under \(start)") }
        o.note("overlay panel frame \(panel.frame), level \(panel.level.rawValue), key \(panel.isKeyWindow)")

        mouse(.mouseMoved, at: start)
        await settle(150)
        o.check(!CaptureSelfTestHook.magnifierShown, "no magnifier until Shift is held")
        snapshotOverlay(panel, "crosshair", focus: CGRect(origin: start, size: .zero), o)
        shift(true, at: start)
        await settle(100)
        o.check(CaptureSelfTestHook.magnifierShown, "holding Shift shows the magnifier")
        snapshotOverlay(panel, "crosshair-shift-magnifier", focus: CGRect(origin: start, size: .zero), o)
        shift(false, at: start)
        await settle(100)
        o.check(!CaptureSelfTestHook.magnifierShown, "releasing Shift hides the magnifier")

        mouse(.leftMouseDown, at: start)
        let steps = 6
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            await settle(40)
        }
        await settle(150)
        o.check(!box.done, "the overlay is still up while the button is held")
        snapshotOverlay(panel, "mid-drag", focus: expected, o)
        mouse(.leftMouseUp, at: end)
        await finishCapture(box, "region capture", o)

        if let error = box.error { throw error }
        guard let c = box.capture else { throw StepError(message: "region capture returned nil") }
        save(c, "region-drag", o)
        o.check(c.details.mode == .region, "mode is region")
        o.check(Self.close(c.details.screenRect, expected), "screenRect \(c.details.screenRect) = dragged \(expected)")
        let (ew, eh) = Self.expectedPixels(expected, scale: scale)
        o.check(c.image.width == ew && c.image.height == eh, "region \(c.image.width)x\(c.image.height) px (expected \(ew)x\(eh))")
        o.check(Self.distinctColors(c.image) > 1, "region image is not one flat color")
        o.check(CaptureSelfTestHook.overlayPanels.isEmpty, "overlay closed after the drag")
    }

    private func captureOverlayModesStep(_ o: Outcome) async throws {
        guard let main = Self.mainScreen else { throw StepError(message: "no display") }
        let home = CGPoint(x: Self.quartzFrame(of: main).midX, y: Self.quartzFrame(of: main).midY)

        // Esc cancels.
        var box = beginCapture(.region)
        if await waitForOverlay(o) {
            key(kVK_Escape, "\u{1b}", at: home)
            let done = await wait(3) { box.done }
            o.check(done, "Esc closed the overlay")
        }
        await finishCapture(box, "Esc test", o)
        o.check(box.capture == nil && box.error == nil, "Esc returns no capture")
        o.check(CaptureSelfTestHook.overlayPanels.isEmpty, "no overlay panel left after Esc")

        // A right click cancels too (the escape hatch for an accidental capture).
        box = beginCapture(.region)
        if await waitForOverlay(o) {
            mouse(.mouseMoved, at: home)
            mouse(.rightMouseDown, at: home)
            let done = await wait(3) { box.done }
            o.check(done, "right click closed the overlay")
        }
        await finishCapture(box, "right click test", o)
        o.check(box.capture == nil && box.error == nil, "right click returns no capture")
        o.check(CaptureSelfTestHook.overlayPanels.isEmpty, "no overlay panel left after the right click")

        guard let target = await clickTarget(), let expectedWindow = Self.windowUnder(target) else {
            o.note("SKIPPED click and window mode tests: no other app's window on the main display")
            return
        }
        let display = NSScreen.screens.map(Self.quartzFrame(of:)).reduce(CGRect.null) { $0.union($1) }
        let expectedRect = expectedWindow.bounds.intersection(display)
        o.note("target point \(target) over window \(expectedWindow.id) \"\(expectedWindow.title.prefix(50))\" \(expectedWindow.bounds)")

        // A click without a drag selects the window under the pointer (as a region).
        box = beginCapture(.region)
        if await waitForOverlay(o) {
            mouse(.mouseMoved, at: target)
            mouse(.leftMouseDown, at: target)
            mouse(.leftMouseUp, at: target)
        }
        await finishCapture(box, "click test", o)
        if let error = box.error { throw error }
        if let c = box.capture {
            save(c, "region-click-window", o)
            o.check(c.details.mode == .region, "click result mode is region")
            o.check(Self.close(c.details.screenRect, expectedRect, tolerance: 1), "click selected the window frame \(expectedRect) (got \(c.details.screenRect))")
            let (ew, eh) = Self.expectedPixels(c.details.screenRect, scale: c.details.scale)
            o.check(c.image.width == ew && c.image.height == eh, "click capture \(c.image.width)x\(c.image.height) px = screenRect x scale")
        } else {
            o.check(false, "click without drag returned no capture")
        }

        // Space switches to window mode; a click there captures the window by itself.
        box = beginCapture(.region)
        if await waitForOverlay(o), let panel = panel(at: target) {
            key(kVK_Space, " ", at: target)
            await settle(100)
            mouse(.mouseMoved, at: target)
            await settle(150)
            snapshotOverlay(panel, "window-mode", focus: expectedRect, o)
            mouse(.leftMouseDown, at: target)
            mouse(.leftMouseUp, at: target)
        }
        await finishCapture(box, "window mode test", o)
        if let error = box.error { throw error }
        if let c = box.capture {
            save(c, "window-mode", o)
            o.check(c.details.mode == .window, "Space then click gives a window capture (mode \(c.details.mode.rawValue))")
            o.check(Self.close(c.details.screenRect, expectedWindow.bounds, tolerance: 1), "window capture frame \(c.details.screenRect) = \(expectedWindow.bounds)")
            let (ew, eh) = Self.expectedPixels(expectedWindow.bounds, scale: c.details.scale)
            o.check(abs(c.image.width - ew) <= 2 && abs(c.image.height - eh) <= 2,
                    "window capture \(c.image.width)x\(c.image.height) px (expected about \(ew)x\(eh))")
        } else {
            o.check(false, "window mode click returned no capture")
        }
        o.check(CaptureSelfTestHook.overlayPanels.isEmpty, "no overlay panel left")
    }

    private func captureClipboardStep(_ o: Outcome) async throws {
        guard let image = Self.makeTestImage() else { throw StepError(message: "could not draw the test image") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw StepError(message: "no PNG encoder")
        }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw StepError(message: "PNG encoding failed") }

        let generalCount = NSPasteboard.general.changeCount
        let pasteboard = NSPasteboard.withUniqueName()
        CaptureSelfTestHook.pasteboard = pasteboard
        defer {
            CaptureSelfTestHook.pasteboard = nil
            pasteboard.releaseGlobally()
        }
        pasteboard.clearContents()
        pasteboard.setData(data as Data, forType: .png)
        o.note("private pasteboard \(pasteboard.name.rawValue) holds a \(image.width)x\(image.height) PNG at 144 dpi")

        guard let c = try await CaptureService.shared.capture(.clipboard, options: CaptureOptions()) else {
            throw StepError(message: "clipboard capture returned nil")
        }
        save(c, "clipboard", o)
        o.check(c.details.mode == .clipboard, "mode is clipboard")
        o.check(c.image.width == 1200 && c.image.height == 800 && c.details.scale == 2,
                "clipboard image \(c.image.width)x\(c.image.height) px at scale \(c.details.scale) (expected 1200x800 at 2)")
        let cmp = Pixels.compare(image, c.image)
        o.check(cmp.equal, "pixels match the pasted image (\(cmp.detail))")
        o.check(NSPasteboard.general.changeCount == generalCount, "the general pasteboard was not touched")
    }

    private func captureCleanupStep(_ o: Outcome) async throws {
        if !CaptureSelfTestHook.overlayPanels.isEmpty { CaptureSelfTestHook.cancelOverlay() }
        await settle(300)
        o.check(CaptureSelfTestHook.overlayPanels.isEmpty, "no overlay panels")
        o.check(!CaptureService.shared.isCapturing, "no capture in progress")
        let visible = NSApp.windows.filter { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") }
        o.check(visible.isEmpty, "no visible windows left: \(visible.map { "\(type(of: $0)) \"\($0.title)\"" })")
    }
}
