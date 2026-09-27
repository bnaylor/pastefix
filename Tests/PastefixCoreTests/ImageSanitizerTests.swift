import Testing
import Foundation
import ImageIO
import AppKit
@testable import PastefixCore

/// #20. Every fixture is synthetic — never a real photograph — and every test first checks the
/// fixture really carries what is being removed, or the test would pass by proving nothing.
@Suite("ImageSanitizer")
struct ImageSanitizerTests {
    static let formats = ["public.tiff", "public.png", "public.jpeg"]

    @Test("removes GPS, EXIF dates, camera make and IPTC", arguments: formats)
    func removesMetadata(format: String) throws {
        let input = try #require(Fixture.image(as: format))
        let before = try #require(Fixture.properties(input))
        #expect(before["{GPS}"] != nil)
        #expect(Fixture.exif(before)["DateTimeOriginal"] != nil)
        #expect(before["{IPTC}"] != nil)

        let out = try #require(ImageSanitizer.stripped(input)).png
        let after = try #require(Fixture.properties(out))
        #expect(after["{GPS}"] == nil)
        #expect(after["{IPTC}"] == nil)
        #expect(after["{TIFF}"] == nil)
        // The encoder synthesises pixel dimensions; nothing else may survive.
        #expect(Set(Fixture.exif(after).keys).isSubset(of: ["PixelXDimension", "PixelYDimension"]))
    }

    @Test("bakes orientation into the pixels before dropping the tag", arguments: formats)
    func bakesOrientation(format: String) throws {
        let input = try #require(Fixture.image(as: format, orientation: 6))
        #expect(Fixture.properties(input)?["Orientation"] as? Int == 6)

        let out = try #require(ImageSanitizer.stripped(input)).png
        let props = try #require(Fixture.properties(out))
        #expect(props["PixelWidth"] as? Int == Fixture.height)   // stored 60x40, displayed 40x60
        #expect(props["PixelHeight"] as? Int == Fixture.width)
        #expect(props["Orientation"] == nil || props["Orientation"] as? Int == 1)
        // Stored left half is red, right half blue. Rotated clockwise, stored bottom-right (blue)
        // becomes displayed bottom-left — a check that a dropped-but-unapplied tag fails.
        let rep = try #require(NSBitmapImageRep(data: out))
        let bottomLeft = try #require(rep.colorAt(x: 0, y: rep.pixelsHigh - 1)?.usingColorSpace(.sRGB))
        #expect(bottomLeft.blueComponent > 0.5 && bottomLeft.redComponent < 0.5)
    }

    @Test("keeps the colour profile", arguments: formats)
    func keepsProfile(format: String) throws {
        let input = try #require(Fixture.image(as: format))
        #expect(Fixture.properties(input)?["ProfileName"] as? String == "Display P3")
        let out = try #require(ImageSanitizer.stripped(input)).png
        #expect(Fixture.properties(out)?["ProfileName"] as? String == "Display P3")
    }

    @Test("output is PNG, never the input bytes, and stripping twice changes nothing more")
    func pngAndIdempotent() throws {
        let input = try #require(Fixture.image(as: "public.png"))
        let once = try #require(ImageSanitizer.stripped(input)).png
        #expect(once != input)
        let onceSource = try #require(CGImageSourceCreateWithData(once as CFData, nil))
        #expect(CGImageSourceGetType(onceSource) as String? == "public.png")
        let twice = try #require(ImageSanitizer.stripped(once)).png
        let p1 = try #require(Fixture.properties(once)), p2 = try #require(Fixture.properties(twice))
        #expect(p1["PixelWidth"] as? Int == p2["PixelWidth"] as? Int)
        #expect(p1["PixelHeight"] as? Int == p2["PixelHeight"] as? Int)
        #expect(Set(p1.keys) == Set(p2.keys))
    }

    @Test("dimensions are unchanged when there is nothing to rotate", arguments: formats)
    func noSilentDownscale(format: String) throws {
        // The thumbnail API downscales if its max size is ever left to a default.
        let input = try #require(Fixture.image(as: format))
        let out = try #require(ImageSanitizer.stripped(input)).png
        let props = try #require(Fixture.properties(out))
        #expect(props["PixelWidth"] as? Int == Fixture.width)
        #expect(props["PixelHeight"] as? Int == Fixture.height)
    }

