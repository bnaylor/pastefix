import Testing
import AppKit
import Combine
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Upper: Transformer {
    let id = "test.upper"; let name = "Upper"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text.uppercased() }
}

private struct Same: Transformer {
    let id = "test.same"; let name = "Same"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

private struct Fails: Transformer {
    struct Boom: Error {}
    let id = "test.fails"; let name = "Fails"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { throw Boom() }
}

/// Holds a transform in flight until the test opens it; ignores cancellation, like a Foundation
/// call that can't be interrupted.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock(); defer { lock.unlock() }
            if isOpen { c.resume() } else { waiter = c }
        }
    }
    func open() {
        lock.lock(); isOpen = true; let w = waiter; waiter = nil; lock.unlock()
        w?.resume()
    }
}

private struct Held: Transformer {
    let id = "test.held"; let name = "Held"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let gate: Gate
    func apply(_ input: TransformInput) async throws -> String { await gate.wait(); return input.text + "!" }
}

private struct Reading: ImageTransformer {
    let id = "test.reading"; let name = "Reading"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.reading")
    let text: String
    func transformImage(_ png: Data) throws -> TransformOutput { .text(text) }
}

/// #103: typing and transforms share the panel window's one undo stack, so ⌘Z walks them in the
/// order they happened — and a typing action is never replayed against text it wasn't recorded on.
@MainActor
@Suite("one undo stack for typing and transforms (#103)")
struct OneUndoStackTests {
    private func host(_ f: ModelFixture) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView, t.isEditable { return t }
        for sub in view.subviews { if let t = textView(in: sub) { return t } }
        return nil
    }

    /// What Edit ▸ Undo does: `undo:` up the responder chain from the first responder.
    private func sendUndo(_ window: NSWindow, redo: Bool = false) -> Bool {
        let action = Selector(redo ? "redo:" : "undo:")
        return (window.firstResponder ?? window).tryToPerform(action, with: nil)
    }

    private func bound(_ f: ModelFixture, _ window: NSWindow) async -> UndoManager? {
        _ = await f.eventually { f.model.undoManager != nil }
        #expect(f.model.undoManager === window.undoManager, "the model registers on the panel window's manager")
        return f.model.undoManager
    }

    @Test("a transform is one action on the window's stack, named after it")
    func registersOneNamedAction() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        f.model.apply(Upper())
        #expect(await f.eventually { f.model.document?.working == "HELLO" && !f.model.isApplying })
        #expect(um.canUndo && um.undoActionName == "Upper")
        #expect(await f.eventually { f.model.undoState.canUndo && !f.model.undoState.canRedo }, "the toolbar mirrors the manager")
        um.undo()
        #expect(f.model.document?.working == "hello")
        #expect(!um.canUndo && um.canRedo && um.redoActionName == "Upper")
        #expect(await f.eventually { !f.model.undoState.canUndo && f.model.undoState.canRedo })
        um.redo()
        #expect(f.model.document?.working == "HELLO")
        #expect(um.canUndo && !um.canRedo)
    }

    @Test("an apply that changes nothing leaves nothing to undo", arguments: ["same", "fails"])
    func noOpRegistersNothing(_ which: String) async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        f.model.apply(which == "same" ? Same() as any Transformer : Fails())
        #expect(await f.eventually { !f.model.isApplying })
        #expect(!um.canUndo, "\"\(um.undoActionName)\" left on the stack")
        #expect(await f.eventually { !f.model.undoState.canUndo })
    }

    @Test("typing, then a transform: ⌘Z undoes the transform back to the typed text, alone")
    func typingThenTransform() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha   beta   gamma", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "alpha   beta   gamma" })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("   Q", replacementRange: NSRange(location: 0, length: 0))
        #expect(await f.eventually { f.model.document?.working == "   Qalpha   beta   gamma" })
        #expect(um.canUndo, "precondition: the typing is on the window's stack")
        // The end of the key event closes its group; nothing ends one in a test host (measured:
        // `groupingLevel` stays 1 across run-loop passes), so do what the event loop would.
        if um.groupingLevel > 0 { um.endUndoGrouping() }
        let cleanup = try #require(f.model.transformers.first { $0.id == "builtin.whitespace" })
        f.model.apply(cleanup)
        #expect(await f.eventually { editor.string == "Qalpha   beta   gamma" && !f.model.isApplying })
        // The transform's group is closed when it lands: left open, the next keystroke would join it.
        #expect(um.groupingLevel == 0, "the transform's group is still open")
        #expect(um.undoActionName == cleanup.name, "the transform is on top of the typing")
        #expect(sendUndo(window), "undo: reached a handler")
        #expect(await f.eventually { editor.string == "   Qalpha   beta   gamma" })
        #expect(f.model.document?.working == "   Qalpha   beta   gamma")
        // The transform was alone in its group: the typing below it is still there to undo.
        #expect(um.canUndo, "the typing went with the transform")
        #expect(um.redoActionName == cleanup.name)
    }

    @Test("every session boundary empties the stack", arguments: ["refresh", "begin", "end"])
    func boundariesClear(_ boundary: String) async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "hello")
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        f.model.apply(Upper())
        #expect(await f.eventually { f.model.document?.working == "HELLO" && !f.model.isApplying })
        #expect(um.canUndo)
        switch boundary {
        case "refresh": f.model.refresh()
        case "begin": f.model.beginSession(from: ClipboardSnapshot(plainText: "other", richRTFD: nil))
        default: f.model.cancel()
        }
        #expect(!um.canUndo && !um.canRedo, "\"\(um.undoActionName)\" survived \(boundary)")
        #expect(!f.model.undoState.canUndo && !f.model.undoState.canRedo)
    }

    /// The undo itself goes ahead on the previous step; ⌘⇧Z brings it back.
    @Test("⌘Z while a transform is applying cancels it before undoing")
    func undoDuringApplyCancels() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        f.model.apply(Upper())
        #expect(await f.eventually { f.model.document?.working == "HELLO" && !f.model.isApplying })
        let gate = Gate()
        f.model.apply(Held(gate: gate))
        #expect(f.model.isApplying)
        #expect(await f.eventually { f.model.undoState.canUndo }, "Undo stays available while applying")
        um.undo()
        #expect(!f.model.isApplying, "cancelled")
        #expect(f.model.document?.working == "hello")
        gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(f.model.document?.working == "hello", "the cancelled result never lands")
        #expect(!um.canUndo && um.canRedo && um.redoActionName == "Upper")
        um.redo()
        #expect(f.model.document?.working == "HELLO")
    }

    @Test("OCR, then ⌘Z brings the image back through the window's stack")
    func imageSessionUndo() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        f.model.apply(Reading(text: "recognised"))
        #expect(await f.eventually { f.model.document?.working == "recognised" && !f.model.isApplying })
        #expect(sendUndo(window))
        #expect(f.model.document?.imagePNG == png)
        #expect(sendUndo(window, redo: true))
        #expect(f.model.document?.working == "recognised")
        #expect(um.canUndo && !um.canRedo)
    }
    /// GUI pass (#111): the first keystroke flips Undo on, and publishing that on the model
    /// re-rendered the view that owns the TextEditor mid-keystroke; a fast "   Q" came out as
    /// "  one two three Q" (caret thrown to the end). Undo state is its own object, which the
    /// model never republishes.
    @Test("an undo-state change doesn't publish on the model")
    func undoStateIsNotModelState() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "one two three", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        #expect(await f.eventually { !f.model.undoState.canUndo })
        try? await Task.sleep(nanoseconds: 100_000_000)
        var published = 0
        let watch = f.model.objectWillChange.sink { _ in published += 1 }
        defer { watch.cancel() }
        final class Target {}
        let target = Target()
        um.beginUndoGrouping()
        um.registerUndo(withTarget: target) { _ in }
        um.endUndoGrouping()
        #expect(await f.eventually { f.model.undoState.canUndo })
        #expect(published == 0, "the model published \(published)× for an undo-state change")
        um.removeAllActions()
    }

    /// GUI pass (#111): IME marked text lives in the editor and on the undo stack but not in the
    /// model, so a transform ran on text without it — the "´" was dropped — and ⌘Z later replayed
    /// the marked insert's undo at a stale range, deleting a newline. Marked text is committed
    /// before a transform reads the buffer.
    @Test("marked text is committed before a transform reads the buffer")
    func markedTextCommittedBeforeApply() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "cafe\nbar   ", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "cafe\nbar   " })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.setMarkedText("\u{00B4}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 4, length: 0))
        #expect(editor.hasMarkedText(), "precondition: marked text is up")
        let cleanup = try #require(f.model.transformers.first { $0.id == "builtin.whitespace" })
        f.model.apply(cleanup)
        #expect(await f.eventually { !f.model.isApplying })
        #expect(f.model.document?.working == "cafe\u{00B4}\nbar", "the marked character reached the transform")
        #expect(!editor.hasMarkedText())
        um.undo()
        #expect(f.model.document?.working == "cafe\u{00B4}\nbar   ")
    }

    /// GUI pass 2 (#111): the marked "´" was already gone before the transform ran. Any re-render
    /// of the panel (⌘K opening, a sidebar click) had SwiftUI's TextEditor re-set its text from the
    /// binding — which never holds marked text — discarding the composition without an undo
    /// record, so the marked insert's undo later deleted a newline (measured in-process: "cafebar").
    @Test("a re-render during a composition keeps it, and undo stays in step")
    func compositionSurvivesARerender() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "cafe\nbar   ", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "cafe\nbar   " })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.setMarkedText("\u{00B4}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 4, length: 0))
        f.model.transformNote = "re-render"                       // anything the panel shows
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(editor.hasMarkedText() && editor.string == "cafe\u{00B4}\nbar   ", "the composition was discarded: \(editor.string.debugDescription)")
        let cleanup = try #require(f.model.transformers.first { $0.id == "builtin.whitespace" })
        f.model.apply(cleanup)
        #expect(await f.eventually { !f.model.isApplying })
        #expect(f.model.document?.working == "cafe\u{00B4}\nbar")
        um.undo()
        #expect(f.model.document?.working == "cafe\u{00B4}\nbar   ")
        #expect(await f.eventually { editor.string == "cafe\u{00B4}\nbar   " })
    }

    /// A session boundary during a composition ends it: the new session's text is shown, not the
    /// old composition, and nothing is left to undo.
    @Test("a refresh during a composition shows the new clipboard")
    func refreshEndsAComposition() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "fresh")
        f.model.beginSession(from: ClipboardSnapshot(plainText: "cafe", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "cafe" })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.setMarkedText("\u{00B4}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 4, length: 0))
        f.model.refresh()
        #expect(await f.eventually { editor.string == "fresh" }, "editor shows \(editor.string.debugDescription)")
        #expect(f.model.document?.working == "fresh", "the old composition leaked into the new session")
        #expect(!editor.hasMarkedText() && !um.canUndo)
    }

    /// GUI pass 3 (#111): ending a composition at Refresh made the editor write its old text
    /// through the binding AFTER the new document was installed — the refreshed session showed,
    /// and saved, the old buffer. That late write is dropped.
    @Test("the ended session's late editor write doesn't land in the new one")
    func lateWriteAfterABoundaryIsDropped() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "fresh clip")
        f.model.beginSession(from: ClipboardSnapshot(plainText: "cafe", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        _ = try #require(await bound(f, window))
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "cafe" })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.setMarkedText("\u{00B4}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 4, length: 0))
        f.model.refresh()
        // The late binding write carries whatever the editor held once the composition ended: "cafe"
        // with a real input method (the accent discarded), "cafe´" here (no input method).
        let ended = editor.string
        f.model.setWorking(ended)
        #expect(f.model.document?.working == "fresh clip")
        #expect(await f.eventually { editor.string == "fresh clip" })
        f.model.setWorking("fresh clip!")                           // real typing still lands
        #expect(f.model.document?.working == "fresh clip!")
    }

    /// GUI passes 2–4 (#111): whatever ended a composition from inside the apply path, AppKit left
    /// the marked insert's undo on the stack, and after the transform was undone it deleted a
    /// newline. Four attempts to make AppKit settle it depended on event timing. Deterministic
    /// instead: a transform over a live composition starts from an empty stack. Rare (an accent
    /// half-typed when a transform is clicked), and it costs history, never text.
    @Test("a transform over a live composition leaves nothing stale beneath it")
    func compositionAtApplyEmptiesTheStack() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "cafe\nbar   ", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        let um = try #require(await bound(f, window))
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "cafe\nbar   " })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        // Each keystroke in a group of its own, as its event would give it (nothing closes an
        // automatic group in a test host, and registering outside one throws).
        if um.groupingLevel > 0 { um.endUndoGrouping() }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        um.beginUndoGrouping()
        editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        um.endUndoGrouping()
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        um.beginUndoGrouping()
        editor.setMarkedText("\u{00B4}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 5, length: 0))
        um.endUndoGrouping()
        let cleanup = try #require(f.model.transformers.first { $0.id == "builtin.whitespace" })
        f.model.apply(cleanup)
        #expect(await f.eventually { !f.model.isApplying })
        #expect(um.undoActionName == cleanup.name)
        um.undo()
        #expect(!um.canUndo, "\"\(um.undoActionName)\" is still under the transform")
        #expect(await f.eventually { self.editorIsFocused(window) }, "focus comes back after the apply")
    }

    @Test("a refresh that ended a composition gives the editor its focus back")
    func refreshKeepsFocus() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "fresh clip")
        f.model.beginSession(from: ClipboardSnapshot(plainText: "cafe", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        _ = try #require(await bound(f, window))
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "cafe" })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.setMarkedText("\u{00B4}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 4, length: 0))
        f.model.refresh()
        #expect(await f.eventually { editor.string == "fresh clip" && self.editorIsFocused(window) })
    }

    private func editorIsFocused(_ window: NSWindow) -> Bool {
        guard let text = window.firstResponder as? NSTextView else { return false }
        return text.isEditable && !text.isFieldEditor
    }
}
