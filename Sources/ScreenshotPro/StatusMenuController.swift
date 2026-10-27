import AppKit
import ScreenshotProCapture
import ScreenshotProCore

/// The menu bar item and its menu. The menu is rebuilt each time it opens, so hotkey hints,
/// quick-setting checkmarks and the permission warning are always current; the window list
/// submenu is filled lazily from `CaptureService.listWindows()`.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let store = SettingsStore.shared
    /// Incremented per window list load so a slow, stale load never overwrites a newer one.
    private var windowListGeneration = 0
    private weak var windowListMenu: NSMenu?

    private static let maxTitleLength = 60

    /// The menu the status item shows (read by the self-test).
    var statusItemMenu: NSMenu { menu }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = StatusIcon.make()
            button.imageScaling = .scaleNone
            button.toolTip = "Screenshot Pro"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
    }

    /// Rebuilds the top-level menu (also called when settings change).
    func rebuild() {
        menu.removeAllItems()
        let hotkeys = store.settings.hotkeys

        if !ScreenRecordingPermission.isGranted {
            let warning = item("Screen Recording permission needed...", #selector(showPermission))
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        // A short menu: the captures, the filmstrip, settings and quit. The rest waits
        // under More so the everyday items stay easy to hit.
        menu.addItem(captureItem(.region, hotkeys))
        menu.addItem(captureItem(.window, hotkeys))

        let fromList = NSMenuItem(title: HotkeyAction.windowFromList.displayName, action: nil, keyEquivalent: "")
        fromList.setShortcutHint(hotkeys[.windowFromList])
        let submenu = NSMenu(title: fromList.title)
        submenu.delegate = self
        submenu.autoenablesItems = false
        fromList.submenu = submenu
        windowListMenu = submenu
        menu.addItem(fromList)

        menu.addItem(captureItem(.fullScreen, hotkeys))
        menu.addItem(captureItem(.allScreens, hotkeys))
        menu.addItem(.separator())
        menu.addItem(captureItem(.history, hotkeys))
        menu.addItem(.separator())

        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.submenu = moreMenu(hotkeys)
        menu.addItem(more)
        menu.addItem(item("Settings...", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Screenshot Pro", #selector(quit), key: "q"))
    }

    /// The less used captures, quick settings and About.
    private func moreMenu(_ hotkeys: [HotkeyAction: KeyCombo]) -> NSMenu {
        let more = NSMenu(title: "More")
        more.autoenablesItems = false
        more.addItem(captureItem(.lastRegion, hotkeys))
        more.addItem(captureItem(.openClipboard, hotkeys))
        more.addItem(item("Open Image File...", #selector(openFile)))
        more.addItem(.separator())
        let quick = NSMenuItem(title: "Quick Settings", action: nil, keyEquivalent: "")
        quick.submenu = quickSettingsMenu()
        more.addItem(quick)
        more.addItem(.separator())
        more.addItem(item("About Screenshot Pro", #selector(showAbout)))
        return more
    }

    // MARK: Building blocks

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func captureItem(_ action: HotkeyAction, _ hotkeys: [HotkeyAction: KeyCombo]) -> NSMenuItem {
        let item = item(action.displayName, #selector(captureFromMenu(_:)))
        item.representedObject = action.rawValue
        item.setShortcutHint(hotkeys[action])
        return item
    }

    private func quickSettingsMenu() -> NSMenu {
        let quick = NSMenu(title: "Quick Settings")
        quick.autoenablesItems = false
        let s = store.settings
        let toggles: [(String, WritableKeyPath<ScreenshotProSettings, Bool>, Bool)] = [
            ("Ask for Destination", \.askForDestination, s.askForDestination),
            ("Capture Mouse Pointer", \.captureMousePointer, s.captureMousePointer),
            ("Always Show Magnifier", \.alwaysShowMagnifier, s.alwaysShowMagnifier),
            ("Play Camera Sound", \.playCameraSound, s.playCameraSound),
            ("Show Notifications", \.showNotifications, s.showNotifications),
        ]
        for (title, keyPath, isOn) in toggles {
            let toggle = item(title, #selector(toggleQuickSetting(_:)))
            toggle.state = isOn ? .on : .off
            toggle.representedObject = QuickSetting(keyPath: keyPath)
            quick.addItem(toggle)
        }
        return quick
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            rebuild()
        } else if menu === windowListMenu {
            loadWindowList(into: menu)
        }
    }

    // MARK: Window list

    private func loadWindowList(into menu: NSMenu) {
        menu.removeAllItems()
        guard ScreenRecordingPermission.isGranted else {
            menu.addItem(item("Screen Recording permission needed...", #selector(showPermission)))
            return
        }
        menu.addItem(disabledItem("Loading windows..."))
        windowListGeneration += 1
        let generation = windowListGeneration
        Task {
            let items = await windowItems()
            guard generation == windowListGeneration else { return }
            menu.removeAllItems()
            items.forEach(menu.addItem)
        }
    }

    /// Menu items for every capturable window, or a disabled item describing the problem.
    private func windowItems() async -> [NSMenuItem] {
        do {
            let windows = try await CaptureService.shared.listWindows()
            guard !windows.isEmpty else { return [disabledItem("No windows to capture")] }
            return windows.map(windowItem)
        } catch ScreenshotProError.screenRecordingPermissionDenied {
            return [item("Screen Recording permission needed...", #selector(showPermission))]
        } catch {
            return [disabledItem("Could not list windows: \(error.localizedDescription)")]
        }
    }

    private func windowItem(_ window: CapturableWindow) -> NSMenuItem {
        let title = window.title.isEmpty ? window.appName : "\(window.appName) - \(window.title)"
        let item = item(Self.truncated(title), #selector(captureListedWindow(_:)))
        item.toolTip = title
        item.representedObject = NSNumber(value: window.windowID)
        if let icon = NSRunningApplication(processIdentifier: window.processID)?.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func truncated(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 3)) + "..." : title
    }

    /// Pops the window list up at the mouse pointer (the "Capture Window from List" hotkey).
    func popUpWindowList() {
        guard !CaptureService.shared.isCapturing else { return }
        Task {
            if !ScreenRecordingPermission.isGranted {
                guard await ScreenRecordingPermission.requestAndProbe() else {
                    PermissionWindowController.shared.show()
                    return
                }
            }
            let items = await windowItems()
            let popup = NSMenu(title: HotkeyAction.windowFromList.displayName)
            popup.autoenablesItems = false
            items.forEach(popup.addItem)
            popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // MARK: Actions

    @objc private func captureFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotkeyAction(rawValue: raw) else { return }
        AppDelegate.perform(action)
    }

    @objc private func captureListedWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        CaptureCoordinator.shared.captureWindow(id: CGWindowID(id))
    }

    @objc private func openFile() {
        CaptureCoordinator.shared.capture(.file)
    }

    @objc private func toggleQuickSetting(_ sender: NSMenuItem) {
        guard let setting = sender.representedObject as? QuickSetting else { return }
        store.update { $0[keyPath: setting.keyPath].toggle() }
    }

    @objc private func showPermission() {
        PermissionWindowController.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func showAbout() {
        AboutPanel.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Boxes a settings key path for `NSMenuItem.representedObject`.
private final class QuickSetting: NSObject {
    let keyPath: WritableKeyPath<ScreenshotProSettings, Bool>
    init(keyPath: WritableKeyPath<ScreenshotProSettings, Bool>) { self.keyPath = keyPath }
}
