import Testing
import Foundation
@testable import PastefixAppCore

@Suite("PasteDocument display form")
struct PasteDocumentImageTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func doc(text: String?, image: Data?) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, imagePNG: image))
    }

    @Test("image and no text displays as an image")
    func imageOnly() {
        #expect(doc(text: nil, image: png).displaysAsImage)
    }

    @Test("image and real text displays as text")
    func mixed() {
        // The decision that protects every existing text workflow: a clipboard carrying both
        // keeps opening the editor. The image stays on the session for image-aware actions.
        let d = doc(text: "https://example.test/cat.png", image: png)
        #expect(d.displaysAsImage == false)
        #expect(d.imagePNG == png, "the image must still be carried, not dropped")
    }

    @Test("text and no image displays as text")
    func textOnly() {
        #expect(doc(text: "hello", image: nil).displaysAsImage == false)
    }

    @Test("neither displays as text")
    func neither() {
        #expect(doc(text: nil, image: nil).displaysAsImage == false)
    }

    @Test("blank text with an image displays as an image", arguments: ["", " ", "\n", "  \t\n "])
    func blankTextIsNotText(_ blank: String) {
        // Same rule as PendingImage.resolve:33 and HistoryStore.record: blank once trimmed is
        // not text. Without it, an image plus a single space opens the editor on nothing —
        // and a capture path and a session path disagreeing about "has text" is the kind of
        // divergence that produces two answers for one clipboard.
        #expect(doc(text: blank, image: png).displaysAsImage)
    }

    @Test("blank text with no image still displays as text")
    func blankTextNoImage() {
        #expect(doc(text: " ", image: nil).displaysAsImage == false)
    }

    @Test("an image session has nothing to undo")
    func noUndo() {
        #expect(doc(text: nil, image: png).canUndo == false)
    }

    @Test("clearing a mixed session's text leaves it displaying as text")
    func clearingMixedTextIsSticky() {
        // The editor must not vanish mid-edit. `setWorking` pushes no history, so a live
        // derivation over `working` would flip this true on the keystroke that empties the buffer,
        // swap the editor for the image view, and leave `canUndo == false` — no ⌘Z back, no way to
        // type for the rest of the session. The form is decided at init and stays decided.
        var d = doc(text: "caption", image: png)
        #expect(d.displaysAsImage == false)
        d.setWorking("")
        #expect(d.displaysAsImage == false, "the editor must still be there after ⌘A Delete")
        d.setWorking("   \n ")
        #expect(d.displaysAsImage == false, "blank is not a different answer from empty here")
        #expect(d.canUndo == false, "and there is nothing to undo, which is why stickiness matters")
    }

    @Test("a pushed transform cannot change the display form either")
    func pushIsSticky() {
        var d = doc(text: "caption", image: png)
        d.pushState("")
        #expect(d.displaysAsImage == false)
    }

    @Test("a refreshed origin is a new decision")
    func refreshRederives() {
        // Stickiness is per origin, not for ever: ⌘R replaces the whole document, so a clipboard
        // now holding only an image opens as an image session.
        var d = doc(text: "caption", image: nil)
        #expect(d.displaysAsImage == false)
        d.refresh(origin: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        #expect(d.displaysAsImage)
    }
}
