import Testing
import Foundation
import ImageIO
import AppKit
import UniformTypeIdentifiers
@testable import PastefixCore

/// #21: the JPEG candidate `ImageSanitizer.encodings` adds for an opaque image. The same bar as the
/// PNG path — nothing of the source survives — but held by an **allowlist of JPEG segments** rather
/// than a denylist of properties, because a denylist only catches what someone thought to list.
@Suite("ImageSanitizer JPEG")
struct ImageSanitizerJPEGTests {
    static var displayP3ICC: Data {
        CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data? ?? Data()
    }

    /// An RGBA image whose alpha channel is present in the encoded PNG, every pixel at 255 except,
    /// optionally, one at `oddAlpha`. The shape `screencapture` writes: a channel, all opaque.
    static func rgba(width: Int = 48, height: Int = 32, oddAlpha: UInt8? = nil) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8(i / 4 % 200); pixels[i + 1] = 90; pixels[i + 2] = UInt8(i / 4 % 170); pixels[i + 3] = 255
        }
        if let oddAlpha { pixels[(height / 2 * width + width / 3) * 4 + 3] = oddAlpha }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// Fixture sanity: the encoded PNG really carries an alpha channel. Without this, a fixture that
    /// ImageIO had quietly written as RGB would pass an alpha-channel check as well as a pixel scan.
    static func hasAlphaChannel(_ data: Data) -> Bool {
        guard let image = Fixture.decoded(data) else { return false }
        return ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
    }

    // MARK: Opacity is a pixel test

    @Test("an alpha channel with every pixel at 255 is opaque: a JPEG is made")
    func opaqueAlphaChannelGetsJPEG() throws {
        let input = try #require(Self.rgba())
        #expect(Self.hasAlphaChannel(input))
        let encodings = try #require(ImageSanitizer.encodings(input))
        let jpeg = try #require(encodings.jpeg.image)
        #expect(jpeg.format == .jpeg)
        #expect(encodings.png.format == .png)
        #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithData(jpeg.data as CFData, nil))) as String? == "public.jpeg")
    }

    @Test("one pixel at alpha 254 is not opaque: no JPEG is made at all")
    func oneTranslucentPixelNoJPEG() throws {
        let input = try #require(Self.rgba(oddAlpha: 254))
        #expect(Self.hasAlphaChannel(input))
        let encodings = try #require(ImageSanitizer.encodings(input))
        #expect(encodings.jpeg == .notOpaque)
        #expect(encodings.png.format == .png)
    }

    @Test("a transparent half is not opaque, and the PNG keeps it")
    func transparentNoJPEG() throws {
        let input = try #require(Fixture.image(as: "public.png", transparentRightHalf: true))
        let encodings = try #require(ImageSanitizer.encodings(input))
        #expect(encodings.jpeg == .notOpaque)
    }

    @Test("an image with no alpha channel at all is opaque")
    func noChannelIsOpaque() throws {
        let input = try #require(Fixture.image(as: "public.jpeg"))
        #expect(!Self.hasAlphaChannel(input))
        #expect(try #require(ImageSanitizer.encodings(input)).jpeg.image != nil)
    }

    @Test("encodings' PNG is exactly what stripped makes")
    func pngMatchesStripped() throws {
        let input = try #require(Fixture.image(as: "public.png"))
        #expect(try #require(ImageSanitizer.encodings(input)).png == ImageSanitizer.stripped(input))
    }

    @Test("encodings refuses what stripped refuses")
    func encodingsRefuse() throws {
        #expect(ImageSanitizer.encodings(Data()) == nil)
        #expect(ImageSanitizer.encodings(Data("not an image".utf8)) == nil)
        let input = try #require(Fixture.image(as: "public.png"))
        #expect(ImageSanitizer.encodings(input, maxPixels: Fixture.width * Fixture.height - 1) == nil)
    }

    // MARK: A failed JPEG falls back to the PNG (#93 review)

    @Test("a failed JPEG encode keeps the PNG and says encodeFailed — not notOpaque, not nil")
    func failedEncodeFallsBack() throws {
        let input = try #require(Self.rgba())
        let encodings = try #require(ImageSanitizer.encodings(input, maxPixels: PixelLimits.maxConvertiblePixels,
                                                               jpegEncoder: { _, _ in nil }))
        #expect(encodings.jpeg == .encodeFailed)
        #expect(encodings.png == ImageSanitizer.stripped(input))
    }

    @Test("an empty JPEG counts as a failed one")
    func emptyEncodeFallsBack() throws {
        let input = try #require(Self.rgba())
        let encodings = try #require(ImageSanitizer.encodings(input, maxPixels: PixelLimits.maxConvertiblePixels,
                                                               jpegEncoder: { _, _ in Data() }))
        #expect(encodings.jpeg == .encodeFailed)
    }

    @Test("a non-opaque image never reaches the JPEG encoder, so it stays notOpaque")
    func notOpaqueSkipsEncoder() throws {
        let input = try #require(Self.rgba(oddAlpha: 254))
        var called = false
        let encodings = try #require(ImageSanitizer.encodings(input, maxPixels: PixelLimits.maxConvertiblePixels,
                                                               jpegEncoder: { _, _ in called = true; return nil }))
        #expect(encodings.jpeg == .notOpaque)
        #expect(!called)
    }

    // MARK: What the JPEG keeps

    @Test("the JPEG bakes orientation into its pixels", arguments: ImageSanitizerTests.formats)
    func jpegBakesOrientation(format: String) throws {
        let input = try #require(Fixture.image(as: format, orientation: 6))
        #expect(Fixture.properties(input)?["Orientation"] as? Int == 6)
        let out = try #require(ImageSanitizer.encodings(input)?.jpeg.image).data
        let props = try #require(Fixture.properties(out))
        #expect(props["PixelWidth"] as? Int == Fixture.height)
        #expect(props["PixelHeight"] as? Int == Fixture.width)
        #expect(props["Orientation"] == nil || props["Orientation"] as? Int == 1)
        let rep = try #require(NSBitmapImageRep(data: out))
        let bottomLeft = try #require(rep.colorAt(x: 0, y: rep.pixelsHigh - 1)?.usingColorSpace(.sRGB))
        #expect(bottomLeft.blueComponent > 0.5 && bottomLeft.redComponent < 0.5)
    }

    @Test("the JPEG keeps Display P3, as the canonical profile", arguments: ImageSanitizerTests.formats)
    func jpegKeepsDisplayP3(format: String) throws {
        let input = try #require(Fixture.image(as: format))
        let out = try #require(ImageSanitizer.encodings(input)?.jpeg.image).data
        let space = try #require(Fixture.decoded(out)?.colorSpace)
        #expect(space.name as String? == CGColorSpace.displayP3 as String)
        #expect(space.copyICCData() as Data? == Self.displayP3ICC)
    }

    @Test("a non-standard profile reaches the JPEG as Display P3")
    func jpegPersonalProfileReplaced() throws {
        let custom = try #require(Fixture.nonStandardColorSpace())
        let input = try #require(Fixture.image(as: "public.png", space: custom))
        let out = try #require(ImageSanitizer.encodings(input)?.jpeg.image).data
        #expect(Fixture.decoded(out)?.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    }

    // MARK: The segment allowlist

    @Test("the JPEG carries only allowlisted segments, from a source with GPS, EXIF, TIFF and IPTC",
          arguments: ImageSanitizerTests.formats)
    func jpegSegmentsAllowlisted(format: String) throws {
        let input = try #require(Fixture.image(as: format, orientation: 6))
        let before = try #require(Fixture.properties(input))
        #expect(before["{GPS}"] != nil)                   // fixture sanity: there is something to leak
        #expect(before["{IPTC}"] != nil)
        let out = try #require(ImageSanitizer.encodings(input)?.jpeg.image).data
        #expect(JPEGSegments.violations(in: out, expectedICC: Self.displayP3ICC) == [])
        #expect(!Fixture.contains(out, "FixtureCam"))
        #expect(!Fixture.contains(out, "Fixtureville"))
    }

    @Test("the allowlist is checked on the non-standard-profile path too")
    func jpegSegmentsAllowlistedAfterRedraw() throws {
        let custom = try #require(Fixture.nonStandardColorSpace())
        let input = try #require(Fixture.image(as: "public.png", space: custom))
        let out = try #require(ImageSanitizer.encodings(input)?.jpeg.image).data
        #expect(JPEGSegments.violations(in: out, expectedICC: Self.displayP3ICC) == [])
    }

    // MARK: The checker can fail — each admission is by exact content, not by type

    /// A bare ImageIO JPEG plus whatever properties a mutation might pass.
    static func imageIOJPEG(properties: [CFString: Any]) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return nil }
        var all = properties
        all[kCGImageDestinationLossyCompressionQuality] = ImageSanitizer.jpegQuality
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, all as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    @Test("the baseline ImageIO JPEG passes — so the failures below are the additions")
    func checkerBaseline() throws {
        let jpeg = try #require(Self.imageIOJPEG(properties: [:]))
        #expect(JPEGSegments.violations(in: jpeg, expectedICC: Self.displayP3ICC) == [])
    }

    @Test("an EXIF APP1 carrying a camera make fails")
    func checkerRejectsMake() throws {
        let jpeg = try #require(Self.imageIOJPEG(properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FixtureCam"]]))
        #expect(JPEGSegments.violations(in: jpeg, expectedICC: Self.displayP3ICC).contains { $0.hasPrefix("APP1") })
    }

    @Test("an EXIF APP1 carrying a date fails")
    func checkerRejectsExifDate() throws {
        let jpeg = try #require(Self.imageIOJPEG(properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:01 12:00:00"]]))
        #expect(JPEGSegments.violations(in: jpeg, expectedICC: Self.displayP3ICC).contains { $0.hasPrefix("APP1") })
    }

    @Test("GPS fails")
    func checkerRejectsGPS() throws {
        let jpeg = try #require(Self.imageIOJPEG(properties: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N"]]))
        #expect(JPEGSegments.violations(in: jpeg, expectedICC: Self.displayP3ICC).contains { $0.hasPrefix("APP1") })
    }

    @Test("a non-empty IPTC APP13 fails")
    func checkerRejectsIPTC() throws {
        let jpeg = try #require(Self.imageIOJPEG(properties: [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Fixtureville"]]))
        #expect(JPEGSegments.violations(in: jpeg, expectedICC: Self.displayP3ICC).contains { $0.hasPrefix("APP13") })
    }

    struct Splice: Sendable, CustomTestStringConvertible {
        let name: String
        let marker: UInt8
        let payload: [UInt8]
        var testDescription: String { name }
    }

    static let splices: [Splice] = [
        Splice(name: "XMP APP1", marker: 0xE1, payload: Array("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>".utf8)),
        Splice(name: "COM", marker: 0xFE, payload: Array("a comment".utf8)),
        Splice(name: "APP2 MPF", marker: 0xE2, payload: Array("MPF\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8]),
        Splice(name: "APP14 Adobe", marker: 0xEE, payload: Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 1]),
        Splice(name: "JFIF with a thumbnail", marker: 0xE0,
               payload: Array("JFIF\0".utf8) + [1, 1, 0, 0, 72, 0, 72, 1, 1, 0, 0, 0]),
        Splice(name: "Exif with a spare byte", marker: 0xE1,
               payload: Array("Exif\0\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0xAB]),
    ]

    @Test("spliced segments fail: XMP, COM, MPF, APP14, a JFIF thumbnail, a malformed Exif", arguments: splices)
    func checkerRejectsSplices(_ splice: Splice) throws {
        let base = try #require(Self.imageIOJPEG(properties: [:]))
        let spliced = JPEGSegments.splicing(base, marker: splice.marker, payload: splice.payload)
        #expect(!JPEGSegments.violations(in: spliced, expectedICC: Self.displayP3ICC).isEmpty)
    }

    @Test("bytes after EOI fail")
    func checkerRejectsTrailer() throws {
        let base = try #require(Self.imageIOJPEG(properties: [:]))
        #expect(!JPEGSegments.violations(in: base + Data([0xFF, 0xD8, 0x00]), expectedICC: Self.displayP3ICC).isEmpty)
    }

    @Test("an ICC profile other than the expected one fails")
    func checkerRejectsOtherICC() throws {
        let base = try #require(Self.imageIOJPEG(properties: [:]))
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        #expect(!JPEGSegments.violations(in: base, expectedICC: srgb).isEmpty)
    }
}

/// Walks a JPEG's markers and reports every segment that is not on the allowlist (#21).
///
/// **Allowed:** SOI; APP0 JFIF with no thumbnail; APP2 ICC_PROFILE whose reassembled bytes equal
/// the expected profile; DQT, SOF0/SOF2, DHT, DRI; SOS and its entropy-coded data (RSTn inside
/// it); EOI with **nothing after it**.
///
/// **Two ImageIO segments admitted by exact content, never by type.** Measured on macOS 26.3.1
/// and 26.6.2, a bare `CGImageDestinationAddImage` JPEG with only the quality option *always*
/// carries:
/// - **APP1 Exif** (64 bytes for P3, 76 for sRGB): a TIFF header and IFD0 with exactly one entry,
///   the ExifIFD pointer `0x8769`; the Exif IFD holds only `A002`/`A003` (pixel dimensions), plus
///   `A001` ColorSpace for sRGB; next-IFD offset 0, so no IFD1 and no thumbnail. Admitted only in
///   exactly that layout, every value inline, with no byte to spare.
/// - **APP13 "Photoshop 3.0"**: 8BIM `0x0404` (IPTC-NAA) of length 0 and 8BIM `0x0425` (IPTC
///   digest) = MD5 of the empty string. Admitted only when byte-equal to that 56-byte constant.
///
/// They are ImageIO's own stamps, not carried from the source. Anything else — an XMP APP1, an
/// EXIF with any other tag, a non-empty IPTC, COM, APP2 MPF (gain maps, depth), APP14, a JFIF
/// thumbnail — is a violation. Do not widen an admission to "any APP1" or "any APP13".
enum JPEGSegments {
    static let imageIOEmptyIPTC: [UInt8] = hex(
        "50686f746f73686f7020332e30003842494d04040000000000003842494d0425000000000010d41d8cd98f00b204e9800998ecf8427e")

    /// Every violation found; empty means every segment is allowlisted.
    static func violations(in data: Data, expectedICC: Data?) -> [String] {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return ["no SOI"] }
        var problems: [String] = []
        var icc: [UInt8] = []
        var i = 2
        while true {
            guard i + 1 < b.count, b[i] == 0xFF else { problems.append("junk or truncation at \(i)"); break }
            let marker = b[i + 1]
            if marker == 0xD9 {
                if i + 2 != b.count { problems.append("\(b.count - i - 2) bytes after EOI") }
                break
            }
            guard i + 3 < b.count else { problems.append("truncated at \(i)"); break }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { problems.append("bad length at \(i)"); break }
            let payload = Array(b[(i + 4)..<(i + 2 + length)])
            switch marker {
            case 0xE0:
                // JFIF, 14 bytes: identifier, version, units, densities, and a 0x0 thumbnail.
                if !(payload.count == 14 && payload.starts(with: Array("JFIF\0".utf8)) && payload[12] == 0 && payload[13] == 0) {
                    problems.append("APP0 is not a thumbnail-free JFIF: \(describe(payload))")
                }
            case 0xE1:
                if let problem = exifProblem(payload) { problems.append("APP1: \(problem): \(describe(payload))") }
            case 0xED:
                if payload != imageIOEmptyIPTC { problems.append("APP13 is not ImageIO's empty-IPTC stamp: \(describe(payload))") }
            case 0xE2:
                let tag = Array("ICC_PROFILE\0".utf8)
                if payload.starts(with: tag), payload.count > tag.count + 2 {
                    icc += payload[(tag.count + 2)...]
                } else {
                    problems.append("APP2 is not ICC_PROFILE: \(describe(payload))")
                }
            case 0xDB, 0xC0, 0xC2, 0xC4, 0xDD:
                break
            case 0xDA:
                // Entropy-coded data runs to the next marker that is not a stuffed 0x00 or an RSTn.
                var j = i + 2 + length
                while j + 1 < b.count, !(b[j] == 0xFF && b[j + 1] != 0x00 && !(0xD0...0xD7).contains(b[j + 1])) { j += 1 }
                i = j
                continue
            default:
                problems.append(String(format: "segment FF%02X: ", marker) + describe(payload))
            }
            i += 2 + length
        }
        if let expectedICC {
            if Data(icc) != expectedICC { problems.append("ICC profile is not the expected one (\(icc.count) bytes)") }
        } else if !icc.isEmpty {
            problems.append("an ICC profile where none was expected")
        }
        return problems
    }

    /// nil when `payload` is exactly ImageIO's minimal Exif: IFD0 = {0x8769}, the Exif IFD's tags
    /// within {A001, A002, A003}, each a single inline SHORT or LONG, no IFD1, and no spare byte.
    static func exifProblem(_ payload: [UInt8]) -> String? {
        guard payload.starts(with: Array("Exif\0\0".utf8)) else { return "not Exif (XMP or other)" }
        let t = Array(payload[6...])
        guard t.count >= 8 else { return "truncated TIFF header" }
        let big: Bool
        switch (t[0], t[1]) {
        case (0x4D, 0x4D): big = true
        case (0x49, 0x49): big = false
        default: return "bad byte order"
        }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= t.count else { return nil }
            return big ? Int(t[o]) << 8 | Int(t[o + 1]) : Int(t[o + 1]) << 8 | Int(t[o])
        }
        func u32(_ o: Int) -> Int? {
            guard let hi = u16(big ? o : o + 2), let lo = u16(big ? o + 2 : o) else { return nil }
            return hi << 16 | lo
        }
        guard u16(2) == 42, u32(4) == 8, let n0 = u16(8), n0 == 1 else { return "IFD0 is not a single entry at offset 8" }
        guard u16(10) == 0x8769, u16(12) == 4, u32(14) == 1, let exifOffset = u32(18) else { return "IFD0's entry is not the ExifIFD pointer" }
        guard u32(22) == 0 else { return "IFD0 has a next IFD (IFD1: a thumbnail)" }
        guard exifOffset == 26, let n1 = u16(26) else { return "Exif IFD not directly after IFD0" }
        for k in 0..<n1 {
            let e = 28 + 12 * k
            guard let tag = u16(e), [0xA001, 0xA002, 0xA003].contains(tag) else {
                return String(format: "Exif tag %04X", u16(e) ?? -1)
            }
            guard let type = u16(e + 2), type == 3 || type == 4, u32(e + 4) == 1 else { return "Exif value not a single inline number" }
        }
        guard u32(28 + 12 * n1) == 0 else { return "Exif IFD has a next IFD" }
        guard t.count == 28 + 12 * n1 + 4 else { return "\(t.count - (28 + 12 * n1 + 4)) unaccounted bytes" }
        return nil
    }

    /// `jpeg` with one segment inserted straight after SOI.
    static func splicing(_ jpeg: Data, marker: UInt8, payload: [UInt8]) -> Data {
        let length = payload.count + 2
        let segment = [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        return jpeg.prefix(2) + Data(segment) + jpeg.dropFirst(2)
    }

    static func describe(_ payload: [UInt8]) -> String {
        let head = payload.prefix(24).map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
        return "\(payload.count) bytes, \"\(head)\", hex \(payload.prefix(96).map { String(format: "%02x", $0) }.joined())"
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            out.append(UInt8(s[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}
