import Testing
import Foundation
import CoreGraphics
@testable import PastefixAppCore

/// #26: the panel remembers its size and where it sits on the display, as a fraction of the space
/// it can move in, and opens at that relative spot on the display you're using.
@Suite struct PanelPlacementTests {
    private let big = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    private let small = CGRect(x: 3000, y: 100, width: 1000, height: 700)
    private let size = CGSize(width: 640, height: 460)

    @Test func roundTripOnTheSameDisplay() {
        let frame = CGRect(x: 300, y: 500, width: 640, height: 460)
        let placement = PanelPlacement(frame: frame, in: big)
        #expect(placement.frame(in: big) == frame)
    }

    @Test func topRightStaysTopRightOnAnotherDisplay() {
        let topRight = CGRect(x: big.maxX - size.width, y: big.maxY - size.height, width: size.width, height: size.height)
        let there = PanelPlacement(frame: topRight, in: big).frame(in: small)
        #expect(there.maxX == small.maxX && there.maxY == small.maxY && there.size == size)
        let bottomLeft = CGRect(origin: big.origin, size: size)
        #expect(PanelPlacement(frame: bottomLeft, in: big).frame(in: small).origin == small.origin)
    }

    @Test func tooBigForTheDisplayIsClampedToIt() {
        let huge = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let there = PanelPlacement(frame: huge, in: big).frame(in: small)
        #expect(there == small, "fits the smaller display exactly")
    }

    @Test func nothingSavedCentres() {
        let centred = PanelPlacement.centred(size: size, in: big)
        #expect(centred == CGRect(x: 680, y: 370, width: 640, height: 460))
    }

    @Test func aFrameOffTheDisplayIsPulledOn() {
        let off = CGRect(x: -500, y: 5000, width: 640, height: 460)
        let there = PanelPlacement(frame: off, in: big).frame(in: big)
        #expect(big.contains(there))
    }

    @Test func persistsAsJSON() throws {
        let p = PanelPlacement(frame: CGRect(x: 10, y: 20, width: 640, height: 460), in: big)
        let back = try JSONDecoder().decode(PanelPlacement.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
}

@MainActor
@Suite(.serialized) struct PanelPlacementSettingsTests {
    @Test func savedAndCleared() {
        let iso = IsolatedDefaults(); defer { iso.remove() }
        let s = SettingsStore(defaults: iso.defaults)
        #expect(s.panelPlacement == nil)
        let p = PanelPlacement(frame: CGRect(x: 10, y: 20, width: 640, height: 460), in: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        s.panelPlacement = p
        #expect(SettingsStore(defaults: iso.defaults).panelPlacement == p)
        s.panelPlacement = nil
        #expect(SettingsStore(defaults: iso.defaults).panelPlacement == nil)
    }
}
