import AppKit
import SwiftUI

/// Hosts the SwiftUI settings tabs in an ordinary AppKit window.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private static let autosaveName = "ScreenshotPro.Settings"

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Screenshot Pro Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // Join the active Space instead of switching to the one the window was last on.
        window.collectionBehavior.insert(.moveToActiveSpace)
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Brings the window forward on the current Space.
    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
