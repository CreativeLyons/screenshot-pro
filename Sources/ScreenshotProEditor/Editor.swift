import AppKit
import ScreenshotProCore
import ScreenshotProOutput

extension Editor {
    /// Open editor windows, kept alive until they close.
    static var controllers: [EditorWindowController] = []

    /// Called by the editor's "Settings..." menu item; the app sets it to show its Settings window.
    public static var settingsHandler: (() -> Void)?

    /// File extension of the editor's element files (".sspro": base image plus elements).
    public static let elementFileExtension = DocumentFile.fileExtension

    /// Opens an element file (".sspro") in a new editor window with its base image and
    /// editable elements. Saving with ⌘S writes back to the file.
    public static func openElementFile(at url: URL) throws {
        let doc = try DocumentFile.read(url)
        let details = CaptureDetails(mode: .file, title: url.deletingPathExtension().lastPathComponent,
                                     scale: doc.scale, sourceURL: url)
        show(EditorWindowController(document: doc, details: details, documentURL: url))
    }

    @discardableResult
    static func openWindow(for capture: Capture) -> EditorWindowController {
        var image = capture.image
        let scale = max(capture.details.scale, 0.1)
        let settings = SettingsStore.shared.settings
        if settings.autoResizeLargeScreenshots, let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let points = capture.pointSize
            let f = min(1, (visible.width - 80) / points.width, (visible.height - 160) / points.height)
            if f < 1 {
                let size = CGSize(width: (CGFloat(image.width) * f).rounded(), height: (CGFloat(image.height) * f).rounded())
                image = ImageEffects.resize(image, to: size)
            }
        }
        let doc = EditorDocument(image: image, scale: scale)
        // Only an opened image file is a save target; captures go through the "file" destination.
        let url = capture.details.mode == .file ? capture.details.sourceURL : nil
        let controller = EditorWindowController(document: doc, details: capture.details, documentURL: url)
        show(controller)
        return controller
    }

    private static func show(_ controller: EditorWindowController) {
        let previous = controllers.last?.window
        controllers.append(controller)
        EditorMenuInstaller.shared.start()
        controller.placeWindow(cascadeFrom: previous)
        // The app is an accessory app: activate so the window comes forward.
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
        if SettingsStore.shared.settings.showTextHints { controller.showMessage(EditorTool.select.hint) }
        EditorMenuInstaller.shared.update()
    }

    static func windowDidClose(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
        DispatchQueue.main.async { EditorMenuInstaller.shared.update() }
    }
}
