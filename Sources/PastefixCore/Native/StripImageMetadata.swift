import Foundation

/// ⌘K "Strip Image Metadata" (#82): the image with its location, camera, date and other metadata
/// removed and its orientation baked in — exactly what image upload does, through the same
/// `ImageSanitizer`, so there is one implementation. It says what it removed, and says so when there
/// was nothing to remove rather than silently re-encoding.
public struct StripImageMetadata: ImageTransformer {
    public let id = "builtin.stripimagemetadata"
    public let name = "Strip Image Metadata"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.privacy
    public init() {}

    public func transformImage(_ png: Data) throws -> TransformOutput {
        let found = ImageMetadata.inspect(png)
        guard !found.isEmpty else { return .nothingToDo(ImageMetadata.nothingToRemoveMessage) }
        // The coordinator has refused anything over the pixel ceiling, so nil here is a decode or
        // encode failure, not a size.
        guard let clean = ImageSanitizer.stripped(png) else {
            throw TransformError.invalidInput("Couldn't strip this image's metadata.")
        }
        return .image(clean.data, note: ImageMetadata.removedMessage(found))
    }
}
