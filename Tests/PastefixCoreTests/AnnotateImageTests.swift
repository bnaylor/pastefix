import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

/// Annotate (markup mode): mark geometry and each mark burned into the image.
@Suite struct AnnotateImageTests {
    private let lane = ImageTransformLane.makeLane(label: "test.annotate.core")

    /// `w`×`h` opaque white, with an optional black block (a stand-in for text).
    static func page(_ w: Int, _ h: Int, black: CGRect? = nil) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let black {   // given top-left; CG is bottom-left
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: black.minX, y: CGFloat(h) - black.maxY, width: black.width, height: black.height))
        }
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func mark(_ m: ImageMark, on png: Data) async throws -> (Data, String?) {
        let t = AnnotateImage(m, lane: lane)
        guard case .image(let out, let note) = try await offThePool({ try t.transformImage(png) }) else {
            Issue.record("\(m.tool): expected an image"); throw CancellationError()
        }
        return (out, note)
    }
    private func changed(_ a: (w: Int, h: Int, px: [UInt8]), _ b: (w: Int, h: Int, px: [UInt8]), outside box: CGRect) -> Int {
        var n = 0
        for y in 0..<a.h { for x in 0..<a.w where !box.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
            if RedactBlurTests.at(a, x, y) != RedactBlurTests.at(b, x, y) { n += 1 }
        } }
        return n
    }
    private func isWhite(_ c: [UInt8]) -> Bool { c[0] > 245 && c[1] > 245 && c[2] > 245 }
    private func isRed(_ c: [UInt8]) -> Bool { c[0] > 180 && c[1] < 120 && c[2] < 120 }

    // MARK: geometry

    @Test func sizesScaleWithTheImage() {
        #expect(MarkGeometry.strokeWidth(longerSide: 400) == 2 && MarkGeometry.strokeWidth(longerSide: 1200) == 5
                && MarkGeometry.strokeWidth(longerSide: 5120) == 20 && MarkGeometry.strokeWidth(longerSide: 10) == 2)
        #expect(MarkGeometry.fontSize(longerSide: 400) == 12 && MarkGeometry.fontSize(longerSide: 1200) == 30
                && MarkGeometry.fontSize(longerSide: 5120) == 128)
        #expect(MarkGeometry.haloWidth(stroke: 2) == 1 && MarkGeometry.haloWidth(stroke: 5) == 3 && MarkGeometry.haloWidth(stroke: 20) == 10)
    }

    @Test func arrowHeadPoints() {
        let h = MarkGeometry.arrowHead(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 0), stroke: 5)
        #expect(h.tip == CGPoint(x: 100, y: 0) && h.base == CGPoint(x: 80, y: 0))
        #expect(abs(h.left.x - 80) < 1e-9 && abs(abs(h.left.y) - 7.5) < 1e-9 && abs(h.left.y + h.right.y) < 1e-9)
        let v = MarkGeometry.arrowHead(tail: CGPoint(x: 10, y: 10), tip: CGPoint(x: 10, y: 50), stroke: 2)
        #expect(v.base == CGPoint(x: 10, y: 42) && abs(abs(v.left.x - 10) - 3) < 1e-9)
    }

    @Test func thinningKeepsEndpoints() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5.2, y: 0.1), CGPoint(x: 5.3, y: 0)]
        let t = MarkGeometry.thinned(pts, minDistance: 1)
        #expect(t.first == CGPoint(x: 0, y: 0) && t.last == CGPoint(x: 5.3, y: 0) && t.count == 3)
    }

    // MARK: pixels

    @Test func boxOutlinesWithoutFilling() async throws {
        let png = try Self.page(400, 300)
        let m = ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 100, y: 100), ImagePoint(x: 200, y: 180)])
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Box added.")
        let a = try RedactBlurTests.pixels(png), b = try RedactBlurTests.pixels(out)
        #expect(isRed(RedactBlurTests.at(b, 100, 140)) && isRed(RedactBlurTests.at(b, 150, 100)), "edges")
        #expect(isWhite(RedactBlurTests.at(b, 150, 140)), "interior untouched")
        #expect(changed(a, b, outside: CGRect(x: 96, y: 96, width: 108, height: 88)) == 0)
    }

    @Test func arrowLineAndHead() async throws {
        let png = try Self.page(400, 300)
        let m = ImageMark(tool: .arrow, color: .red, points: [ImagePoint(x: 50, y: 150), ImagePoint(x: 350, y: 150)])
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Arrow added.")
        let a = try RedactBlurTests.pixels(png), b = try RedactBlurTests.pixels(out)
        #expect(isRed(RedactBlurTests.at(b, 200, 150)) && isWhite(RedactBlurTests.at(b, 200, 158)))
        // Pixel centre (343.5, 151.5): 6.5 px from the tip, where the head is 2.4 px wide each side; the
        // line's stroke (1 px each side) and its round cap (ending at x 343) don't reach it.
        #expect(isRed(RedactBlurTests.at(b, 343, 151)), "head is wider than the line")
        #expect(changed(a, b, outside: CGRect(x: 46, y: 144, width: 308, height: 12)) == 0)
    }

    /// Review Focus 4.
    @Test func highlightKeepsTextDark() async throws {
        let png = try Self.page(400, 300, black: CGRect(x: 120, y: 140, width: 60, height: 20))
        let m = ImageMark(tool: .highlight, color: .blue, points: [ImagePoint(x: 100, y: 130), ImagePoint(x: 200, y: 170)])
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Highlight added.")
        let b = try RedactBlurTests.pixels(out)
        let text = RedactBlurTests.at(b, 150, 150), paper = RedactBlurTests.at(b, 105, 135)
        #expect(text[0] < 30 && text[1] < 30 && text[2] < 30, "text stays dark: \(text)")
        #expect(paper[0] > 200 && paper[1] > 180 && paper[2] < 170, "paper turns yellow, the swatch ignored: \(paper)")
        #expect(isWhite(RedactBlurTests.at(b, 250, 150)))
    }

    @Test func textDrawsInsideItsBox() async throws {
        let png = try Self.page(400, 300)
        let m = ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 50, y: 50)], text: "Hi there")
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Text added.")
        let a = try RedactBlurTests.pixels(png), b = try RedactBlurTests.pixels(out)
        let box = CGRect(x: 44, y: 44, width: 120, height: 30)    // font 12 px, plus the halo
        #expect(changed(a, b, outside: box) == 0)
        var reds = 0
        for y in 50..<70 { for x in 50..<150 where isRed(RedactBlurTests.at(b, x, y)) { reds += 1 } }
        #expect(reds > 20, "glyphs drawn: \(reds) red pixels")
    }

    @Test func freehandFollowsThePath() async throws {
        let png = try Self.page(400, 300)
        let ring = (0...36).map { i -> ImagePoint in
            let t = Double(i) / 36 * 2 * .pi
            return ImagePoint(x: 200 + Int((60 * cos(t)).rounded()), y: 150 + Int((40 * sin(t)).rounded()))
        }
        let (out, note) = try await mark(ImageMark(tool: .freehand, color: .red, points: ring), on: png)
        #expect(note == "Drawing added.")
        let b = try RedactBlurTests.pixels(out)
        // The curve runs through midpoints between samples, so allow a pixel either way.
        func redNear(_ x: Int, _ y: Int) -> Bool {
            (-2...2).contains { dy in (-2...2).contains { dx in isRed(RedactBlurTests.at(b, x + dx, y + dy)) } }
        }
        #expect(redNear(260, 150) && redNear(200, 110) && redNear(140, 150))
        #expect(isWhite(RedactBlurTests.at(b, 200, 150)), "the inside of the oval is untouched")
    }

    /// Review Focus 3: orientation 6 shows 40×60 with the stored left (red) half on top.
    @Test func marksTheDisplayedOrientation() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        let m = ImageMark(tool: .box, color: .white, points: [ImagePoint(x: 5, y: 5), ImagePoint(x: 35, y: 25)])
        let (out, _) = try await mark(m, on: png)
        let b = try RedactBlurTests.pixels(out)
        #expect(b.w == 40 && b.h == 60)
        #expect(isWhite(RedactBlurTests.at(b, 5, 15)), "the box's left edge, on the red top half")
        let lower = RedactBlurTests.at(b, 5, 45)
        #expect(lower[2] > 150 && lower[0] < 100, "the blue bottom half untouched: \(lower)")
    }

    @Test func keepsProfileDepthDropsMetadata() async throws {
        let m = ImageMark(tool: .box, color: .black, points: [ImagePoint(x: 2, y: 2), ImagePoint(x: 20, y: 20)])
        let (p3, _) = try await mark(m, on: try #require(Fixture.image(as: "public.png")))
        #expect(Fixture.decoded(p3)?.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Fixture.properties(p3)?[kCGImagePropertyGPSDictionary as String] == nil)
        let (deep, _) = try await mark(m, on: try RedactBlurDepthTests.png16())
        #expect(Fixture.decoded(deep)?.bitsPerComponent == 16)
    }

    @Test func degenerateMarksDrawNothing() throws {
        let png = try Self.page(40, 30)
        for m in [ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 1, y: 1)]),
                  ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 1, y: 1)], text: "  "),
                  ImageMark(tool: .freehand, color: .red, points: [])] {
            #expect(try AnnotateImage(m, lane: lane).transformImage(png) == .nothingToDo(AnnotateImage.nothingToDrawMessage))
        }
    }

    @Test func namesAndNotRegistered() {
        let names = ImageMark.Tool.allCases.map { AnnotateImage(ImageMark(tool: $0, color: .red, points: [])).name }
        #expect(names == ["Box", "Arrow", "Text", "Highlight", "Freehand"])
        let reg = TransformerRegistry(config: .init(scriptsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("none-\(UUID().uuidString)"), wrapWidth: 80))
        #expect(!reg.load().contains { $0 is AnnotateImage })
    }
}
