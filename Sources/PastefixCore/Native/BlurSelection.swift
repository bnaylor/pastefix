import Foundation
import CoreGraphics
import CoreImage

/// Blurs the selected region: cosmetic, not redaction (redact/blur spec). Blurred screenshot text
/// can often be reconstructed, which the result note says. Only the region goes through Core
/// Image: cropped out, edges clamped so nothing outside is sampled and the edges don't fade to
/// transparent, blurred, rendered in the image's colour space, then drawn over the original in a
/// 1:1 bitmap, so every pixel outside the region is untouched.
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
        guard let blurred = context.createCGImage(patch, from: rect, format: .RGBA8, colorSpace: space) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        ctx.setBlendMode(.copy)
        ctx.draw(blurred, in: rect)
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        return .image(out, note: Self.resultNote(region.width, region.height))
    }
}
