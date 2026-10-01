import CoreGraphics
import PastefixCore

/// Turns a markup drag (view points over the fitted image) into an `ImageMark` in image pixels
/// (annotate spec), or nil when it draws nothing: a tap (under 3 pt), a flat box or highlight,
/// or the text tool, whose mark comes from its text field.
public enum MarkupGeometry {
    public static func pixel(_ p: CGPoint, frame: CGRect, pixelSize: (width: Int, height: Int)) -> ImagePoint {
        let x = (p.x - frame.minX) / max(frame.width, 1) * Double(pixelSize.width)
        let y = (p.y - frame.minY) / max(frame.height, 1) * Double(pixelSize.height)
        return ImagePoint(x: min(max(Int(x.rounded()), 0), pixelSize.width),
                          y: min(max(Int(y.rounded()), 0), pixelSize.height))
    }

    public static func mark(tool: ImageMark.Tool, color: ImageMark.Color, path: [CGPoint],
                            frame: CGRect, pixelSize: (width: Int, height: Int)) -> ImageMark? {
        guard tool != .text, let first = path.first, let last = path.last,
              !RegionGeometry.isTap(from: first, to: path.max { hypot($0.x - first.x, $0.y - first.y) < hypot($1.x - first.x, $1.y - first.y) } ?? last)
        else { return nil }
        func px(_ p: CGPoint) -> ImagePoint { pixel(p, frame: frame, pixelSize: pixelSize) }
        switch tool {
        case .box, .highlight:
            let a = px(first), b = px(last)
            guard a.x != b.x, a.y != b.y else { return nil }
            return ImageMark(tool: tool, color: color, points: [a, b])
        case .arrow:
            let a = px(first), b = px(last)
            guard a != b else { return nil }
            return ImageMark(tool: tool, color: color, points: [a, b])
        case .freehand:
            return ImageMark(tool: tool, color: color, points: path.map(px))
        case .text:
            return nil
        }
    }
}
