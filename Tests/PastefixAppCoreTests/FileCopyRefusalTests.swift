import Testing
import Foundation
import ImageIO
import AppKit
@testable import PastefixAppCore

/// #78: `public.file-url` alone must not decide "no image". Finder's file copy and a Photos.app
/// copy both carry one, and only Finder's image is an icon. The two type lists below are measured,
/// not invented — copied from real pasteboards (see #78) — so the rule is tested against the
/// exact shapes it has to separate.
@Suite("ClipboardImageRead.refusesAsFileCopy")
struct FileCopyRefusalTests {
    /// Finder writes these same 16 types for every file it copies — a JPEG, a PNG and a .txt
    /// alike. Its `public.tiff` is the file's 1024×1024 icon, and it never offers the file's own
    /// image format.
    static let finderCopy: Set<String> = [
        "public.file-url", "CorePasteboardFlavorType 0x6675726C",
        "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn",
        "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
        "NSFilenamesPboardType", "Apple URL pasteboard type",
        "com.apple.finder.noderef", "fndf",
        "public.utf16-external-plain-text", "CorePasteboardFlavorType 0x75743136",
        "public.utf8-plain-text", "NSStringPboardType",
        "com.apple.icns", "CorePasteboardFlavorType 0x69636E73",
        "public.tiff", "NeXT TIFF v4.0 pasteboard type",
    ]

    /// Photos.app, one photo copied: a file-url *and* the photograph itself as JPEG and TIFF.
    static let photosCopy: Set<String> = [
        "com.apple.photos.object-reference.asset",
        "public.jpeg", "CorePasteboardFlavorType 0x4A504547",
        "public.file-url", "CorePasteboardFlavorType 0x6675726C",
        "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn", "NSFilenamesPboardType",
        "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu", "Apple URL pasteboard type",
        "dyn.ah62d4rv4gu8za0cuqf31k3pcr7u1e3cmsvw04vdbsvuyq4pqqznzexcdr71004pfnv61a3k",
        "PXPasteboardItemDataFileURLCookieType",
        "dyn.ah62d4rv4gu8zawctqmzgn25ynmw0q3pwqz1gg3ndr71004pfnv61a3k", "PHObjectReferenceCookieType",
        "public.tiff", "NeXT TIFF v4.0 pasteboard type",
    ]

    @Test("a Finder file copy is refused")
    func finderRefused() {
        #expect(ClipboardImageRead.refusesAsFileCopy(declaredTypes: Self.finderCopy))
    }

    @Test("a Photos.app copy is accepted — the bug")
    func photosAccepted() {
        #expect(!ClipboardImageRead.refusesAsFileCopy(declaredTypes: Self.photosCopy))
    }

    @Test("a screenshot-shaped pasteboard with no file-url is untouched")
    func noFileURL() {
        #expect(!ClipboardImageRead.refusesAsFileCopy(declaredTypes: ["public.png", "public.tiff"]))
        #expect(!ClipboardImageRead.refusesAsFileCopy(declaredTypes: ["public.tiff"]))
        #expect(!ClipboardImageRead.refusesAsFileCopy(declaredTypes: []))
    }

    @Test("a file-url with only a TIFF is refused, whatever else is missing")
    func fileURLWithOnlyTIFF() {
        // Finder's shape with its positive markers stripped: the non-TIFF rule must refuse on its
        // own, so a rename of `icns`/`noderef` in a future macOS cannot reopen the icon bug.
        #expect(ClipboardImageRead.refusesAsFileCopy(declaredTypes: ["public.file-url", "public.tiff"]))
    }

    @Test("each file-url spelling counts, including the legacy flavours")
    func legacyFileURLSpellings() {
        for url in ["public.file-url", "CorePasteboardFlavorType 0x6675726C", "NSFilenamesPboardType"] {
            #expect(ClipboardImageRead.refusesAsFileCopy(declaredTypes: [url, "public.tiff"]), "\(url)")
        }
    }

    @Test("a file-url beside a real image format is eligible")
    func fileURLWithRealFormat() {
        for format in ["public.png", "public.jpeg", "public.heic"] {
            #expect(!ClipboardImageRead.refusesAsFileCopy(declaredTypes: ["public.file-url", format, "public.tiff"]), "\(format)")
        }
    }

    @Test("Finder's own markers refuse even beside a real image format")
    func finderMarkersWin() {
        // Positive refusal: these describe the icon case directly. Only on the refusal side, so a
        // false positive fails safe (no image session) rather than admitting an icon.
        #expect(ClipboardImageRead.refusesAsFileCopy(declaredTypes: ["com.apple.icns", "public.png"]))
        #expect(ClipboardImageRead.refusesAsFileCopy(declaredTypes: ["com.apple.finder.noderef", "public.jpeg", "public.file-url"]))
    }
}

