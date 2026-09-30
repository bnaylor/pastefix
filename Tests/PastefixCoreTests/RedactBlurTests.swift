import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

/// Redact and Blur Selection (redact/blur spec). Pixels are compared by drawing the decoded
/// image into one sRGB RGBA8 buffer, top-left origin, so "outside the region is untouched" is a
/// byte comparison.
@Suite struct RedactBlurTests {
    /// RGBA8 in sRGB, row 0 at the top.
    static func pixels(_ png: Data) throws -> (w: Int, h: Int, px: [UInt8]) {
        let image = try #require(Fixture.decoded(png))
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, px)
    }
    static func at(_ p: (w: Int, h: Int, px: [UInt8]), _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * p.w + x) * 4
        return Array(p.px[i..<i + 4])
    }
    static func inside(_ r: ImageRegion, _ x: Int, _ y: Int) -> Bool {
        x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
    }
    /// Every pixel outside `r` is identical in `a` and `b`.
    static func outsideUnchanged(_ a: (w: Int, h: Int, px: [UInt8]), _ b: (w: Int, h: Int, px: [UInt8]), _ r: ImageRegion) -> Bool {
        guard a.w == b.w, a.h == b.h else { return false }
        for y in 0..<a.h { for x in 0..<a.w where !inside(r, x, y) { if at(a, x, y) != at(b, x, y) { return false } } }
        return true
    }
    /// `w`×`h`, alternating 2 px black and white rows.
    static func stripes(_ w: Int, _ h: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for y in stride(from: 0, to: h, by: 4) { ctx.fill(CGRect(x: 0, y: y, width: w, height: 2)) }
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    static func solid(_ w: Int, _ h: Int, space: CFString = CGColorSpace.sRGB, grey: Bool = false) throws -> Data {
        let cs = CGColorSpace(name: grey ? CGColorSpace.genericGrayGamma2_2 : space)!
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                         bitmapInfo: grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue))
        if grey { ctx.setFillColor(gray: 0.8, alpha: 1) } else { ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) }
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func image(_ out: TransformOutput) throws -> (Data, String?) {
        guard case .image(let data, let note) = out else { Issue.record("expected an image, got \(out)"); throw CancellationError() }
        return (data, note)
    }

    // MARK: Redact

    @Test func redactFillsTheRegionAndNothingElse() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        let r = ImageRegion(x: 25, y: 5, width: 10, height: 20)
        let (out, note) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(note == "Redacted 10×20.")
        let a = try Self.pixels(png), b = try Self.pixels(out)
        #expect(Self.outsideUnchanged(a, b, r))
        for y in r.y..<r.y + r.height { for x in r.x..<r.x + r.width { #expect(Self.at(b, x, y) == [0, 0, 0, 255]) } }
        #expect(Fixture.properties(out)?[kCGImagePropertyGPSDictionary as String] == nil, "metadata is dropped")
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3, "profile kept")
    }

    @Test func redactWholeImageIsAllBlack() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        let (out, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 60, height: 40)) })
        let b = try Self.pixels(out)
        #expect(stride(from: 0, to: b.px.count, by: 4).allSatisfy { Array(b.px[$0..<$0 + 4]) == [0, 0, 0, 255] })
    }

    /// Orientation 6: displayed 40×60 with the stored left (red) half on top.
    @Test func redactUsesTheDisplayedOrientation() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        let (out, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 40, height: 30)) })
        let b = try Self.pixels(out)
        #expect(b.w == 40 && b.h == 60, "orientation baked in")
        #expect(Self.at(b, 20, 10) == [0, 0, 0, 255], "top (red) half redacted")
        let bottom = Self.at(b, 20, 45)
        #expect(bottom[2] > 150 && bottom[0] < 100, "bottom half still blue: \(bottom)")
    }

    /// Review Focus 1.
    @Test func redactOverTransparencyIsOpaqueBlack() async throws {
        let png = try #require(Fixture.image(as: "public.png", transparentRightHalf: true))
        let r = ImageRegion(x: 40, y: 10, width: 10, height: 10)   // inside the transparent half
        let (out, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(Self.at(try Self.pixels(out), 45, 15) == [0, 0, 0, 255])
    }

    /// Review Focus 2.
    @Test func greyscaleInputWorks() async throws {
        let png = try Self.solid(30, 20, grey: true)
        let r = ImageRegion(x: 5, y: 5, width: 10, height: 10)
        let (redacted, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(Self.at(try Self.pixels(redacted), 8, 8) == [0, 0, 0, 255])
        let (blurred, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: r) })
        #expect(Self.outsideUnchanged(try Self.pixels(png), try Self.pixels(blurred), r))
    }

    /// Review Focus 4.
    @Test func onePixelRegion() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        let r = ImageRegion(x: 3, y: 4, width: 1, height: 1)
        let (redacted, note) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(note == "Redacted 1×1.")
        let a = try Self.pixels(png), b = try Self.pixels(redacted)
        #expect(Self.outsideUnchanged(a, b, r) && Self.at(b, 3, 4) == [0, 0, 0, 255])
        let (blurred, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: r) })
        #expect(Self.outsideUnchanged(a, try Self.pixels(blurred), r))
    }

    @Test func noRegionAndOutsideTheImage() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        #expect(try RedactSelection().transformImage(png, region: nil) == .nothingToDo(RedactSelection.noRegionMessage))
        #expect(try BlurSelection().transformImage(png, region: nil) == .nothingToDo(BlurSelection.noRegionMessage))
        #expect(RedactSelection.noRegionMessage == "Drag on the image to choose what to hide, then choose Redact Selection.")
        #expect(BlurSelection.noRegionMessage == "Drag on the image to choose what to blur, then choose Blur Selection.")
        #expect(throws: TransformError.self) { try RedactSelection().transformImage(png, region: ImageRegion(x: 55, y: 0, width: 10, height: 10)) }
        #expect(throws: TransformError.self) { try BlurSelection().transformImage(png, region: ImageRegion(x: 55, y: 0, width: 10, height: 10)) }
    }

    // MARK: Blur

    @Test func blurSoftensTheRegionAndNothingElse() async throws {
        let png = try Self.stripes(80, 60)
        let r = ImageRegion(x: 20, y: 10, width: 40, height: 40)
        let (out, note) = try image(try await offThePool { try BlurSelection().transformImage(png, region: r) })
        #expect(note == "Blurred 40×40. Blur can be reversed; use Redact Selection to hide something for good.")
        let a = try Self.pixels(png), b = try Self.pixels(out)
        #expect(Self.outsideUnchanged(a, b, r))
        // Down the middle column, well inside the region: the stripes' contrast at least halves.
        let column = (20..<40).map { Int(Self.at(b, 40, $0)[0]) }
        #expect(column.max()! - column.min()! < 128, "contrast \(column.max()! - column.min()!)")
        #expect(Set(column).count > 1, "blurred, not filled")
    }

    @Test func blurRadius() {
        #expect(BlurSelection.radius(for: ImageRegion(x: 0, y: 0, width: 40, height: 40)) == 6)
        #expect(BlurSelection.radius(for: ImageRegion(x: 0, y: 0, width: 400, height: 1000)) == 20)
    }

    /// Review Focus 3.
    @Test func blurAtTheEdgesDoesNotDarken() async throws {
        let png = try Self.solid(50, 30)
        let (out, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 50, height: 30)) })
        let a = try Self.pixels(png), b = try Self.pixels(out)
        for (x, y) in [(0, 0), (49, 0), (0, 29), (49, 29), (25, 15)] {
            let d = zip(Self.at(a, x, y), Self.at(b, x, y)).map { abs(Int($0) - Int($1)) }.max()!
            #expect(d <= 3, "(\(x), \(y)) differs by \(d)")
        }
    }

    @Test func blurKeepsOrientationAndProfileAndDropsMetadata() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        let (out, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 40, height: 30)) })
        let b = try Self.pixels(out)
        #expect(b.w == 40 && b.h == 60)
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Fixture.properties(out)?[kCGImagePropertyGPSDictionary as String] == nil)
    }

    @Test func registered() {
        let r = RedactSelection(), b = BlurSelection()
        #expect(r.id == "builtin.redactselection" && r.name == "Redact Selection" && r.category == TransformCategory.images)
        #expect(b.id == "builtin.blurselection" && b.name == "Blur Selection" && b.category == TransformCategory.images)
        #expect(r.acceptedForms == [.image] && b.acceptedForms == [.image])
    }
}

