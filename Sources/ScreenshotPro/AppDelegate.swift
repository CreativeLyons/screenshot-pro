import AppKit
import Combine
import ScreenshotProCapture
import ScreenshotProCore
import ScreenshotProEditor
import ScreenshotProOutput

/// App lifecycle: registers destinations, builds the menu bar item, keeps global hotkeys in
/// sync with settings and opens Settings when the app is launched again while running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private var cancellables: Set<AnyCancellable> = []

    /// The running delegate, so static actions can reach the status menu.
    private static weak var current: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.current = self
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()

        if let directory = SelfTest.directory {
            // Scripted UI tour that snapshots its own windows, then quits (see SelfTest.swift).
            // No hotkeys, notifications, login item or temporary file purge in this mode.
            StandardDestinations.makeAll().forEach(DestinationRegistry.shared.register)
            DestinationRegistry.shared.register(EditorDestination())
            Editor.settingsHandler = { SettingsWindowController.shared.show() }
            let menu = StatusMenuController()
            statusMenu = menu
            SelfTest.start(in: directory, statusMenu: menu)
            return
        }

        StandardDestinations.registerAll(in: .shared)
        DestinationRegistry.shared.register(EditorDestination())
        Editor.settingsHandler = { SettingsWindowController.shared.show() }

        NotificationController.shared.configure()
        HistoryStrip.exportHandler = { capture, destination in
            await CaptureCoordinator.shared.export(capture, to: destination)
        }
        HistoryStrip.openHandler = { capture in
            await CaptureCoordinator.shared.reopen(capture)
        }
        statusMenu = StatusMenuController()
        HistoryStrip.restore()
        registerHotkeys(SettingsStore.shared.settings.hotkeys)
        observeSettings()

        // Preflight only: the system prompt waits for the first capture (ARCHITECTURE "Permissions").
        if !ScreenRecordingPermission.isGranted {
            NSLog("Screenshot Pro: Screen Recording permission is not granted yet")
        }
        LaunchAtLogin.shared.refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The menu bar item can be hidden (notch, too many items): reopening must show something.
        SettingsWindowController.shared.show()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The monthly re-authorization can revoke the grant at any time; refresh the warning.
        statusMenu?.rebuild()
        PermissionWindowController.shared.recheckIfVisible()
    }

    // MARK: Settings

    private func observeSettings() {
        let settings = SettingsStore.shared.$settings
        settings
            .map(\.hotkeys)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] hotkeys in self?.registerHotkeys(hotkeys) }
            .store(in: &cancellables)
        settings
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.statusMenu?.rebuild() }
            .store(in: &cancellables)
        settings
            .map(\.historyLimit)
            .removeDuplicates()
            .dropFirst()
            .sink { _ in
                CaptureHistory.shared.trim()
            }
            .store(in: &cancellables)
    }

    private func registerHotkeys(_ hotkeys: [HotkeyAction: KeyCombo]) {
        let bindings = HotkeyAction.allCases.compactMap { action -> HotkeyManager.Hotkey? in
            guard let combo = hotkeys[action] else { return nil }
            return HotkeyManager.Hotkey(combo: combo) { AppDelegate.perform(action) }
        }
        let failed = HotkeyManager.shared.register(bindings)
        if !failed.isEmpty {
            NSLog("Screenshot Pro: could not register hotkeys %@", failed.map(\.label).joined(separator: ", "))
        }
    }

    /// Files opened with the app (Open With, dropped on the icon, `open -a`): images open in the
    /// editor, element files restore their editable annotations.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                if url.pathExtension.lowercased() == Editor.elementFileExtension {
                    try Editor.openElementFile(at: url)
                } else {
                    Editor.open(try CaptureService.shared.importImage(at: url))
                }
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Actions

    /// Runs a hotkey or menu action.
    static func perform(_ action: HotkeyAction) {
        switch action {
        case .windowFromList:
            current?.statusMenu?.popUpWindowList()
        case .openClipboard:
            CaptureCoordinator.shared.capture(.clipboard)
        case .history:
            HistoryStrip.toggle()
        default:
            if let mode = action.captureMode { CaptureCoordinator.shared.capture(mode) }
        }
    }
}
