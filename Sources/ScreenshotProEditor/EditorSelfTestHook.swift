import AppKit
import ScreenshotProCore
import ScreenshotProOutput

/// TEST-ONLY. Drives editor windows for the app's self-test mode (launch with
/// SCREENSHOTPRO_SELFTEST_DIR set, see the app's SelfTest.swift). The app never calls this in normal
/// use. Every operation goes through the same session, menu and export code the UI uses.
@MainActor
public enum EditorSelfTestHook {
    /// Open editor windows, oldest first.
    public static var windows: [NSWindow] { Editor.controllers.compactMap(\.window) }

    private static func controller(_ window: NSWindow) -> EditorWindowController? {
        window.windowController as? EditorWindowController
    }

    public static func elementCount(in window: NSWindow) -> Int? {
        controller(window)?.session.document.elements.count
    }

    /// Ends the current undo group the way a user action does. AppKit closes the window undo
    /// manager's top-level group (groupsByEvent) only after it dispatches an event, so scripted
    /// changes without events would all merge into one undo step. Posts an application-defined
    /// event and waits until it has been dispatched.
    public static func endEventUndoGroup(in window: NSWindow) async {
        guard let um = window.undoManager, um.groupingLevel > 0 else { return }
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        for _ in 0..<40 where um.groupingLevel > 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Steps on the session's undo and redo stacks.
    public static func historyDepth(in window: NSWindow) -> (undo: Int, redo: Int)? {
        guard let h = controller(window)?.session.history else { return nil }
        return (h.undoStack.count, h.redoStack.count)
    }

    /// Image size in pixels and scale of the window's document.
    public static func documentSize(in window: NSWindow) -> (size: CGSize, scale: CGFloat)? {
        guard let doc = controller(window)?.session.document else { return nil }
        return (doc.size, doc.scale)
    }

    /// Base image plus all elements at full resolution, as exports see it.
    public static func flattenedImage(of window: NSWindow) -> CGImage? {
        controller(window)?.flattenedImage()
    }

    /// Where Save writes (set by an export through the "file" destination).
    public static func documentURL(of window: NSWindow) -> URL? {
        controller(window)?.documentURL
    }

    /// Adds one element of every type (highlight once per mode, obfuscate once per mode,
    /// three counters), each as its own undo step, with no event in between (each session step
    /// opens its own undo group). Selects the speech bubble.
    /// Returns the added type names in order.
    @discardableResult
    public static func addSampleElements(to window: NSWindow) async -> [String] {
        guard let c = controller(window) else { return [] }
        let session = c.session
        let settings = c.settings
        let s = session.document.scale
        func style(_ type: ElementType) -> ElementStyle { session.newElementStyle(type, settings: settings) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        var elements: [Element] = []
        elements.append(Element(type: .rectangle, rect: rect(20, 20, 120, 70), style: style(.rectangle)))
        elements.append(Element(type: .ellipse, rect: rect(160, 20, 110, 70), style: style(.ellipse)))
        elements.append(Element(type: .line, points: [pt(290, 30), pt(380, 90)], style: style(.line)))
        elements.append(Element(type: .arrow, points: [pt(400, 90), pt(480, 30)], style: style(.arrow)))
        let freehand = (0...24).map { i -> CGPoint in
            let t = CGFloat(i) / 24
            return pt(500 + 80 * t, 60 + 25 * sin(t * .pi * 4))
        }
        elements.append(Element(type: .freehand, points: freehand, style: style(.freehand)))
        var text = Element(type: .text, rect: rect(20, 110, 170, 50), style: style(.text))
        text.text = "Text element"
        elements.append(text)
        var bubble = Element(type: .speechBubble, rect: rect(220, 110, 170, 60), style: style(.speechBubble))
        bubble.text = "Speech bubble"
        bubble.tailTarget = pt(200, 200)
        elements.append(bubble)
        for i in 0..<3 {
            let x = 420 + CGFloat(i) * 45
            elements.append(Element(type: .counter, rect: rect(x, 120, 30, 30), style: style(.counter)))
        }
        for (i, mode) in HighlightMode.allCases.enumerated() {
            var st = style(.highlight)
            st.highlightMode = mode
            elements.append(Element(type: .highlight, rect: rect(20 + CGFloat(i) * 140, 220, 120, 60), style: st))
        }
        for (i, mode) in ObfuscateMode.allCases.enumerated() {
            var st = style(.obfuscate)
            st.obfuscateMode = mode
            elements.append(Element(type: .obfuscate, rect: rect(20 + CGFloat(i) * 140, 300, 120, 70), style: st))
        }

        var names: [String] = []
        var bubbleID: UUID?
        for e in elements {
            let added = session.add(e)
            if e.type == .speechBubble { bubbleID = added.id }
            var name = e.type.displayName
            if e.type == .highlight { name += " (\(e.style.highlightMode.displayName))" }
            if e.type == .obfuscate { name += " (\(e.style.obfuscateMode.displayName))" }
            names.append(name)
        }

        // An image element, through the same path as paste and drop.
        if let img = sampleImage(side: Int(40 * s)) {
            c.insertImages([img], at: pt(320, 300))
            names.append(ElementType.image.displayName)
        }

        c.selectTool(.select)
        if let bubbleID { session.selection = [bubbleID] }
        return names
    }

    private static func sampleImage(side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(r)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: r.insetBy(dx: CGFloat(side) / 4, dy: CGFloat(side) / 4))
        return ctx.makeImage()
    }

    /// Selects the element at `index` (z-order) and the select tool, so its handles show.
    public static func selectElement(at index: Int, in window: NSWindow) {
        guard let c = controller(window), c.session.document.elements.indices.contains(index) else { return }
        c.selectTool(.select)
        c.session.selection = [c.session.document.elements[index].id]
    }

    /// Finds the editor main menu item at `path` (e.g. ["Effects", "Border"]), validates it like
    /// AppKit would and sends its action to the window's controller. Returns false when the item
    /// is missing or disabled.
    @discardableResult
    public static func performMenuItem(_ path: [String], in window: NSWindow) -> Bool {
        guard let c = controller(window), let item = menuItem(path), let action = item.action else { return false }
        guard c.validateMenuItem(item) else { return false }
        return NSApp.sendAction(action, to: c, from: item)
    }

    /// The item at `path` in a fresh copy of the editor's main menu.
    public static func menuItem(_ path: [String]) -> NSMenuItem? {
        var menu: NSMenu? = EditorMenus.makeMainMenu()
        var found: NSMenuItem?
        for title in path {
            found = menu?.items.first { $0.title == title }
            menu = found?.submenu
        }
        return found
    }

    /// A fresh copy of the editor's main menu with each item enabled or disabled the way
    /// AppKit's validation would for `window`.
    public static func mainMenu(validatedFor window: NSWindow) -> NSMenu {
        let menu = EditorMenus.makeMainMenu()
        guard let c = controller(window) else { return menu }
        func validate(_ m: NSMenu) {
            m.autoenablesItems = false
            for item in m.items {
                if let action = item.action, c.responds(to: action) { item.isEnabled = c.validateMenuItem(item) }
                if let sub = item.submenu { validate(sub) }
            }
        }
        validate(menu)
        return menu
    }

    /// The crop bar's Apply button (also Return in the crop tool).
    public static func applyPendingCrop(in window: NSWindow) {
        controller(window)?.applyCrop()
    }

    /// The pending crop rectangle in pixels, if the crop tool shows one.
    public static func pendingCropRect(in window: NSWindow) -> CGRect? {
        controller(window)?.canvas.cropRect
    }

    /// Exports the flattened image through a destination, as the toolbar and File menu do.
    public static func export(_ window: NSWindow, to destinationID: String) async -> Bool {
        guard let c = controller(window) else { return false }
        return await c.export(to: destinationID)
    }

    /// Writes the document as an element file, as File > Save Elements does after its panel.
    public static func saveElementFile(of window: NSWindow, to url: URL) throws {
        guard let c = controller(window) else { throw ScreenshotProError.writeFailed("not an editor window") }
        try DocumentFile.write(c.session.document, to: url)
    }

    /// Closes every editor window without asking (the "Don't Save" choice).
    public static func closeAllDiscardingChanges() {
        for c in Editor.controllers { c.closeNow() }
    }

    /// The status bar message (hints, export results).
    public static func statusMessage(in window: NSWindow) -> String? {
        controller(window)?.statusBar.messageLabel.stringValue
    }
}
