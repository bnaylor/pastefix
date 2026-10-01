import Foundation
import PastefixCore

/// The real image transforms, each on a lane of its own. The hosted suites run in parallel, and
/// jobs on the shared lane displace each other's waiting ones ("The transform was cancelled."), as
/// `ImageTransformer.lane` says; stubs never use it.
struct LanedCrop: RegionImageTransformer {
    let id = "builtin.crop"; let name = "Crop to Selection"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let category: String? = TransformCategory.images
    let lane = ImageTransformLane.makeLane(label: "test.crop")
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        try CropToSelection().transformImage(png, region: region)
    }
}

struct LanedStripMetadata: ImageTransformer {
    let id = "builtin.stripimagemetadata"; let name = "Strip Image Metadata"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let category: String? = TransformCategory.images
    let lane = ImageTransformLane.makeLane(label: "test.strip")
    func transformImage(_ png: Data) throws -> TransformOutput { try StripImageMetadata().transformImage(png) }
}

struct LanedRedact: RegionImageTransformer {
    let id = "builtin.redactselection"; let name = "Redact Selection"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let category: String? = TransformCategory.images
    let lane = ImageTransformLane.makeLane(label: "test.redact")
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        try RedactSelection().transformImage(png, region: region)
    }
}

struct LanedBlur: RegionImageTransformer {
    let id = "builtin.blurselection"; let name = "Blur Selection"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let category: String? = TransformCategory.images
    let lane = ImageTransformLane.makeLane(label: "test.blur")
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        try BlurSelection().transformImage(png, region: region)
    }
}
