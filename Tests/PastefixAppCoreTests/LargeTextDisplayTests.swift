import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// Over 1 MB, the panel shows a placeholder instead of laying the text out (#52, #62): layout is
/// ~1 s per MB (measured), so a 17 MB clipboard kept ⌘⇧U waiting ~9 s just to say "too large".
@Suite("PasteDocument.displaysAsLargeText")
struct LargeTextDisplayTests {
    private func doc(bytes: Int, image: Data? = nil) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: String(repeating: "a", count: bytes),
                                                richRTFD: nil, imagePNG: image))
    }

    @Test("the limit is exactly 1 MB, shared with detection's cap")
    func boundary() {
        #expect(PasteDocument.editorDisplayLimitBytes == ContentDetector.maxBytes)
        #expect(!doc(bytes: PasteDocument.editorDisplayLimitBytes).displaysAsLargeText)
        #expect(doc(bytes: PasteDocument.editorDisplayLimitBytes + 1).displaysAsLargeText)
    }

    @Test("bytes, not characters: multi-byte text crosses the limit on its UTF-8 size")
    func utf8Bytes() {
        let emoji = String(repeating: "🙂", count: PasteDocument.editorDisplayLimitBytes / 4 + 1)
        #expect(PasteDocument(origin: ClipboardSnapshot(plainText: emoji, richRTFD: nil)).displaysAsLargeText)
    }

    @Test("it follows the working text: a transform that shrinks it brings the editor back")
    func followsWorkingText() {
        var d = doc(bytes: 2_000_000)
        #expect(d.displaysAsLargeText)
        d.pushState("short")
        #expect(!d.displaysAsLargeText)
        d.undo()
        #expect(d.displaysAsLargeText)
    }

    @Test("an image session is never a large-text session")
    func imageSessionUnaffected() {
        let img = PasteDocument(origin: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: Data([1, 2, 3])))
        #expect(img.displaysAsImage && !img.displaysAsLargeText)
    }
}
