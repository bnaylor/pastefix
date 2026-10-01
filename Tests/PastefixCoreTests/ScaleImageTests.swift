import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

/// Scale to 50% and Fit Within 1920 px: whole-image downsampling for chat and web pastes.
@Suite struct ScaleImageTests {
    static func solid(_ w: Int, _ h: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    /// `w`×`h` 1-px black/white checkerboard: any downsample that skips pixels instead of
    /// averaging them comes out black, white or striped, never an even grey.
    static func checker(_ w: Int, _ h: Int) throws -> Data {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v: UInt8 = (x + y) % 2 == 0 ? 255 : 0; let i = (y * w + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255 } }
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func run(_ kind: ScaleImage.Kind, _ png: Data) async throws -> TransformOutput {
        try await offThePool { try ScaleImage(kind).transformImage(png) }
    }
    private func size(_ png: Data) -> [Int] {
        guard let p = Fixture.properties(png) else { return [] }
        return [p[kCGImagePropertyPixelWidth as String] as? Int ?? 0, p[kCGImagePropertyPixelHeight as String] as? Int ?? 0]
    }

    @Test func halvesEachSideRoundingToNearest() async throws {
        for (w, h, ew, eh) in [(800, 600, 400, 300), (1201, 801, 601, 401), (3, 1, 2, 1), (1, 9, 1, 5)] {
            guard case .image(let out, let note) = try await run(.half, try Self.solid(w, h)) else {
                Issue.record("\(w)×\(h): expected an image"); continue
            }
            #expect(size(out) == [ew, eh], "\(w)×\(h)")
            #expect(note == "Scaled to \(ew)×\(eh).")
        }
    }

    @Test func tooSmallToHalve() async throws {
        #expect(try await run(.half, try Self.solid(1, 1)) == .nothingToDo(ScaleImage.tooSmallMessage))
        #expect(ScaleImage.tooSmallMessage == "This image is too small to scale down.")
    }

    @Test func fitsTheLongerSideWithin1920() async throws {
        // Thin strips, not full 5K frames: the footprint test in PNGEncoderTests measures the whole
        // process, and big decodes here in parallel pushed it over its bound.
        for (w, h, ew, eh) in [(5120, 30, 1920, 11), (30, 3000, 19, 1920), (1921, 7, 1920, 7), (3840, 2, 1920, 1)] {
            guard case .image(let out, let note) = try await run(.fit1920, try Self.solid(w, h)) else {
                Issue.record("\(w)×\(h): expected an image"); continue
            }
            #expect(size(out) == [ew, eh], "\(w)×\(h)")
            #expect(note == "Scaled to \(ew)×\(eh).")
        }
    }

    @Test func alreadyWithin1920() async throws {
        #expect(try await run(.fit1920, try Self.solid(1920, 1080)) == .nothingToDo(ScaleImage.alreadyFitsMessage))
        #expect(try await run(.fit1920, try Self.solid(800, 1920)) == .nothingToDo(ScaleImage.alreadyFitsMessage))
        #expect(ScaleImage.alreadyFitsMessage == "This image is already within 1920 px.")
    }

    /// Averaged, not skipped: a 1-px checkerboard downsampled is an even grey.
    @Test func downsamplingAverages() async throws {
        for (kind, w, h) in [(ScaleImage.Kind.half, 200, 100), (.fit1920, 4000, 40)] {
            guard case .image(let out, _) = try await run(kind, try Self.checker(w, h)) else {
                Issue.record("\(kind): expected an image"); continue
            }
            let p = try RedactBlurTests.pixels(out)
            // Away from the edges, every pixel's red channel.
            var values: [Int] = []
            for y in 2..<(p.h - 2) { for x in 2..<(p.w - 2) { values.append(Int(RedactBlurTests.at(p, x, y)[0])) } }
            let mean = Double(values.reduce(0, +)) / Double(values.count)
            #expect(values.min()! > 60 && values.max()! < 230 && mean > 90 && mean < 210,
                    "\(kind): min \(values.min()!) max \(values.max()!) mean \(mean)")
        }
    }

