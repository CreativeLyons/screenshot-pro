import AppKit
import ScreenshotProCapture
import ScreenshotProCore
import ScreenshotProOutput

/// Runs one capture from trigger to destinations (docs/ARCHITECTURE.md "Capture flow"):
/// permission check, capture, last-region bookkeeping, camera sound, destinations,
/// notifications and error alerts.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let store = SettingsStore.shared
    /// Covers the permission probe as well as the capture itself, so a second hotkey press
    /// while the permission prompt or overlay is up is ignored.
    private var isAcquiring = false

    private init() {}

    // MARK: Triggers

    /// Captures in `mode` (menu items and hotkeys). `.windowFromList` is handled by the menu.
    func capture(_ mode: CaptureMode) {
        Task { await run(mode: mode) { options in
            try await CaptureService.shared.capture(mode, options: options)
        } }
    }

    /// Captures one window picked from the "Capture Window from List" menu.
    func captureWindow(id: CGWindowID) {
        Task { await run(mode: .windowFromList) { options in
            try await CaptureService.shared.captureWindow(id: id, options: options)
        } }
    }

    // MARK: Flow

    private func run(mode: CaptureMode, acquire: (CaptureOptions) async throws -> Capture?) async {
        guard !isAcquiring, !CaptureService.shared.isCapturing else { return }
        isAcquiring = true

        let capture: Capture?
        do {
            if mode.needsScreenRecording, !ScreenRecordingPermission.isGranted {
                // Ask before any overlay exists: the system prompt would be hidden under it.
                guard await ScreenRecordingPermission.requestAndProbe() else {
                    isAcquiring = false
                    PermissionWindowController.shared.show()
                    return
                }
            }
            if mode == .file { NSApp.activate() }
            capture = try await acquire(makeOptions())
        } catch ScreenshotProError.screenRecordingPermissionDenied {
            isAcquiring = false
            PermissionWindowController.shared.show()
            return
        } catch {
            isAcquiring = false
            showError(error, title: "The capture failed")
            return
        }
        isAcquiring = false

        guard let capture else { return } // cancelled
        if mode.storesLastRegion, !capture.details.screenRect.isEmpty {
            store.update { $0.lastRegion = capture.details.screenRect }
        }
        if mode.needsScreenRecording, store.settings.playCameraSound {
            CameraSound.play()
        }
        if mode.needsScreenRecording {
            // Saved in the background; the picker does not wait for it.
            Task { await CaptureHistory.shared.add(capture) }
        }
        await deliver(capture)
    }

    /// Runs one destination for `capture` outside a capture (the recent screenshots strip),
    /// with the same notifications and error alerts. Nil when it failed.
    @discardableResult
    func export(_ capture: Capture, to destination: CaptureDestination, notifying: Bool = true) async -> ExportResult? {
        do {
            let result = try await destination.export(capture, context: ExportContext())
            if notifying, case .exported(let url, let message) = result {
                notify(destination: destination, url: url, message: message, capture: capture)
            }
            return result
        } catch {
            StatusHUD.shared.hide()
            showError(error, title: "\(destination.displayName) failed")
            return nil
        }
    }

    private func makeOptions() -> CaptureOptions {
        let s = store.settings
        return CaptureOptions(includeCursor: s.captureMousePointer, showMagnifier: s.alwaysShowMagnifier,
                              windowShadow: s.windowShadow, delay: s.captureDelay,
                              showHints: s.showTextHints, lastRegion: s.lastRegion)
    }

    // MARK: Destinations

    /// Sends `capture` to the chosen destinations: non-editor ones first in priority order,
    /// the editor last.
    private func deliver(_ capture: Capture) async {
        guard let destinations = await chooseDestinations(for: capture) else { return }
        for destination in destinations {
            await send(capture, to: destination)
        }
    }

    /// A recent screenshot clicked in the sidebar: back up in the capture window, and the
    /// chosen destination runs as it would right after the capture.
    func reopen(_ capture: Capture) async {
        guard let destination = await pickDestination(for: capture) else { return }
        await send(capture, to: destination)
    }

    private func send(_ capture: Capture, to destination: CaptureDestination) async {
        if destination.id == DestinationID.ocr {
            await exportText(capture, to: destination)
        } else {
            await export(capture, to: destination)
        }
    }

    /// Copy Text has no window and takes a moment: a HUD shows it reading and then the result,
    /// whatever the notification setting (a banner on top would only repeat it).
    private func exportText(_ capture: Capture, to destination: CaptureDestination) async {
        StatusHUD.shared.showProgress("Reading text...")
        guard case .exported(_, let message)? = await export(capture, to: destination, notifying: false) else {
            StatusHUD.shared.hide()
            return
        }
        let found = message != OCRDestination.noTextMessage
        StatusHUD.shared.showResult(message, symbol: found ? "checkmark.circle.fill" : "text.magnifyingglass",
                                    success: found)
    }

    /// The destinations to run, or nil when the picker was dismissed (the capture is discarded).
    private func chooseDestinations(for capture: Capture) async -> [CaptureDestination]? {
        let registry = DestinationRegistry.shared
        let settings = store.settings
        var ids: [String]

        let defaults = settings.defaultDestinations.filter { registry.destination(id: $0)?.isAvailable == true }
        if settings.askForDestination || defaults.isEmpty {
            guard let destination = await pickDestination(for: capture) else { return nil }
            ids = [destination.id]
        } else {
            ids = defaults
        }
        if settings.alwaysCopyToClipboard { ids.append(DestinationID.clipboard) }
        if settings.alwaysSaveToFolder { ids.append(DestinationID.file) }

        var seen = Set<String>()
        let chosen = ids.filter { seen.insert($0).inserted }
            .compactMap { registry.destination(id: $0) }
            .filter(\.isAvailable)
        // The registry is sorted by priority then name; keep that order, editor last.
        let ordered = registry.all.filter { d in chosen.contains { $0 === d } }
        return ordered.filter { !$0.isEditor } + ordered.filter(\.isEditor)
    }

    /// Shows the capture window and returns the chosen destination, nil when dismissed.
    /// "Always use this destination" saves it as the default and stops asking.
    private func pickDestination(for capture: Capture) async -> CaptureDestination? {
        guard let choice = await DestinationPicker.pick(for: capture, from: DestinationRegistry.shared.available) else {
            return nil
        }
        if choice.remember {
            store.update {
                $0.defaultDestinations = [choice.destination.id]
                $0.askForDestination = false
            }
        }
        return choice.destination
    }

    private func notify(destination: CaptureDestination, url: URL?, message: String, capture: Capture) {
        // Opening the editor is visible on its own; a banner for it would be noise.
        guard store.settings.showNotifications, !destination.isEditor else { return }
        let body = url?.lastPathComponent ?? capture.details.title ?? capture.details.mode.displayName
        NotificationController.shared.post(title: message, body: body, fileURL: url)
    }

    // MARK: Errors

    private func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}

private extension CaptureMode {
    /// Clipboard and file sources read existing images and need no Screen Recording grant.
    var needsScreenRecording: Bool { self != .clipboard && self != .file }

    /// Modes whose selected area becomes the new "last region".
    var storesLastRegion: Bool { self == .region || self == .window || self == .windowFromList }
}

/// The optional shutter sound after a screen capture.
@MainActor
enum CameraSound {
    private static let candidates = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
    ]

    private static let sound: NSSound? = {
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) { return sound }
        }
        return NSSound(named: "Grab")
    }()

    /// Plays the sound, or does nothing when no suitable sound exists.
    static func play() {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
