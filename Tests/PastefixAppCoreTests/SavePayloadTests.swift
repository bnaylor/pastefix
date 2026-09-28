import Testing
import Foundation
@testable import PastefixAppCore

/// The spec singled one rule out as needing a test rather than a comment — "a mixed session whose
/// text was edited saves the edited text *and* the original image" — and for most of this
/// increment that test could not exist, because the decision lived in `AppModel.save()`, app-target
/// code with no test host (#68). `SavePayload` is that decision, extracted; this is that test.
///
/// What is still uncovered here is the `NSPasteboard` write itself (`ClipboardBridge`), which stays
/// app-target and GUI-verified. These tests pin *what* Save writes, not that the pasteboard took it.
@Suite("SavePayload")
struct SavePayloadTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func doc(text: String?, image: Data? = nil, rich: Data? = nil) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: rich, imagePNG: image))
    }

    @Test("an image session writes the image and declares no empty string")
    func imageOnly() {
        let payload = SavePayload(document: doc(text: nil, image: png))
        #expect(payload.imagePNG == png)
        // nil, not "": an empty `public.string` alongside the image offers a text target nothing
        // where it could otherwise have taken the picture.
        #expect(payload.text == nil)
        #expect(payload.isEmpty == false)
    }

    @Test("a mixed session whose text was edited writes the edited text and the original image")
    func mixedEdited() {
        // The rule the spec named as needing a test. Both halves asserted: losing either one is the
        // failure ("Save never writes less than it was given" in the image half, and an image
        // session silently discarding typed text in the other).
        var d = doc(text: "before", image: png)
        d.setWorking("after")
        let payload = SavePayload(document: d)
        #expect(payload.text == "after")
        #expect(payload.imagePNG == png, "the origin's image, byte for byte")
        #expect(payload.isEmpty == false)
    }

    @Test("a text session writes its text and no image")
    func textOnly() {
        let payload = SavePayload(document: doc(text: "hello"))
        #expect(payload.text == "hello")
        #expect(payload.imagePNG == nil)
        #expect(payload.isEmpty == false)
    }

    // Before Plan 20 this typed "  " into an image session through `setWorking` and expected it
    // written back. An image session has no editor on screen, and since Plan 20 `setWorking` on an
    // image entry is ignored — that is what makes a stale TextEditor write-back after ⌘Z harmless.
    @Test("an image session writes its image, and a write-back onto it is ignored")
    func whitespaceInAnImageSession() {
        var d = doc(text: nil, image: png)
        d.setWorking("  ")
        let payload = SavePayload(document: d)
        #expect(payload.text == nil)
        #expect(payload.imagePNG == png)
        #expect(payload.isEmpty == false)
    }

    // MARK: Save's refusal — `isEmpty` is one half, `PasteDocument.isUnedited` the other

    @Test("a session that holds nothing has an empty payload, and it is unedited")
    func nothingToWrite() {
        // Reachable: a history item whose image file has gone missing, or whose blob was unusable.
        // Both halves true is what makes `save()` end the session instead of writing — the write
        // would be `clearContents()` and nothing else, over a clipboard still holding the picture.
        let d = doc(text: "")
        #expect(SavePayload(document: d).isEmpty)
        #expect(d.isUnedited)
    }

    @Test("an unedited session holding a refused image refuses to write, text or no text")
    func refusedImageRefusesEvenWithText() {
        // The regression this predicate exists to prevent, and the reason "is the payload empty" was
        // the wrong question. A *mixed* unedited session — real text plus an image over the ceiling —
        // has a perfectly non-empty payload, so an emptiness-only guard writes the text, and
        // `clearContents()` in front of that write destroys the picture the banner on screen has
        // just promised is safe. The session has no bytes for that image, so *any* write drops it.
        let mixed = PasteDocument(origin: ClipboardSnapshot(plainText: "notes about that photo",
                                                           richRTFD: nil, imagePNG: nil,
                                                           refusedImagePixels: 30_000_000))
        #expect(SavePayload(document: mixed).isEmpty == false, "there is text to write…")
        #expect(mixed.saveWouldLoseContent, "…and writing it would still lose the image")

        // The empty refused session is the same rule, reached through the other half of it.
        let empty = PasteDocument(origin: ClipboardSnapshot(plainText: nil, richRTFD: nil,
                                                           imagePNG: nil,
                                                           refusedImagePixels: 30_000_000))
        #expect(empty.saveWouldLoseContent)
    }

    @Test("typing in a refused-image session earns the write back")
    func editingARefusedSessionWrites() {
        // Deliberate destruction still works: the banner says the picture is on the clipboard until
        // you save text over it, and this is that. An edited document writes whatever it holds.
        var d = PasteDocument(origin: ClipboardSnapshot(plainText: "notes", richRTFD: nil,
                                                       imagePNG: nil,
                                                       refusedImagePixels: 30_000_000))
        d.setWorking("notes, edited")
        #expect(d.saveWouldLoseContent == false)
        #expect(SavePayload(document: d).text == "notes, edited")
    }

    @Test("an ordinary session writes")
    func ordinarySessionsWrite() {
        #expect(doc(text: "hello").saveWouldLoseContent == false)
        #expect(doc(text: nil, image: png).saveWouldLoseContent == false, "an image session saves it back")
        var cleared = doc(text: "something")
        cleared.setWorking("")
        #expect(cleared.saveWouldLoseContent == false, "a deliberate clear is a write")
        #expect(doc(text: "").saveWouldLoseContent, "but an unedited session with nothing in it is not")
    }

    @Test("blank once trimmed is nothing", arguments: ["", " ", "\n", "  \t\n "])
    func blankIsNothing(_ blank: String) {
        // The same rule as `PasteDocument.displaysAsImage`, `PendingImage.resolve` and
        // `HistoryStore.record`. A save path that disagreed with the capture path about whether a
        // buffer has text would give two answers for one clipboard.
        #expect(SavePayload(document: doc(text: blank)).isEmpty)
    }

    @Test("select all, delete, save still clears the clipboard")
    func deliberateClearStillWrites() {
        // The case where this fix could break correct behaviour rather than fixing a bug: clearing
        // the clipboard on purpose is a use of this app. `isUnedited` is a *content* comparison
        // against the origin, so a cleared buffer reports edited — and `save()`'s refusal needs
        // both halves, so the empty write happens.
        var d = doc(text: "something")
        d.setWorking("")
        #expect(SavePayload(document: d).isEmpty, "there is nothing to write…")
        #expect(d.isUnedited == false, "…but the user asked for it, so Save must write it")
        // And the write it performs is the clearing one: an empty string, no image.
        #expect(SavePayload(document: d).text == "")
        #expect(SavePayload(document: d).imagePNG == nil)
    }

    @Test("clearing and retyping the origin text reports unedited again")
    func retypingTheOriginIsUneditedAgain() {
        // A consequence of `isUnedited` comparing content rather than tracking a dirty flag. It is
        // harmless — the buffer is not empty, so the payload has something to write and the refusal
        // never fires — but pinned here so that turning `isUnedited` into a dirty flag later shows
        // up as a failing test rather than as a silent change to what ⌘S does.
        var d = doc(text: "something")
        d.setWorking("")
        d.setWorking("something")
        #expect(d.isUnedited)
        #expect(SavePayload(document: d).isEmpty == false)
    }

    @Test("an empty image is nothing, not an image")
    func emptyImageIsNotAnImage() {
        // The backstop, and it deliberately does not trust the thing it backs up: `imagePNG` is
        // nil-or-valid at both entry points (`ClipboardImageRead`, `AppModel.load`), so `Data()`
        // should be unreachable here — but a guard that assumed that would be decoration. A
        // zero-byte `public.png` write is the failure this area of the code exists to prevent.
        let payload = SavePayload(document: doc(text: nil, image: Data()))
        #expect(payload.imagePNG == nil)
        #expect(payload.isEmpty)
    }

    // MARK: The armed-Markdown branch reads the same payload as every other save

    @Test("an armed-Markdown save cannot emit zero-byte image data")
    func armedMarkdownNeverWritesEmptyImageData() {
        // The bug this replaces: `ClipboardBridge.writeRich` took a loose `imagePNG: Data?` and
        // `save()` handed it `doc.imagePNG`, the raw origin bytes, bypassing the backstop in
        // `SavePayload.init` — so an armed-Markdown Save over an origin with empty image bytes wrote
        // zero bytes under `public.png`, the one write this area exists to prevent.
        //
        // This is the deepest level the seam allows: `writeRich` is app-target code with no test
        // host (#68), so what a test can pin is that its *only* source of image bytes is a payload
        // that never carries empty ones. The signature change is what makes that the only source —
        // there is no longer a parameter to pass raw bytes through.
        var armed = doc(text: "# heading", image: Data())
        armed.outputMode = .renderedMarkdown
        #expect(SavePayload(document: armed).imagePNG == nil)
    }

    @Test("arming Markdown changes the text, never the other representations")
    func armingChangesNothingButText() {
        // The rule in the signature, asserted on the value the signature carries: a rendered save
        // may choose how the *text* is written (HTML and RTF are its renderings of it) and reads
        // every other representation off the payload — so arming must leave the payload's non-text
        // fields identical to the plain save's.
        var plain = doc(text: "# heading", image: png)
        var armed = plain
        armed.outputMode = .renderedMarkdown
        #expect(SavePayload(document: armed) == SavePayload(document: plain))
        #expect(SavePayload(document: armed).imagePNG == png, "the origin's image, byte for byte")
        // And the mode itself is not a representation the payload records: it decides *how* the
        // app target renders the text, which is the exception, not a fourth field here.
        plain.outputMode = .plain
        #expect(SavePayload(document: plain).text == "# heading")
    }

    @Test("the origin's rich content is not part of a plain save")
    func richIsNotWritten() {
        // Stating the policy rather than discovering it: putting *plain* text back is what this app
        // is for, and no non-Markdown save has ever written the origin's RTFD. Armed
        // Markdown → Rich Text is how a user asks for formatted output, and that path renders its
        // own rich content in the app target rather than coming through here.
        let payload = SavePayload(document: doc(text: "hello", rich: Data([0x7B, 0x5C, 0x72, 0x74])))
        #expect(payload.richRTFD == nil)
        #expect(payload.text == "hello")
    }
}
