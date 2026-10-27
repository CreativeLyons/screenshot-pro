import AppKit
import Carbon.HIToolbox
import ScreenshotProCore

/// The freeze-frame selection overlay: one panel per display showing its frozen image.
///
/// Region mode: drag to select (may span displays), click a window to select its frame, or
/// use the keyboard (arrows move the pointer, Enter starts and finishes). Window mode: the
/// window under the pointer is highlighted and a click picks it. Space toggles the modes,
/// holding Shift shows the magnifier (Z keeps it on), Esc or a right click cancels.
@MainActor
final class SelectionOverlay: OverlayInputHandler {
    enum Outcome {
        /// A region in Quartz points; `window` is set when it came from clicking a window.
        case region(CGRect, window: WindowInfo?)
        case window(WindowInfo)
        case cancelled
    }

    /// Clicks this soon after showing are ignored (the click that opened a menu item, say).
    static let armingDelay: TimeInterval = 0.25
    /// The overlay currently shown, if any (for `CaptureSelfTestHook`).
    private(set) static weak var active: SelectionOverlay?
    /// A drag shorter than this (points, both axes) is a click.
    static let clickTolerance: CGFloat = 3

    private let displays: [FrozenDisplay]
    private let windows: [WindowInfo]
    private let showHints: Bool
    private var state = OverlayState()
    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private let keys = OverlayKeyGrabber()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var previousApp: NSRunningApplication?
    private var shownAt = Date.distantPast
    private var anchor: CGPoint?
    private var mouseSelecting = false
    private var keyboardSelecting = false
    /// True between an accepted (armed) mouse down and its mouse up.
    private var pressAccepted = false
    /// Polls the hardware Shift state while the overlay lacks key focus (flagsChanged only
    /// reaches the key window). Edge-triggered, so delivered events are not overridden.
    private var modifierTimer: Timer?
    private var lastPolledShift = false

    init(displays: [FrozenDisplay], windows: [WindowInfo], mode: OverlayState.Mode, options: CaptureOptions) {
        self.displays = displays
        self.windows = windows
        self.showHints = options.showHints
        state.mode = mode
        state.showMagnifier = options.showMagnifier
    }

    /// Shows the overlay and waits for the user.
    func run() async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    // MARK: Showing and closing

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        let h = CoordinateSpace.primaryDisplayHeight
        for screen in NSScreen.screens {
            let quartzFrame = CoordinateSpace.quartzRect(fromAppKit: screen.frame, primaryHeight: h)
            guard let display = SelectionOverlay.display(matching: quartzFrame, in: displays) else { continue }
            let panel = OverlayPanel(frame: screen.frame)
            let view = OverlayView(display: display, size: screen.frame.size, backingScale: screen.backingScaleFactor)
            view.handler = self
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }
        guard !panels.isEmpty else {
            finish(.cancelled)
            return
        }
        SelectionOverlay.active = self

