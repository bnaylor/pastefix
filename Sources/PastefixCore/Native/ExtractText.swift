import Foundation
import ImageIO

/// ⌘K "Extract Text (OCR)" (#19): the image's text, as the session's next entry — the session
/// becomes a text session, and ⌘Z (until the user types) or the Undo button brings the image back.
/// Runs on the image-transform lane (`ImageTransformer`), under the coordinator's pixel ceiling.
///
/// No confusable folding: the output is the user's text, and folding Cyrillic or other lookalikes
/// to ASCII would corrupt genuine non-Latin text. The secret scan's input is #102's question.
public struct ExtractText: ImageTransformer {
    public let id = "builtin.extracttext"
    public let name = "Extract Text (OCR)"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images
    /// Deliberately not "this image has no text": Vision can return nothing on an image full of it.
    public static let noTextMessage = "No text was recognised in this image."
    public init() {}

    public func transformImage(_ png: Data) throws -> TransformOutput {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TransformError.invalidInput("Couldn't read this image.")
        }
        let observations = try OCRLayout.recognize(width: image.width, height: image.height,
                                                   whole: { try TextRecognizer.recognize(image) },
                                                   tiled: { try TextRecognizer.recognizeTiled(image) })
        let text = OCRLayout.lines(observations).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothingToDo(Self.noTextMessage)
        }
        return .text(text)
    }
}
