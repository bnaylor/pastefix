import Foundation
import CoreGraphics
import CoreText

/// Draws one mark into a bitmap that already holds the image (annotate spec). Mark points are
/// top-left oriented pixels; the bitmap is bottom-left, so y flips. Antialiased: marks are new
/// pixels, so smooth edges are wanted.
enum MarkRenderer {
    static func draw(_ mark: ImageMark, in ctx: CGContext, imageWidth: Int, imageHeight: Int) {
        let longer = max(imageWidth, imageHeight)
        let stroke = CGFloat(MarkGeometry.strokeWidth(longerSide: longer))
        func flip(_ p: ImagePoint) -> CGPoint { CGPoint(x: Double(p.x), y: Double(imageHeight - p.y)) }
        func cg(_ c: ImageMark.Color, alpha: Double = 1) -> CGColor {
            CGColor(srgbRed: c.rgb.r, green: c.rgb.g, blue: c.rgb.b, alpha: alpha)
        }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setShouldAntialias(true)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(cg(mark.color)); ctx.setFillColor(cg(mark.color))
        switch mark.tool {
        case .box:
            let a = flip(mark.points[0]), b = flip(mark.points[1])
            ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .highlight:
            let a = flip(mark.points[0]), b = flip(mark.points[1])
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.90, blue: 0.0, alpha: 0.45))
            ctx.fill(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .arrow:
            let tail = flip(mark.points[0]), tip = flip(mark.points[1])
            let arrowStroke = CGFloat(MarkGeometry.arrowStrokeWidth(longerSide: longer))
            ctx.setLineWidth(arrowStroke)
            let head = MarkGeometry.arrowHead(tail: tail, tip: tip, stroke: arrowStroke)
            ctx.move(to: tail); ctx.addLine(to: head.base); ctx.strokePath()
            ctx.move(to: head.tip); ctx.addLine(to: head.left); ctx.addLine(to: head.right); ctx.closePath(); ctx.fillPath()
        case .freehand:
            let pts = MarkGeometry.thinned(mark.points.map(flip), minDistance: 1)
            ctx.addPath(MarkGeometry.smoothPath(pts)); ctx.strokePath()
        case .text:
            guard let text = mark.text else { return }
            let fontPixels = MarkGeometry.fontSize(longerSide: longer, size: mark.textSize)
            let size = CGFloat(fontPixels)
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let halo = CGFloat(MarkGeometry.haloWidth(fontSize: fontPixels))
            let origin = flip(mark.points[0])
            let ascent = CTFontGetAscent(font)
            let baseline = CGPoint(x: origin.x, y: origin.y - ascent)
            // Halo: the text stroked in the contrasting colour at twice the halo width (half falls
            // inside the glyph, under the fill), then the fill on top.
            func line(_ color: ImageMark.Color, strokeWidthPercent: Double?) -> CTLine {
                var attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(color),
                ]
                if let w = strokeWidthPercent {
                    attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = w
                    attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = cg(color)
                }
                return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            }
            // kCTStrokeWidth is a percentage of the font size; positive = stroke only.
            let haloPercent = Double(2 * halo / size * 100)
            ctx.textPosition = baseline
            CTLineDraw(line(mark.color.halo, strokeWidthPercent: haloPercent), ctx)
            ctx.textPosition = baseline
            CTLineDraw(line(mark.color, strokeWidthPercent: nil), ctx)
        }
    }
}
