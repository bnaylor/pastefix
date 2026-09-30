import CoreGraphics
import PastefixCore

public enum RegionHandle: CaseIterable, Sendable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
public enum RegionHit: Equatable, Sendable { case new, move, handle(RegionHandle) }

/// The drag maths for the image region, in view points. Pure; the overlay maps its result to pixels.
public enum RegionGeometry {
    public static let handleHitSize: CGFloat = 8
    public static let tapTravel: CGFloat = 3

    public static func handlePoints(_ r: CGRect) -> [(RegionHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    /// Handles first (they sit on and just outside the edge), then inside to move, else a new region.
    public static func hit(_ p: CGPoint, selection: CGRect?) -> RegionHit {
        guard let r = selection else { return .new }
        if let handle = handlePoints(r).first(where: { abs($0.1.x - p.x) <= handleHitSize && abs($0.1.y - p.y) <= handleHitSize }) {
            return .handle(handle.0)
        }
        return r.contains(p) ? .move : .new
    }

    public static func isTap(from: CGPoint, to: CGPoint) -> Bool {
        hypot(to.x - from.x, to.y - from.y) < tapTravel
    }

    /// The region after a drag from `from` to `to`, clamped to `bounds`.
    public static func dragged(_ hit: RegionHit, from: CGPoint, to: CGPoint, original: CGRect?, bounds: CGRect) -> CGRect {
        func clampPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        switch hit {
        case .new, .handle where original == nil:
            let a = clampPoint(from), b = clampPoint(to)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .move:
            guard let r = original else { return .zero }
            let dx = min(max(to.x - from.x, bounds.minX - r.minX), bounds.maxX - r.maxX)
            let dy = min(max(to.y - from.y, bounds.minY - r.minY), bounds.maxY - r.maxY)
            return r.offsetBy(dx: dx, dy: dy)
        case .handle(let h):
            guard let r = original else { return .zero }
            let p = clampPoint(to)
            var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
            if [.topLeft, .left, .bottomLeft].contains(h) { x0 = p.x }
            if [.topRight, .right, .bottomRight].contains(h) { x1 = p.x }
            if [.topLeft, .top, .topRight].contains(h) { y0 = p.y }
            if [.bottomLeft, .bottom, .bottomRight].contains(h) { y1 = p.y }
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
    }
}

public extension RegionGeometry {
    /// The region after a drag, in image pixels. A new region maps its rectangle through points; a
    /// move or a handle works in whole pixels from the original region, by the pointer's travel —
    /// so a moved region keeps its exact size and edges no handle touched stay put. (Round-tripping
    /// through points grew a moved region by a pixel per drag, and float error nudged still edges.)
    /// Nil leaves the region as it was: a zero-area rectangle, or a handle dragged onto its opposite edge.
    static func draggedRegion(_ hit: RegionHit, from: CGPoint, to: CGPoint, original: ImageRegion?,
                              imageFrame: CGRect, pixelSize: (width: Int, height: Int)) -> ImageRegion? {
        guard let original, hit != .new, imageFrame.width > 0, imageFrame.height > 0 else {
            let rect = dragged(.new, from: from, to: to, original: nil, bounds: imageFrame)
            return ImageRegion.from(viewRect: rect, imageFrame: imageFrame, pixelSize: pixelSize)
        }
        let dx = Int(((to.x - from.x) * Double(pixelSize.width) / imageFrame.width).rounded())
        let dy = Int(((to.y - from.y) * Double(pixelSize.height) / imageFrame.height).rounded())
        func clamp(_ v: Int, _ hi: Int) -> Int { min(max(v, 0), hi) }
        switch hit {
        case .move:
            return ImageRegion(x: clamp(original.x + dx, pixelSize.width - original.width),
                               y: clamp(original.y + dy, pixelSize.height - original.height),
                               width: original.width, height: original.height)
        case .handle(let h):
            var x0 = original.x, x1 = original.x + original.width
            var y0 = original.y, y1 = original.y + original.height
            if [.topLeft, .left, .bottomLeft].contains(h) { x0 = clamp(x0 + dx, pixelSize.width) }
            if [.topRight, .right, .bottomRight].contains(h) { x1 = clamp(x1 + dx, pixelSize.width) }
            if [.topLeft, .top, .topRight].contains(h) { y0 = clamp(y0 + dy, pixelSize.height) }
            if [.bottomLeft, .bottom, .bottomRight].contains(h) { y1 = clamp(y1 + dy, pixelSize.height) }
            let region = ImageRegion(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
            return region.isEmpty ? nil : region
        case .new:
            return nil   // handled above
        }
    }
}
