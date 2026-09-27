import Testing
import AppKit
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// Save's defects from Plan 15 / #48, each pinned against the real `AppModel.save` and a real
/// (private) pasteboard. The package-level tests pin the decisions (`SavePayload`,
/// `saveWouldLoseContent`); these pin that `save()` actually obeys them.
@MainActor
@Suite("Save")
struct SaveDefectTests {
    /// Every PNG on the pasteboard must be non-empty: zero bytes under public.png written over the
    /// user's clipboard is what this whole area exists to prevent.
    func pngOnPasteboard(_ pb: NSPasteboard) -> Data? { pb.data(forType: .png) }

    @Test("a zero-byte history blob never becomes a session image, and Save writes no empty PNG")
    func zeroByteBlob() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 8, height: 8, type: "public.png"))
        let item = try #require(f.history.record(CaptureCandidate(imagePNG: png, imagePixelWidth: 8, imagePixelHeight: 8)))
        f.history.flush()
        let blob = try #require(f.history.imageURL(for: item))
        try Data().write(to: blob)                       // the blob on disk is now zero bytes
        f.model.load(item)
        // `try #require` first: `document?.origin.imagePNG != Data()` alone passes when there is
        // no document at all.
        let doc = try #require(f.model.document)
        #expect(doc.origin.imagePNG != Data())
        let before = f.pasteboard.changeCount
        f.model.save()
        if f.pasteboard.changeCount != before, let written = pngOnPasteboard(f.pasteboard) {
            #expect(!written.isEmpty, "Save wrote a zero-byte PNG over the clipboard")
        }
    }

    @Test("an unedited mixed session holding a refused image does not write — the image survives")
    func refusedImageSurvivesUneditedSave() throws {
        let f = try ModelFixture(); defer { f.finish() }
        // 26 MP: over the ceiling. LZW-compressed and solid, so it is small and never decoded.
        let tiff = try #require(Pixels.encoded(width: 5200, height: 5000, type: "public.tiff", compressedTIFF: true))
        f.copy([.string: Data("some text".utf8), .tiff: tiff])
        f.model.summon()
        #expect(f.model.document?.origin.refusedImagePixels != nil)   // fixture sanity
        let before = f.pasteboard.changeCount
        f.model.save()
        #expect(f.pasteboard.changeCount == before, "Save wrote over a clipboard it could not reproduce")
        #expect(f.pasteboard.data(forType: .tiff) == tiff)
    }

    @Test("an armed-Markdown Save takes its image from the payload, so an empty image is never written")
    func markdownSaveUsesPayload() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        // Upstream validation now keeps `Data()` out of sessions; this starts from one anyway,
        // because the defect was the Markdown branch reading the raw origin instead of the payload.
        f.model.beginSession(from: ClipboardSnapshot(plainText: "# Title\n\nbody", richRTFD: nil, imagePNG: Data()))
        let markdown = try #require(f.model.enabledTransformers().first { $0.id == "builtin.markdowntorich" })
        f.model.apply(markdown)
        #expect(await f.eventually { f.model.document?.outputMode == .renderedMarkdown })
        f.model.save()
        let written = pngOnPasteboard(f.pasteboard)
        #expect(written == nil || !(written!.isEmpty), "the Markdown branch wrote a zero-byte PNG")
    }
}
