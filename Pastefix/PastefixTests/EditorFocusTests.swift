import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// #117: the editor only exists while text is showing, so a focus request made while an image
/// was up landed on nothing, and the editor came back without first responder — the first
/// keystroke went nowhere (GUI pass, #111).
@MainActor
@Suite("the editor takes focus when it comes back (#117)")
struct EditorFocusTests {
    private func host(_ f: ModelFixture) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func editorIsFirstResponder(_ window: NSWindow) -> Bool {
        guard let text = window.firstResponder as? NSTextView else { return false }
        return text.isEditable && !text.isFieldEditor
    }

    @Test("a text session after an image session")
    func afterImageSession() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.document?.displaysAsImage == true })
        try? await Task.sleep(nanoseconds: 100_000_000)
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        #expect(await f.eventually { self.editorIsFirstResponder(window) }, "first responder: \(String(describing: window.firstResponder))")
    }

    @Test("redo from the image back to recognised text")
    func redoBackToText() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        let window = host(f); defer { window.orderOut(nil) }
        f.model.apply(Reading(text: "recognised"))
        #expect(await f.eventually { f.model.document?.working == "recognised" && !f.model.isApplying })
        f.model.undo()
        #expect(await f.eventually { f.model.document?.displaysAsImage == true })
        try? await Task.sleep(nanoseconds: 100_000_000)
        window.makeFirstResponder(nil)
        f.model.redo()
        #expect(await f.eventually { self.editorIsFirstResponder(window) }, "first responder: \(String(describing: window.firstResponder))")
    }
}

private struct Reading: ImageTransformer {
    let id = "test.reading"; let name = "Reading"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.reading.focus")
    let text: String
    func transformImage(_ png: Data) throws -> TransformOutput { .text(text) }
}
