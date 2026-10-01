import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// The mark queue (annotate spec): one mark applies at a time, none are dropped, each is one undo step.
@MainActor
@Suite("markup queue (annotate)")
struct MarkupQueueTests {
    private func png() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func host(_ f: ModelFixture) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func box(_ x: Int) -> ImageMark {
        ImageMark(tool: .box, color: .red, points: [ImagePoint(x: x, y: 20), ImagePoint(x: x + 40, y: 60)])
    }

    /// Review Focus 1.
    @Test func twoQuickMarksBothLand() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.queue")
        let original = try png()
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: original))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        f.model.enqueueMark(box(20))
        f.model.enqueueMark(ImageMark(tool: .arrow, color: .blue, points: [ImagePoint(x: 100, y: 100), ImagePoint(x: 200, y: 150)]))
        #expect(f.model.pendingMarks.count == 2)
        #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying })
        #expect(f.model.transformNote == "Arrow added.", "applied in order")
        let um = try #require(f.model.undoManager)
        #expect(um.undoActionName == "Arrow")
        um.undo()
        #expect(await f.eventually { um.undoActionName == "Box" })
        um.undo()
        #expect(await f.eventually { f.model.document?.imagePNG == original }, "two marks, two undo steps")
        #expect(f.settings.transformUsage.keys.allSatisfy { !$0.hasPrefix("builtin.annotate") }, "marks aren't transform uses")
    }

    /// #135: a label's size travels on its mark, so undo and redo replay it exactly as drawn.
    @Test func undoAndRedoReplayALabelsSize() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.size")
        let original = try png()
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: original))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        f.model.enqueueMark(ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 10, y: 10)], text: "Big", textSize: .xl))
        #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying && f.model.transformNote == "Text added." })
        let drawn = try #require(f.model.document?.imagePNG)
        let um = try #require(f.model.undoManager)
        um.undo()
        #expect(await f.eventually { f.model.document?.imagePNG == original })
        um.redo()
        #expect(await f.eventually { f.model.document?.imagePNG == drawn }, "redo restores the XL label byte for byte")
    }

    /// Review Focus 2.
    @Test func boundaryEmptiesTheQueue() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.boundary")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        f.model.enqueueMark(box(10)); f.model.enqueueMark(box(60)); f.model.enqueueMark(box(110))
        let second = try png()
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: second))
        #expect(f.model.pendingMarks.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(f.model.document?.imagePNG == second, "nothing from the old queue reached the new session")
    }

    @Test func aFailedMarkIsDroppedAndTheQueueMovesOn() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.fail")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        f.model.enqueueMark(ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 5, y: 5)], text: " "))   // nothing to draw
        f.model.enqueueMark(box(30))
        #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying })
        #expect(f.model.transformNote == "Box added.")
    }
}
