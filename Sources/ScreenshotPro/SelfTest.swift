import AppKit
import CoreText
import ScreenshotProCapture
import ScreenshotProCore
import ScreenshotProEditor
import ScreenshotProOutput
import ImageIO
import UniformTypeIdentifiers

/// Self-test mode: with SCREENSHOTPRO_SELFTEST_DIR set, the app runs a scripted tour of its own UI
/// on the main actor, photographs its own windows (rendering our own views needs no Screen
/// Recording permission), writes numbered PNGs plus report.txt into that directory and quits.
///
///     SCREENSHOTPRO_SELFTEST_DIR=/tmp/st "build/Screenshot Pro.app/Contents/MacOS/ScreenshotPro"
///
/// The capture section (SelfTest+Capture.swift) then takes real screenshots through
/// `CaptureService`, which needs the app's Screen Recording grant; it drives the selection
/// overlay with synthetic events delivered in-process only. SCREENSHOTPRO_SELFTEST_ONLY=capture
/// runs just that section.
///
/// It never posts notifications, sends mail, writes the user's clipboard or opens other apps.
/// Every UserDefaults key it changes (settings, window frames, tool defaults) is put back
/// before it quits, also when the watchdog fires; file output goes to the self-test directory.
@MainActor
enum SelfTest {
    static let environmentKey = "SCREENSHOTPRO_SELFTEST_DIR"
    /// "capture" runs only the capture section.
    static let onlyKey = "SCREENSHOTPRO_SELFTEST_ONLY"
    /// The whole tour is cut off after this many seconds.
    static let watchdogSeconds: Double = 420

    /// The output directory when self-test mode is requested.
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func start(in directory: URL, statusMenu: StatusMenuController) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = SelfTestReport(url: directory.appendingPathComponent("report.txt"))
        let defaults = DefaultsGuard()
        let seconds = watchdogSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            let restored = defaults.restore()
            // Exiting also removes any overlay panel that is still up.
            report.line("WATCHDOG: tour did not finish in \(Int(seconds)) s; restored defaults keys: \(restored)")
            exit(3)
        }
        let tour = SelfTestTour(directory: directory, report: report, defaults: defaults, statusMenu: statusMenu)
        Task { @MainActor in
            await tour.run()
            exit(tour.failures > 0 ? 1 : tour.blockedSteps > 0 ? 2 : 0)
        }
    }
}

// MARK: - Report

/// Appends lines to report.txt as they happen, so a crash still leaves the earlier results.
final class SelfTestReport: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func line(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
        try? handle.close()
    }
}

/// Snapshot of the app's UserDefaults domain; `restore` puts back every key that changed since.
final class DefaultsGuard: @unchecked Sendable {
    private let domain: String
    private let original: [String: Any]
    private let lock = NSLock()
    private var restored = false

    init() {
        domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        original = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    }

    /// Restores changed keys once; returns their names.
    @discardableResult
    func restore() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !restored else { return [] }
        restored = true
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        var changed: [String] = []
        for key in Set(original.keys).union(current.keys) {
            let before = original[key] as? NSObject
            let now = current[key] as? NSObject
            if let before, let now, before.isEqual(now) { continue }
            if before == nil && now == nil { continue }
            if let before { defaults.set(before, forKey: key) } else { defaults.removeObject(forKey: key) }
            changed.append(key)
        }
        defaults.synchronize()
        return changed.sorted()
    }
}

// MARK: - Tour

@MainActor
final class SelfTestTour {
    let directory: URL
    let report: SelfTestReport
    let defaults: DefaultsGuard
    let statusMenu: StatusMenuController
    private(set) var failures = 0
    /// Steps that need the screen but could not run (screen locked or asleep).
    private(set) var blockedSteps = 0
    private var blockedNames: [String] = []
    var snapshotIndex = 0
    /// Layout warnings already reported (each is listed once, at its first snapshot).
    private var seenWarnings: Set<String> = []

    private var capture: Capture?
    private var mainEditor: NSWindow?
    private var step2Image: CGImage?
    private var step2Count = 0

    init(directory: URL, report: SelfTestReport, defaults: DefaultsGuard, statusMenu: StatusMenuController) {
        self.directory = directory
        self.report = report
        self.defaults = defaults
        self.statusMenu = statusMenu
    }

    /// Collects the checks of one step.
    final class Outcome {
        var pass = true
        var notes: [String] = []
        func check(_ condition: Bool, _ message: String) {
            notes.append((condition ? "ok: " : "FAILED: ") + message)
            if !condition { pass = false }
        }
        func note(_ message: String) { notes.append(message) }
    }

    struct StepError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func run() async {
        let bundle = Bundle.main.bundleURL.path
        report.line("Screenshot Pro self-test")
        report.line("app: \(bundle)")
        report.line("date: \(ISO8601DateFormatter().string(from: Date()))")
        report.line("screen recording granted (preflight only): \(ScreenRecordingPermission.isGranted)")
        let only = ProcessInfo.processInfo.environment[SelfTest.onlyKey]?.lowercased() ?? ""
        let captureOnly = only == "capture"
        if !only.isEmpty && !captureOnly {
            report.line("unknown \(SelfTest.onlyKey) value \"\(only)\" (known: capture); running everything")
        }
        report.line("sections: \(captureOnly ? "capture only" : "UI tour and capture")")
        report.line("")

        SettingsStore.shared.update { s in
            s.outputFolder = directory.path
            s.filenamePattern = "selftest-export"
            s.outputFormat = .png
            s.avoidOverwrite = true
            s.copyPathAfterSave = false
            s.promptForQuality = false
            s.autoResizeLargeScreenshots = false
            s.showNotifications = false
            s.showTextHints = true
            s.expandCanvasAmount = 100
            s.historyLimit = 10
        }
        // The strip test fills a history of its own; the user's stays untouched.
        CaptureHistory.shared.use(directory: directory.appendingPathComponent("history", isDirectory: true))

