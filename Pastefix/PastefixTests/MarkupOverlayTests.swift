import Testing
import AppKit
import SwiftUI
import Combine
import PastefixCore
@testable import Pastefix

/// The markup overlay driven by real mouse events, alone in a window (as ImageRegionOverlayTests).
@MainActor
@Suite("markup overlay, mouse (annotate)")
struct MarkupOverlayTests {
    final class Box: ObservableObject {
        @Published var tool: ImageMark.Tool = .box
        @Published var draft: TextDraft?
        var marks: [ImageMark] = []
    }
    private struct Host: View {
        @ObservedObject var box: Box
        var body: some View {
            MarkupOverlay(pixelSize: (600, 400),
                          config: MarkupConfig(tool: box.tool, color: .red, pending: [],
                                               textDraft: $box.draft, onMark: { box.marks.append($0) }))
                .frame(width: 300, height: 200)
        }
    }
    private func window(_ box: Box) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Host(box: box))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func drag(_ w: NSWindow, _ pts: [CGPoint]) async {
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: 200 - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        w.sendEvent(event(.leftMouseDown, pts[0])); await Task.yield()
        for p in pts.dropFirst() { w.sendEvent(event(.leftMouseDragged, p)); await Task.yield() }
        w.sendEvent(event(.leftMouseUp, pts.last!))
        try? await Task.sleep(for: .milliseconds(60))
    }

    @Test func aBoxDragMakesOneMarkInPixels() async {
        let box = Box(); let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, [CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 80), CGPoint(x: 150, y: 120)])
        #expect(box.marks == [ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 100, y: 100), ImagePoint(x: 300, y: 240)])])
    }

    @Test func aTapDrawsNothing() async {
        let box = Box(); let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, [CGPoint(x: 50, y: 50), CGPoint(x: 51, y: 51)])
        #expect(box.marks.isEmpty)
    }

    @Test func freehandRecordsThePath() async {
        let box = Box(); box.tool = .freehand
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, (0...10).map { CGPoint(x: 40 + Double($0) * 10, y: 100 + Double($0 % 3) * 5) })
        #expect(box.marks.count == 1 && box.marks[0].tool == .freehand && box.marks[0].points.count >= 3)
        #expect(box.marks.first?.points.first == ImagePoint(x: 80, y: 200))
    }

    @Test func aTextClickOpensADraftAndASecondClickCommitsIt() async {
        let box = Box(); box.tool = .text
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, [CGPoint(x: 60, y: 40)])
        #expect(box.draft?.point == ImagePoint(x: 120, y: 80))
        box.draft?.text = "Look here"
        await drag(w, [CGPoint(x: 200, y: 150)])   // a click elsewhere finishes it, and opens nothing new
        #expect(box.marks == [ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 120, y: 80)], text: "Look here")])
        #expect(box.draft == nil)
    }
}