/// The TIFF→PNG conversion strips GPS and camera EXIF. Photos.app offers no PNG, so a Photos
/// session goes through this conversion and its `imagePNG` carries no location. That protection
/// was *accidental* when #78 was fixed; this test makes it a property. If the converter is ever
/// changed to carry image properties forward, image upload (#48) starts publishing the GPS of
/// every photo copied from Photos — so that change must fail here and be decided on purpose,
/// together with #20 (strip EXIF/GPS).
@Suite("ImageBytes conversion strips location")
struct ConversionStripsLocationTests {
    @Test("a GPS-bearing TIFF converts to a PNG with no GPS, date or camera")
    func conversionDropsGPS() throws {
        let tiff = try #require(Self.geotagged(as: "public.tiff"))
        let before = try #require(Self.properties(tiff))
        #expect(before["{GPS}"] != nil)   // the fixture really carries it, or this proves nothing

        guard case .png(let png) = ImageBytes.normalise(tiff) else {
            Issue.record("a small TIFF must convert"); return
        }
        let after = try #require(Self.properties(png))
        #expect(after["{GPS}"] == nil)
        #expect((after["{Exif}"] as? [String: Any])?["DateTimeOriginal"] == nil)
        #expect((after["{TIFF}"] as? [String: Any])?["Make"] == nil)
    }

    @Test("a GPS-bearing PNG keeps its GPS through the session — verbatim by design")
    func verbatimPNGKeepsGPS() throws {
        // The other half, stated so the suite does not read as "images are stripped", which is
        // false *inside* the session: a PNG is kept verbatim so Save writes back exactly what was
        // copied, and a geotagged PNG therefore keeps its GPS here. Stripping happens on the way
        // out — `ImageSanitizer` in PastefixCore (#20), which image upload (#48) must go through,
        // and which `ImageSanitizerTests` pins. This assertion guards the other direction: a
        // change that starts re-encoding PNGs on the session path would break Save's promise.
        let png = try #require(Self.geotagged(as: "public.png"))
        #expect(Self.properties(png)?["{GPS}"] != nil)   // fixture sanity
        guard case .png(let out) = ImageBytes.normalise(png) else {
            Issue.record("a small PNG must be accepted"); return
        }
        #expect(out == png)                              // byte-for-byte
        #expect(Self.properties(out)?["{GPS}"] != nil)   // GPS and all — deliberately
    }

    // #97: history capture defers bytes labelled public.png that aren't a PNG to the same
    // conversion as a TIFF, instead of storing them raw. The sniff decides; the conversion strips.
    @Test("the PNG sniff reads the header, not the label")
    func pngSniff() throws {
        #expect(ImageBytes.isPNG(try #require(Self.geotagged(as: "public.png"))))
        #expect(!ImageBytes.isPNG(try #require(Self.geotagged(as: "public.jpeg"))))
        #expect(!ImageBytes.isPNG(try #require(Self.geotagged(as: "public.tiff"))))
        #expect(!ImageBytes.isPNG(Data("not an image at all".utf8)))
        #expect(!ImageBytes.isPNG(Data()))
    }

    @Test("a GPS-bearing JPEG converts to a PNG with no GPS, date or camera")
    func jpegConversionDropsGPS() throws {
        let jpeg = try #require(Self.geotagged(as: "public.jpeg"))
        #expect(Self.properties(jpeg)?["{GPS}"] != nil)   // fixture sanity
        let png = try #require(ImageBytes.convertedToPNG(jpeg))
        #expect(ImageBytes.isPNG(png))
        let after = try #require(Self.properties(png))
        #expect(after["{GPS}"] == nil)
        #expect((after["{Exif}"] as? [String: Any])?["DateTimeOriginal"] == nil)
        #expect((after["{TIFF}"] as? [String: Any])?["Make"] == nil)
    }

    @Test("conversion applies the orientation tag instead of dropping it")
    func conversionBakesOrientation() throws {
        // A phone stores a portrait photo as landscape sensor pixels plus Orientation 6. The
        // conversion drops every tag — so unless it *applies* the rotation first, the session
        // shows the photo on its side. #78 made Photos copies reach this conversion.
        let tiff = try #require(Self.geotagged(as: "public.tiff", orientation: 6))
        guard case .png(let png) = ImageBytes.normalise(tiff) else {
            Issue.record("a small TIFF must convert"); return
        }
        let props = try #require(Self.properties(png))
        #expect(props["PixelWidth"] as? Int == 12)    // 16x12 stored, displayed 12x16
        #expect(props["PixelHeight"] as? Int == 16)
        #expect(props["Orientation"] == nil || props["Orientation"] as? Int == 1)
        // The left half of the stored pixels is red. Rotated clockwise, stored bottom-right
        // (blue) becomes displayed bottom-left — a check a dropped-but-unapplied tag fails.
        let rep = try #require(NSBitmapImageRep(data: png))
        let bottomLeft = try #require(rep.colorAt(x: 0, y: rep.pixelsHigh - 1)?.usingColorSpace(.sRGB))
        #expect(bottomLeft.blueComponent > 0.5 && bottomLeft.redComponent < 0.5)
    }

    static func properties(_ d: Data) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
    }

    static func geotagged(as type: String, orientation: Int = 1) -> Data? {
        guard let ctx = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 12))       // left half red
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 8, y: 0, width: 8, height: 12))       // right half blue
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3456, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 45.6789, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:01 12:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FixtureCam"],
        ]
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}
