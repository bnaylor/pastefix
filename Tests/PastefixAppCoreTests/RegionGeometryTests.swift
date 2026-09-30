import Testing
import CoreGraphics
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
}
