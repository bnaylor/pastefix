import Testing
import Foundation
import ImageIO
@testable import PastefixCore

@Suite("ImageMetadata.inspect (#82)")
struct ImageMetadataTests {
    /// A PNG shaped like a macOS screenshot: resolution, pixel dimensions and a `UserComment` of
    /// "Screenshot" — what the spec review measured on a real ⌃⇧⌘4 capture.
    static func screenshotShaped(extraExif: [CFString: Any] = [:], gps: Bool = false) -> Data? {
        guard let plain = Fixture.image(as: "public.png"), let stripped = ImageSanitizer.stripped(plain),
              let src = CGImageSourceCreateWithData(stripped.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "Screenshot",
                                     kCGImagePropertyExifPixelXDimension: Fixture.width,
                                     kCGImagePropertyExifPixelYDimension: Fixture.height]
        exif.merge(extraExif) { $1 }
        var props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFResolutionUnit: 2,
                                             kCGImagePropertyTIFFXResolution: 144, kCGImagePropertyTIFFYResolution: 144],
            kCGImagePropertyExifDictionary: exif,
        ]
        if gps { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N"] }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    @Test("the GPS fixture reports location, camera/date, and other")
    func fixture() throws {
        let data = try #require(Fixture.image(as: "public.png"))
        #expect(ImageMetadata.inspect(data) == [.location, .cameraAndDate, .other])
    }

    // Without the structural allowlist, ImageIO's own keys make "other" true of every image and
    // "nothing to remove" unreachable (measured in the spec review).
    @Test("a stripped image reports nothing: stripping twice finds nothing the second time")
    func strippedIsClean() throws {
        let data = try #require(Fixture.image(as: "public.png"))
        let clean = try #require(ImageSanitizer.stripped(data))
        #expect(ImageMetadata.inspect(clean.data).isEmpty)
    }

    @Test("a screenshot's structural keys and its 'Screenshot' comment are not metadata")
    func screenshot() throws {
        #expect(ImageMetadata.inspect(try #require(Self.screenshotShaped())).isEmpty)
    }

    @Test("any other UserComment is metadata")
    func otherComment() throws {
        let data = try #require(Self.screenshotShaped(extraExif: [kCGImagePropertyExifUserComment: "meeting notes"]))
        #expect(ImageMetadata.inspect(data) == [.other])
    }

    // Review Focus 1: the exemption is for one key, not for the image.
    @Test("a screenshot comment does not hide GPS")
    func screenshotWithGPS() throws {
        #expect(ImageMetadata.inspect(try #require(Self.screenshotShaped(gps: true))) == [.location])
    }

    /// A clean PNG carrying one XMP tag in a namespace no properties dictionary surfaces.
    static func withXMPCreator() -> Data? {
        guard let plain = Fixture.image(as: "public.png"), let stripped = ImageSanitizer.stripped(plain),
              let src = CGImageSourceCreateWithData(stripped.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        // A namespace ImageIO has no dictionary for, so only the XMP branch can see it. (`dc:creator`
        // is no good here: ImageIO also maps it into a dictionary, so a test with it passed with
        // the XMP branch switched off.)
        let meta = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(meta, "http://example.com/pastefix-test/" as CFString,
                                                        "pfxtest" as CFString, nil),
              CGImageMetadataSetValueWithPath(meta, nil, "pfxtest:note" as CFString, "anything" as CFString)
        else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageAndMetadata(dst, image, meta, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    // ImageIO carries a PNG's EXIF as XMP, so "has an XMP packet" is true of every screenshot
    // (measured). What counts is a tag in a namespace the dictionaries don't already show.
    @Test("an XMP tag outside the surfaced namespaces is metadata")
    func xmpCreator() throws {
        #expect(ImageMetadata.inspect(try #require(Self.withXMPCreator())) == [.other])
    }

    /// A PNG with no metadata at all, drawn in a calibrated-display-style ICC profile — what a
    /// screenshot on an external or calibrated display carries. Built in-test, never from the
    /// machine's Displays folder.
    static func displayProfiled() -> Data? {
        guard let space = Fixture.nonStandardColorSpace(),
              let ctx = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    // #104 review: a display's profile names the monitor model (and, calibrated, often a person).
    // Upload converts it; Strip said "nothing to remove" and left it. Measured on a real
    // "DELL P2723DE" profile: inspect() was [].
    @Test("a non-standard (display) colour profile is metadata, and stripping it leaves nothing")
    func displayProfile() throws {
        let data = try #require(Self.displayProfiled())
        #expect(ImageMetadata.inspect(data) == [.other])
        let clean = try #require(ImageSanitizer.stripped(data))
        #expect(ImageMetadata.inspect(clean.data).isEmpty, "stripped to a standard space")
    }

    @Test("the removal sentence names what went")
    func messages() {
        #expect(ImageMetadata.removedMessage([.location]) == "Removed location details.")
        #expect(ImageMetadata.removedMessage([.location, .cameraAndDate]) == "Removed location and camera details.")
        #expect(ImageMetadata.removedMessage([.location, .cameraAndDate, .other]) == "Removed location, camera details and other metadata.")
        #expect(ImageMetadata.removedMessage([.other]) == "Removed metadata.")
    }

    @Test("bytes that aren't an image report nothing")
    func notAnImage() {
        #expect(ImageMetadata.inspect(Data("hello".utf8)).isEmpty)
    }
}
