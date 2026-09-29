import Combine

/// Whether the panel window's undo stack can undo or redo, for the toolbar's Undo/Redo (#103).
///
/// An object of its own, never `AppModel` state: the first keystroke flips `canUndo`, and the
/// manager's notification arrives inside that keystroke. Published on the model it re-rendered
/// `PanelView` — the TextEditor's owner — mid-edit, and a fast "   Q" came out with the caret
/// thrown to the end (GUI pass, 3/3). Only `UndoButtons` observes this.
@MainActor
final class UndoState: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Assigns only on change: the checkpoint notification fires on every registration.
    func update(canUndo undo: Bool, canRedo redo: Bool) {
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }
}
