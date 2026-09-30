import CoreGraphics

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
