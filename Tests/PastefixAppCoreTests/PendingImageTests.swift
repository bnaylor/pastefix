import Testing
import Foundation
@testable import PastefixAppCore

@Suite("PendingImage")
struct PendingImageTests {
    private func candidate(text: String? = nil) -> CaptureCandidate {
        CaptureCandidate(plainText: text, richRTFD: nil, imagePNG: nil,
                         sourceBundleID: "com.example.app", sourceAppName: "Example")
    }

    @Test("a converted PNG within budget becomes the capture's image")
    func convertedImage() throws {
        let png = Data(repeating: 0xAB, count: 1_000)
        let out = try #require(PendingImage.resolve(candidate(text: "caption"), png: png,
                                                    pixelWidth: 800, pixelHeight: 600,
                                                    maxImageBytes: 5_000))
        #expect(out.imagePNG == png)
        #expect(out.imagePixelWidth == 800)
        #expect(out.imagePixelHeight == 600)
        #expect(out.plainText == "caption")
        #expect(out.sourceBundleID == "com.example.app")   // attribution survives the hop
    }

    @Test("a failed conversion keeps the text and no image")
    func failedConversionKeepsText() throws {
        let out = try #require(PendingImage.resolve(candidate(text: "caption"), png: nil,
                                                    pixelWidth: 800, pixelHeight: 600,
                                                    maxImageBytes: 5_000))
        #expect(out.imagePNG == nil)
        #expect(out.imagePixelWidth == nil)
        #expect(out.imagePixelHeight == nil)
        #expect(out.plainText == "caption")
    }

    @Test("an over-budget PNG is dropped, not recorded")
    func overBudgetImageDropped() throws {
        let out = try #require(PendingImage.resolve(candidate(text: "caption"),
                                                    png: Data(repeating: 0xAB, count: 6_000),
                                                    pixelWidth: 800, pixelHeight: 600,
                                                    maxImageBytes: 5_000))
        #expect(out.imagePNG == nil)
        #expect(out.plainText == "caption")
    }

    @Test("nothing is recorded when the conversion fails and there is no text")
    func failedConversionWithoutText() {
        #expect(PendingImage.resolve(candidate(), png: nil, pixelWidth: 1, pixelHeight: 1,
                                     maxImageBytes: 5_000) == nil)
    }

    @Test("blank text is not text, as in HistoryStore.record")
    func blankTextIsNotText() {
        #expect(PendingImage.resolve(candidate(text: "  \n\t "), png: nil, pixelWidth: nil,
                                     pixelHeight: nil, maxImageBytes: 5_000) == nil)
    }

    @Test("a stale image on the incoming candidate is never carried through")
    func staleImageCleared() {
        var stale = candidate(text: "caption")
        stale.imagePNG = Data(repeating: 0x01, count: 10)
        stale.imagePixelWidth = 4; stale.imagePixelHeight = 4
        let out = PendingImage.resolve(stale, png: nil, pixelWidth: nil, pixelHeight: nil,
                                       maxImageBytes: 5_000)
        #expect(out?.imagePNG == nil)
        #expect(out?.imagePixelWidth == nil)
    }

    @Test("an image with no text at all is still a capture")
    func imageOnly() throws {
        let out = try #require(PendingImage.resolve(candidate(), png: Data(repeating: 0x2, count: 8),
                                                    pixelWidth: 10, pixelHeight: 10,
                                                    maxImageBytes: 5_000))
        #expect(out.imagePNG?.count == 8)
        #expect(out.plainText == nil)
    }
}
