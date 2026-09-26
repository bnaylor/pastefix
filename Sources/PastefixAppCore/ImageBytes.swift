import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The one place pasteboard image bytes are measured, validated and converted.
///
/// Both image paths come here. The capture path (`PasteboardMonitor.read`, `TIFFConversionSlot`)
/// size-gates a TIFF from its header and converts it off the main actor; the session path
/// (`ClipboardBridge.snapshot`) validates and normalises the same two types synchronously at
/// summon. They used to hold a copy each of the header read, the `NSBitmapImageRep` route and the
/// 25M-pixel literal — three chances for two agreeing implementations to stop agreeing, which is
/// the drift the spec chose one canonical PNG form to prevent.
///
/// What is **not** shared is concurrency, deliberately: the capture path runs
/// `convertedToPNG` inside `TIFFConversionSlot`'s single lane off the main actor, and `snapshot`
/// calls `normalise` inline because its result seeds the document the panel is about to show.
/// Nothing here touches actor state, so either is fine — this file is the *what*, and each caller
/// keeps its own *where*.
public enum ImageBytes {
    /// The pixel ceiling on bytes we are willing to decode and re-encode.
    ///
    /// 25M px covers any real display grab (a 6K Pro Display XDR is ~20M px) while bounding a
    /// decode + PNG re-encode that costs ~1.5 s at the ceiling. A header-only gate rather than a
    /// byte-size one, because TIFF byte size says almost nothing about pixel count: a full-screen
    /// Retina grab is ~81 MB as raw TIFF and 2-6 MB once PNG-compressed, so gating on bytes
    /// rejects exactly the images that should be kept.
    ///
    /// The ~1.5 s is measured, not estimated: 1.57 s and 1.60 s over two passes converting a
    /// 5000×5000 noise TIFF (100 MB) on this machine — worst case for the PNG encoder, since noise
    /// cannot be compressed away. It brackets the capture path's own figures (0.4 s at 6.6 MP,
    /// 1.3 s at 20.4 MP, #32).
    public static let maxConvertiblePixels = 25_000_000

    /// What `normalise` made of some bytes. `tooLarge` exists so a caller can *say so*: an image
    /// silently becoming no image is the failure mode this codebase treats as a defect.
    public enum Normalised: Sendable, Equatable {
        /// PNG bytes ready to use. For input that was already a PNG these are the **input bytes,
        /// unchanged** — see `normalise`.
        case png(Data)
        /// A non-PNG image whose pixel count is over the ceiling, so it was never decoded.
        case tooLarge(pixels: Int)
        /// Not an image at all, or an image whose conversion failed.
        case unusable
    }

    /// Pixel dimensions from the image header alone — no decode, no bitmap.
    ///
    /// Used to size-gate before paying for a decode, and to fill a capture's
    /// `imagePixelWidth`/`Height` without constructing an `NSBitmapImageRep` just to read them.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// The one decode-and-re-encode route in the app: bitmap in, PNG out, nil if either half
    /// fails. Callers are responsible for the pixel gate (`maxConvertiblePixels`) and for deciding
    /// which thread pays for this.
    public static func convertedToPNG(_ data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    /// PNG bytes for arbitrary pasteboard image bytes.
    ///
    /// **Already a PNG: the bytes come back untouched.** Validation is the header read above, so
    /// the common case costs no decode at all — and `Save` writes back the bytes the user copied
    /// rather than a re-encode of them, which is what the spec's one-canonical-form rule asks for.
    /// The pixel ceiling therefore does not apply to a PNG: nothing here decodes it, and whoever
    /// eventually draws it does so off the main actor at display size.
    ///
    /// Anything else (a TIFF, in practice) is converted under the ceiling.
    ///
    /// The form is decided by **sniffing the bytes**, not by trusting a declared pasteboard type,
    /// so a pasteboard that mislabels its contents is harmless in both directions: a TIFF
    /// advertised as `.png` is converted rather than handed on under a PNG's name.
    public static func normalise(_ data: Data, maxPixels: Int = maxConvertiblePixels) -> Normalised {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let size = pixelSize(of: data), size.width > 0, size.height > 0 else { return .unusable }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { return .png(data) }
        let pixels = size.width * size.height
        guard pixels <= maxPixels else { return .tooLarge(pixels: pixels) }
        guard let converted = convertedToPNG(data) else { return .unusable }
        return .png(converted)
    }

    /// "25 MP" / "30.9 MP" — for telling a user why their image was refused in the unit the limit
    /// is actually expressed in. Bytes would be the wrong unit here: the limit is on pixels, and a
    /// 3 MB TIFF and a 3 MB PNG are nowhere near the same amount of decoding.
    public static func megapixelLabel(_ pixels: Int) -> String {
        let mp = Double(pixels) / 1_000_000
        let rounded = (mp * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f MP", rounded)
            : String(format: "%.1f MP", rounded)
    }
}