        state.cursor = currentMouseLocation()
        lastPolledShift = NSEvent.modifierFlags.contains(.shift)
        updateDerivedState()
        for (panel, view) in zip(panels, views) {
            view.apply(state)
            panel.orderFrontRegardless()
        }
        activateIfSafe()
        focusPanel(under: state.cursor)
        NSCursor.crosshair.push()
        keys.start([.escape, .enter, .keypadEnter, .space]) { [weak self] key in self?.handleGrabbed(key) }
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollModifiers() }
        }

        // The release of a button still held from the triggering click arrives without an
        // accepted press, so it is ignored.
        shownAt = Date()
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        if SelectionOverlay.active === self { SelectionOverlay.active = nil }
        keys.stop()
        modifierTimer?.invalidate()
        modifierTimer = nil
        if !panels.isEmpty { NSCursor.pop() }
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        views.removeAll()
        restoreFocus()
        continuation.resume(returning: outcome)
    }

    /// Activating gives reliable keyboard focus and cursor control, but it can switch Spaces
    /// when one of our document windows is open elsewhere (03 section 2.2), so only do it
    /// when none is visible. The Carbon key grabber covers the other case.
    private func activateIfSafe() {
        let hasDocumentWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is OverlayPanel) }
        if !hasDocumentWindow, !NSApp.isActive {
            NSApp.activate()
        }
    }

    /// Hands activation back to the app that was in front before the overlay.
    private func restoreFocus() {
        guard let previous = previousApp, previous != NSRunningApplication.current,
              !previous.isTerminated, NSApp.isActive else { return }
        NSApp.yieldActivation(to: previous)
        previous.activate(from: NSRunningApplication.current, options: [])
    }

    private func focusPanel(under point: CGPoint) {
        guard let index = views.firstIndex(where: { $0.display.frame.contains(point) }) ?? views.indices.first else { return }
        let panel = panels[index]
        if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        if panel.firstResponder !== views[index] { panel.makeFirstResponder(views[index]) }
    }

    static func display(matching frame: CGRect, in displays: [FrozenDisplay]) -> FrozenDisplay? {
        displays.first { d in
            abs(d.frame.minX - frame.minX) < 1 && abs(d.frame.minY - frame.minY) < 1
                && abs(d.frame.width - frame.width) < 1 && abs(d.frame.height - frame.height) < 1
        }
    }

    /// The overlay panels while shown (for `CaptureSelfTestHook`).
    var panelWindows: [NSWindow] { panels }

    /// True while the magnifier is drawn (for `CaptureSelfTestHook`).
    var isMagnifierShown: Bool { state.mode == .region && (state.showMagnifier || state.magnifierHeld) }

    /// Closes the overlay as Esc does.
    func cancel() {
        finish(.cancelled)
    }

    private var isArmed: Bool { Date().timeIntervalSince(shownAt) >= SelectionOverlay.armingDelay }

    // MARK: State

    private var layouts: [DisplayLayout] { displays.map(\.layout) }

    private func currentMouseLocation() -> CGPoint {
        CoordinateSpace.quartzPoint(fromAppKit: NSEvent.mouseLocation, primaryHeight: CoordinateSpace.primaryDisplayHeight)
    }

    private func updateDerivedState() {
        let scale = DisplayComposition.outputScale(for: CGRect(origin: state.cursor, size: CGSize(width: 1, height: 1)),
                                                   displays: layouts)
        if let anchor, state.mode == .region {
            let rect = clippedToDisplays(CoordinateSpace.selectionRect(from: anchor, to: state.cursor, scale: scale))
            state.selection = rect
            state.selectionPixels = rect.map {
                CoordinateSpace.pixelSize(of: $0, scale: DisplayComposition.outputScale(for: $0, displays: layouts))
            }
        } else {
            state.selection = nil
            state.selectionPixels = nil
        }

        if state.mode == .window {
            state.highlight = WindowHitTesting.window(at: state.cursor, in: windows)
            state.highlightPixels = state.highlight.flatMap { clippedToDisplays($0.bounds) }.map {
                CoordinateSpace.pixelSize(of: $0, scale: DisplayComposition.outputScale(for: $0, displays: layouts))
            }
        } else {
            state.highlight = nil
            state.highlightPixels = nil
        }

        state.showCrosshair = state.mode == .region && anchor == nil
        state.hint = showHints ? hintText() : nil
    }

    private func hintText() -> String {
        switch state.mode {
        case .window:
            return "Click a window to capture it.  Space: region mode.  Esc or right click: cancel."
        case .region where keyboardSelecting:
            return "Arrow keys resize (Shift: 10 pt).  Enter: capture.  Esc: cancel."
        case .region:
            return "Drag to select an area or click a window.  Hold Shift: magnifier.  Space: window mode.  Esc or right click: cancel."
        }
    }

    private func clippedToDisplays(_ rect: CGRect) -> CGRect? {
        let r = rect.intersection(DisplayComposition.bounds(of: layouts))
        return r.isNull || r.isEmpty ? nil : r
    }

    private func redraw() {
        updateDerivedState()
        for view in views { view.apply(state) }
    }

    // MARK: Input

    func overlayMouseMoved(to point: CGPoint, in view: OverlayView) {
        state.cursor = point
        // Reclaim key focus whenever the pointer moves (cooperative activation can leave it
        // with the previous app).
        focusPanel(under: point)
        NSCursor.crosshair.set()
        redraw()
    }

    func overlayMouseDown(at point: CGPoint) {
        pressAccepted = isArmed
        guard pressAccepted else { return }
        state.cursor = point
        if state.mode == .region {
            anchor = point
            mouseSelecting = true
            keyboardSelecting = false
        }
        redraw()
    }

    func overlayMouseDragged(to point: CGPoint) {
        guard pressAccepted else { return }
        state.cursor = point
        redraw()
    }

    func overlayMouseUp(at point: CGPoint) {
        guard pressAccepted else { return }
        pressAccepted = false
        state.cursor = point
        switch state.mode {
        case .window:
            pickHighlightedWindow()
        case .region:
            guard mouseSelecting, let start = anchor else { return }
            mouseSelecting = false
            anchor = nil
            completeRegion(from: start, to: point)
        }
    }

    /// Right click (also Control-click and other buttons) is the escape hatch for a capture
    /// started by accident: it cancels at once, also mid-drag and before the overlay is armed.
    func overlayRightMouseDown() {
        finish(.cancelled)
    }

    func overlayModifiersChanged(_ flags: NSEvent.ModifierFlags) {
        setMagnifierHeld(flags.contains(.shift))
    }

    private func pollModifiers() {
        let shift = NSEvent.modifierFlags.contains(.shift)
        guard shift != lastPolledShift else { return }
        lastPolledShift = shift
        setMagnifierHeld(shift)
    }

    private func setMagnifierHeld(_ held: Bool) {
        guard continuation != nil, held != state.magnifierHeld else { return }
        state.magnifierHeld = held
        redraw()
    }

    func overlayKeyDown(_ event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Escape: finish(.cancelled)
        case kVK_Return, kVK_ANSI_KeypadEnter: handleGrabbed(.enter)
        case kVK_Space: handleGrabbed(.space)
        case kVK_LeftArrow: movePointer(dx: -step, dy: 0)
        case kVK_RightArrow: movePointer(dx: step, dy: 0)
        case kVK_UpArrow: movePointer(dx: 0, dy: -step)
        case kVK_DownArrow: movePointer(dx: 0, dy: step)
        case kVK_ANSI_Z:
            state.showMagnifier.toggle()
            redraw()
        default: break
        }
    }

    /// Esc, Enter and Space arrive here from the key grabber or from keyDown.
    private func handleGrabbed(_ key: OverlayKeyGrabber.Key) {
        guard continuation != nil else { return }
        switch key {
        case .escape:
            finish(.cancelled)
        case .enter, .keypadEnter:
            enterPressed()
        case .space:
            if keyboardSelecting {
                enterPressed()
            } else if !mouseSelecting {
                state.mode = state.mode == .region ? .window : .region
                anchor = nil
                redraw()
            }
        }
    }

    private func enterPressed() {
        state.cursor = currentMouseLocation()
        switch state.mode {
        case .window:
            pickHighlightedWindow()
        case .region:
            if keyboardSelecting, let start = anchor {
                keyboardSelecting = false
                anchor = nil
                completeRegion(from: start, to: state.cursor)
            } else if !mouseSelecting {
                anchor = state.cursor
                keyboardSelecting = true
                redraw()
            }
        }
    }

    /// Moves the real pointer (so the next mouse event agrees) and the overlay cursor.
    private func movePointer(dx: CGFloat, dy: CGFloat) {
        let current = currentMouseLocation()
        let target = CGPoint(x: current.x + dx, y: current.y + dy)
        let frames = displays.map(\.frame)
        let home = frames.first { $0.contains(current) } ?? frames.first ?? .zero
        let next = frames.contains { $0.contains(target) } ? target : CoordinateSpace.clamp(target, to: home)
        CGWarpMouseCursorPosition(next)
        // Warping suppresses local mouse events briefly; re-associate right away.
        CGAssociateMouseAndMouseCursorPosition(1)
        state.cursor = next
        focusPanel(under: next)
        redraw()
    }

    private func completeRegion(from start: CGPoint, to end: CGPoint) {
        let isClick = abs(end.x - start.x) < SelectionOverlay.clickTolerance
            && abs(end.y - start.y) < SelectionOverlay.clickTolerance
        if isClick {
            // A click selects the window under the pointer; on the desktop it does nothing.
            if let window = WindowHitTesting.window(at: end, in: windows), let rect = clippedToDisplays(window.bounds) {
                finish(.region(rect, window: window))
            } else {
                redraw()
            }
            return
        }
        let scale = DisplayComposition.outputScale(for: CGRect(origin: end, size: CGSize(width: 1, height: 1)), displays: layouts)
        guard let rect = clippedToDisplays(CoordinateSpace.selectionRect(from: start, to: end, scale: scale)) else {
            redraw()
            return
        }
        finish(.region(rect, window: nil))
    }

    private func pickHighlightedWindow() {
        guard let window = WindowHitTesting.window(at: state.cursor, in: windows) else { return }
        finish(.window(window))
    }
}
