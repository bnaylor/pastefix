import Foundation
import CoreGraphics

/// Crops the image to the selected region. The decode is `OrientedSource`'s: EXIF orientation
/// applied (the region is in oriented pixels, as the panel draws the image) and no colour-profile
/// conversion, so cropping never shifts colours. The re-encode drops metadata, as Strip Image Metadata does.
/// `cropping(to:)` shares the decoded image's storage, so peak memory is one full decode, run on
/// the image lane like every image transform.
public struct CropToSelection: RegionImageTransformer {
    public let id = "builtin.crop"
    public let name = "Crop to Selection"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init() {}

    public static let noRegionMessage = "Drag on the image to choose what to keep, then choose Crop to Selection."
    public static let wholeImageMessage = "The selection is the whole image."
    public static func resultNote(_ w: Int, _ h: Int) -> String { "Cropped to \(w)×\(h)." }

    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits((source.width, source.height)) else { throw TransformError.invalidInput("The selection is outside the image.") }
        if region.width == source.width, region.height == source.height { return .nothingToDo(Self.wholeImageMessage) }
        guard let oriented = source.image(),
              let cropped = oriented.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)),
              let out = PNGEncoder.encode(cropped) else {
            throw TransformError.invalidInput("\(name) couldn't crop this image.")
        }
        return .image(out, note: Self.resultNote(region.width, region.height))
    }
}
