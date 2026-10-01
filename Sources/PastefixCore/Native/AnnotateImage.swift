import Foundation
import CoreGraphics

/// Burns one markup mark into the image (annotate spec): markup mode applies one of these per
/// finished mark, so each is one undo step through the ordinary transform pipeline. Not in the
/// registry: it carries its mark, and nothing in ⌘K or the sidebar could supply one. The decode
/// is `OrientedSource`'s (orientation applied, so a mark lands where it was drawn), the bitmap
/// keeps the source's colour space and depth, and the re-encode drops metadata.
public struct AnnotateImage: ImageTransformer {
    public let mark: ImageMark
    public let lane: ImageTransformLane.Lane
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init(_ mark: ImageMark, lane: ImageTransformLane.Lane = ImageTransformLane.shared) {
        self.mark = mark
        self.lane = lane
    }

    public var id: String { "builtin.annotate.\(mark.tool.rawValue)" }
    public var name: String { mark.tool.name }

    public static let nothingToDrawMessage = "Nothing to draw."

    /// Whether the mark has enough to draw: two points for the shapes, one or more for freehand,
    /// a point and visible text for text.
    var isDrawable: Bool {
        switch mark.tool {
        case .box, .arrow, .highlight: mark.points.count >= 2
        case .freehand: !mark.points.isEmpty
        case .text: mark.points.count >= 1 && !(mark.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func transformImage(_ png: Data) throws -> TransformOutput {
        guard isDrawable else { return .nothingToDo(Self.nothingToDrawMessage) }
        guard let source = OrientedSource(png), let image = source.image(),
              let ctx = OrientedSource.bitmap(for: image) else {
            throw TransformError.invalidInput("This image can't be read.")
        }
        MarkRenderer.draw(mark, in: ctx, imageWidth: source.width, imageHeight: source.height)
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't be drawn on this image.")
        }
        return .image(out, note: mark.tool.note)
    }
}
