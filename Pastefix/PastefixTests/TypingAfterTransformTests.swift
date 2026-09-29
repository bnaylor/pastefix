import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Upper: Transformer {
    let id = "test.upper-type"; let name = "Upper"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text.uppercased() }
}

/// Typing after a transform that leaves non-ASCII text crashed the app ("String index is out of
/// bounds") — found through OCR in Plan 21's GUI pass, reproduced with no OCR involved. A real
/// keystroke into the hosted editor: on the old code the test process traps.
@MainActor
@Suite("typing after a non-ASCII transform (Plan 21 GUI pass)")
struct TypingAfterTransformTests {
    private func textView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView { return t }
        for sub in view.subviews { if let t = textView(in: sub) { return t } }
        return nil
    }

    @Test("a keystroke after the transform lands, instead of trapping")
    func typeAfterTransform() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "héllo wörld", richRTFD: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.makeKeyAndOrderFront(nil)
        f.model.apply(Upper())
        #expect(await f.eventually { f.model.document?.working == "HÉLLO WÖRLD" })
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "HÉLLO WÖRLD" })
        let editor = try #require(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(await f.eventually { f.model.document?.working == "HÉLLO WÖRLDx" })
    }
}
