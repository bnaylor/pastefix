import Foundation
import CoreGraphics

/// Covers the selected region with opaque black: the redaction tool (redact/blur spec). Black
/// reads as a redaction on any image and carries nothing from what was there; over transparency
/// the region becomes opaque. Pixels outside the region are drawn 1:1 in the image's own colour
/// space and depth, so opaque ones come out unchanged (see `OrientedSource.bitmap`); the re-encode
/// drops metadata.
public struct RedactSelection: RegionImageTransformer {
    public let id = "builtin.redactselection"
    public let name = "Redact Selection"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init() {}

    public static let noRegionMessage = "Drag on the image to choose what to hide, then choose Redact Selection."
    public static func resultNote(_ w: Int, _ h: Int) -> String { "Redacted \(w)×\(h)." }

    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits((source.width, source.height)) else { throw TransformError.invalidInput("The selection is outside the image.") }
        guard let image = source.image(), let ctx = OrientedSource.bitmap(for: image) else {
            throw TransformError.invalidInput("\(name) couldn't redact this image.")
        }
        ctx.setBlendMode(.copy)   // replace, so transparency under the box can't show through
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(OrientedSource.bitmapRect(region, height: source.height))
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't redact this image.")
        }
        return .image(out, note: Self.resultNote(region.width, region.height))
    }
}
