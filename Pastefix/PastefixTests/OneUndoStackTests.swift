import Testing
import AppKit
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
        #expect(await f.eventually { f.model.canUndo && !f.model.canRedo }, "the toolbar mirrors the manager")
        um.undo()
        #expect(f.model.document?.working == "hello")
        #expect(!um.canUndo && um.canRedo && um.redoActionName == "Upper")
        #expect(await f.eventually { !f.model.canUndo && f.model.canRedo })
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
        #expect(await f.eventually { !f.model.canUndo })
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
        #expect(!f.model.canUndo && !f.model.canRedo)
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
        #expect(await f.eventually { f.model.canUndo }, "Undo stays available while applying")
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
}
