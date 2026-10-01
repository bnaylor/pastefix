import Testing
import AppKit
import SwiftUI
import Combine
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Slow: Transformer {
    let id = "test.slow"; let name = "Slow"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { try await Task.sleep(for: .milliseconds(400)); return input.text }
}

/// Annotate final review: C1 (queue vs cancel/abandon), I1 (a landing mark must not kill a stroke),
/// I2 (no drawing while a non-mark transform runs), I3 (Esc with the label field focused).
@MainActor
@Suite("markup, final review fixes (annotate)")
struct MarkupReviewFixTests {
    static func png(_ w: Int = 300, _ h: Int = 200) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func host(_ f: ModelFixture) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func mark(_ tool: ImageMark.Tool, _ x: Int) -> ImageMark {
        ImageMark(tool: tool, color: .red, points: [ImagePoint(x: x, y: 20), ImagePoint(x: x + 40, y: 60)])
    }
    private func mouse(_ w: NSWindow, _ type: NSEvent.EventType, _ p: CGPoint) {
        let height = w.contentView!.bounds.height
        w.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    /// C1(a): a session switch with marks queued must not leave the new session "applying".
    @Test func sessionSwitchWithMarksQueuedLeavesNothingApplying() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.c1a")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try Self.png()))
        f.model.enqueueMark(mark(.box, 10)); f.model.enqueueMark(mark(.box, 60)); f.model.enqueueMark(mark(.box, 110))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try Self.png()))
        #expect(await f.eventually { !f.model.isApplying }, "stuck applying in the new session")
        f.model.enqueueMark(mark(.arrow, 30))
        #expect(await f.eventually { f.model.transformNote == "Arrow added." && f.model.pendingMarks.isEmpty })
    }

    /// C1(b): ⌘Z with a mark in flight and one queued undoes the last LANDED mark; the queued ones
    /// still land, each its own step, and the stack matches the document.
    @Test func undoWhileMarksArePendingKeepsTheStackStraight() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.c1b")
        let original = try Self.png()
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: original))
        let w = host(f); defer { w.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        let um = try #require(f.model.undoManager)
        f.model.enqueueMark(mark(.box, 10))
        #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying })
        f.model.enqueueMark(mark(.arrow, 60)); f.model.enqueueMark(mark(.highlight, 110))
        um.undo()                                                     // the arrow is in flight
        #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying }, "the queue resumed and drained")
        #expect(um.undoActionName == "Highlight", "top: \(um.undoActionName)")
        um.undo()
        #expect(await f.eventually { um.undoActionName == "Arrow" })
        um.undo()
        #expect(await f.eventually { f.model.document?.imagePNG == original }, "box undone first, then arrow and highlight")
        #expect(!um.canUndo)
    }

    /// I2: drawing is off while a transform the user chose runs (its result may move the pixels a
    /// queued mark was drawn on), and on while a mark applies.
    @Test func drawingIsOffDuringAUserTransform() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "x", richRTFD: nil))
        f.model.apply(Slow())
        #expect(f.model.isApplyingNonMark)
        #expect(await f.eventually { !f.model.isApplying })
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.i2")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try Self.png()))
        f.model.enqueueMark(mark(.box, 10))
        #expect(f.model.isApplying && !f.model.isApplyingNonMark, "a mark applying leaves drawing on")
    }

    final class Box: ObservableObject {
        @Published var revision = 0
        @Published var enabled = true
        @Published var draft: TextDraft?
        var region: ImageRegion?
        var marks: [ImageMark] = []
    }
    private struct SessionHost: View {
        @ObservedObject var box: Box
        let png: Data
        var body: some View {
            ImageSessionView(imagePNG: png, revision: box.revision,
                             region: Binding(get: { box.region }, set: { box.region = $0 }), interactive: true,
                             markup: MarkupConfig(tool: .box, color: .red, pending: [], textDraft: $box.draft,
                                                  enabled: box.enabled, onMark: { box.marks.append($0) }))
                .frame(width: 324, height: 300)
        }
    }

    /// I1: a mark landing (a new revision) in the middle of the next stroke must not end that stroke.
    @Test func aStrokeSurvivesARevisionChange() async throws {
        let box = Box()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 324, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: SessionHost(box: box, png: try Self.png(600, 400)))
        w.makeKeyAndOrderFront(nil); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))                 // first decode
        mouse(w, .leftMouseDown, CGPoint(x: 120, y: 110)); await Task.yield()
        mouse(w, .leftMouseDragged, CGPoint(x: 150, y: 130)); await Task.yield()
        box.revision += 1                                              // a mark landed
        try await Task.sleep(for: .milliseconds(250))                 // its decode
        mouse(w, .leftMouseDragged, CGPoint(x: 180, y: 150)); await Task.yield()
        mouse(w, .leftMouseUp, CGPoint(x: 200, y: 160))
        try await Task.sleep(for: .milliseconds(80))
        #expect(box.marks.count == 1, "marks: \(box.marks)")
    }

    /// I2, the overlay half: disabled, it draws nothing.
    @Test func aDisabledOverlayDrawsNothing() async throws {
        let box = Box(); box.enabled = false
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 324, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: SessionHost(box: box, png: try Self.png(600, 400)))
        w.makeKeyAndOrderFront(nil); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        mouse(w, .leftMouseDown, CGPoint(x: 120, y: 110)); await Task.yield()
        mouse(w, .leftMouseDragged, CGPoint(x: 200, y: 160)); await Task.yield()
        mouse(w, .leftMouseUp, CGPoint(x: 200, y: 160))
        try await Task.sleep(for: .milliseconds(80))
        #expect(box.marks.isEmpty)
    }

    final class StripBox: ObservableObject {
        @Published var tool: ImageMark.Tool = .text
        @Published var color: ImageMark.Color = .red
        @Published var draft: TextDraft? = TextDraft(point: ImagePoint(x: 10, y: 10), viewPoint: .zero, text: "half-typed")
        var committed = 0
    }
    private struct StripHost: View {
        @ObservedObject var box: StripBox
        var body: some View {
            MarkupStrip(tool: $box.tool, color: $box.color, textDraft: $box.draft, commitText: { box.committed += 1 }, done: {})
                .frame(width: 640)
        }
    }

    /// I3: a real Esc keyDown, through NSApp, with the strip's label field focused, discards the
    /// label. (The field editor gets Esc first; the panel-level order is `PanelEscape`'s, tested as a
    /// pure decision — in-process, clicks in the full panel don't reach the overlay, so a draft
    /// can't be opened there by mouse; measured.)
    @Test func escWithTheLabelFieldFocused() async throws {
        let box = StripBox()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: StripHost(box: box))
        w.makeKeyAndOrderFront(nil); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(w.firstResponder is NSTextView, "the label field has focus: \(String(describing: w.firstResponder))")
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApplication.shared.sendEvent(esc)
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.draft == nil, "Esc discarded the label")
        #expect(box.committed == 0, "and didn't add it")
    }
}
