import Testing
import Foundation
import AppKit
@testable import PastefixAppCore

@Suite("ImageBytes")
struct ImageBytesTests {
    /// A real 8×6 image in both forms, so these tests exercise ImageIO and `NSBitmapImageRep`
    /// rather than a stand-in. This is the coverage the app-target copies of this code never had.
    private static func sample() throws -> (png: Data, tiff: Data) {
        // An explicit bitmap rep, not `NSImage.lockFocus`: that draws through the screen's
        // backing scale, so the same source produced a 16×12 bitmap on a Retina machine and an
        // 8×6 one elsewhere — a test whose pixel counts depend on the display it runs on.
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let tiff = try #require(rep.representation(using: .tiff, properties: [:]))
        return (png, tiff)
    }

    @Test("pixel dimensions come from the header")
    func pixelSize() throws {
        let sample = try Self.sample()
        let size = try #require(ImageBytes.pixelSize(of: sample.png))
        #expect(size.width == 8)
        #expect(size.height == 6)
        #expect(ImageBytes.pixelSize(of: sample.tiff) != nil)
    }

    @Test("bytes that are not an image have no dimensions")
    func pixelSizeOfGarbage() {
        #expect(ImageBytes.pixelSize(of: Data("not an image".utf8)) == nil)
        #expect(ImageBytes.pixelSize(of: Data()) == nil)
    }

    @Test("a PNG is returned byte-for-byte, never re-encoded")
    func pngVerbatim() throws {
        let sample = try Self.sample()
        // The rule Save depends on: what the user copied is what goes back on the clipboard.
        #expect(ImageBytes.normalise(sample.png) == .png(sample.png))
    }

    @Test("a TIFF is converted to PNG")
    func tiffConverted() throws {
        let sample = try Self.sample()
        guard case .png(let out) = ImageBytes.normalise(sample.tiff) else {
            Issue.record("a TIFF should normalise to a PNG"); return
        }
        #expect(out != sample.tiff, "never the raw TIFF under a PNG's name")
        #expect(out.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("a non-PNG over the pixel ceiling is refused, with its pixel count")
    func tooLarge() throws {
        let sample = try Self.sample()
        // The ceiling is injected so this costs 48 pixels instead of 25 million.
        #expect(ImageBytes.normalise(sample.tiff, maxPixels: 10) == .tooLarge(pixels: 48))
    }

    @Test("a PNG is never refused for its pixel count")
    func pngIgnoresTheCeiling() throws {
        let sample = try Self.sample()
        // Deliberate asymmetry, and the reason the ceiling exists: it bounds a *decode*, and the
        // PNG path performs none. A huge PNG is carried as-is and drawn later, off the main actor,
        // at display size.
        #expect(ImageBytes.normalise(sample.png, maxPixels: 1) == .png(sample.png))
    }

    @Test("bytes that are not an image are unusable")
    func unusable() {
        #expect(ImageBytes.normalise(Data("hello".utf8)) == .unusable)
        #expect(ImageBytes.normalise(Data()) == .unusable)
    }

    @Test("a truncated PNG is unusable")
    func truncated() throws {
        let sample = try Self.sample()
        #expect(ImageBytes.normalise(Data(sample.png.prefix(20))) == .unusable)
    }

    @Test("the conversion route reports failure rather than empty bytes")
    func conversionFailure() {
        #expect(ImageBytes.convertedToPNG(Data("not an image".utf8)) == nil)
    }

    @Test("megapixel labels read the way a limit is quoted")
    func megapixels() {
        #expect(ImageBytes.megapixelLabel(25_000_000) == "25 MP")
        #expect(ImageBytes.megapixelLabel(30_900_000) == "30.9 MP")
        #expect(ImageBytes.megapixelLabel(6_600_000) == "6.6 MP")
    }
}
