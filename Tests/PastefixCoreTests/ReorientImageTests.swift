import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

/// Rotate Left/Right and Flip Horizontal/Vertical: exact pixel moves, whole image.
@Suite struct ReorientImageTests {
    static let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255]
    static let blue: [UInt8] = [0, 0, 255, 255], white: [UInt8] = [255, 255, 255, 255]

    /// 6×4, black, with a different colour in each corner pixel (as displayed: top-left red,
    /// top-right green, bottom-left blue, bottom-right white).
    static func corners() throws -> Data {
        let w = 6, h = 4
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CG is bottom-left: y = h - 1 is the top row.
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: h - 1, width: 1, height: 1))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); ctx.fill(CGRect(x: w - 1, y: h - 1, width: 1, height: 1))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: w - 1, y: 0, width: 1, height: 1))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }

    private func apply(_ kind: ReorientImage.Kind, _ png: Data) async throws -> (Data, String?) {
        guard case .image(let out, let note) = try await offThePool({ try ReorientImage(kind).transformImage(png) }) else {
            Issue.record("\(kind): expected an image"); throw CancellationError()
        }
        return (out, note)
    }
    private func cornersOf(_ png: Data) throws -> (w: Int, h: Int, tl: [UInt8], tr: [UInt8], bl: [UInt8], br: [UInt8]) {
        let p = try RedactBlurTests.pixels(png)
        return (p.w, p.h, RedactBlurTests.at(p, 0, 0), RedactBlurTests.at(p, p.w - 1, 0),
                RedactBlurTests.at(p, 0, p.h - 1), RedactBlurTests.at(p, p.w - 1, p.h - 1))
    }

    @Test func eachCornerLandsWhereItShould() async throws {
        let png = try Self.corners()
        let (rr, n1) = try await apply(.rotateRight, png)
        let r = try cornersOf(rr)
        #expect(n1 == "Rotated right." && r.w == 4 && r.h == 6)
        #expect(r.tl == Self.blue && r.tr == Self.red && r.br == Self.green && r.bl == Self.white)

        let (rl, n2) = try await apply(.rotateLeft, png)
        let l = try cornersOf(rl)
        #expect(n2 == "Rotated left." && l.w == 4 && l.h == 6)
        #expect(l.tl == Self.green && l.tr == Self.white && l.br == Self.blue && l.bl == Self.red)

        let (fh, n3) = try await apply(.flipHorizontal, png)
        let h = try cornersOf(fh)
        #expect(n3 == "Flipped horizontally." && h.w == 6 && h.h == 4)
        #expect(h.tl == Self.green && h.tr == Self.red && h.bl == Self.white && h.br == Self.blue)

        let (fv, n4) = try await apply(.flipVertical, png)
        let v = try cornersOf(fv)
        #expect(n4 == "Flipped vertically." && v.w == 6 && v.h == 4)
        #expect(v.tl == Self.blue && v.tr == Self.white && v.bl == Self.red && v.br == Self.green)
    }

    /// Exact: no resampling, so the round trips give back the original pixels.
    @Test func roundTripsAreExact() async throws {
        let png = try #require(Fixture.image(as: "public.png"))   // 60×40 P3
        let original = try RedactBlurTests.pixels(png).px
        var four = png
        for _ in 0..<4 { four = try await apply(.rotateRight, four).0 }
        #expect(try RedactBlurTests.pixels(four).px == original, "four right turns")
        let lr = try await apply(.rotateRight, try await apply(.rotateLeft, png).0).0
        #expect(try RedactBlurTests.pixels(lr).px == original, "left then right")
        let hh = try await apply(.flipHorizontal, try await apply(.flipHorizontal, png).0).0
        #expect(try RedactBlurTests.pixels(hh).px == original, "flip horizontal twice")
        let vv = try await apply(.flipVertical, try await apply(.flipVertical, png).0).0
        #expect(try RedactBlurTests.pixels(vv).px == original, "flip vertical twice")
    }

    /// Orientation 6 displays 40×60 with the stored left (red) half on top. Turned right, the red
    /// half is on the right, as the user saw it turn.
    @Test func rotatesWhatIsDisplayed() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        let (out, _) = try await apply(.rotateRight, png)
        let p = try RedactBlurTests.pixels(out)
        #expect(p.w == 60 && p.h == 40)
        let right = RedactBlurTests.at(p, 50, 20), left = RedactBlurTests.at(p, 10, 20)
        #expect(right[0] > 150 && right[2] < 100, "red on the right: \(right)")
        #expect(left[2] > 150 && left[0] < 100, "blue on the left: \(left)")
    }

    @Test func keepsProfileDepthAndDropsMetadata() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        let (out, _) = try await apply(.flipVertical, png)
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Fixture.properties(out)?[kCGImagePropertyGPSDictionary as String] == nil)
        let deep = try RedactBlurDepthTests.png16()
        var four = deep
        for _ in 0..<4 { four = try await apply(.rotateLeft, four).0 }
        let a = try RedactBlurDepthTests.pixels16(deep), b = try RedactBlurDepthTests.pixels16(four)
        #expect(b.depth == 16 && a.px == b.px, "16-bit survives four turns exactly")
    }

    @Test func registered() {
        let expected: [(ReorientImage.Kind, String, String)] = [
            (.rotateLeft, "builtin.rotateleft", "Rotate Left"), (.rotateRight, "builtin.rotateright", "Rotate Right"),
            (.flipHorizontal, "builtin.fliphorizontal", "Flip Horizontal"), (.flipVertical, "builtin.flipvertical", "Flip Vertical"),
        ]
        for (kind, id, name) in expected {
            let t = ReorientImage(kind)
            #expect(t.id == id && t.name == name && t.category == TransformCategory.images && t.acceptedForms == [.image])
        }
        #expect(throws: TransformError.self) { try ReorientImage(.rotateLeft).transformImage(Data("nope".utf8)) }
    }
}
