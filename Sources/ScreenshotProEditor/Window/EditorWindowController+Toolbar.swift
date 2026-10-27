import AppKit
import ScreenshotProOutput

/// The toolbar, one row: destinations, the drawing tools, the quick colors and
/// the drag-out handle. Print, OCR, mail and undo live in the menus.
extension EditorWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    private enum Item {
        static let save = NSToolbarItem.Identifier("sp.save")
        static let copy = NSToolbarItem.Identifier("sp.copy")
        static let share = NSToolbarItem.Identifier("sp.share")
        static let tools = NSToolbarItem.Identifier("sp.tools")
        static let colors = NSToolbarItem.Identifier("sp.colors")
        static let dragOut = NSToolbarItem.Identifier("sp.dragOut")
    }

    func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ScreenshotProEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.save, Item.copy, Item.share, .space, Item.tools, .space, Item.colors, .flexibleSpace, Item.dragOut]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = false
            return item
        }
        switch id {
        case Item.save: return button("Save", "square.and.arrow.down", #selector(editorSave(_:)))
        case Item.copy: return button("Copy to Clipboard", "doc.on.clipboard", #selector(editorCopyToClipboard(_:)))
        case Item.share: return button("Share", "square.and.arrow.up", #selector(editorShare(_:)))
        case Item.tools:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Tools"
            item.paletteLabel = "Tools"
            item.view = palette
            item.menuFormRepresentation = palette.menuRepresentation()
            return item
        case Item.colors:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Colors"
            item.paletteLabel = "Colors"
            item.view = quickColors
            item.menuFormRepresentation = quickColors.menuRepresentation()
            return item
        case Item.dragOut:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Drag Image"
            item.paletteLabel = "Drag Image"
            item.toolTip = dragOut.toolTip
            item.view = dragOut
            return item
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        return validate(action: action)
    }
}
