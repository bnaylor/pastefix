import AppKit
import SwiftUI

/// Clears the panel window's undo stack whenever the buffer is replaced programmatically.
///
/// The TextEditor's typing-undo lives on the window's `NSUndoManager` and records ranges into the
/// text as it was typed. A programmatic replacement — a transform landing, Pastefix's own undo/redo,
/// a new or refreshed session — neither clears those actions nor registers one of its own (measured
/// by the `work` session), so ⌘Z replayed typing at ranges into text that no longer exists: "   Q"
/// typed, Whitespace Cleanup, ⌘Z deleted "Qalp" instead. And the toolbar's Redo then carried the
/// damage into the model's history. Two undo stacks over one buffer.
///
/// This is the hotfix: typing-undo keeps working while you type, and is dropped the moment the
/// text it was recorded against goes away. #103 replaces it with one stack.
///
/// `token` changes exactly on programmatic replacement: `detectionRevision` moves on every push,
/// undo, redo and refresh and never on a keystroke, and `sessionGeneration` on every new session.
struct EditorUndoReset: NSViewRepresentable {
    let token: [Int]

    final class Coordinator { var last: [Int]? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.last != token else { return }
        let first = context.coordinator.last == nil
        context.coordinator.last = token
        // Not on first appearance: nothing has been typed into a buffer that just appeared.
        guard !first else { return }
        view.window?.undoManager?.removeAllActions()
    }
}
