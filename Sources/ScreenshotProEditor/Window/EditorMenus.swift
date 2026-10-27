import AppKit

/// Builds the editor's main menu (the app is an accessory app without one of its own) and
/// installs it as `NSApp.mainMenu` while an editor window is key, restoring the previous menu
/// otherwise. Items target the first responder, so they act on the key editor window.
@MainActor
final class EditorMenuInstaller {
    static let shared = EditorMenuInstaller()

    private lazy var menu = EditorMenus.makeMainMenu()
    private var savedMenu: NSMenu?
    private var savedWindowsMenu: NSMenu?
    private var installed = false
    private var observers: [NSObjectProtocol] = []

    /// Starts watching key window changes (idempotent).
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willCloseNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The new key window is known only after the current event finishes.
                    DispatchQueue.main.async { self?.update() }
                }
            })
        }
    }

    func update() {
        if wantsEditorMenu {
            guard !installed else { return }
            savedMenu = NSApp.mainMenu
            savedWindowsMenu = NSApp.windowsMenu
            NSApp.mainMenu = menu
            NSApp.windowsMenu = menu.items.last?.submenu
            installed = true
        } else if installed {
            NSApp.mainMenu = savedMenu
            NSApp.windowsMenu = savedWindowsMenu
            savedMenu = nil
            savedWindowsMenu = nil
            installed = false
        }
    }

    private var wantsEditorMenu: Bool {
        guard let key = NSApp.keyWindow else { return false }
        if key.windowController is EditorWindowController { return true }
        if key.sheetParent?.windowController is EditorWindowController { return true }
        // Panels opened from the editor (colors, fonts) keep the editor menu.
        if installed, key is NSPanel, NSApp.mainWindow?.windowController is EditorWindowController { return true }
        return false
    }
}

@MainActor
enum EditorMenus {
    typealias C = EditorWindowController

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(objectMenu()))
        main.addItem(submenu(imageMenu()))
        main.addItem(submenu(effectsMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(windowMenu()))
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return i
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        return m
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Screenshot Pro"
    }

    private static func appMenu() -> NSMenu {
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        let m = menu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings...", #selector(C.editorShowSettings(_:)), ","),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            hideOthers,
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        return m
    }

    private static func fileMenu() -> NSMenu {
        menu("File", [
            item("Save", #selector(C.editorSave(_:)), "s"),
            item("Save As...", #selector(C.editorSaveAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("Copy to Clipboard", #selector(C.editorCopyToClipboard(_:)), "c", [.command, .shift]),
            item("Print...", #selector(C.editorPrint(_:)), "p"),
            item("Send as Mail", #selector(C.editorMail(_:)), "m", [.command, .shift]),
            item("Share...", #selector(C.editorShare(_:))),
            item("Copy Text (OCR)", #selector(C.editorOCR(_:))),
            .separator(),
            item("Save Elements...", #selector(C.editorSaveElements(_:))),
            item("Load Elements...", #selector(C.editorLoadElements(_:))),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
    }

    private static func editMenu() -> NSMenu {
        menu("Edit", [
            item("Undo", #selector(C.undo(_:)), "z"),
            item("Redo", #selector(C.redo(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Duplicate", #selector(C.editorDuplicate(_:)), "d"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Image", #selector(C.editorCopyImage(_:)), "c", [.command, .option]),
        ])
    }

    private static func objectMenu() -> NSMenu {
        menu("Object", [
            item("Bring to Front", #selector(C.editorBringToFront(_:)), "]", [.command, .shift]),
            item("Bring Forward", #selector(C.editorBringForward(_:)), "]"),
            item("Send Backward", #selector(C.editorSendBackward(_:)), "["),
            item("Send to Back", #selector(C.editorSendToBack(_:)), "[", [.command, .shift]),
            .separator(),
            item("Edit Text", #selector(C.editorEditText(_:))),
            item("Reset Counter", #selector(C.editorResetCounter(_:))),
            .separator(),
            item("Insert Image from File...", #selector(C.editorInsertImage(_:))),
        ])
    }

    private static func imageMenu() -> NSMenu {
        menu("Image", [
            item("Crop", #selector(C.editorCrop(_:))),
            item("Auto Crop", #selector(C.editorAutoCrop(_:))),
            .separator(),
            item("Resize...", #selector(C.editorResize(_:)), "r", [.command, .option]),
            item("Rotate Clockwise", #selector(C.editorRotateClockwise(_:)), "r"),
            item("Rotate Counterclockwise", #selector(C.editorRotateCounterclockwise(_:)), "l"),
            item("Expand Canvas", #selector(C.editorExpandCanvas(_:))),
            .separator(),
            item("Clear", #selector(C.editorClear(_:))),
            item("Remove Transparency", #selector(C.editorRemoveTransparency(_:))),
        ])
    }

    private static func effectsMenu() -> NSMenu {
        menu("Effects", [
            item("Border", #selector(C.editorBorder(_:)), "b"),
            item("Drop Shadow", #selector(C.editorDropShadow(_:)), "s", [.command, .option]),
            item("Drop Shadow...", #selector(C.editorDropShadowSettings(_:))),
            item("Torn Edges", #selector(C.editorTornEdges(_:)), "t", [.command, .option]),
            item("Torn Edges...", #selector(C.editorTornEdgesSettings(_:))),
            .separator(),
            item("Grayscale", #selector(C.editorGrayscale(_:)), "g", [.command, .option]),
            item("Invert", #selector(C.editorInvert(_:)), "i", [.command, .option]),
        ])
    }

    private static func viewMenu() -> NSMenu {
        let zoomInAlt = item("Zoom In", #selector(C.editorZoomIn(_:)), "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        return menu("View", [
            item("Zoom In", #selector(C.editorZoomIn(_:)), "+"),
            zoomInAlt,
            item("Zoom Out", #selector(C.editorZoomOut(_:)), "-"),
            item("Actual Size", #selector(C.editorActualSize(_:)), "0"),
            item("Zoom to Fit", #selector(C.editorZoomToFit(_:)), "9"),
        ])
    }

    private static func windowMenu() -> NSMenu {
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
    }
}
