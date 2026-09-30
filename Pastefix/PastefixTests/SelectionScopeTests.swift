import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Bracket: Transformer {
    let id = "test.bracket"; let name = "Bracket"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { "[" + input.text + "]" }
}

/// #25, view half: the scoping predicate, and the span selected after apply, ⌘Z and ⌘⇧Z.
@MainActor
@Suite("selection-scoped transforms, view (#25)")
struct SelectionScopeTests {
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
    private func scope(_ text: String, _ location: Int, _ length: Int) -> TransformScope {
        TransformScope.make(selected: Range(NSRange(location: location, length: length), in: text)!, in: text)!
    }
    private func sendUndo(_ window: NSWindow, redo: Bool = false) -> Bool {
        (window.firstResponder ?? window).tryToPerform(Selector(redo ? "redo:" : "undo:"), with: nil)
    }

    @Test func onlyASingleRealSubrangeScopes() {
        let text = "alpha beta"
        let beta = Range(NSRange(location: 6, length: 4), in: text)!
        #expect(SelectionScope.scope(for: TextSelection(range: beta), in: text)?.expected == "beta")
        #expect(SelectionScope.scope(for: nil, in: text) == nil)
        #expect(SelectionScope.scope(for: TextSelection(range: text.startIndex..<text.endIndex), in: text) == nil)
        #expect(SelectionScope.scope(for: TextSelection(insertionPoint: text.startIndex), in: text) == nil)
        let alpha = Range(NSRange(location: 0, length: 5), in: text)!
        let multi = TextSelection(ranges: RangeSet([alpha, beta]))
        #expect(SelectionScope.scope(for: multi, in: text) == nil, "multi-range runs on the whole buffer")
    }

    @Test func theNewSpanIsSelectedAndUndoRedoReselect() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "alpha beta gamma" && f.model.undoManager != nil })
        let editor = try #require(textView(in: window.contentView!))
        f.model.apply(Bracket(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { editor.string == "alpha [beta] gamma" && editor.selectedRange() == NSRange(location: 6, length: 6) },
                "selected \(editor.selectedRange())")
        #expect(f.model.pendingSelection == nil, "consumed")
        #expect(sendUndo(window))
        #expect(await f.eventually { editor.string == "alpha beta gamma" && editor.selectedRange() == NSRange(location: 6, length: 4) },
                "after ⌘Z \(editor.selectedRange())")
        #expect(sendUndo(window, redo: true))
        #expect(await f.eventually { editor.string == "alpha [beta] gamma" && editor.selectedRange() == NSRange(location: 6, length: 6) },
                "after ⌘⇧Z \(editor.selectedRange())")
    }

    /// The measured failure: without the pending span, `carrySelection` keeps raw offsets after a
    /// length change and selects the wrong characters. Shorter result, span at the end of the text.
    @Test func shorterResultSelectsExactlyTheNewText() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "     aaa bbb ccc", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "     aaa bbb ccc" && f.model.undoManager != nil })
        let editor = try #require(textView(in: window.contentView!))
        let dropFirst = TestTransformer(name: "Drop") { String($0.text.dropFirst()) }
        f.model.apply(dropFirst, scope: scope("     aaa bbb ccc", 13, 3))
        #expect(await f.eventually { editor.string == "     aaa bbb cc" && editor.selectedRange() == NSRange(location: 13, length: 2) },
                "selected \(editor.selectedRange())")
    }

    /// Review Focus 4: typing into the transformed span, then ⌘Z ⌘Z ⌘⇧Z — the re-selection is always
    /// in bounds and never traps. Typing goes in its own undo group, as its key event would give it
    /// (nothing closes an automatic group in a test host, and registering outside one throws).
    @Test func redoAfterTypingDoesNotTrap() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "alpha beta gamma" && f.model.undoManager != nil })
        let editor = try #require(textView(in: window.contentView!))
        let um = try #require(f.model.undoManager)
        f.model.apply(Bracket(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { editor.string == "alpha [beta] gamma" && !f.model.isApplying })
        if um.groupingLevel > 0 { um.endUndoGrouping() }
        um.beginUndoGrouping()
        editor.insertText(" and more", replacementRange: NSRange(location: 18, length: 0))
        um.endUndoGrouping()
        #expect(await f.eventually { f.model.document?.working == "alpha [beta] gamma and more" })
        #expect(sendUndo(window))                            // the typing
        #expect(sendUndo(window))                            // the transform: re-selects (6,4)
        #expect(await f.eventually { editor.string == "alpha beta gamma" })
        #expect(sendUndo(window, redo: true))                // the transform again: re-selects (6,6)
        #expect(await f.eventually {
            NSMaxRange(editor.selectedRange()) <= (editor.string as NSString).length
                && editor.selectedRange() == NSRange(location: 6, length: 6)
        }, "selected \(editor.selectedRange()) in \(editor.string.debugDescription)")
    }

    /// GUI pass: a whole-only transform run while text was selected left raw offsets selecting
    /// unrelated characters ("a be" after Rich → Markdown). It leaves a caret at the selection's start.
    @Test func wholeOnlyTransformWithASelectionLeavesACaret() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "alpha beta gamma" && f.model.undoManager != nil })
        let editor = try #require(textView(in: window.contentView!))
        f.model.apply(WholeOnly(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { editor.string == "**alpha beta gamma**" && editor.selectedRange() == NSRange(location: 6, length: 0) },
                "selected \(editor.selectedRange())")
        // ⌘Z brings back the selection the user had, as it does for a scoped transform (GUI recheck).
        #expect(sendUndo(window))
        #expect(await f.eventually { editor.string == "alpha beta gamma" && editor.selectedRange() == NSRange(location: 6, length: 4) },
                "after ⌘Z \(editor.selectedRange())")
    }
}

/// Can't scope (an output-mode transform), and changes the whole buffer.
private struct WholeOnly: OutputModeTransformer {
    let id = "test.wholeonly"; let name = "Whole Only"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let outputMode: OutputMode = .plain
    func apply(_ input: TransformInput) async throws -> String { "**" + input.text + "**" }
}

private struct TestTransformer: Transformer {
    let id = "test.t"; let name: String; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let body: @Sendable (TransformInput) -> String
    init(name: String, _ body: @escaping @Sendable (TransformInput) -> String) { self.name = name; self.body = body }
    func apply(_ input: TransformInput) async throws -> String { body(input) }
}
