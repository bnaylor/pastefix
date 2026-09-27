import Testing
@testable import PastefixCore

/// #21: the format rule, as the pure function it is. The numbers it rests on are measured (see
/// `ImageFormatChoice`); these cases pin the rule's shape, including its boundaries.
@Suite("ImageFormatChoice")
struct ImageFormatChoiceTests {
    static let cap = 16_000_000

    @Test("a non-opaque image is PNG, with no escape")
    func nonOpaqueIsPNG() {
        let choice = ImageFormatChoice.choose(pngBytes: 1_000_000, jpegBytes: nil, maxBytes: Self.cap)
        #expect(choice == .png)
        #expect(!choice.offersPNGEscape)
    }

    @Test("a non-opaque image over the cap is refused, naming the PNG")
    func nonOpaqueOverCapRefused() {
        #expect(ImageFormatChoice.choose(pngBytes: 20_000_000, jpegBytes: nil, maxBytes: Self.cap)
                == .refused(bytes: 20_000_000, format: .png))
    }

    @Test("PNG over the cap with a JPEG that fits is JPEG, whatever the ratio, with no escape",
          arguments: [1_000_000, 10_000_000, 15_000_000, 16_000_000])
    func overCapForcesJPEG(jpegBytes: Int) {
        // 0.05 to 0.94 of the PNG: the ratio plays no part once the PNG cannot be sent.
        let choice = ImageFormatChoice.choose(pngBytes: 17_000_000, jpegBytes: jpegBytes, maxBytes: Self.cap)
        #expect(choice == .jpegForcedByCap)
        #expect(choice.format == .jpeg)
        #expect(!choice.offersPNGEscape)
    }

    @Test("PNG over the cap with a JPEG that is larger than the PNG still goes as JPEG if it fits")
    func overCapEvenAboveRatioOne() {
        // Unreachable in practice (a JPEG bigger than an over-cap PNG is itself over the cap) but
        // the rule's words are "whatever the ratio"; with a lowered cap it is reachable.
        #expect(ImageFormatChoice.choose(pngBytes: 101, jpegBytes: 100, maxBytes: 100) == .jpegForcedByCap)
    }

    @Test("neither fits: refused, naming the JPEG")
    func neitherFitsNamesJPEG() {
        #expect(ImageFormatChoice.choose(pngBytes: 60_000_000, jpegBytes: 18_000_000, maxBytes: Self.cap)
                == .refused(bytes: 18_000_000, format: .jpeg))
    }

    @Test("PNG fits and JPEG is at most half: JPEG, with the escape",
          arguments: [(10_100_000, 1_640_000), (1_000_000, 500_000), (2, 1)])
    func photoGoesJPEGWithEscape(pngBytes: Int, jpegBytes: Int) {
        let choice = ImageFormatChoice.choose(pngBytes: pngBytes, jpegBytes: jpegBytes, maxBytes: Self.cap)
        #expect(choice == .jpegWithPNGEscape)
        #expect(choice.format == .jpeg)
        #expect(choice.offersPNGEscape)
    }

    @Test("PNG fits and JPEG is over half: PNG",
          arguments: [(1_000_000, 500_001), (830_000, 1_010_000), (190_000, 270_000)])
    func otherwisePNG(pngBytes: Int, jpegBytes: Int) {
        let choice = ImageFormatChoice.choose(pngBytes: pngBytes, jpegBytes: jpegBytes, maxBytes: Self.cap)
        #expect(choice == .png)
        #expect(!choice.offersPNGEscape)
    }

    @Test("a PNG exactly at the cap fits")
    func capIsInclusive() {
        #expect(ImageFormatChoice.choose(pngBytes: Self.cap, jpegBytes: Self.cap - 1, maxBytes: Self.cap) == .png)
        #expect(ImageFormatChoice.choose(pngBytes: Self.cap, jpegBytes: nil, maxBytes: Self.cap) == .png)
    }

    @Test("the named constants")
    func constants() {
        #expect(ImageFormatChoice.jpegRatioThreshold == 0.5)
        #expect(ImageSanitizer.jpegQuality == 0.85)
    }

    @Test("a refusal has no format to send")
    func refusalHasNoFormat() {
        #expect(ImageFormatChoice.refused(bytes: 1, format: .jpeg).format == nil)
        #expect(ImageFormatChoice.png.format == .png)
    }
}