        if !captureOnly {
            await step(1, "Open synthetic capture in the editor", step1)
            await step(2, "Add one element of every type", step2)
            await step(3, "Effects, then undo and redo", step3)
            await step(4, "Export through the file destination", step4)
            await step(5, "Save and reopen an element file", step5)
            await step(6, "Settings window tabs", step6)
            await step(7, "Destination picker", step7)
            await step(23, "Copy Text status HUD", step23)
            await step(8, "Permission window", step8)
            await step(9, "Status item menu", step9)
            await step(17, "Screenshot filmstrip", step17)
            await step(10, "Close all windows", step10)
        }
        await runCaptureSteps()

        let restored = defaults.restore()
        report.line("restored defaults keys: \(restored.isEmpty ? "none" : restored.joined(separator: ", "))")
        if failures > 0 {
            report.line("RESULT: FAIL (\(failures) step(s) failed\(blockedSteps > 0 ? ", \(blockedSteps) blocked" : ""))")
        } else if blockedSteps > 0 {
            report.line("RESULT: INCOMPLETE (no failures, \(blockedSteps) step(s) blocked: \(blockedNames.joined(separator: ", ")))")
        } else {
            report.line("RESULT: PASS")
        }
    }

    /// Runs one step. A failed step that `needsScreen` counts as BLOCKED instead of FAIL when
    /// the screen cannot be captured at all (locked or asleep), which is not a permission error.
    func step(_ number: Int, _ title: String, needsScreen: Bool = false, _ body: (Outcome) async throws -> Void) async {
        let outcome = Outcome()
        do {
            try await body(outcome)
        } catch ScreenshotProError.screenRecordingPermissionDenied {
            outcome.check(false, "error: SCREEN RECORDING PERMISSION DENIED for this app")
        } catch {
            outcome.check(false, "error: \(error.localizedDescription)")
        }
        var status = outcome.pass ? "PASS" : "FAIL"
        if !outcome.pass, needsScreen, let reason = Self.screenBlockReason {
            status = "BLOCKED (\(reason); not a permission error)"
            blockedSteps += 1
            blockedNames.append("\(number)")
        } else if !outcome.pass {
            failures += 1
        }
        report.line("STEP \(number) \(title): \(status)")
        for n in outcome.notes { report.line("    " + n) }
    }

    /// Why ScreenCaptureKit cannot see the screen right now, or nil when it can.
    static var screenBlockReason: String? {
        var active: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &active)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let locked = (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        guard active == 0 || locked else { return nil }
        return "screen locked: \(locked ? "yes" : "no"), active displays: \(active), main display asleep: \(CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? "yes" : "no")"
    }

    // MARK: Helpers

