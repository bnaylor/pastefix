import Testing
import Foundation
import AppKit
import PastefixCore
@testable import PastefixAppCore

private struct ImageStub: ImageTransformer {
    let id = "test.image"; let name = "Stub"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.coordinator")
    let output: @Sendable (Data) -> TransformOutput
    func transformImage(_ png: Data) throws -> TransformOutput { output(png) }
}

private struct RichStub: Transformer {
    let id = "test.rich"; let name = "Rich"; let requiresRichInput = true
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { "from rich" }
}

@Suite("the coordinator with image transforms (Plan 20)")
struct ImageTransformCoordinatorTests {
    /// A real PNG `width`×`height`, so `isPNG` and the pixel ceiling see real headers.
    static func png(_ width: Int = 8, _ height: Int = 8) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
    private func imageDoc(_ png: Data = png(), text: String? = nil, rich: Data? = nil) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: rich, imagePNG: png))
    }

    @Test("an image transform is offered in an image session and not in text or mixed ones")
    func gating() {
        let t = ImageStub { .image($0) }
        #expect(TransformCoordinator.isEnabled(t, for: imageDoc()))
        #expect(!TransformCoordinator.isEnabled(t, for: imageDoc(text: "caption")), "mixed opens as text")
        #expect(!TransformCoordinator.isEnabled(t, for: PasteDocument(origin: ClipboardSnapshot(plainText: "x", richRTFD: nil))))
    }

    @Test("an image result is pushed, with its note")
    func imagePushed() async {
        let other = Self.png(9, 9)
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .image(other, note: "done") }, to: imageDoc())
        #expect(outcome == .appliedWithNote("done") && doc.imagePNG == other && doc.canUndo)
    }

    @Test("the same image back is unchanged, with no push")
    func sameImage() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { .image($0) }, to: imageDoc())
        #expect(outcome == .unchanged && !doc.canUndo)
    }

    @Test("nothing to do pushes nothing and carries its sentence")
    func nothingToDo() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .nothingToDo("nothing") }, to: imageDoc())
        #expect(outcome == .nothingToDo("nothing") && !doc.canUndo)
    }

    @Test("an image result that isn't a PNG is refused")
    func notPNG() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .image(Data("jpeg?".utf8)) }, to: imageDoc())
        #expect(outcome == .failed("Stub didn't produce a usable image.") && !doc.canUndo)
    }

    @Test("a text result from an image replaces it")
    func textFromImage() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .text("read") }, to: imageDoc())
        #expect(outcome == .applied && doc.working == "read" && doc.imagePNG == nil)
    }

    // Review Focus 2: a session can hold a verbatim PNG over the ceiling.
    @Test("an image over the pixel ceiling is refused with its size and the limit")
    func overCeiling() async {
        let big = Self.png(6_000, 5_000)   // 30 MP
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { .image($0) }, to: imageDoc(big))
        #expect(outcome == .failed("Stub works on images up to 25 MP; this one is 30 MP.") && !doc.canUndo)
    }

    // Chrome's "Copy Image" writes HTML beside the image; after OCR, rich transforms would
    // replace the recognised text with a rendering of that HTML.
    @Test("rich transforms need a session that opened as text")
    func richAfterOCR() async {
        let rtfd = try? NSAttributedString(string: "html").data(from: NSRange(location: 0, length: 4),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        var doc = imageDoc(rich: rtfd)
        doc.pushState("ocr text")
        #expect(!TransformCoordinator.isEnabled(RichStub(), for: doc))
        let textOrigin = PasteDocument(origin: ClipboardSnapshot(plainText: "t", richRTFD: rtfd))
        #expect(TransformCoordinator.isEnabled(RichStub(), for: textOrigin))
    }
}
