import AppKit

/// A minimal main menu, shown while one of the app's windows is active. AppKit routes key
/// equivalents through it, so text fields in Settings get Cut/Copy/Paste/Undo and windows close
/// with Command-W. Other modules (the editor) may add their own menus to `NSApp.mainMenu`.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Screenshot Pro")
        app.addItem(withTitle: "About Screenshot Pro", action: #selector(MenuActions.showAbout), keyEquivalent: "")
            .target = MenuActions.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Settings...", action: #selector(MenuActions.showSettings), keyEquivalent: ",")
            .target = MenuActions.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Screenshot Pro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Screenshot Pro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: window)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

/// Targets for main menu items that are app actions rather than responder-chain actions.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func showAbout() { AboutPanel.show() }
    @objc func showSettings() { SettingsWindowController.shared.show() }
}
