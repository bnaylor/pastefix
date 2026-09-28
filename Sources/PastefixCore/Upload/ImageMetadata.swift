import Foundation
import ImageIO

/// What an image carries that `ImageSanitizer` would remove, in categories a user can read (#82).
/// Header-only: `CGImageSourceCopyPropertiesAtIndex`, no decode.
///
/// **Structural keys don't count, by an explicit allowlist.** ImageIO fills keys into *every*
/// image — a bare PNG written by `CGImageDestination` reports `{Exif: ColorSpace,
/// PixelXDimension, PixelYDimension}` and `{PNG: Chromaticities, Gamma, InterlaceType, sRGBIntent}`;
/// a ⌃⇧⌘4 screenshot adds `{TIFF: ResolutionUnit, XResolution, YResolution}` and `UserComment`
/// (measured, spec review). Without the allowlist "other metadata" is true of everything and
/// "nothing to remove" is unreachable.
public enum ImageMetadata {
    public enum Category: Int, Sendable, Comparable, CaseIterable {
        case location, cameraAndDate, other
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public static let nothingToRemoveMessage = "This image has no location or camera details to remove."

    private static func keys(_ keys: [CFString]) -> Set<String> { Set(keys.map { $0 as String }) }

    /// Keys ImageIO writes on its own, per dictionary. Present in a clean image; never "metadata".
    static let structural: [String: Set<String>] = [
        kCGImagePropertyExifDictionary as String: keys([
            kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifColorSpace,
        ]),
        kCGImagePropertyTIFFDictionary as String: keys([
            kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFXResolution,
            kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFOrientation,
        ]),
        kCGImagePropertyPNGDictionary as String: keys([
            kCGImagePropertyPNGGamma, kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGInterlaceType,
            kCGImagePropertyPNGsRGBIntent, kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter,
        ]).union(["pHYs"]),
    ]

    /// Keys that are camera or date details, per dictionary. Anything else that is not structural
    /// is "other".
    static let cameraAndDate: [String: Set<String>] = [
        kCGImagePropertyExifDictionary as String: keys([
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
            kCGImagePropertyExifSubsecTime, kCGImagePropertyExifSubsecTimeOriginal,
            kCGImagePropertyExifSubsecTimeDigitized, kCGImagePropertyExifOffsetTime,
            kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
            kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSerialNumber,
            kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName,
        ]),
        kCGImagePropertyTIFFDictionary as String: keys([
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
        ]),
        kCGImagePropertyPNGDictionary as String: keys([
            kCGImagePropertyPNGCreationTime, kCGImagePropertyPNGModificationTime,
        ]),
    ]

    /// XMP namespaces not to count: those ImageIO also surfaces as the dictionaries `inspect`
    /// walks (`exif`, `exifEX`, `tiff`), and `iio`, ImageIO's own bookkeeping — it adds
    /// `iio:hasXMP` to any image with a packet (measured on the screenshot-shaped fixture).
    static let surfacedXMPPrefixes: Set<String> = ["exif", "exifEX", "tiff", "iio"]

    public static func inspect(_ data: Data) -> Set<Category> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var found: Set<Category> = []
        for (key, value) in props {
            // Only the metadata dictionaries; top-level keys (PixelWidth, DPIWidth, ProfileName…)
            // describe the image itself.
            guard key.hasPrefix("{"), let dict = value as? [String: Any], !dict.isEmpty else { continue }
            if key == kCGImagePropertyGPSDictionary as String { found.insert(.location); continue }
            if key == kCGImagePropertyExifAuxDictionary as String || key.hasPrefix("{Maker") {
                found.insert(.cameraAndDate); continue
            }
            let skip = structural[key] ?? []
            let camera = cameraAndDate[key] ?? []
            for (field, fieldValue) in dict where !skip.contains(field) {
                // macOS writes "Screenshot" here on every screen capture; any other comment is text
                // someone wrote, and can say anything.
                if key == kCGImagePropertyExifDictionary as String,
                   field == kCGImagePropertyExifUserComment as String,
                   (fieldValue as? String) == "Screenshot" { continue }
                found.insert(camera.contains(field) ? .cameraAndDate : .other)
            }
        }
        // XMP beyond what the dictionaries above already showed. Not "an XMP packet exists": ImageIO
        // writes a PNG's EXIF *as* XMP, so every screenshot has one (`exif:UserComment` is where its
        // "Screenshot" lives; measured). Tags in the namespaces the dictionaries surface — `exif`,
        // `exifEX`, `tiff`, with the allowlists applied there — are not counted twice; any other
        // namespace (`dc`, `xmp`, `photoshop`, `Iptc4xmpCore`…) is metadata the dictionaries don't show.
        if let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag],
           tags.contains(where: { !surfacedXMPPrefixes.contains((CGImageMetadataTagCopyPrefix($0) as String?) ?? "") }) {
            found.insert(.other)
        }
        return found
    }

    /// "Removed location and camera details." — what a strip took, in plain words.
    public static func removedMessage(_ found: Set<Category>) -> String {
        switch (found.contains(.location), found.contains(.cameraAndDate), found.contains(.other)) {
        case (true, true, true): return "Removed location, camera details and other metadata."
        case (true, true, false): return "Removed location and camera details."
        case (true, false, true): return "Removed location details and other metadata."
        case (true, false, false): return "Removed location details."
        case (false, true, true): return "Removed camera details and other metadata."
        case (false, true, false): return "Removed camera details."
        case (false, false, _): return "Removed metadata."
        }
    }
}