    @Test("a non-standard colour profile is replaced with Display P3")
    func personalProfileReplaced() throws {
        // A calibrated or external display's profile — what a screenshot embeds — is not a
        // standard one, and its bytes (header device fields, creation date, often a name like
        // "Someone's MBP calibrated") go out with the image unless replaced.
        let custom = try #require(Fixture.nonStandardColorSpace())
        #expect(custom.name == nil)   // fixture sanity: really not a standard profile
        let input = try #require(Fixture.image(as: "public.png", space: custom))
        let inImage = try #require(Fixture.decoded(input))
        #expect(inImage.colorSpace?.name == nil)   // and it survives into the input bytes

        let out = try #require(ImageSanitizer.stripped(input)).png
        let outImage = try #require(Fixture.decoded(out))
        #expect(outImage.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    }

    @Test("alpha is kept")
    func keepsAlpha() throws {
        let input = try #require(Fixture.image(as: "public.png", transparentRightHalf: true))
        let out = try #require(ImageSanitizer.stripped(input)).png
        let rep = try #require(NSBitmapImageRep(data: out))
        #expect(rep.hasAlpha)
        let right = try #require(rep.colorAt(x: Fixture.width - 1, y: 0))
        let left = try #require(rep.colorAt(x: 0, y: 0))
        #expect(right.alphaComponent < 0.1)
        #expect(left.alphaComponent > 0.9)
    }

    @Test("alpha is kept when the profile is replaced, too")
    func keepsAlphaThroughRedraw() throws {
        // The non-standard-profile path redraws into a new context — a second place alpha can go.
        let custom = try #require(Fixture.nonStandardColorSpace())
        let input = try #require(Fixture.image(as: "public.png", space: custom, transparentRightHalf: true))
        let out = try #require(ImageSanitizer.stripped(input)).png
        let rep = try #require(NSBitmapImageRep(data: out))
        let right = try #require(rep.colorAt(x: Fixture.width - 1, y: 0))
        #expect(rep.hasAlpha)
        #expect(right.alphaComponent < 0.1)
    }

    @Test("PNG text chunks are dropped")
    func dropsPNGText() throws {
        let marker = "FixtureSoftwareMarker"
        let input = try #require(Fixture.image(as: "public.png", pngText: marker))
        #expect(input.range(of: Data(marker.utf8)) != nil)   // the chunk really is in the input
        let out = try #require(ImageSanitizer.stripped(input)).png
        #expect(out.range(of: Data(marker.utf8)) == nil)
        #expect((Fixture.properties(out)?["{PNG}"] as? [String: Any])?["Software"] == nil)
    }

    @Test("refuses rather than returning anything unstripped")
    func failuresAreNil() throws {
        #expect(ImageSanitizer.stripped(Data()) == nil)
        #expect(ImageSanitizer.stripped(Data("not an image".utf8)) == nil)
        // Over the ceiling: nil — the caller must refuse the upload, never fall back to the input.
        let input = try #require(Fixture.image(as: "public.png"))
        #expect(ImageSanitizer.stripped(input, maxPixels: Fixture.width * Fixture.height - 1) == nil)
        #expect(ImageSanitizer.stripped(input, maxPixels: Fixture.width * Fixture.height) != nil)
    }
}

enum Fixture {
    static let width = 60, height = 40

    static func properties(_ d: Data) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
    }
    static func decoded(_ d: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    static func exif(_ p: [String: Any]) -> [String: Any] { p["{Exif}"] as? [String: Any] ?? [:] }

    /// 60x40 Display P3, left half red / right half blue, carrying GPS, an EXIF date, a camera
    /// make, IPTC and an orientation tag.
    static func image(as type: String, orientation: Int = 1, space: CGColorSpace? = nil,
                      transparentRightHalf: Bool = false, pngText: String? = nil) -> Data? {
        guard let space = space ?? CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: transparentRightHalf ? 0 : 1)
        if transparentRightHalf { ctx.clear(CGRect(x: width / 2, y: 0, width: width / 2, height: height)) }
        else { ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height)) }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3456, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 45.6789, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:01 12:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FixtureCam"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Fixtureville"],
            kCGImagePropertyPNGDictionary: pngText.map { [kCGImagePropertyPNGSoftware: $0] } ?? [:],
        ] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// sRGB's ICC with its red primary nudged and its profile ID cleared: colorimetrically a
    /// *different* profile, as a calibrated display's is, so ColorSync cannot match it back to a
    /// standard one. (Only renaming a copy of sRGB is not enough — it is recognised as sRGB.)
    static func nonStandardColorSpace() -> CGColorSpace? {
        guard let data = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? else { return nil }
        var icc = [UInt8](data)
        let tags = Int(icc[128]) << 24 | Int(icc[129]) << 16 | Int(icc[130]) << 8 | Int(icc[131])
        for k in 0..<tags {
            let b = 132 + 12 * k
            guard String(bytes: icc[b..<b + 4], encoding: .ascii) == "rXYZ" else { continue }
            let off = Int(icc[b + 4]) << 24 | Int(icc[b + 5]) << 16 | Int(icc[b + 6]) << 8 | Int(icc[b + 7])
            icc[off + 11] &+= 40
        }
        for i in 84..<100 { icc[i] = 0 }
        return CGColorSpace(iccData: Data(icc) as CFData)
    }
}
