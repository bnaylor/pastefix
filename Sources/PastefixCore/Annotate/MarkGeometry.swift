import CoreGraphics

/// Mark sizes and shapes (annotate spec), pure. Sizes scale with the image's longer side so a
/// mark looks alike on a small crop and a 5K screenshot.
public enum MarkGeometry {
    public static func strokeWidth(longerSide: Int) -> Int { max(2, Int((Double(longerSide) / 250).rounded())) }
    /// Arrows are drawn heavier than boxes and freehand, 2× the stroke (owner, after the GUI pass);
    /// the head scales with it.
    public static func arrowStrokeWidth(longerSide: Int) -> Int { 2 * strokeWidth(longerSide: longerSide) }
    public static func fontSize(longerSide: Int) -> Int { max(12, Int((Double(longerSide) / 40).rounded())) }
    /// A label's size in pixels (#135): S/M/L/XL = 1×/1.5×/2×/3× the base, `max(12, L/40)`.
    public static func fontSize(longerSide: Int, size: ImageMark.TextSize) -> Int {
        Int((Double(fontSize(longerSide: longerSide)) * size.scale).rounded())
    }
    /// A label's halo, a tenth of its font size (at least 1 px): it scales with the text, so a big
    /// label keeps a readable edge instead of a hairline (#135).
    public static func haloWidth(fontSize: Int) -> Int { max(1, Int((Double(fontSize) / 10).rounded())) }
    public static func haloWidth(stroke: Int) -> Int { max(1, Int((Double(stroke) / 2).rounded())) }

    /// The filled head at `tip`: 4 × stroke long, 3 × stroke wide, centred on the line.
    public static func arrowHead(tail: CGPoint, tip: CGPoint, stroke: CGFloat) -> (tip: CGPoint, left: CGPoint, right: CGPoint, base: CGPoint) {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let len = max(hypot(dx, dy), .ulpOfOne)
        let ux = dx / len, uy = dy / len            // along the arrow
        let length = 4 * stroke, half = 1.5 * stroke
        let base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        let left = CGPoint(x: base.x - uy * half, y: base.y + ux * half)
        let right = CGPoint(x: base.x + uy * half, y: base.y - ux * half)
        return (tip, left, right, base)
    }

    /// Drops points closer than `minDistance` to the previous kept one; always keeps both ends.
    public static func thinned(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first, let last = points.last, points.count > 2 else { return points }
        var kept = [first]
        for p in points.dropFirst().dropLast() where hypot(p.x - kept.last!.x, p.y - kept.last!.y) >= minDistance { kept.append(p) }
        if kept.last != last { kept.append(last) }
        return kept
    }

    /// Quadratic curves through the midpoints of successive points: smooth, and through both ends.
    public static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else { points.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points.last!)
        return path
    }
}
