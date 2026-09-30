import Foundation
import CoreGraphics
import ImageIO

/// An image's oriented size, and its oriented full-size decode, from one `CGImageSource`, for the
/// region transforms (crop, redact, blur).
///
/// One source for both on purpose: ImageIO's PNG reader applies an eXIf orientation in a
/// `WithTransform` thumbnail only once the properties have been read on *that* source
/// (measured: thumbnail-first gives the unrotated image). `init` reads them; `image()` decodes.
struct OrientedSource {
    let width: Int
    let height: Int
    private let source: CGImageSource

    init?(_ png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = ImageRegion.orientedPixelSize(of: source) else { return nil }
        self.source = source
        self.width = size.width
        self.height = size.height
    }

    /// The oriented image at full size, with no colour-profile conversion. Nil if the decode's size
    /// isn't the oriented size: never act on a differently shaped image than the region was drawn on.
    func image() -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              image.width == width, image.height == height else { return nil }
        return image
    }

    /// An RGBA8 bitmap with `image` drawn in at 1:1, in the image's own colour space so pixels and
    /// profile are unchanged; sRGB when that space isn't RGB (greyscale), which can't back an
    /// RGBA context.
    static func bitmap(for image: CGImage) -> CGContext? {
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let space = own ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    /// `region` (top-left origin) as a rect in a bitmap of this height (bottom-left origin).
    static func bitmapRect(_ region: ImageRegion, height: Int) -> CGRect {
        CGRect(x: region.x, y: height - region.y - region.height, width: region.width, height: region.height)
    }
}
