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

    @Test("a personal description on an otherwise canonical profile does not survive")
    func personalDescriptionNotCarried() throws {
        // The shape a desc-only fixture was trying to be. It cannot be made through CoreGraphics'
        // own encoder, which re-embeds the canonical profile for sRGB/P3/2020 and so launders the
        // marker before the test starts. A third-party app writing the ICC verbatim is the real
        // threat, so the fixture is a PNG with a hand-built iCCP chunk: Display P3's canonical
        // profile with its description overwritten in place.
        //
        // What this does NOT test: `ImageSanitizer.withStandardProfile`. Mutation-checked — with
        // the normalisation removed this still passes, because CoreGraphics' PNG encoder writes
        // the canonical profile for a space colorimetrically identical to P3 even when that space
        // has no name. So it pins the end-to-end property (a personal description does not leave)
        // against an encoder change, and the sanitizer's own conversion is pinned by
        // `personalProfileReplaced`, whose fixture differs in colorimetry and so is NOT laundered.
        let marker = "PersonalBN"                 // same length as "Display P3"
        let profile = try #require(Fixture.displayP3ProfileRenamed(to: marker))
        let input = try #require(Fixture.pngWithRawICCP(profile))
        let decoded = try #require(Fixture.decoded(input))
        #expect(decoded.colorSpace?.name == nil)                       // fixture sanity: not named
        let embedded = try #require(decoded.colorSpace?.copyICCData() as Data?)
        #expect(Fixture.contains(embedded, marker))                    // and really personal

        let out = try #require(ImageSanitizer.stripped(input)).png
        #expect(!Fixture.contains(out, marker))
        #expect(Fixture.decoded(out)?.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
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

    static func contains(_ data: Data, _ marker: String) -> Bool {
        let ascii = Data(marker.utf8)
        let utf16 = Data(marker.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        return data.range(of: ascii) != nil || data.range(of: utf16) != nil
    }

    /// Display P3's canonical ICC with every "Display P3" (ASCII and UTF-16BE) overwritten in place.
    static func displayP3ProfileRenamed(to marker: String) -> Data? {
        guard var icc = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?,
              marker.count == "Display P3".count else { return nil }
        for (from, to) in [(Data("Display P3".utf8), Data(marker.utf8)),
                           (Data("Display P3".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }),
                            Data(marker.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }))] {
            while let r = icc.range(of: from) { icc.replaceSubrange(r, with: to) }
        }
        return icc
    }

    /// A small PNG whose colour profile is `profile`, embedded verbatim as an iCCP chunk — the way
    /// an app that writes PNGs itself would, bypassing CoreGraphics' canonicalisation.
    static func pngWithRawICCP(_ profile: Data) -> Data? {
        guard let base = image(as: "public.png", space: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let bytes = [UInt8](base)
        var out = Array(bytes[0..<8])
        var i = 8
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let type = String(bytes: bytes[i + 4..<i + 8], encoding: .ascii) ?? ""
            let end = i + 12 + length
            guard end <= bytes.count else { return nil }
            if !["iCCP", "sRGB", "gAMA", "cHRM"].contains(type) { out += bytes[i..<end] }
            if type == "IHDR" {
                guard let deflated = try? (profile as NSData).compressed(using: .zlib) as Data else { return nil }
                var z: [UInt8] = [0x78, 0x9C] + [UInt8](deflated)
                let adler = adler32([UInt8](profile))
                z += [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
                out += chunk("iCCP", [UInt8]("Personal".utf8) + [0, 0] + z)
            }
            i = end
        }
        return Data(out)
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let n = UInt32(data.count), t = [UInt8](type.utf8), c = crc32(t + data)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + t + data
            + [UInt8(c >> 24), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)]
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in bytes { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }
}
