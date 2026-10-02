import Foundation
import CoreGraphics
import CoreImage

/// Blurs the selected region: cosmetic, not redaction (redact/blur spec). Blurred screenshot text
/// can often be reconstructed, which the result note says. Only the region goes through Core
/// Image: cropped out, edges clamped so nothing outside is sampled and the edges don't fade to
/// transparent, blurred, rendered in the image's colour space and depth, then drawn over the original
/// in a 1:1 bitmap, so opaque pixels outside the region are unchanged (see `OrientedSource.bitmap`).
public struct BlurSelection: RegionImageTransformer {
    public let id = "builtin.blurselection"
    public let name = "Blur Selection"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init() {}

    public static let noRegionMessage = "Drag on the image to choose what to blur, then choose Blur Selection."
    public static func resultNote(_ w: Int, _ h: Int) -> String {
        "Blurred \(w)×\(h). Blur can be reversed; use Redact Selection to hide something for good."
    }
    /// The largest region whose text is read for the secret warning.
    static let secretCheckMaxPixels = 4_000_000

    /// The note when the region looked like it held a secret (#129): blur can be reversed, so it
    /// points at Redact Selection.
    static func secretNote(_ w: Int, _ h: Int, _ kinds: [SecretKind]) -> String {
        "Blurred \(w)×\(h). It looks like this hides \(secretPhrase(kinds)). Blur can be reversed: ⌘Z, then use Redact Selection to hide it for good."
    }

    /// "an AWS access key", "a GitHub token and an AWS access key", "a, b and c".
    static func secretPhrase(_ kinds: [SecretKind]) -> String {
        let named = kinds.map { kind -> String in
            let name = kind.displayName
            return (name.first.map { "AEIOU".contains($0.uppercased()) } ?? false ? "an " : "a ") + name
        }
        guard named.count > 1 else { return named.first ?? "" }
        return named.dropLast().joined(separator: ", ") + " and " + named.last!
    }

    /// The kinds of secret in the region's text, read by OCR (the recognizer Extract Text uses),
    /// in the order found and without repeats. Best effort: a failed or empty read is no kinds, so
    /// the blur still happens with the ordinary note — and that note never claims the region is safe.
    static func secretKinds(in image: CGImage, region: ImageRegion) -> [SecretKind] {
        // Accurate OCR is slow on large, dense regions — a whole 5K screenshot of text measured
        // 11.4 s, past the 10 s transform limit — so only regions up to 4 MP are read. That covers
        // selecting a token, a line or a panel; a bigger blur keeps the ordinary note, which never
        // claimed the region was safe.
        guard region.width * region.height <= secretCheckMaxPixels else { return [] }
        guard let crop = image.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)),
              let observations = try? OCRLayout.recognize(width: crop.width, height: crop.height,
                                                          whole: { try TextRecognizer.recognize(crop) },
                                                          tiled: { try TextRecognizer.recognizeTiled(crop) }) else { return [] }
        let text = OCRLayout.lines(observations).joined(separator: "\n")
        guard SecretDetector.isScannable(text) else { return [] }
        var kinds: [SecretKind] = []
        for match in SecretDetector.scan(text) where !kinds.contains(match.kind) { kinds.append(match.kind) }
        return kinds
    }

    /// 5% of the region's shorter side, at least 6 px: text is unreadable at a glance.
    public static func radius(for region: ImageRegion) -> Double {
        max(6, 0.05 * Double(min(region.width, region.height)))
    }

    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits((source.width, source.height)) else { throw TransformError.invalidInput("The selection is outside the image.") }
        guard let image = source.image(), let ctx = OrientedSource.bitmap(for: image), let space = ctx.colorSpace else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        let rect = OrientedSource.bitmapRect(region, height: source.height)   // Core Image is bottom-left too
        let patch = CIImage(cgImage: image)
            .cropped(to: rect)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Self.radius(for: region))
            .cropped(to: rect)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let format: CIFormat = ctx.bitsPerComponent > 8 ? .RGBA16 : .RGBA8   // the bitmap's own depth
        guard let blurred = context.createCGImage(patch, from: rect, format: format, colorSpace: space) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        ctx.setBlendMode(.copy)
        ctx.draw(blurred, in: rect)
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        let kinds = Self.secretKinds(in: image, region: region)
        return .image(out, note: kinds.isEmpty ? Self.resultNote(region.width, region.height)
                                               : Self.secretNote(region.width, region.height, kinds))
    }
}
