import Testing
import Foundation
@testable import PastefixAppCore
@testable import PastefixCore

private struct FormStub: Transformer {
    let id: String
    let name = "Stub"
    let requiresRichInput = false
    let source = TransformerSource.builtin
    var acceptedForms: Set<ContentForm>
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

private struct TextDefaultStub: Transformer {
    let id = "text-default"
    let name = "Text default"
    let requiresRichInput = false
    let source = TransformerSource.builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite("Transform form filtering")
struct TransformFormFilterTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func doc(text: String?, image: Data?) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, imagePNG: image))
    }

    @Test("a transform that declares nothing accepts text only")
    func defaultIsText() {
        // The default must be explicit and text: ~30 existing transforms declare nothing, and a
        // new one must not claim it handles images by omission.
        #expect(TextDefaultStub().acceptedForms == [.text])
    }

    @Test("a text transform is enabled for a text session and not an image one")
    func textTransform() {
        let t = FormStub(id: "t", acceptedForms: [.text])
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: "hi", image: nil)))
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: nil, image: png)) == false)
    }

    @Test("an image transform is enabled for an image session and not a text one")
    func imageTransform() {
        let t = FormStub(id: "i", acceptedForms: [.image])
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: nil, image: png)))
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: "hi", image: nil)) == false)
    }

    @Test("a both-forms transform is enabled either way")
    func eitherTransform() {
        let t = FormStub(id: "e", acceptedForms: [.text, .image])
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: "hi", image: nil)))
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: nil, image: png)))
    }

    @Test("a mixed session is a text session for filtering")
    func mixedSessionFiltersAsText() {
        // Follows displaysAsImage, not "is there an image": a clipboard with both opens the
        // editor, so text transforms must be available there.
        let mixed = doc(text: "https://example.test/cat.png", image: png)
        #expect(TransformCoordinator.isEnabled(FormStub(id: "t", acceptedForms: [.text]), for: mixed))
        #expect(TransformCoordinator.isEnabled(FormStub(id: "i", acceptedForms: [.image]), for: mixed) == false)
    }

    @Test("requiresRichInput still gates independently of form")
    func richStillGates() {
        // Two independent gates; an image is not rich content, so a rich transform stays off in
        // an image session for its own reason.
        struct RichStub: Transformer {
            let id = "r"; let name = "Rich"; let requiresRichInput = true
            let source = TransformerSource.builtin
            func apply(_ input: TransformInput) async throws -> String { input.text }
        }
        #expect(TransformCoordinator.isEnabled(RichStub(), for: doc(text: "hi", image: nil)) == false)
    }
}
