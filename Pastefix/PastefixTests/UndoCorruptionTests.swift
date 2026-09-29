import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// Data corruption on main (found by the `work` session, GUI-measured): type, apply a transform that
/// changes the text's length, ⌘Z — the editor replays its typing-undo at ranges recorded against the
/// OLD text, on the NEW text, deleting the wrong characters; the toolbar's Redo then carried the
/// damage into the model's history. Two undo stacks over one buffer.
@MainActor
@Suite("typing-undo after a transform (#103 hotfix)")
struct UndoCorruptionTests {
    private func textView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView { return t }
        for sub in view.subviews { if let t = textView(in: sub) { return t } }
        return nil
    }

    @Test("⌘Z after a length-changing transform doesn't replay typing at stale ranges")
    func noStaleReplay() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha   beta   gamma", richRTFD: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.makeKeyAndOrderFront(nil)
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "alpha   beta   gamma" })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("   Q", replacementRange: NSRange(location: 0, length: 0))   // typed: undoable
        #expect(await f.eventually { f.model.document?.working == "   Qalpha   beta   gamma" })
        // Precondition, or the test passes vacuously: the typing is on the editor's undo stack.
        #expect(editor.allowsUndo, "editor allowsUndo")
        #expect(editor.undoManager != nil, "editor has an undo manager")
        #expect(editor.undoManager?.canUndo == true, "typing registered an undo")
        #expect(editor.undoManager === window.undoManager, "the editor's typing-undo lives on the window's manager")
        let cleanup = try #require(f.model.transformers.first { $0.id == "builtin.whitespace" })
        f.model.apply(cleanup)
        #expect(await f.eventually { f.model.document?.working == "Qalpha   beta   gamma" })
        #expect(await f.eventually { editor.string == "Qalpha   beta   gamma" })
        // The root cause: a typing-undo recorded against the old text must not survive a programmatic
        // replacement, or ⌘Z replays it at stale ranges on the new text (measured in the GUI: "Qalp"
        // deleted, giving "ha   beta   gamma"). An in-process undo() doesn't reproduce the menu's
        // replay, so the survival of the action is what this pins; the replay is the GUI pass's.
        #expect(await f.eventually { editor.undoManager?.canUndo == false },
                "a stale \"\(editor.undoManager?.undoActionName ?? "")\" action survived the transform")
    }
}
