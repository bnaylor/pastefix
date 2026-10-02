import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import PastefixCore

/// #129: Blur Selection reads the region's text first and, when it looks like a secret, says so —
/// blur can be reversed, so the note points at Redact Selection. Best effort: no text, or no
/// secret, is today's note; OCR never makes a blur fail.
@Suite struct BlurSecretWarningTests {
    /// `width`×`height` white, with each line drawn in black monospace at its top-left point.
    static func page(_ lines: [(String, CGFloat, CGFloat)], width: Int = 1400, height: Int = 400) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 34, nil)
        for (text, x, top) in lines {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - top - CTFontGetAscent(font))
            CTLineDraw(line, ctx)
        }
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func note(_ png: Data, _ region: ImageRegion) async throws -> String? {
        guard case .image(_, let note) = try await offThePool({ try BlurSelection().transformImage(png, region: region) }) else {
            Issue.record("expected an image"); return nil
        }
        return note
    }

    @Test func warnsWhenTheRegionHidesASecret() async throws {
        let png = try Self.page([("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", 40, 60)])
        let n = try #require(try await note(png, ImageRegion(x: 20, y: 40, width: 1100, height: 80)))
        #expect(n.contains("AWS access key"), "\(n)")
        #expect(n.contains("Redact Selection") && n.hasPrefix("Blurred 1100×80."), "\(n)")
        #expect(n != BlurSelection.resultNote(1100, 80))
    }

    @Test func plainWordsGiveTheNormalNote() async throws {
        let png = try Self.page([("the quick brown fox jumps over", 40, 60)])
        #expect(try await note(png, ImageRegion(x: 20, y: 40, width: 1100, height: 80)) == BlurSelection.resultNote(1100, 80))
    }

    @Test func noTextGivesTheNormalNote() async throws {
        let png = try Self.page([])
        #expect(try await note(png, ImageRegion(x: 20, y: 40, width: 600, height: 80)) == BlurSelection.resultNote(600, 80))
    }

    /// Only the region is read: a key elsewhere on the image is not this blur's business.
    @Test func aSecretOutsideTheRegionIsIgnored() async throws {
        let png = try Self.page([("hello there, nothing to see", 40, 60), ("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", 40, 260)])
        #expect(try await note(png, ImageRegion(x: 20, y: 40, width: 1100, height: 80)) == BlurSelection.resultNote(1100, 80))
    }

    /// Regions over 4 MP aren't read (accurate OCR on a dense 5K region took 11.4 s, past the 10 s
    /// limit): the blur still happens, with the ordinary note, and promptly.
    @Test func aHugeRegionIsNotRead() async throws {
        let png = try Self.page([("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", 40, 60)], width: 2600, height: 1600)
        let start = ContinuousClock.now
        #expect(try await note(png, ImageRegion(x: 0, y: 0, width: 2600, height: 1600)) == BlurSelection.resultNote(2600, 1600))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func kindsAreListedReadably() {
        #expect(BlurSelection.secretPhrase([.awsAccessKey]) == "an AWS access key")
        #expect(BlurSelection.secretPhrase([.githubToken, .awsAccessKey]) == "a GitHub token and an AWS access key")
        #expect(BlurSelection.secretPhrase([.githubToken, .awsAccessKey, .jwt]) == "a GitHub token, an AWS access key and a JWT")
    }
}
