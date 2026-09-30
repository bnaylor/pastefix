import Testing
import Foundation
import CoreGraphics
@testable import PastefixCore

@Suite struct ImageRegionTests {
    @Test func viewToPixelsUsesThePixelSizeNotTheDisplay() {
        // A 6000×3000 image drawn in a 600×300 frame (it's downsampled on screen): 10 px per point.
        let frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        let r = ImageRegion.from(viewRect: CGRect(x: 10, y: 20, width: 30, height: 40), imageFrame: frame, pixelSize: (6000, 3000))
        #expect(r == ImageRegion(x: 100, y: 200, width: 300, height: 400))
    }

    @Test func roundsOutwardAndClamps() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        // 100×100 image in 300×200: 1/3 px per point horizontally, 1/2 vertically.
        let r = ImageRegion.from(viewRect: CGRect(x: 1, y: 1, width: 1, height: 1), imageFrame: frame, pixelSize: (100, 100))
        #expect(r == ImageRegion(x: 0, y: 0, width: 1, height: 1), "at least 1 px, rounded outward")
        let over = ImageRegion.from(viewRect: CGRect(x: -50, y: -50, width: 500, height: 500), imageFrame: frame, pixelSize: (100, 100))
        #expect(over == ImageRegion(x: 0, y: 0, width: 100, height: 100))
        #expect(ImageRegion.from(viewRect: CGRect(x: 5, y: 5, width: 0, height: 10), imageFrame: frame, pixelSize: (100, 100)) == nil)
    }

    @Test func viewRectIsTheInverse() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        let r = ImageRegion(x: 100, y: 200, width: 300, height: 400)
        #expect(r.viewRect(imageFrame: frame, pixelSize: (6000, 3000)) == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @Test func fits() {
        #expect(ImageRegion(x: 0, y: 0, width: 10, height: 10).fits((10, 10)))
        #expect(!ImageRegion(x: 5, y: 0, width: 10, height: 10).fits((10, 10)))
        #expect(ImageRegion(x: 0, y: 0, width: 0, height: 5).isEmpty)
    }

    @Test func orientedPixelSizeSwapsFor5Through8() throws {
        let up = try #require(Fixture.image(as: "public.png", orientation: 1))
        let rotated = try #require(Fixture.image(as: "public.png", orientation: 6))
        #expect(ImageRegion.orientedPixelSize(of: up).map { [$0.width, $0.height] } == [60, 40])
        #expect(ImageRegion.orientedPixelSize(of: rotated).map { [$0.width, $0.height] } == [40, 60])
        #expect(ImageRegion.orientedPixelSize(of: Data("no".utf8)) == nil)
    }
}
