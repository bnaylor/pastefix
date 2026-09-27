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
///
/// It carries its format (#21), so the upload takes its extension and content type from the bytes
/// it actually holds rather than from a caller's say-so.
public struct SanitizedImage: Sendable, Equatable {
    public let format: ImageFormat
    public let data: Data
    fileprivate init(format: ImageFormat, data: Data) {
        self.format = format
        self.data = data
    }
}

/// The two encodings an upload can send (#21).
public enum ImageFormat: Sendable, Equatable {
    case png
    case jpeg

    /// What `ZiplineUpload(image:)` names the file: Zipline serves by type.
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    /// The multipart part's `Content-Type`.
    public var contentType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        }
    }
}

/// One strip, both encodings an upload can choose between (#21). `ImageFormatChoice` decides
/// which is sent.
public struct SanitizedEncodings: Sendable, Equatable {
    /// Always present: every image can go as PNG.
    public let png: SanitizedImage
    /// Present exactly when every pixel is opaque. JPEG has no alpha, and flattening changes what
    /// the user sees, so an image with any non-opaque pixel is never encoded as JPEG at all.
    public let jpeg: SanitizedImage?
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
/// - For upload, also encodes a JPEG of the same stripped pixels — only when every pixel is opaque
///   (`encodings(_:maxPixels:)`, #21). `ImageFormatChoice` decides which one is sent.
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

    /// A stripped PNG of `data`, or nil. (Upload wants `encodings(_:maxPixels:)`, which adds the
    /// JPEG candidate; this is the PNG-only form.)
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
        strippedImage(data, maxPixels: maxPixels).flatMap(encodePNG)
    }

    /// JPEG quality for uploads (#21): the usual default, and photos stay visually lossless at
    /// about a fifth of their PNG's size.
    public static let jpegQuality = 0.85

    /// `stripped(_:maxPixels:)`'s PNG, plus a JPEG of the same stripped pixels when every pixel is
    /// opaque — the two candidates `ImageFormatChoice` chooses between (#21). Both encodes, always,
    /// on the full image: sampling would bias the size ratio from both sides (downscaling averages
    /// away the sensor noise that makes a photo's PNG big, and anti-aliases the hard edges that
    /// keep a screenshot's PNG small), and the JPEG costs ~8% on top of the PNG (measured).
    ///
    /// nil on every failure, as `stripped`. That includes a JPEG encode failing on an opaque
    /// image: nil there, rather than a PNG-only answer, keeps "no JPEG" meaning exactly "has a
    /// non-opaque pixel", which the card's wording relies on.
    public static func encodings(_ data: Data, maxPixels: Int = PixelLimits.maxConvertiblePixels) -> SanitizedEncodings? {
        guard let image = strippedImage(data, maxPixels: maxPixels),
              let png = encodePNG(image) else { return nil }
        guard isOpaque(image) else { return SanitizedEncodings(png: png, jpeg: nil) }
        // The same bare, stripped `CGImage` the PNG was made from — never the source, and no
        // properties but the quality (see `JPEGEncoder`).
        guard let jpeg = JPEGEncoder.encode(image, quality: jpegQuality) else { return nil }
        return SanitizedEncodings(png: png, jpeg: SanitizedImage(format: .jpeg, data: jpeg))
    }

    /// Whether every pixel's alpha is 255 — **a pixel test, not a question about the channel.**
    /// `screencapture` output, and many TIFF→PNG pasteboard conversions, carry an alpha channel with
    /// every pixel at 255; asking "has an alpha channel?" would silently turn JPEG off for all of
    /// them. The image is drawn into an 8-bit alpha-only bitmap — the pixels' alpha and nothing
    /// else, so no colour conversion is paid for — and each row is compared against a row of 255s
    /// with `memcmp`. Measured at 25 MP: ~20 ms (an RGBA render with a per-pixel Swift loop was
    /// ~0.7 s unoptimised). An image with no alpha channel draws as 255 everywhere.
    ///
    /// Any failure answers "not opaque": the cost of a wrong "no" is a PNG, the cost of a wrong
    /// "yes" is a flattened image.
    static func isOpaque(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: nil as CGColorSpace?,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue))
        else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return false }
        let stride = context.bytesPerRow
        let opaqueRow = [UInt8](repeating: 255, count: width)
        return opaqueRow.withUnsafeBytes { row in
            guard let rowBase = row.baseAddress else { return false }
            for y in 0..<height where memcmp(base + y * stride, rowBase, width) != 0 { return false }
            return true
        }
    }

    private static func encodePNG(_ image: CGImage) -> SanitizedImage? {
        // No properties: nothing of the source's metadata is carried across. Passing the source's
        // dictionary to an encoder — the obvious way to "preserve quality" — is the regression
        // `ImageSanitizerTests` exists to catch. Encoded via `PNGEncoder`, not an in-memory
        // destination: ImageIO leaks the encoder's buffers there (see `PNGEncoder`).
        PNGEncoder.encode(image).map { SanitizedImage(format: .png, data: $0) }
    }

    /// The decoded, oriented, profile-normalised pixels both encodes start from, or nil.
    private static func strippedImage(_ data: Data, maxPixels: Int) -> CGImage? {
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
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return withStandardProfile(oriented)
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
