import Testing
import Foundation
import AppKit
@testable import PastefixAppCore

@Suite("ClipboardSnapshot carries an image")
struct ClipboardSnapshotImageTests {
    @Test("an image round-trips through the Data initialiser")
    func dataInit() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let snap = ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png, changeCount: 7)
        #expect(snap.imagePNG == png)
        #expect(snap.changeCount == 7)
    }

    @Test("an image round-trips through the attributed-string initialiser")
    func richInit() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let snap = ClipboardSnapshot(plainText: "hi", rich: nil, imagePNG: png, changeCount: 3)
        #expect(snap.imagePNG == png)
        #expect(snap.plainText == "hi")
    }

    @Test("existing callers that pass no image get nil, not empty")
    func defaultsToNil() {
        // Every current call site omits the image; nil must mean "there wasn't one",
        // and an empty Data would later be written over someone's clipboard as zero bytes.
        #expect(ClipboardSnapshot(plainText: "x", richRTFD: nil).imagePNG == nil)
        #expect(ClipboardSnapshot(plainText: "x", rich: nil).imagePNG == nil)
    }

    @Test("an image inside rich text is not the image field")
    func embeddedImageIsNotAnImage() throws {
        // The spec's rule: `imagePNG` means a standalone pasteboard image type. An attributed
        // string carrying an attachment goes into `richRTFD` and nowhere else — without this,
        // every rich paste from a web page becomes an image session.
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 4, height: 4))
        let rich = NSAttributedString(attachment: attachment)
        let snap = ClipboardSnapshot(plainText: nil, rich: rich, changeCount: 1)
        #expect(snap.imagePNG == nil)
        #expect(snap.richRTFD != nil, "the attachment should have gone into the rich data")
    }

    @Test("hasRichContent still only means rich text")
    func richIsNotImage() {
        // An image is not rich content: `requiresRichInput` transforms gate on hasRichContent,
        // and an image session must not make Rich → Plain Text look applicable.
        let snap = ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: Data([1, 2, 3]))
        #expect(snap.hasRichContent == false)
    }
}
