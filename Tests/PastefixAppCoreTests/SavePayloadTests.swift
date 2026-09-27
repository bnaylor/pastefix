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

    @Test("an image session's real text is written verbatim, whitespace included")
    func whitespaceInAnImageSession() {
        var d = doc(text: nil, image: png)
        d.setWorking("  ")
        let payload = SavePayload(document: d)
        // Written, because there is a buffer and Save is not the place to decide a user's text is
        // not worth keeping. `isEmpty` still reads false on the image alone.
        #expect(payload.text == "  ")
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
