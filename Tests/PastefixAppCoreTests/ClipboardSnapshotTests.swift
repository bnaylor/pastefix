import Testing
import AppKit
@testable import PastefixAppCore

@Suite struct ClipboardSnapshotTests {
    @Test func plainOnlyHasNoRichContent() {
        let snap = ClipboardSnapshot(plainText: "hello", rich: nil)
        #expect(snap.plainText == "hello")
        #expect(snap.richRTFD == nil)
        #expect(snap.hasRichContent == false)
    }

    @Test func richProducesRTFDAndReconstructsPlain() throws {
        let styled = NSAttributedString(
            string: "Bold",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]
        )
        let snap = ClipboardSnapshot(plainText: "Bold", rich: styled)
        #expect(snap.hasRichContent == true)
        let data = try #require(snap.richRTFD)
        let round = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        #expect(round.string == "Bold")
    }

    @Test func memberwiseInitStoresDataDirectly() {
        let snap = ClipboardSnapshot(plainText: nil, richRTFD: Data([1, 2, 3]))
        #expect(snap.plainText == nil)
        #expect(snap.hasRichContent == true)
    }
}
