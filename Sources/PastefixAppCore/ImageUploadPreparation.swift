import Foundation
import Vision
import PastefixCore

/// What the image upload card shows, decided as a value off the main actor (#48).
///
/// Strip first, then the byte cap on what the strip produced — the strip can shrink an image, so
/// a too-big input is fully decoded before it is refused; that cost is accepted. Then text-region
/// detection on the stripped pixels, which decides only how *loud* the card is, never whether it
/// reassures (see `hasText`).
public enum ImageUploadPreparation {
    public enum Refusal: Equatable, Sendable {
        /// Over `PixelLimits.maxConvertiblePixels` — the figure, for "31 MP; limit 25 MP".
        case tooManyPixels(Int)
        /// Stripped, and still over `UploadLimits.maxPayloadBytes` — the stripped size. For photos
        /// this, not the pixel ceiling, is the binding limit (measured: a smooth 12 MP render is
        /// already 12.5 MB as PNG); the refusal points at lossy output (#21).
        case tooManyBytes(Int)
        /// Could not be decoded or stripped.
        case unusable
    }

    public enum Outcome: Equatable, Sendable {
        /// `hasText` is "text regions were detected", and `false` means **not detected** — never
        /// "no text". Measured: an 11 px line produces no regions. The card shows the not-checked
        /// verdict either way; this only escalates it.
        case ready(SanitizedImage, hasText: Bool)
        case refused(Refusal)
    }

    /// A full decode, encode and Vision pass: call off the main actor.
    public static func prepare(_ png: Data,
                               maxPixels: Int = PixelLimits.maxConvertiblePixels,
                               maxBytes: Int = UploadLimits.maxPayloadBytes) -> Outcome {
        // The pixel figure is read first so a ceiling refusal can name it; the sanitizer refuses
        // the same images on its own, and would return the bare nil below without this.
        if let size = ImageBytes.pixelSize(of: png) {
            let pixels = PixelLimits.pixelCount(width: size.width, height: size.height) ?? ImageBytes.unmeasurablePixels
            if pixels > maxPixels { return .refused(.tooManyPixels(pixels)) }
        }
        guard let image = ImageSanitizer.stripped(png, maxPixels: maxPixels) else { return .refused(.unusable) }
        guard image.png.count <= maxBytes else { return .refused(.tooManyBytes(image.png.count)) }
        return .ready(image, hasText: containsText(image.png))
    }

    /// Whether Vision finds any text region. A failed request counts as text found: this may only
    /// ever make the card louder, so the error case takes the louder branch.
    static func containsText(_ png: Data) -> Bool {
        let request = VNDetectTextRectanglesRequest()
        do {
            try VNImageRequestHandler(data: png, options: [:]).perform([request])
        } catch {
            return true
        }
        return !(request.results ?? []).isEmpty
    }
}
