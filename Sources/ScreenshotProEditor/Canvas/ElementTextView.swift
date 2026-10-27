import AppKit

/// The in-place text editor laid over a text box or speech bubble. Command-Return confirms,
/// Esc cancels, Return inserts a newline. Keystrokes use their own undo manager; the whole
/// edit becomes one document step when editing ends.
@MainActor
final class ElementTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let typingUndo = UndoManager()

    override var undoManager: UndoManager? { typingUndo }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if isReturn && event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) { typingUndo.undo() }
    @objc func redo(_ sender: Any?) { typingUndo.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return typingUndo.canUndo
        case #selector(redo(_:)): return typingUndo.canRedo
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
