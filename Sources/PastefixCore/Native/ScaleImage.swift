import Foundation
import CoreGraphics

/// Scale to 50% and Fit Within 1920 px: whole-image downsampling, for pasting into chat and the web
/// (resize spec, #21). Fewer pixels is what makes those pastes small, and the result stays PNG so
/// every app can paste it (a JPEG-only clipboard pastes nothing in a browser). Sizes come from the
/// image as displayed (`OrientedSource` applies the orientation first); each side rounds to the
/// nearest pixel, at least 1. One high-quality draw into a bitmap of the new size averages the
/// pixels rather than skipping them; colour space and depth follow the source, and the re-encode
/// drops metadata.
public struct ScaleImage: ImageTransformer {
    public enum Kind: Sendable { case half, fit1920 }

    public let kind: Kind
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init(_ kind: Kind) { self.kind = kind }

    public var id: String { kind == .half ? "builtin.scalehalf" : "builtin.fitwithin1920" }
    public var name: String { kind == .half ? "Scale to 50%" : "Fit Within 1920 px" }

    public static let tooSmallMessage = "This image is too small to scale down."
    public static let alreadyFitsMessage = "This image is already within 1920 px."
    static let fitLimit = 1920

    /// The new size, or nil when there's nothing to do.
    static func target(_ kind: Kind, width w: Int, height h: Int) -> (width: Int, height: Int)? {
        func side(_ v: Int, _ scale: Double) -> Int { max(1, Int((Double(v) * scale).rounded())) }
        switch kind {
        case .half:
            let size = (side(w, 0.5), side(h, 0.5))
            return size == (w, h) ? nil : size
        case .fit1920:
            let longer = max(w, h)
            guard longer > fitLimit else { return nil }
            let scale = Double(fitLimit) / Double(longer)
            return (side(w, scale), side(h, scale))
        }
    }

    public func transformImage(_ png: Data) throws -> TransformOutput {
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard let size = Self.target(kind, width: source.width, height: source.height) else {
            return .nothingToDo(kind == .half ? Self.tooSmallMessage : Self.alreadyFitsMessage)
        }
        guard let image = source.image(),
              let ctx = OrientedSource.emptyBitmap(like: image, width: size.width, height: size.height) else {
            throw TransformError.invalidInput("\(name) couldn't scale this image.")
        }
        ctx.interpolationQuality = .high
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't scale this image.")
        }
        return .image(out, note: "Scaled to \(size.width)×\(size.height).")
    }
}
