import CoreGraphics
import Foundation

/// What one undo step restores: the document and the selection that went with it.
struct HistoryState: Equatable {
    var document: EditorDocument
    var selection: Set<UUID>
}

/// Snapshot undo/redo: each step stores the complete value state from before (undo stack) or
/// after (redo stack) a change. Annotation-only steps share the base image by reference, so
/// they cost almost nothing; steps holding a different image count against `byteBudget` and
/// the oldest are dropped when it is exceeded (the newest step is always kept).
final class DocumentHistory {
    struct Step {
        var state: HistoryState
        var name: String
    }

    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []
    /// Maximum bytes of base images retained only by history steps.
    var byteBudget: Int

    /// Merge key of the most recent step; a new step with the same key folds into it.
    private var lastMergeKey: String?

    init(byteBudget: Int = 256 * 1024 * 1024) {
        self.byteBudget = byteBudget
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    enum RecordResult: Equatable {
        /// A new step was pushed; `dropped` old steps were removed to stay within the budget.
        case pushed(dropped: Int)
        /// The change merged into the previous step (same merge key).
        case merged
    }

    /// Records that the state is about to change from `before`. Consecutive records with the
    /// same non-nil `mergeKey` form one step (e.g. arrow-key nudges, a color dragged in the
    /// color panel). Clears the redo stack.
    @discardableResult
    func record(before: HistoryState, name: String, mergeKey: String? = nil, current: CGImage? = nil) -> RecordResult {
        redoStack.removeAll()
        if let key = mergeKey, key == lastMergeKey, !undoStack.isEmpty {
            return .merged
        }
        lastMergeKey = mergeKey
        undoStack.append(Step(state: before, name: name))
        return .pushed(dropped: trim(current: current ?? before.document.image))
    }

    /// Ends merging: the next record starts a new step even with the same key.
    func breakMerge() { lastMergeKey = nil }

    /// Pops the newest undo step, pushing `current` for redo. Returns the state to restore.
    func undo(current: HistoryState) -> Step? {
        lastMergeKey = nil
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(Step(state: current, name: step.name))
        return step
    }

    /// Pops the newest redo step, pushing `current` for undo. Returns the state to restore.
    func redo(current: HistoryState) -> Step? {
        lastMergeKey = nil
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(Step(state: current, name: step.name))
        return step
    }

    func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastMergeKey = nil
    }

    /// Bytes of distinct base images held by the stacks but not by the current document.
    func retainedImageBytes(current: CGImage) -> Int {
        var seen = Set<ObjectIdentifier>([ObjectIdentifier(current)])
        var total = 0
        for step in undoStack + redoStack {
            let img = step.state.document.image
            if seen.insert(ObjectIdentifier(img)).inserted { total += img.bytesPerRow * img.height }
        }
        return total
    }

    private func trim(current: CGImage) -> Int {
        var dropped = 0
        while undoStack.count > 1, retainedImageBytes(current: current) > byteBudget {
            undoStack.removeFirst()
            dropped += 1
        }
        return dropped
    }
}
