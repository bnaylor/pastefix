import Testing
import AppKit
import SwiftUI
import Combine
import PastefixCore
@testable import Pastefix

/// The overlay's gesture, driven by real mouse events (final review C1: with no region on screen
/// the overlay had no size, so the first region could never be drawn — and every other hosted test
/// puts its region up through ⌘Z, never the mouse).
@MainActor
@Suite("image region overlay, mouse (crop)")
struct ImageRegionOverlayTests {
    final class Box: ObservableObject { @Published var region: ImageRegion?; @Published var enabled = true }

    private struct Host: View {
        @ObservedObject var box: Box
        var body: some View {
            ImageRegionOverlay(region: $box.region, pixelSize: (600, 400), enabled: box.enabled)
                .frame(width: 300, height: 200)
        }
    }

    private func window(_ box: Box) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Host(box: box))
        w.makeKeyAndOrderFront(nil)
        return w
    }

    /// A press-drag-release from `a` to `b`, in top-left view points.
    private func drag(_ w: NSWindow, from a: CGPoint, to b: CGPoint) async {
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: 200 - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        w.sendEvent(event(.leftMouseDown, a))
        await Task.yield()
        for i in 1...4 {
            let t = Double(i) / 4
            w.sendEvent(event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
            await Task.yield()
        }
        w.sendEvent(event(.leftMouseUp, b))
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
        return condition()
    }

    @Test func theFirstRegionIsDrawnByDragging() async {
        let box = Box()
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 120))
        #expect(await eventually { box.region == ImageRegion(x: 100, y: 100, width: 200, height: 140) },
                "region: \(String(describing: box.region))")
    }

    @Test func movingKeepsTheSizeAndATapOutsideClears() async {
        let box = Box()
        box.region = ImageRegion(x: 100, y: 100, width: 101, height: 77)
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, from: CGPoint(x: 90, y: 80), to: CGPoint(x: 110.3, y: 90.2))   // inside: a move
        #expect(await eventually { box.region?.x != 100 }, "region: \(String(describing: box.region))")
        #expect(box.region?.width == 101 && box.region?.height == 77)
        await drag(w, from: CGPoint(x: 280, y: 190), to: CGPoint(x: 280, y: 190))    // a tap outside
        #expect(await eventually { box.region == nil })
    }
    @Test func aSmallRegionMovesAndKeepsItsSize() async {
        let box = Box()
        box.region = ImageRegion(x: 100, y: 100, width: 20, height: 20)   // 10×10 pt at 2 px/pt
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, from: CGPoint(x: 55, y: 55), to: CGPoint(x: 85, y: 75))   // inside, near its centre
        #expect(await eventually { box.region == ImageRegion(x: 160, y: 140, width: 20, height: 20) },
                "region: \(String(describing: box.region))")
    }

    /// Review Focus 5: a drag cancelled mid-way (the overlay is disabled when a transform starts)
    /// must not leave its hit behind for the next gesture.
    @Test func aCancelledDragDoesNotReplay() async {
        let box = Box()
        box.region = ImageRegion(x: 100, y: 100, width: 101, height: 77)
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: 200 - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Press inside (a move) and drag, then cancel by disabling before the release.
        w.sendEvent(event(.leftMouseDown, CGPoint(x: 90, y: 80))); await Task.yield()
        w.sendEvent(event(.leftMouseDragged, CGPoint(x: 100, y: 85))); await Task.yield()
        box.enabled = false
        try? await Task.sleep(for: .milliseconds(50))
        w.sendEvent(event(.leftMouseUp, CGPoint(x: 100, y: 85)))
        box.enabled = true
        try? await Task.sleep(for: .milliseconds(50))
        let afterCancel = box.region
        await drag(w, from: CGPoint(x: 280, y: 190), to: CGPoint(x: 280, y: 190))   // a tap outside
        #expect(await eventually { box.region == nil }, "was \(String(describing: afterCancel)), now \(String(describing: box.region))")
    }
}
