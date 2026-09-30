import Foundation
import PastefixCore

/// What a transform is scoped to: a text selection (#25) or a region of the image. One channel from
/// the view to the coordinator for both.
public enum TransformScope: Sendable, Equatable {
    case text(TextScope)
    /// A region drawn on the image entry whose `detectionRevision` was `revision`.
    case image(ImageRegion, revision: Int)

    public var text: TextScope? { if case .text(let t) = self { t } else { nil } }
    public var imageRegion: ImageRegion? { if case .image(let r, _) = self { r } else { nil } }

    /// How a transform that can't use this scope is marked in the palette and sidebar.
    public var wholeLabel: String { text != nil ? "whole buffer" : "whole image" }
}
