import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The pixel ceiling for any full decode, and overflow-safe pixel counting. Here in Core so the
/// upload sanitizer and `PastefixAppCore.ImageBytes` share one number (`ImageBytes` forwards to
/// it; see there for how 25 M was measured).
public enum PixelLimits {
    public static let maxConvertiblePixels = 25_000_000

    /// `width * height`, or nil if it overflows. Image dimensions come from untrusted headers, and
    /// an unchecked `*` on crafted values traps the process. nil is always over any ceiling.
    public static func pixelCount(width: Int, height: Int) -> Int? {
        let (pixels, overflowed) = width.multipliedReportingOverflow(by: height)
        return overflowed ? nil : pixels
    }
}

/// Image bytes that have been through `ImageSanitizer` — and cannot have come from anywhere else.
///
/// The initialiser is private to this file, so the only way to obtain one is a successful
/// `ImageSanitizer.stripped(_:)`. Image upload (#48) accepts a `SanitizedImage`, never `Data`, so
/// "strip, and if that fails send the original" does not compile rather than merely failing a
/// test. The same shape `UploadPayload.text` uses for the secret gate.
public struct SanitizedImage: Sendable, Equatable {
    public let png: Data
    fileprivate init(png: Data) { self.png = png }
}

/// Removes identifying metadata from an image before it leaves the machine (#20).
///
/// Why, measured rather than assumed (the per-source comparison is on #20): the pasteboard carries
/// whatever the writing app put there. A Photos.app copy carries full GPS and device EXIF; the
/// session's TIFF→PNG conversion happens to drop it, but a PNG is kept **verbatim**, so any source
/// writing a geotagged PNG puts its coordinates in the session.
///
/// Relationship to Critical Invariant 13: that invariant's scan clause is written for text
/// (SecretDetector). For an image the equivalent gate is this function — an image upload is sent
/// only as a `SanitizedImage`, and a nil here refuses the upload. Images are **not** scanned for
/// secrets (#19 is OCR); the upload surface says so.
///
/// What it does — each pinned by `ImageSanitizerTests`, each checked against a mutation:
/// - **Bakes orientation into the pixels, then drops the tag.** A phone stores a portrait as
///   landscape sensor pixels plus Orientation 6; stripping the tag without applying it rotates it.
/// - **Keeps a standard colour profile, and replaces any other.** A standard profile (sRGB,
///   Display P3, …) is generic. A non-standard one is usually a *display's* — screenshots embed
///   it — and is often named after the person or machine that calibrated it, while every ICC
///   header carries device manufacturer, model and a creation date whatever its name says. Such a
///   profile is converted into Display P3, which is visually lossless for anything inside P3 and
///   clips a wider custom gamut slightly: that clipping is the cost, and it is accepted.
/// - Removes GPS, EXIF, TIFF (make, model), IPTC, XMP and PNG text chunks. The only EXIF left is
///   the pixel dimensions the PNG encoder writes for itself.
/// - Keeps alpha.
///
/// Named limits, not choices: a 16-bit source keeps its depth when its profile is standard, but
/// the Display P3 conversion draws at 8 bits per channel, so a 16-bit image with a *non-standard*
/// profile loses depth (and an HDR gain map is dropped either way). Only the first frame is used:
/// an animated PNG uploads its first frame, a multi-page TIFF its first page.
///
/// Not applied on Save (Save writes back what was copied — Plan 15) or to history (local and
/// owner-only; the harm #20 names is publication).
public enum ImageSanitizer {
    /// Colour spaces kept exactly. Anything else — including every profile with no standard name,
    /// which is what a calibrated or external display's profile is — is converted to Display P3.
    public static let standardColorSpaces: Set<String> = [
        CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.adobeRGB1998,
        CGColorSpace.genericGrayGamma2_2, CGColorSpace.extendedSRGB, CGColorSpace.linearSRGB,
        CGColorSpace.extendedLinearSRGB, CGColorSpace.itur_2020,
    ].map { $0 as String }.reduce(into: []) { $0.insert($1) }

    /// A stripped PNG of `data`, or nil.
    ///
    /// **nil, never the input.** Every failure — empty or undecodable bytes, a pixel count over
    /// the ceiling or one that overflows, a failed conversion or encode — is nil, and the caller
    /// refuses to send. Over the ceiling it refuses rather than downscaling: shrinking an image
    /// silently changes what the user chose to share. (Note the ceiling *does* bite here: the
    /// session keeps a PNG verbatim without a pixel check, so a 40 MP PNG can be open in a
    /// session and still be refused by this function. A user-chosen "upload downscaled" would be
    /// #21's.)
    ///
    /// A full decode and encode: callers run it off the main actor.
    public static func stripped(_ data: Data, maxPixels: Int = PixelLimits.maxConvertiblePixels) -> SanitizedImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let pixels = PixelLimits.pixelCount(width: width, height: height),
              pixels <= maxPixels else { return nil }
        // The thumbnail API is the one ImageIO entry point that *applies* the orientation
        // transform. The max size is passed explicitly as the full dimension: relying on a
        // default is where a silent downscale would creep in.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let image = withStandardProfile(oriented) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        // No properties: nothing of the source's metadata is carried across. Passing the source's
        // dictionary here — the obvious way to "preserve quality" — is the regression
        // `ImageSanitizerTests` exists to catch.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), out.length > 0 else { return nil }
        return SanitizedImage(png: out as Data)
    }

    /// `image` unchanged if its colour space is standard, otherwise redrawn into Display P3.
    static func withStandardProfile(_ image: CGImage) -> CGImage? {
        // No colour space means an image *mask*: drawing one paints it in the fill colour, so the
        // redraw below would turn content into a black silhouette rather than fail. Not reachable
        // from ImageIO in any input measured (grey, indexed, 16-bit, gAMA-only, JPEG) — refused
        // anyway, because "nil, never a wrong image" is the contract.
        guard let space = image.colorSpace else { return nil }
        if let name = space.name as String?, standardColorSpaces.contains(name) { return image }
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: p3,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
