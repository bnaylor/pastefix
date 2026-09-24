import Testing
import AppKit
@testable import PastefixAppCore

@Suite("Zipline pasteboard image detection")
struct ZiplinePasteboardImageTests {
    @Test("no types is not an image")
    func empty() {
        #expect(!ZiplinePasteboardImage.typesIndicateImage([]))
    }

    @Test("plain text is not an image")
    func plainText() {
        #expect(!ZiplinePasteboardImage.typesIndicateImage([.string]))
    }

    @Test("tiff indicates an image")
    func tiff() {
        #expect(ZiplinePasteboardImage.typesIndicateImage([.tiff]))
    }

    @Test("png indicates an image")
    func png() {
        #expect(ZiplinePasteboardImage.typesIndicateImage([.png]))
    }

    @Test("an image type alongside other types still indicates an image")
    func mixed() {
        #expect(ZiplinePasteboardImage.typesIndicateImage([.string, .rtf, .png]))
    }

    @Test("a concealed-type marker alone is not an image")
    func concealedMarkerAlone() {
        #expect(!ZiplinePasteboardImage.typesIndicateImage([.init("org.nspasteboard.ConcealedType")]))
    }
}
