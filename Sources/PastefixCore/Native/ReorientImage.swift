import Foundation
import CoreGraphics

/// Rotate Left/Right (90°) and Flip Horizontal/Vertical: the whole image, as it's displayed (EXIF
/// orientation applied first, so "right" is right as the user sees it). Exact: the image is drawn
/// once through an affine map whose entries are 0, ±1 and whole-pixel offsets — built by hand, not
/// with `rotate(by: .pi / 2)`, whose cos is 6e-17 rather than 0 — with interpolation off, so every
/// pixel moves to its new place unchanged. Colour space and depth follow the source
/// (`OrientedSource`); the re-encode drops metadata.
public struct ReorientImage: ImageTransformer {
    public enum Kind: Sendable { case rotateLeft, rotateRight, flipHorizontal, flipVertical }

    public let kind: Kind
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init(_ kind: Kind) { self.kind = kind }

    public var id: String {
        switch kind {
        case .rotateLeft: "builtin.rotateleft"
        case .rotateRight: "builtin.rotateright"
        case .flipHorizontal: "builtin.fliphorizontal"
        case .flipVertical: "builtin.flipvertical"
        }
    }

    public var name: String {
        switch kind {
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate Right"
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
    }

    private var note: String {
        switch kind {
        case .rotateLeft: "Rotated left."
        case .rotateRight: "Rotated right."
        case .flipHorizontal: "Flipped horizontally."
        case .flipVertical: "Flipped vertically."
        }
    }

    public func transformImage(_ png: Data) throws -> TransformOutput {
        guard let source = OrientedSource(png), let image = source.image() else {
            throw TransformError.invalidInput("This image can't be read.")
        }
        let w = image.width, h = image.height
        let turns = kind == .rotateLeft || kind == .rotateRight
        // CG is bottom-left, y up; x' = a·x + c·y + tx, y' = b·x + d·y + ty.
        let map: CGAffineTransform = switch kind {
        case .rotateRight: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w))     // clockwise as seen
        case .rotateLeft: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0)      // anticlockwise
        case .flipHorizontal: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(w), ty: 0)
        case .flipVertical: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h))
        }
        guard let ctx = OrientedSource.emptyBitmap(like: image, width: turns ? h : w, height: turns ? w : h) else {
            throw TransformError.invalidInput("\(name) couldn't change this image.")
        }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.concatenate(map)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't change this image.")
        }
        return .image(out, note: note)
    }
}