    func settle(_ milliseconds: Int = 300) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Waits until `condition` holds, up to `timeout` seconds.
    func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await settle(50)
        }
        return condition()
    }

    private func editor(_ window: NSWindow?) throws -> NSWindow {
        guard let window else { throw StepError(message: "no editor window") }
        return window
    }

    /// Renders `window` (title bar and toolbar included when its frame view draws them) to
    /// a numbered PNG and checks the result is not blank.
    @discardableResult
    private func snapshot(_ window: NSWindow, _ name: String, _ outcome: Outcome) -> URL? {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let view = window.contentView?.superview ?? window.contentView else {
            outcome.check(false, "snapshot \(name): window has no content view")
            return nil
        }
        let rect = view.bounds
        guard rect.width >= 1, rect.height >= 1, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
            outcome.check(false, "snapshot \(name): zero-size view \(rect.size)")
            return nil
        }
        view.cacheDisplay(in: rect, to: rep)
        snapshotIndex += 1
        let file = String(format: "%02d-%@.png", snapshotIndex, name)
        let url = directory.appendingPathComponent(file)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else {
            outcome.check(false, "snapshot \(name): could not write PNG")
            return nil
        }
        let colors = rep.cgImage.map(Self.sampledColorCount) ?? 0
        outcome.check(colors > 3, "snapshot \(file) \(Int(rect.width))x\(Int(rect.height)) pt, \(colors) sampled colors")
        for warning in Self.layoutWarnings(in: window) where seenWarnings.insert(warning).inserted {
            outcome.note("layout: " + warning)
        }
        return url
    }

    /// Distinct colors on a 24 x 24 sample grid (a blank render has one or two).
    static func sampledColorCount(_ image: CGImage) -> Int {
        guard let px = Pixels(image) else { return 0 }
        var seen = Set<UInt32>()
        for gy in 0..<24 {
            for gx in 0..<24 {
                seen.insert(px.rgba(x: (px.width - 1) * gx / 23, y: (px.height - 1) * gy / 23))
            }
        }
        return seen.count
    }

    /// Visible controls with a zero size, outside their window, or overlapping a sibling control.
    static func layoutWarnings(in window: NSWindow) -> [String] {
        guard let root = window.contentView else { return [] }
        var controls: [(NSView, CGRect)] = []
        var warnings: [String] = []
        func describe(_ v: NSView) -> String {
            var label = String(describing: type(of: v))
            if let b = v as? NSButton, !b.title.isEmpty { label += " \"\(b.title)\"" }
            if let t = v as? NSTextField, !t.stringValue.isEmpty { label += " \"\(t.stringValue.prefix(30))\"" }
            if let tip = v.toolTip, !tip.isEmpty { label += " (\(tip.prefix(30)))" }
            return label
        }
        func visit(_ v: NSView) {
            guard !v.isHidden, v.alphaValue > 0 else { return }
            if v.hasAmbiguousLayout { warnings.append("ambiguous layout: \(describe(v))") }
            if let t = v as? NSTextField, t.stringValue.isEmpty, t.placeholderString == nil { return }
            if v is NSControl {
                // Alignment rects: control frames include bezel insets that may overlap legitimately.
                let r = v.convert(v.alignmentRect(forFrame: v.bounds), to: nil)
                if !(r.width < 1 || r.height < 1), v.visibleRect.isEmpty { return }  // scrolled out of view
                if r.width < 1 || r.height < 1 {
                    warnings.append("zero size: \(describe(v)) \(r.size)")
                } else {
                    if !root.convert(root.bounds, to: nil).insetBy(dx: -1, dy: -1).contains(r) {
                        warnings.append("outside window: \(describe(v)) \(r)")
                    }
                    // Overlaps count only where both are visible (not clipped by a scroll view).
                    controls.append((v, v.convert(v.visibleRect, to: nil).intersection(r)))
                }
                return
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        for i in controls.indices {
            for j in controls.indices where j > i {
                let overlap = controls[i].1.intersection(controls[j].1)
                if !overlap.isNull, overlap.width > 2, overlap.height > 2 {
                    warnings.append("overlap: \(describe(controls[i].0)) and \(describe(controls[j].0))")
                }
            }
        }
        return warnings
    }

    /// The synthetic capture: 1200 x 800 pixels at scale 2 (600 x 400 points) with gradients,
    /// colored blocks and Core Text text.
    static func makeTestImage() -> CGImage? {
        let w = 1200, h = 800
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let colors = [CGColor(srgbRed: 0.15, green: 0.35, blue: 0.75, alpha: 1),
                      CGColor(srgbRed: 0.95, green: 0.85, blue: 0.55, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        let radial = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.7),
                      CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: radial, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: 900, y: 250), startRadius: 0,
                                   endCenter: CGPoint(x: 900, y: 250), endRadius: 260, options: [])
        }
        let blocks: [(CGRect, CGColor)] = [
            (CGRect(x: 760, y: 560, width: 160, height: 120), CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)),
            (CGRect(x: 940, y: 560, width: 160, height: 120), CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1)),
            (CGRect(x: 760, y: 420, width: 160, height: 120), CGColor(srgbRed: 0.2, green: 0.3, blue: 0.9, alpha: 1)),
            (CGRect(x: 940, y: 420, width: 160, height: 120), CGColor(srgbRed: 0.95, green: 0.8, blue: 0.1, alpha: 1)),
            (CGRect(x: 60, y: 40, width: 1080, height: 40), CGColor(gray: 0.1, alpha: 1)),
        ]
        for (r, c) in blocks {
            ctx.setFillColor(c)
            ctx.fill(r)
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(1)
        for x in stride(from: 0, through: w, by: 50) {
            ctx.move(to: CGPoint(x: CGFloat(x) + 0.5, y: 0))
            ctx.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h)))
        }
        ctx.strokePath()
        let lines: [(String, CGFloat, CGFloat)] = [
            ("Screenshot Pro self-test", 52, 690),
            ("The quick brown fox jumps over the lazy dog 0123456789", 28, 620),
            ("Synthetic capture: 1200 x 800 px at scale 2", 24, 120),
        ]
        for (text, size, y) in lines {
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            ctx.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(line, ctx)
        }
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(4)
        ctx.stroke(full.insetBy(dx: 2, dy: 2))
        return ctx.makeImage()
    }

    // MARK: Steps

    private func step1(_ o: Outcome) async throws {
        guard let image = Self.makeTestImage() else { throw StepError(message: "could not draw the test image") }
        let details = CaptureDetails(mode: .region, title: "Self-Test", appName: "Screenshot Pro",
                                     screenRect: CGRect(x: 100, y: 100, width: 600, height: 400), scale: 2)
        let capture = Capture(image: image, details: details)
        self.capture = capture
        let before = EditorSelfTestHook.windows.count
        Editor.open(capture)
        await settle(600)
        o.check(EditorSelfTestHook.windows.count == before + 1, "Editor.open added a window")
        let window = try editor(EditorSelfTestHook.windows.last)
        mainEditor = window
        o.check(window.isVisible, "editor window is visible")
        o.note("window frame \(window.frame), title \"\(window.title)\"")
        if let d = EditorSelfTestHook.documentSize(in: window) {
            o.check(d.size == CGSize(width: 1200, height: 800) && d.scale == 2, "document is 1200x800 px at scale 2")
        }
        o.check(window.toolbar?.items.isEmpty == false, "toolbar has \(window.toolbar?.items.count ?? 0) items")
        snapshot(window, "editor-open", o)
    }

    private func step2(_ o: Outcome) async throws {
        let window = try editor(mainEditor)
        let names = await EditorSelfTestHook.addSampleElements(to: window)
        o.note("added: " + names.joined(separator: ", "))
        let count = EditorSelfTestHook.elementCount(in: window) ?? 0
        o.check(count == names.count && count == 17, "document holds \(count) elements")
        o.check(window.undoManager?.canUndo == true, "adding elements is undoable")
        o.note("elements were added without any event in between (no undo group was closed by AppKit)")
        if let um = window.undoManager {
            um.undo()
            o.check(EditorSelfTestHook.elementCount(in: window) == count - 1, "one undo removes exactly one element (\(EditorSelfTestHook.elementCount(in: window) ?? -1) left)")
            um.redo()
            o.check(EditorSelfTestHook.elementCount(in: window) == count, "one redo adds it back")
            EditorSelfTestHook.selectElement(at: 6, in: window)
        }
        await settle(400)
        snapshot(window, "elements-selected", o)
        try await narrowWindowCheck(window, o)
        step2Image = EditorSelfTestHook.flattenedImage(of: window)
        step2Count = count
        o.check(step2Image != nil, "flattened image rendered")
        if let flat = step2Image, let url = writePNG(flat, "flattened-step2") { o.note("flattened: \(url.lastPathComponent)") }
    }

    /// Shrinks the editor to its minimum width with the speech bubble selected: the properties
    /// bar must wrap its controls into rows instead of clipping them.
    private func narrowWindowCheck(_ window: NSWindow, _ o: Outcome) async throws {
        let frame = window.frame
        var narrow = frame
        narrow.size.width = window.minSize.width
        window.setFrame(narrow, display: true)
        await settle(400)
        window.layoutIfNeeded()
        let clipped = Self.layoutWarnings(in: window).filter { $0.hasPrefix("outside window") || $0.hasPrefix("overlap") }
        o.check(clipped.isEmpty, "at \(Int(narrow.width)) pt wide no control is clipped or overlapping\(clipped.isEmpty ? "" : ": " + clipped.joined(separator: "; "))")
        snapshot(window, "narrow-properties-bar", o)
        window.setFrame(frame, display: true)
        await settle(300)
    }

    func writePNG(_ image: CGImage, _ name: String) -> URL? {
        snapshotIndex += 1
        let url = directory.appendingPathComponent(String(format: "%02d-%@.png", snapshotIndex, name))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private func step3(_ o: Outcome) async throws {
        let window = try editor(mainEditor)
        guard let um = window.undoManager else { throw StepError(message: "no undo manager") }
        guard let base = step2Image else { throw StepError(message: "step 2 did not produce a baseline") }
        o.note("no events are posted between effects: each action must still be its own undo step")

        // Two effects in one main-actor turn, with no event and no suspension in between.
        let beforePair = EditorSelfTestHook.flattenedImage(of: window)
        let gray = EditorSelfTestHook.performMenuItem(["Effects", "Grayscale"], in: window)
        let afterGray = EditorSelfTestHook.flattenedImage(of: window)
        let invert = EditorSelfTestHook.performMenuItem(["Effects", "Invert"], in: window)
        o.check(gray && invert, "Grayscale and Invert sent back to back")
        o.check(um.undoActionName == "Invert", "undo name after the pair is \"\(um.undoActionName)\"")
        um.undo()
        var pair = Pixels.compare(afterGray, EditorSelfTestHook.flattenedImage(of: window))
        o.check(pair.equal, "one undo reverts only Invert (\(pair.detail))")
        um.undo()
        pair = Pixels.compare(beforePair, EditorSelfTestHook.flattenedImage(of: window))
        o.check(pair.equal, "a second undo reverts Grayscale (\(pair.detail))")

        let effects: [(String, [String])] = [
            ("border", ["Effects", "Border"]),
            ("drop-shadow", ["Effects", "Drop Shadow"]),
            ("torn-edges", ["Effects", "Torn Edges"]),
            ("grayscale", ["Effects", "Grayscale"]),
            ("invert", ["Effects", "Invert"]),
            ("rotate-cw", ["Image", "Rotate Clockwise"]),
            ("resize-50", ["Image", "Resize..."]),
            ("expand-canvas", ["Image", "Expand Canvas"]),
            ("auto-crop", ["Image", "Auto Crop"]),
        ]
        var applied: [String] = []
        for (slug, path) in effects {
            let before = EditorSelfTestHook.documentSize(in: window)?.size ?? .zero
            let beforeImage = EditorSelfTestHook.flattenedImage(of: window)
            if um.groupingLevel != 0 { o.note("note: undo group open before \(slug)") }
            let sent = EditorSelfTestHook.performMenuItem(path, in: window)
            o.check(sent, "\(path.joined(separator: " > ")) menu item found, enabled and sent")
            guard sent else { continue }
            if slug == "resize-50" {
                try await driveResizeSheet(window, o)
            } else if slug == "auto-crop" {
                let shown = await wait(2) { EditorSelfTestHook.pendingCropRect(in: window) != nil }
                o.check(shown, "auto crop shows a crop rectangle \(EditorSelfTestHook.pendingCropRect(in: window).map { "\($0)" } ?? "")")
                await settle(300)
                snapshot(window, "auto-crop-pending", o)
                EditorSelfTestHook.applyPendingCrop(in: window)
            }
            await settle(400)
            let after = EditorSelfTestHook.documentSize(in: window)?.size ?? .zero
            let changed = Pixels.compare(beforeImage, EditorSelfTestHook.flattenedImage(of: window))
            o.check(!changed.equal, "\(slug): \(Int(before.width))x\(Int(before.height)) -> \(Int(after.width))x\(Int(after.height)) px, \(changed.detail), undo name \"\(um.undoActionName)\"")
            switch slug {
            case "border": o.check(after == CGSize(width: before.width + 4, height: before.height + 4), "border adds 2 px per side")
            case "rotate-cw": o.check(after == CGSize(width: before.height, height: before.width), "rotate swaps width and height")
            case "resize-50":
                o.check(abs(after.width - (before.width / 2).rounded()) <= 1 && abs(after.height - (before.height / 2).rounded()) <= 1,
                        "resize halves the size")
            case "expand-canvas": o.check(after == CGSize(width: before.width + 200, height: before.height + 200), "expand adds 100 px per side")
            case "auto-crop": o.check(after.width < before.width && after.height < before.height, "auto crop shrinks the image")
            default: break
            }
            let depth = EditorSelfTestHook.historyDepth(in: window)
            o.note("undo grouping level \(um.groupingLevel), history undo \(depth?.undo ?? -1) redo \(depth?.redo ?? -1)")
            if !changed.equal { applied.append(slug) }
            snapshot(window, "effect-\(slug)", o)
        }

        let finalImage = EditorSelfTestHook.flattenedImage(of: window)
        let n = applied.count
        var undoNames: [String] = []
        for _ in 0..<n {
            undoNames.append(um.undoActionName)
            um.undo()
            await settle(60)
            let depth = EditorSelfTestHook.historyDepth(in: window)
            let size = EditorSelfTestHook.documentSize(in: window)?.size ?? .zero
            o.note("after undo: grouping level \(um.groupingLevel) history \(depth?.undo ?? -1)/\(depth?.redo ?? -1) size \(size) elements \(EditorSelfTestHook.elementCount(in: window) ?? -1)")
        }
        o.note("undo order: " + undoNames.joined(separator: ", "))
        var cmp = Pixels.compare(base, EditorSelfTestHook.flattenedImage(of: window))
        o.check(cmp.equal, "after \(n) undos the image matches step 2 (\(cmp.detail))")
        o.check(EditorSelfTestHook.elementCount(in: window) == step2Count, "after undo the element count is \(step2Count)")
        await settle(300)
        snapshot(window, "undo-all", o)

        var redoNames: [String] = []
        for _ in 0..<n {
            redoNames.append(um.redoActionName)
            um.redo()
            await settle(60)
        }
        o.note("redo order: " + redoNames.joined(separator: ", "))
        cmp = Pixels.compare(finalImage, EditorSelfTestHook.flattenedImage(of: window))
        o.check(cmp.equal, "after \(n) redos the image matches the final effect state (\(cmp.detail))")
        o.check(!um.canRedo, "nothing left to redo")

        for _ in 0..<n {
            um.undo()
            await settle(60)
        }
        cmp = Pixels.compare(base, EditorSelfTestHook.flattenedImage(of: window))
        o.check(cmp.equal, "undo again returns to step 2 (\(cmp.detail))")
        o.check(um.canUndo, "element additions remain undoable")
    }

    /// Resize... opens a sheet: press its "50 %" preset, snapshot it, then press OK.
    private func driveResizeSheet(_ window: NSWindow, _ o: Outcome) async throws {
        let before = EditorSelfTestHook.documentSize(in: window)?.size
        guard await wait(3, { window.attachedSheet != nil }), let sheet = window.attachedSheet else {
            throw StepError(message: "Resize sheet did not appear")
        }
        await settle(300)
        guard let preset = Self.findButton("50 %", in: sheet.contentView), let ok = Self.findButton("OK", in: sheet.contentView) else {
            throw StepError(message: "Resize sheet has no 50 % or OK button")
        }
        preset.performClick(nil)
        await settle(100)
        snapshot(sheet, "resize-sheet", o)
        ok.performClick(nil)
        let done = await wait(3) { EditorSelfTestHook.documentSize(in: window)?.size != before }
        o.check(done, "Resize sheet OK resized the image")
        _ = await wait(2) { window.attachedSheet == nil }
    }

    static func tabViews(in view: NSView?) -> [NSTabView] {
        guard let view else { return [] }
        if let t = view as? NSTabView { return [t] }
        return view.subviews.flatMap { tabViews(in: $0) }
    }

    static func findButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton, b.title == title { return b }
        for v in view.subviews {
            if let found = findButton(title, in: v) { return found }
        }
        return nil
    }

    private func step4(_ o: Outcome) async throws {
        let window = try editor(mainEditor)
        guard let expected = EditorSelfTestHook.flattenedImage(of: window) else { throw StepError(message: "no image") }
        let exported = await EditorSelfTestHook.export(window, to: DestinationID.file)
        o.check(exported, "file destination reported success")
        guard let url = EditorSelfTestHook.documentURL(of: window) else { throw StepError(message: "no saved file URL") }
        o.note("saved \(url.path)")
        o.check(url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                "file is in the self-test directory")
        o.check(FileManager.default.fileExists(atPath: url.path), "file exists")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw StepError(message: "unreadable file") }
        let type = CGImageSourceGetType(source) as String? ?? "?"
        o.check(type == UTType.png.identifier, "file type is \(type)")
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let dpiW = props[kCGImagePropertyDPIWidth] as? Double ?? 0
        let dpiH = props[kCGImagePropertyDPIHeight] as? Double ?? 0
        o.check(w == expected.width && h == expected.height, "pixel size \(w)x\(h) (expected \(expected.width)x\(expected.height))")
        o.check(abs(dpiW - 144) < 0.5 && abs(dpiH - 144) < 0.5, "resolution \(dpiW) x \(dpiH) dpi (expected 144)")
        if let saved = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let cmp = Pixels.compare(expected, saved)
            o.check(cmp.equal, "file pixels match the flattened image (\(cmp.detail))")
        }
        o.note("status bar: \"\(EditorSelfTestHook.statusMessage(in: window) ?? "")\"")
        o.check(window.isDocumentEdited == false, "window is marked saved")
    }

    private func step5(_ o: Outcome) async throws {
        let window = try editor(mainEditor)
        let url = directory.appendingPathComponent("selftest." + Editor.elementFileExtension)
        try EditorSelfTestHook.saveElementFile(of: window, to: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        o.check(bytes > 0, "wrote \(url.lastPathComponent) (\(bytes) bytes)")
        let before = EditorSelfTestHook.windows.count
        try Editor.openElementFile(at: url)
        await settle(600)
        o.check(EditorSelfTestHook.windows.count == before + 1, "openElementFile opened a window")
        let reopened = try editor(EditorSelfTestHook.windows.last)
        let original = EditorSelfTestHook.elementCount(in: window) ?? -1
        let loaded = EditorSelfTestHook.elementCount(in: reopened) ?? -2
        o.check(original == loaded, "element count \(loaded) matches \(original)")
        let cmp = Pixels.compare(EditorSelfTestHook.flattenedImage(of: window), EditorSelfTestHook.flattenedImage(of: reopened))
        o.check(cmp.equal, "reopened document renders the same (\(cmp.detail))")
        o.note("reopened title \"\(reopened.title)\"")
        snapshot(reopened, "element-file-reopened", o)
    }

    private func step6(_ o: Outcome) async throws {
        let controller = SettingsWindowController.shared
        controller.show()
        await settle(800)
        guard let window = controller.window else { throw StepError(message: "no settings window") }
        o.check(window.isVisible, "settings window is visible")
        for tab in SettingsTabID.allCases {
            SettingsNavigation.shared.tab = tab
            await settle(700)
            o.note("\(tab.rawValue): window \(Int(window.frame.width))x\(Int(window.frame.height))")
            let selected = Self.tabViews(in: window.contentView).first?.selectedTabViewItem?.label
            o.check(selected == tab.rawValue.capitalized, "\(tab.rawValue) tab is selected (\(selected ?? "none"))")
            snapshot(window, "settings-\(tab.rawValue)", o)
        }
        SettingsNavigation.shared.tab = .general
        // The tab buttons draw blank in cached displays; list the tab labels instead.
        let tabs = Self.tabViews(in: window.contentView).map { t in
            t.tabViewItems.map(\.label).joined(separator: ", ") + " (selected: \(t.selectedTabViewItem?.label ?? "none"))"
        }
        o.check(tabs.contains { $0.contains("General") && $0.contains("Printing") }, "tab bar labels: \(tabs)")
        controller.close()
    }

    private func step7(_ o: Outcome) async throws {
        guard let capture else { throw StepError(message: "no test capture") }
        final class Box { var done = false; var choice: DestinationPicker.Choice? }
        let box = Box()
        let destinations = DestinationRegistry.shared.all
        Task { @MainActor in
            box.choice = await DestinationPicker.pick(for: capture, from: destinations)
            box.done = true
        }
        let appeared = await wait(3) { Self.pickerPanel != nil }
        o.check(appeared, "picker panel appeared")
        guard let panel = Self.pickerPanel else { return }
        await settle(400)
        o.note("panel frame \(panel.frame)")
        snapshot(panel, "destination-picker", o)
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        if let esc { NSApp.postEvent(esc, atStart: false) }
        let finished = await wait(3) { box.done }
        o.check(finished, "Esc dismissed the picker")
        if !finished {
            panel.performClose(nil)
            _ = await wait(2) { box.done }
        }
        o.check(box.choice == nil, "dismissing returns no destination")
        o.check(!panel.isVisible, "picker panel is gone")

        let titles = Self.buttons(in: panel.contentView).map(\.title)
        for expected in ["Copy", "Save", "Copy Text", "Edit", "More"] {
            o.check(titles.contains(expected), "preview has a \"\(expected)\" button")
        }

        // A right click on the preview dismisses it too.
        let again = Box()
        Task { @MainActor in
            again.choice = await DestinationPicker.pick(for: capture, from: destinations)
            again.done = true
        }
        guard await wait(3, { Self.pickerPanel != nil }), let second = Self.pickerPanel else {
            o.check(false, "picker reappeared")
            return
        }
        await settle(400)  // past the arming delay
        let right = NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: second.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        if let right { NSApp.postEvent(right, atStart: false) }
        let closed = await wait(3) { again.done }
        o.check(closed && again.choice == nil, "right click dismissed the picker")
        if !closed {
            second.performClose(nil)
            _ = await wait(2) { again.done }
        }
    }

    /// The HUD that Copy Text from the picker shows: a spinner while reading, then the result,
    /// which fades out by itself.
    private func step23(_ o: Outcome) async throws {
        let hud = StatusHUD.shared
        hud.showProgress("Reading text...")
        await settle(200)
        guard let panel = NSApp.windows.first(where: { $0.title == StatusHUD.title }) else {
            throw StepError(message: "no status HUD panel")
        }
        o.check(panel.isVisible && panel.ignoresMouseEvents, "HUD is up and ignores the mouse")
        o.check(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) }, "HUD \(panel.frame) is inside a screen")
        snapshot(panel, "status-hud-reading", o)
        let center = panel.frame.midX
        hud.showResult("Copied 3 lines of text", symbol: "checkmark.circle.fill")
        await settle(200)
        o.check(abs(panel.frame.midX - center) < 1, "result keeps the HUD's center (\(panel.frame.midX) vs \(center))")
        snapshot(panel, "status-hud-copied", o)
        let gone = await wait(StatusHUD.resultSeconds + 1.5) { !panel.isVisible }
        o.check(gone, "result HUD fades out by itself")
        hud.showResult(OCRDestination.noTextMessage, symbol: "text.magnifyingglass", success: false)
        await settle(200)
        snapshot(panel, "status-hud-no-text", o)
        hud.hide()
        o.check(!panel.isVisible, "hide() removes the HUD")
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }

    private func step17(_ o: Outcome) async throws {
        guard let capture else { throw StepError(message: "no test capture") }
        let history = CaptureHistory.shared
        history.clear()
        o.check(history.directory.path.hasPrefix(directory.path), "history lives in the self-test directory")
        for i in 0..<3 {
            var c = capture
            c.details.title = "Self-test \(i + 1)"
            c.details.date = Date().addingTimeInterval(Double(i - 3) * 60)
            let entry = await history.add(c)
            o.check(entry != nil, "added history entry \(i + 1)")
        }
        o.check(history.entries.count == 3, "history has \(history.entries.count) entries")
        o.check(history.entries.first?.title == "Self-test 3", "newest entry is first")
        o.check(history.entries.allSatisfy { FileManager.default.fileExists(atPath: history.fileURL(for: $0).path) },
                "every entry has its PNG file")
        o.check(history.fileURL(forImage: capture.image) != nil, "the newest capture's file is found by its image")
        if let first = history.entries.first, let loaded = history.capture(for: first) {
            o.check(loaded.image.width == capture.image.width && loaded.image.height == capture.image.height,
                    "an entry loads back at \(loaded.image.width)x\(loaded.image.height) px")
        }

        SettingsStore.shared.update {
            $0.historyStripSize = .small
            $0.historyAutoHide = false
            $0.historyStripFloatingTopLeft = nil
        }
        HistoryStrip.show()
        let shown = await wait(3) { HistoryStrip.window != nil }
        o.check(shown, "strip appeared")
        guard let strip = HistoryStrip.window else { return }
        await settle(500)
        o.note("strip frame \(strip.frame)")
        o.check(Self.historyItems(in: strip.contentView) == 3, "strip shows 3 thumbnails")
        snapshot(strip, "recent-screenshots-small", o)
        let buttons = Self.buttons(in: strip.contentView).map(\.title)
        o.check(buttons.contains("Clear All"), "sidebar has a Clear All button")

        // A click brings the screenshot back up in the capture window (Command-click copies,
        // which would write the user's clipboard, so it is left to the unit test).
        HistoryStrip.clickItem(at: 0)
        if await wait(3, { Self.pickerPanel != nil }), let picker = Self.pickerPanel {
            o.check(true, "clicking a thumbnail opens the capture window")
            await settle(400)
            let titles = Self.buttons(in: picker.contentView).map(\.title)
            o.check(titles.contains("Copy Text") && titles.contains("Edit"), "it offers every destination (\(titles))")
            snapshot(picker, "recent-screenshot-reopened", o)
            let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: picker.windowNumber, context: nil, characters: "\u{1b}",
                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            if let esc { NSApp.postEvent(esc, atStart: false) }
            let dismissed = await wait(3) { Self.pickerPanel == nil }
            o.check(dismissed, "Esc closes it again")
            if !dismissed { picker.performClose(nil) }
        } else {
            o.check(false, "clicking a thumbnail opens the capture window")
        }

        // Sizes: the sidebar width follows the setting.
        for (size, width) in [(HistoryStripSize.medium, 236.0), (.large, 324.0), (.small, 144.0)] {
            SettingsStore.shared.update { $0.historyStripSize = size }
            await settle(400)
            o.check(abs(strip.frame.width - width) < 1, "\(size.rawValue) sidebar is \(Int(strip.frame.width)) pt wide (expected \(Int(width)))")
            o.check(Self.historyItems(in: strip.contentView) == 3, "\(size.rawValue) sidebar shows 3 thumbnails")
            if size != .small { snapshot(strip, "recent-screenshots-\(size.rawValue)", o) }
        }

        // Auto-hide: tucks into the edge tab, the hotkey slides it back out.
        SettingsStore.shared.update { $0.historyAutoHide = true }
        HistoryStrip.collapse()
        let tucked = await wait(2) { HistoryStrip.tabWindow != nil && HistoryStrip.window == nil }
        o.check(tucked, "auto-hide tucks the sidebar into the edge tab")
        await settle(400)
        o.check(!strip.isVisible, "sidebar panel is hidden while tucked away")
        if let tab = HistoryStrip.tabWindow {
            o.note("tab frame \(tab.frame)")
            snapshot(tab, "recent-screenshots-tab", o)
        }
        HistoryStrip.toggle()
        let out = await wait(2) { HistoryStrip.window != nil && HistoryStrip.tabWindow == nil }
        o.check(out, "the hotkey slides the tucked-away sidebar back out")
        SettingsStore.shared.update { $0.historyAutoHide = false }
        await settle(400)
        o.check(HistoryStrip.window != nil, "turning auto-hide off keeps the sidebar open")

        // Placement: the right edge, a third of the way down; the tab follows.
        let area = (strip.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame.insetBy(dx: 10, dy: 10)
        SettingsStore.shared.update {
            $0.historyStripEdge = .right
            $0.historyStripTop = 1.0 / 3
        }
        HistoryStrip.applyPlacement()
        await settle(400)
        let wantedTop = (area.maxY - area.height / 3).rounded()
        o.check(abs(strip.frame.maxX - area.maxX) < 1, "sidebar sits on the right edge (maxX \(strip.frame.maxX), expected \(area.maxX))")
        o.check(abs(strip.frame.maxY - wantedTop) < 1, "sidebar top follows the saved height (\(strip.frame.maxY), expected \(wantedTop))")
        snapshot(strip, "recent-screenshots-right-edge", o)
        SettingsStore.shared.update { $0.historyAutoHide = true }
        HistoryStrip.collapse()
        _ = await wait(2) { HistoryStrip.tabWindow != nil }
        await settle(300)
        if let tab = HistoryStrip.tabWindow {
            o.check(abs(tab.frame.maxX - (area.maxX + 10)) < 1 && abs(tab.frame.maxY - wantedTop) < 1,
                    "tab sits on the right edge, level with the sidebar top (\(tab.frame))")
            snapshot(tab, "recent-screenshots-tab-right", o)
        } else {
            o.check(false, "tab appeared on the right edge")
        }

        // Floating: a saved corner places it out in the open; auto-hide docks it again.
        let corner = CGPoint(x: (area.midX - 72).rounded(), y: (area.maxY - area.height / 4).rounded())
        SettingsStore.shared.update {
            $0.historyAutoHide = false
            $0.historyStripFloatingTopLeft = corner
        }
        HistoryStrip.show()
        HistoryStrip.applyPlacement()
        await settle(400)
        o.check(abs(strip.frame.minX - corner.x) < 1 && abs(strip.frame.maxY - corner.y) < 1,
                "floating sidebar sits at the saved corner (\(strip.frame), expected top-left \(corner))")
        snapshot(strip, "recent-screenshots-floating", o)
        SettingsStore.shared.update { $0.historyAutoHide = true }
        await settle(250)  // docked, before auto-hide tucks it away
        let docked = SettingsStore.shared.settings.historyStripFloatingTopLeft == nil
            && (abs(strip.frame.minX - area.minX) < 1 || abs(strip.frame.maxX - area.maxX) < 1)
        o.check(docked, "turning auto-hide on docks a floating sidebar at an edge (\(strip.frame))")
        SettingsStore.shared.update {
            $0.historyAutoHide = false
            $0.historyStripEdge = .left
            $0.historyStripTop = 0
            $0.historyStripFloatingTopLeft = nil
        }
        HistoryStrip.show()
        HistoryStrip.applyPlacement()
        await settle(400)
        o.check(Self.views(in: strip.contentView).contains { $0.accessibilityRole() == .handle }, "sidebar has a grab bar")

        if let last = history.entries.last { history.remove(last.id) }
        await settle(200)
        o.check(history.entries.count == 2 && Self.historyItems(in: strip.contentView) == 2,
                "removing one updates the strip (\(Self.historyItems(in: strip.contentView)) thumbnails)")

        SettingsStore.shared.update { $0.historyLimit = 1 }
        history.trim()
        o.check(history.entries.count == 1, "lowering the limit trims to \(history.entries.count)")
        SettingsStore.shared.update { $0.historyLimit = 10 }

        history.clear()
        await settle(200)
        o.check(history.entries.isEmpty && Self.historyItems(in: strip.contentView) == 0, "Clear empties the history")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: history.directory.path)) ?? []
        o.check(leftovers.filter { $0 != "index.json" }.isEmpty, "no files left after Clear: \(leftovers)")
        snapshot(strip, "recent-screenshots-empty", o)

        HistoryStrip.close()
        await settle(200)
        o.check(HistoryStrip.window == nil && HistoryStrip.tabWindow == nil && !HistoryStrip.isOpen, "strip closed")
    }

    private static func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }

    /// Thumbnails in the strip (views labelled "Screenshot ...").
    private static func historyItems(in view: NSView?) -> Int {
        guard let view else { return 0 }
        let label = view.accessibilityLabel() ?? ""
        let own = label.hasPrefix("Screenshot ") && label != "Screenshot Pro" ? 1 : 0
        return own + view.subviews.reduce(0) { $0 + historyItems(in: $1) }
    }

    private static var pickerPanel: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == "Choose Destination" }
    }

    private func step8(_ o: Outcome) async throws {
        let controller = PermissionWindowController.shared
        controller.show()
        await settle(500)
        guard let window = controller.window else { throw StepError(message: "no permission window") }
        o.check(window.isVisible, "permission window is visible")
        o.note("window frame \(window.frame)")
        snapshot(window, "permission-window", o)
        controller.close()
        await settle(200)
        o.check(!window.isVisible, "permission window closed")
    }

    private func step9(_ o: Outcome) async throws {
        statusMenu.rebuild()
        let menu = statusMenu.statusItemMenu
        o.check(menu.items.count > 5, "status menu has \(menu.items.count) items")
        report.line("STATUS MENU (title | key | enabled)")
        Self.list(menu, depth: 1, into: report)
        if let window = mainEditor {
            report.line("EDITOR MAIN MENU, validated for the first editor window (title | key | enabled)")
            Self.list(EditorSelfTestHook.mainMenu(validatedFor: window), depth: 1, into: report)
        }
        let titles = menu.items.map(\.title)
        for expected in ["Capture Region", "Capture Window", "Capture Full Screen", "Settings...", "Quit Screenshot Pro"] {
            o.check(titles.contains(expected), "menu has \"\(expected)\"")
        }
        let settings = menu.items.first { $0.title == "Settings..." }
        o.check(settings?.keyEquivalent == "," && settings?.isEnabled == true, "Settings... is enabled with Command-,")
        o.check(menu.items.filter { $0.action != nil }.allSatisfy { $0.target != nil }, "every action item has a target")
    }

    private static func list(_ menu: NSMenu, depth: Int, into report: SelfTestReport) {
        let pad = String(repeating: "    ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem {
                report.line(pad + "---")
                continue
            }
            var line = pad + item.title + " | " + keyDescription(item) + " | " + (item.isEnabled ? "enabled" : "disabled")
            if item.isHidden { line += " | hidden" }
            if item.state == .on { line += " | checked" }
            report.line(line)
            if let sub = item.submenu { list(sub, depth: depth + 1, into: report) }
        }
    }

    static func keyDescription(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "-" }
        var parts: [String] = []
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { parts.append("Ctrl") }
        if m.contains(.option) { parts.append("Opt") }
        if m.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { parts.append("Shift") }
        if m.contains(.command) { parts.append("Cmd") }
        let name: String
        if let scalar = key.unicodeScalars.first, scalar.value >= 0xF704, scalar.value <= 0xF71B {
            name = "F\(scalar.value - 0xF704 + 1)"
        } else {
            switch key {
            case "\r": name = "Return"
            case "\u{1b}": name = "Esc"
            case " ": name = "Space"
            case "\u{8}", "\u{7f}": name = "Delete"
            default: name = key.uppercased()
            }
        }
        parts.append(name)
        return parts.joined(separator: "+")
    }

    private func step10(_ o: Outcome) async throws {
        EditorSelfTestHook.closeAllDiscardingChanges()
        SettingsWindowController.shared.close()
        PermissionWindowController.shared.close()
        await settle(500)
        o.check(Editor.openWindowCount == 0, "no editor windows left (\(Editor.openWindowCount))")
        let visible = NSApp.windows.filter { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") }
        o.check(visible.isEmpty, "no visible windows left: \(visible.map { "\(type(of: $0)) \"\($0.title)\"" })")
    }
}

// MARK: - Pixels

/// RGBA8 pixels of an image in sRGB, for comparisons.
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        bytes = buffer
    }

    func rgba(x: Int, y: Int) -> UInt32 {
        let i = (y * width + x) * 4
        return UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
    }

    /// Equal when the sizes match and no channel differs by more than 2.
    static func compare(_ a: CGImage?, _ b: CGImage?) -> (equal: Bool, detail: String) {
        guard let a, let b, let pa = Pixels(a), let pb = Pixels(b) else { return (false, "missing image") }
        guard pa.width == pb.width, pa.height == pb.height else {
            return (false, "size \(pa.width)x\(pa.height) vs \(pb.width)x\(pb.height)")
        }
        var maxDiff = 0
        var differing = 0
        for p in 0..<(pa.width * pa.height) {
            var pixelDiff = 0
            for c in 0..<4 {
                pixelDiff = max(pixelDiff, abs(Int(pa.bytes[p * 4 + c]) - Int(pb.bytes[p * 4 + c])))
            }
            if pixelDiff > 0 { differing += 1 }
            maxDiff = max(maxDiff, pixelDiff)
        }
        return (maxDiff <= 2, "\(differing) differing pixels, max channel difference \(maxDiff)")
    }
}
