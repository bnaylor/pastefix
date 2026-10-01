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

    /// An RGBA bitmap with `image` drawn in at 1:1, in the image's own colour space and at its own
    /// depth (16 bits per channel for anything deeper than 8: an 8-bit bitmap re-quantised every
    /// pixel of a 16-bit or HDR image — final review I1), so opaque pixels come out unchanged;
    /// sRGB when the space isn't RGB (greyscale), which can't back an RGBA context. Premultiplied,
    /// as every CG RGBA bitmap is, so a semi-transparent pixel's colour can shift by rounding.
    static func bitmap(for image: CGImage) -> CGContext? {
        guard let ctx = emptyBitmap(like: image, width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    /// An empty `width`×`height` RGBA bitmap matching `image`'s colour space and depth, as `bitmap(for:)`
    /// makes it: for a transform whose output has a different shape (rotate).
    static func emptyBitmap(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let deep = image.bitsPerComponent > 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let space = own ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                         bytesPerRow: 0, space: space, bitmapInfo: info)
    }

    /// `region` (top-left origin) as a rect in a bitmap of this height (bottom-left origin).
    static func bitmapRect(_ region: ImageRegion, height: Int) -> CGRect {
        CGRect(x: region.x, y: height - region.y - region.height, width: region.width, height: region.height)
    }
}
