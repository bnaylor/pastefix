import Foundation

/// Which format an image upload is sent in (#21) — decided from measured sizes, never from a guess
/// at what the picture shows.
///
/// By upload time every session image is a PNG, so the source format is gone, and classifying
/// "photo vs screenshot" from pixels fails silently. What *is* measurable is how the two formats
/// compress the same pixels. Measured (JPEG at 0.85, both through files): real photographs come
/// out at 0.15–0.23 of their PNG, text screenshots at 1.2–1.4, and a full-screen screenshot with
/// the wallpaper showing at 0.28 — beside the photos. No ratio separates that last one from a
/// photo, which is why a JPEG chosen by the ratio always comes with the one-click PNG escape.
///
/// The rule (spec `2026-09-27-pastefix-v2-photos-as-jpeg`, "The rule"):
/// 1. No JPEG (`jpegBytes == nil`: a non-opaque pixel, or — never seen — a failed JPEG encode) →
///    PNG; over the cap → refused, naming the PNG.
/// 2. Opaque, PNG over the cap → JPEG if it fits, **whatever the ratio**, with no escape (the PNG
///    could not be sent). If the JPEG does not fit either → refused, naming the **JPEG**.
/// 3. Opaque, PNG fits, JPEG ≤ `jpegRatioThreshold` × PNG → JPEG, with the PNG escape.
/// 4. Otherwise → PNG.
///
/// Do not turn this into a content heuristic: the numbers above are measured, and the escape is
/// the owner's answer to the case the ratio cannot tell apart.
public enum ImageFormatChoice: Equatable, Sendable {
    /// Send the PNG.
    case png
    /// Send the JPEG; the PNG fits and is offered as "Send as PNG instead".
    case jpegWithPNGEscape
    /// Send the JPEG; the PNG is over the cap, so there is no escape.
    case jpegForcedByCap
    /// Neither fits (or there is no JPEG and the PNG does not): the size of the format that would
    /// have been sent.
    case refused(bytes: Int, format: ImageFormat)

    /// JPEG must be at most this fraction of the PNG to be chosen when the PNG fits. Photos
    /// measure 0.15–0.23, text screenshots 1.2–1.4: 0.5 sits well clear of both.
    public static let jpegRatioThreshold = 0.5

    /// The format sent, or nil when refused.
    public var format: ImageFormat? {
        switch self {
        case .png: .png
        case .jpegWithPNGEscape, .jpegForcedByCap: .jpeg
        case .refused: nil
        }
    }

    public var offersPNGEscape: Bool { self == .jpegWithPNGEscape }

    /// - Parameters:
    ///   - pngBytes: the stripped PNG's size.
    ///   - jpegBytes: the stripped JPEG's size, or nil when there is no JPEG — the image has a
    ///     non-opaque pixel, or the JPEG encode failed. The rule treats the two alike; only the
    ///     card's wording tells them apart (`JPEGCandidate`).
    ///   - maxBytes: the upload cap, applied to whichever format is sent.
    public static func choose(pngBytes: Int, jpegBytes: Int?, maxBytes: Int) -> ImageFormatChoice {
        guard let jpegBytes else {
            return pngBytes <= maxBytes ? .png : .refused(bytes: pngBytes, format: .png)
        }
        if pngBytes > maxBytes {
            return jpegBytes <= maxBytes ? .jpegForcedByCap : .refused(bytes: jpegBytes, format: .jpeg)
        }
        return Double(jpegBytes) <= jpegRatioThreshold * Double(pngBytes) ? .jpegWithPNGEscape : .png
    }

    /// `choose(pngBytes:jpegBytes:maxBytes:)` from the sanitizer's own answer: `.encodeFailed`
    /// decides exactly as `.notOpaque` does — PNG, or a refusal naming the PNG.
    public static func choose(pngBytes: Int, jpeg: JPEGCandidate, maxBytes: Int) -> ImageFormatChoice {
        choose(pngBytes: pngBytes, jpegBytes: jpeg.image?.data.count, maxBytes: maxBytes)
    }
}
