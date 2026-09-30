import Testing
import CoreGraphics
import PastefixCore
@testable import PastefixAppCore

@Suite struct RegionGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let sel = CGRect(x: 100, y: 100, width: 100, height: 50)

    @Test func hitTesting() {
        #expect(RegionGeometry.hit(CGPoint(x: 10, y: 10), selection: nil) == .new)
        #expect(RegionGeometry.hit(CGPoint(x: 10, y: 10), selection: sel) == .new)
        #expect(RegionGeometry.hit(CGPoint(x: 150, y: 125), selection: sel) == .move)
        #expect(RegionGeometry.hit(CGPoint(x: 102, y: 98), selection: sel) == .handle(.topLeft))
        #expect(RegionGeometry.hit(CGPoint(x: 199, y: 151), selection: sel) == .handle(.bottomRight))
        #expect(RegionGeometry.hit(CGPoint(x: 150, y: 150), selection: sel) == .handle(.bottom))
    }

    @Test func newDragIsStandardisedAndClamped() {
        let r = RegionGeometry.dragged(.new, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 500, y: 100), original: nil, bounds: bounds)
        #expect(r == CGRect(x: 300, y: 100, width: 100, height: 150))
    }

    @Test func moveKeepsSizeAndStaysInside() {
        let r = RegionGeometry.dragged(.move, from: CGPoint(x: 150, y: 125), to: CGPoint(x: 500, y: 125), original: sel, bounds: bounds)
        #expect(r == CGRect(x: 300, y: 100, width: 100, height: 50))
    }

    @Test func handleResizesOneCorner() {
        let r = RegionGeometry.dragged(.handle(.bottomRight), from: CGPoint(x: 200, y: 150), to: CGPoint(x: 250, y: 200), original: sel, bounds: bounds)
        #expect(r == CGRect(x: 100, y: 100, width: 150, height: 100))
        let flipped = RegionGeometry.dragged(.handle(.left), from: CGPoint(x: 100, y: 120), to: CGPoint(x: 260, y: 120), original: sel, bounds: bounds)
        #expect(flipped == CGRect(x: 200, y: 100, width: 60, height: 50), "dragging past the opposite edge flips, standardised")
    }

    @Test func tapVersusDrag() {
        #expect(RegionGeometry.isTap(from: .zero, to: CGPoint(x: 2, y: 2)))
        #expect(!RegionGeometry.isTap(from: .zero, to: CGPoint(x: 3, y: 3)))
    }
    /// Small regions move from inside; their handles are grabbed from the outer half (redact/blur spec).
    @Test func smallRegionsMoveFromInside() {
        let small = CGRect(x: 100, y: 100, width: 10, height: 10)
        #expect(RegionGeometry.hit(CGPoint(x: 105, y: 105), selection: small) == .move)
        #expect(RegionGeometry.hit(CGPoint(x: 101, y: 101), selection: small) == .move, "inside, near a corner")
        #expect(RegionGeometry.hit(CGPoint(x: 98, y: 98), selection: small) == .handle(.topLeft), "just outside the corner")
        #expect(RegionGeometry.hit(CGPoint(x: 112, y: 105), selection: small) == .handle(.right))
        let thin = CGRect(x: 100, y: 100, width: 200, height: 12)   // wide but short: still small
        #expect(RegionGeometry.hit(CGPoint(x: 102, y: 104), selection: thin) == .move)
        let big = CGRect(x: 100, y: 100, width: 100, height: 100)
        #expect(RegionGeometry.hit(CGPoint(x: 103, y: 103), selection: big) == .handle(.topLeft), "inside a big region, near a corner")
        #expect(RegionGeometry.smallRegionSide == 24)
    }
}

/// Final review I1: moves and handle drags work in pixels, so a region never drifts. Through
/// points, floor/ceil and float error grew a moved region by 1 px per drag and nudged edges no
/// handle touched.
@Suite struct RegionPixelDragTests {
    @Test func moveKeepsThePixelSizeExactly() {
        // 1000 px shown at 200 pt: 5 px per point.
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let original = ImageRegion(x: 100, y: 50, width: 100, height: 60)
        let moved = RegionGeometry.draggedRegion(.move, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 30.1, y: 20),
                                                 original: original, imageFrame: frame, pixelSize: (1000, 500))
        #expect(moved?.width == 100 && moved?.height == 60)
        let far = RegionGeometry.draggedRegion(.move, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 500, y: 500),
                                               original: original, imageFrame: frame, pixelSize: (1000, 500))
        #expect(far == ImageRegion(x: 900, y: 440, width: 100, height: 60), "clamped inside, size kept")
    }

    @Test func aHandleMovesOnlyItsOwnEdges() {
        // 37 px in 100 pt: x = 5 round-trips through points to 4.999…, which floored to 4.
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        for x in 0..<30 {
            let original = ImageRegion(x: x, y: x, width: 5, height: 5)
            let r = RegionGeometry.draggedRegion(.handle(.right), from: .zero, to: CGPoint(x: 99, y: 50),
                                                 original: original, imageFrame: frame, pixelSize: (37, 37))
            #expect(r?.x == x && r?.y == x && r?.height == 5, "x = \(x): only the right edge moves")
            #expect(r.map { $0.x + $0.width } == 37)
        }
    }

    @Test func aHandleDraggedPastTheOppositeEdgeFlipsAndKeepsOnePixel() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let original = ImageRegion(x: 40, y: 40, width: 20, height: 20)
        let flipped = RegionGeometry.draggedRegion(.handle(.left), from: CGPoint(x: 40, y: 50), to: CGPoint(x: 80, y: 50),
                                                   original: original, imageFrame: frame, pixelSize: (100, 100))
        #expect(flipped == ImageRegion(x: 60, y: 40, width: 20, height: 20))
        let collapsed = RegionGeometry.draggedRegion(.handle(.left), from: CGPoint(x: 40, y: 50), to: CGPoint(x: 60, y: 50),
                                                     original: original, imageFrame: frame, pixelSize: (100, 100))
        #expect(collapsed == nil, "zero width: the drag leaves the region as it was")
    }

    @Test func aNewDragMapsThroughPoints() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let r = RegionGeometry.draggedRegion(.new, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 120),
                                             original: nil, imageFrame: frame, pixelSize: (600, 400))
        #expect(r == ImageRegion(x: 100, y: 100, width: 200, height: 140))
    }
}
