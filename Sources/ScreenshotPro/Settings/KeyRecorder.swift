import AppKit
import Carbon.HIToolbox
import ScreenshotProCore
import SwiftUI

/// A shortcut recorder field. Click it, then type the new shortcut: Esc cancels, Delete clears.
/// Global hotkeys are suspended while recording so an existing hotkey reaches the field instead
/// of starting a capture. Validation is left to the owner (`onRecord`).
struct KeyRecorder: NSViewRepresentable {
    var combo: KeyCombo?
    var onRecord: (KeyCombo) -> Void
    var onClear: () -> Void

    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView()
        view.combo = combo
        view.onRecord = onRecord
        view.onClear = onClear
        return view
    }

    func updateNSView(_ view: KeyRecorderView, context: Context) {
        view.combo = combo
        view.onRecord = onRecord
        view.onClear = onClear
    }
}

/// The AppKit side of `KeyRecorder`.
final class KeyRecorderView: NSView {
    var combo: KeyCombo? { didSet { if combo != oldValue { needsDisplay = true; updateAccessibility() } } }
    var onRecord: ((KeyCombo) -> Void)?
    var onClear: (() -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true; updateAccessibility() }
    }
    /// Modifiers held while recording, shown live before the key arrives.
    private var heldModifiers: NSEvent.ModifierFlags = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    // MARK: Recording state

    private func startRecording() {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        heldModifiers = []
        isRecording = true
        HotkeyManager.shared.suspend()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        HotkeyManager.shared.resume()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        let recorded = KeyCombo(event: event)
        let plain = recorded.modifiers.isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plain:
            stopRecording()
        case kVK_Delete where plain, kVK_ForwardDelete where plain:
            stopRecording()
            onClear?()
        default:
            stopRecording()
            onRecord?(recorded)
        }
    }

    /// Command shortcuts arrive here before keyDown; claim them while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        heldModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        needsDisplay = true
    }

    // MARK: Drawing

    private var displayText: String {
        if isRecording {
            let held = Self.symbols(for: heldModifiers)
            return held.isEmpty ? "Type shortcut" : held
        }
        return combo?.label ?? "Click to record"
    }

    /// Modifier symbols in the standard macOS order.
    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let color: NSColor = isRecording || combo == nil ? .secondaryLabelColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
        ]
        let text = NSAttributedString(string: displayText, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    private func updateAccessibility() {
        setAccessibilityLabel(isRecording ? "Recording shortcut" : "Shortcut: \(combo?.label ?? "none")")
    }

    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }
}
