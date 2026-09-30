import Foundation
import CoreGraphics
import ImageIO

/// A rectangle on an image, in the image's **oriented** pixels (EXIF orientation applied, as the
/// panel draws it), origin top-left. Region-aware image transforms (crop; redact later) act on it.
public struct ImageRegion: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isEmpty: Bool { width < 1 || height < 1 }

    public func fits(_ pixelSize: (width: Int, height: Int)) -> Bool {
        !isEmpty && x >= 0 && y >= 0 && x + width <= pixelSize.width && y + height <= pixelSize.height
    }

    /// The image's size as displayed: the header's pixel size, with width and height swapped for
    /// orientations 5–8 (the rotated ones). Header only; nothing is decoded.
    public static func orientedPixelSize(of png: Data) -> (width: Int, height: Int)? {
        CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap(orientedPixelSize(of:))
    }

    /// `orientedPixelSize(of:)` for a source a caller will decode from. Reading the properties
    /// first matters: ImageIO's PNG reader only applies an eXIf orientation in a
    /// `WithTransform` thumbnail once the properties have been read on *that* source (measured:
    /// thumbnail-first gives the unrotated 60×40 for an orientation-6 60×40 PNG).
    static func orientedPixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = (p[kCGImagePropertyOrientation] as? Int) ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }

    /// `viewRect` (points, in the same space as `imageFrame`, the fitted image's rect) as image
    /// pixels: rounded outward so a non-empty drag is at least 1 px, and clamped to the image. Nil
    /// for a zero-area rect.
    public static func from(viewRect: CGRect, imageFrame: CGRect, pixelSize: (width: Int, height: Int)) -> ImageRegion? {
        guard viewRect.width > 0, viewRect.height > 0, imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let sx = Double(pixelSize.width) / imageFrame.width
        let sy = Double(pixelSize.height) / imageFrame.height
        func clampX(_ v: Double) -> Int { min(max(Int(v), 0), pixelSize.width) }
        func clampY(_ v: Double) -> Int { min(max(Int(v), 0), pixelSize.height) }
        let x0 = clampX(((viewRect.minX - imageFrame.minX) * sx).rounded(.down))
        let x1 = clampX(((viewRect.maxX - imageFrame.minX) * sx).rounded(.up))
        let y0 = clampY(((viewRect.minY - imageFrame.minY) * sy).rounded(.down))
        let y1 = clampY(((viewRect.maxY - imageFrame.minY) * sy).rounded(.up))
        let region = ImageRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return region.isEmpty ? nil : region
    }

    /// The inverse of `from`: this region in view points, for drawing it over the fitted image.
    public func viewRect(imageFrame: CGRect, pixelSize: (width: Int, height: Int)) -> CGRect {
        let sx = imageFrame.width / Double(max(pixelSize.width, 1))
        let sy = imageFrame.height / Double(max(pixelSize.height, 1))
        return CGRect(x: imageFrame.minX + Double(x) * sx, y: imageFrame.minY + Double(y) * sy,
                      width: Double(width) * sx, height: Double(height) * sy)
    }
}
