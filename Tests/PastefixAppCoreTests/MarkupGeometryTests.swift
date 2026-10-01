import Testing
import CoreGraphics
import PastefixCore
@testable import PastefixAppCore

@Suite struct MarkupGeometryTests {
    private let frame = CGRect(x: 0, y: 0, width: 300, height: 200)   // a 600×400 image at 2 px/pt
    private let size = (width: 600, height: 400)

    @Test func twoPointMarksMapToPixels() {
        let m = MarkupGeometry.mark(tool: .box, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20), CGPoint(x: 60, y: 40)],
                                    frame: frame, pixelSize: size)
        #expect(m == ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 20, y: 20), ImagePoint(x: 120, y: 80)]))
        let a = MarkupGeometry.mark(tool: .arrow, color: .blue, path: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: -50)], frame: frame, pixelSize: size)
        #expect(a?.points == [ImagePoint(x: 0, y: 0), ImagePoint(x: 600, y: 0)], "clamped to the image")
    }

    @Test func tapsAndFlatShapesAreDiscarded() {
        #expect(MarkupGeometry.mark(tool: .box, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 11)], frame: frame, pixelSize: size) == nil)
        #expect(MarkupGeometry.mark(tool: .freehand, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 11)], frame: frame, pixelSize: size) == nil)
        #expect(MarkupGeometry.mark(tool: .highlight, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10)], frame: frame, pixelSize: size) == nil, "zero height")
        #expect(MarkupGeometry.mark(tool: .arrow, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10)], frame: frame, pixelSize: size) != nil, "a flat arrow is fine")
        #expect(MarkupGeometry.mark(tool: .text, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60)], frame: frame, pixelSize: size) == nil, "text is placed by the text field")
    }

    @Test func freehandKeepsThePath() {
        let path = (0...20).map { CGPoint(x: Double($0) * 5, y: 50) }
        let m = MarkupGeometry.mark(tool: .freehand, color: .black, path: path, frame: frame, pixelSize: size)
        #expect(m?.points.first == ImagePoint(x: 0, y: 100) && m?.points.last == ImagePoint(x: 200, y: 100) && (m?.points.count ?? 0) >= 3)
    }
}
