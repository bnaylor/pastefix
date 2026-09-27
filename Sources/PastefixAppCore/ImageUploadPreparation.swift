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
        /// Stripped, and still over `UploadLimits.maxPayloadBytes` in the format that would have
        /// been sent (`ImageFormatChoice`): the PNG for an image with a non-opaque pixel, otherwise
        /// the JPEG — an opaque image is refused only when even its JPEG does not fit (#21).
        case tooManyBytes(Int, format: ImageFormat)
        /// Could not be decoded or stripped.
        case unusable
    }

    public enum Outcome: Equatable, Sendable {
        /// `hasText` is "text regions were detected", and `false` means **not detected** — never
        /// "no text". Measured: an 11 px line produces no regions. The card shows the not-checked
        /// verdict either way; this only escalates it.
        case ready(PreparedImage, hasText: Bool)
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
        // JPEG is encoded only when every pixel is opaque (`encodings` scans them); the cap is
        // applied to whichever format `ImageFormatChoice` picks.
        guard let encodings = ImageSanitizer.encodings(png, maxPixels: maxPixels) else { return .refused(.unusable) }
        let choice = ImageFormatChoice.choose(pngBytes: encodings.png.data.count,
                                              jpegBytes: encodings.jpeg?.data.count, maxBytes: maxBytes)
        let prepared: PreparedImage
        switch choice {
        case .refused(let bytes, let format):
            return .refused(.tooManyBytes(bytes, format: format))
        case .png:
            prepared = PreparedImage(choice: choice, chosen: encodings.png, pngAlternative: nil,
                                     pngByteCount: encodings.png.data.count)
        case .jpegWithPNGEscape, .jpegForcedByCap:
            // `choose` answers JPEG only when given a JPEG size, so this is always present.
            guard let jpeg = encodings.jpeg else { return .refused(.unusable) }
            prepared = PreparedImage(choice: choice, chosen: jpeg,
                                     pngAlternative: choice.offersPNGEscape ? encodings.png : nil,
                                     pngByteCount: encodings.png.data.count)
        }
        // On the lossless PNG whichever format is sent: the same pixels, without JPEG's ringing
        // around glyph edges.
        return .ready(prepared, hasText: containsText(encodings.png.data))
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

/// A prepared image upload (#21): what the format rule chose, and — only when it chose JPEG with
/// the PNG still under the cap — the PNG as the one-click alternative.
///
/// Both images are `SanitizedImage`s, so switching between them cannot reach unstripped bytes.
/// The initialiser is internal: only `ImageUploadPreparation.prepare` makes one, so `choice`,
/// `chosen` and `pngAlternative` always agree.
public struct PreparedImage: Equatable, Sendable {
    /// `.png`, `.jpegWithPNGEscape` or `.jpegForcedByCap` — never `.refused`.
    public let choice: ImageFormatChoice
    /// The image the rule chose.
    public let chosen: SanitizedImage
    /// The PNG, present exactly when `choice.offersPNGEscape`.
    public let pngAlternative: SanitizedImage?
    /// The PNG's size, kept even when the PNG itself is not (the card says "as PNG it would be Y").
    public let pngByteCount: Int
    /// Whether the user pressed "Send as PNG instead". Only ever true with a `pngAlternative`.
    public private(set) var sendsPNGInstead = false

    init(choice: ImageFormatChoice, chosen: SanitizedImage, pngAlternative: SanitizedImage?, pngByteCount: Int) {
        self.choice = choice
        self.chosen = chosen
        self.pngAlternative = pngAlternative
        self.pngByteCount = pngByteCount
    }

    /// The bytes Upload sends.
    public var toSend: SanitizedImage {
        sendsPNGInstead ? (pngAlternative ?? chosen) : chosen
    }

    /// The escape and its reverse. Does nothing when there is no PNG to switch to.
    public mutating func toggleFormat() {
        guard pngAlternative != nil else { return }
        sendsPNGInstead.toggle()
    }
}