/// Final review I1: a 16-bit image must stay 16-bit, with the pixels outside the region exactly as
/// they were — an 8-bit working bitmap re-quantised the whole picture (visible banding on PQ/HLG).
@Suite struct RedactBlurDepthTests {
    /// 60×40, 16 bits per channel, opaque, a smooth ramp that 8 bits can't hold.
    static func png16() throws -> Data {
        let w = 60, h = 40
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        let buf = ctx.data!.assumingMemoryBound(to: UInt16.self)
        let stride = ctx.bytesPerRow / 2
        for y in 0..<h { for x in 0..<w {
            let i = y * stride + x * 4
            buf[i] = UInt16(x * 1000 + y); buf[i + 1] = UInt16(30000 + x * 7); buf[i + 2] = UInt16(y * 1500 + 3); buf[i + 3] = 65535
        } }
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    /// RGBA16 (little-endian, sRGB) of `png`, row 0 at the top.
    static func pixels16(_ png: Data) throws -> (w: Int, h: Int, depth: Int, px: [UInt16]) {
        let image = try #require(Fixture.decoded(png))
        let w = image.width, h = image.height
        var px = [UInt16](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, image.bitsPerComponent, px)
    }
    static func outsideUnchanged16(_ a: (w: Int, h: Int, depth: Int, px: [UInt16]), _ b: (w: Int, h: Int, depth: Int, px: [UInt16]), _ r: ImageRegion) -> Int {
        var changed = 0
        for y in 0..<a.h { for x in 0..<a.w where !(x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height) {
            let i = (y * a.w + x) * 4
            if a.px[i..<i + 4] != b.px[i..<i + 4] { changed += 1 }
        } }
        return changed
    }

    @Test func redactAndBlurKeepSixteenBits() async throws {
        let png = try Self.png16()
        let r = ImageRegion(x: 20, y: 10, width: 15, height: 12)
        let a = try Self.pixels16(png)
        #expect(a.depth == 16, "fixture is 16-bit")
        for t in [RedactSelection() as any RegionImageTransformer, BlurSelection()] {
            guard case .image(let out, _) = try await offThePool({ try t.transformImage(png, region: r) }) else {
                Issue.record("\(t.name): expected an image"); continue
            }
            let b = try Self.pixels16(out)
            #expect(b.depth == 16, "\(t.name) keeps 16 bits per channel, got \(b.depth)")
            #expect(Self.outsideUnchanged16(a, b, r) == 0, "\(t.name): pixels outside the region changed")
        }
    }
}