    /// Pins the interpolation quality, not just "not skipped": 1-px white lines every 4 px on black,
    /// at 2.67× (5120 → 1920). The ideal is a flat 64 (a quarter white); measured, `.high` gives
    /// 45...83, `.medium` 0...96 (lines dropped between beats), `.none` 0...0. (Final review: the
    /// checkerboard alone passed under `.medium`, and with the `.high` line deleted.)
    @Test func fineLinesStayEvenAtLargeRatios() async throws {
        let w = 5120, h = 24
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v: UInt8 = x % 4 == 0 ? 255 : 0; let i = (y * w + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255 } }
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let png = try #require(PNGEncoder.encode(image))
        guard case .image(let out, _) = try await run(.fit1920, png) else { Issue.record("expected an image"); return }
        let p = try RedactBlurTests.pixels(out)
        let row = (4..<(p.w - 4)).map { Int(RedactBlurTests.at(p, $0, p.h / 2)[0]) }
        let lo = row.min()!, hi = row.max()!
        #expect(lo >= 35 && hi <= 95, "range \(lo)...\(hi) (ideal 64)")
    }

    /// The size rule, without decoding anything: nearest rounding, the 1-px floor, the 1920 boundary.
    @Test func targetSizes() {
        func t(_ k: ScaleImage.Kind, _ w: Int, _ h: Int) -> [Int]? { ScaleImage.target(k, width: w, height: h).map { [$0.width, $0.height] } }
        #expect(t(.fit1920, 100_000, 2) == [1920, 1], "the floor: 0.04 rounds to 0 without it")
        #expect(t(.fit1920, 5000, 1) == [1920, 1])
        #expect(t(.fit1920, 1920, 500) == nil && t(.fit1920, 500, 1920) == nil, "exactly 1920 is within")
        #expect(t(.fit1920, 1921, 3) == [1920, 3])
        #expect(t(.half, 1, 1) == nil, "too small")
        #expect(t(.half, 1, 2) == [1, 1] && t(.half, 2, 1) == [1, 1] && t(.half, 3, 3) == [2, 2])
    }

    @Test func scalesWhatIsDisplayed() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))   // shows 40×60, red on top
        guard case .image(let out, _) = try await run(.half, png) else { Issue.record("expected an image"); return }
        let p = try RedactBlurTests.pixels(out)
        #expect(p.w == 20 && p.h == 30)
        let top = RedactBlurTests.at(p, 10, 5), bottom = RedactBlurTests.at(p, 10, 25)
        #expect(top[0] > 150 && top[2] < 100 && bottom[2] > 150 && bottom[0] < 100, "top \(top) bottom \(bottom)")
    }

    @Test func keepsProfileDepthDropsMetadataAndShrinks() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        guard case .image(let out, _) = try await run(.half, png) else { Issue.record("expected an image"); return }
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Fixture.properties(out)?[kCGImagePropertyGPSDictionary as String] == nil)
        guard case .image(let deep, _) = try await run(.half, try RedactBlurDepthTests.png16()) else { Issue.record("16-bit"); return }
        #expect(Fixture.decoded(deep)?.bitsPerComponent == 16)
        let busy = try Self.checker(1200, 800)
        guard case .image(let small, _) = try await run(.half, busy) else { Issue.record("checker"); return }
        #expect(small.count * 2 < busy.count, "half the pixels per side: \(busy.count) → \(small.count) bytes")
    }

    @Test func registered() {
        let half = ScaleImage(.half), fit = ScaleImage(.fit1920)
        #expect(half.id == "builtin.scalehalf" && half.name == "Scale to 50%")
        #expect(fit.id == "builtin.fitwithin1920" && fit.name == "Fit Within 1920 px")
        for t in [half, fit] { #expect(t.category == TransformCategory.images && t.acceptedForms == [.image]) }
        #expect(throws: TransformError.self) { try half.transformImage(Data("nope".utf8)) }
    }
}
