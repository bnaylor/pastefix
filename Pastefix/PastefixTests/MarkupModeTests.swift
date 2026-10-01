import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

@MainActor
@Suite("markup mode (annotate)")
struct MarkupModeTests {
    /// Review Focus 5, and the whole Esc order, as a pure decision.
    @Test func escapeOrder() {
        func a(palette: Bool = false, history: Bool = false, upload: Bool = false, preview: Bool = false,
               text: Bool = false, markup: Bool = false, region: Bool = false) -> PanelEscape {
            PanelEscape.action(paletteOpen: palette, historyOpen: history, uploadOpen: upload, previewing: preview,
                               textDraftOpen: text, markupMode: markup, regionUp: region)
        }
        #expect(a(palette: true, text: true, markup: true) == .closePalette)
        #expect(a(history: true, markup: true) == .closeHistory)
        #expect(a(upload: true, markup: true) == .closeUpload)
        #expect(a(preview: true, text: true) == .closePreview)
        #expect(a(text: true, markup: true, region: true) == .discardText)
        #expect(a(markup: true, region: true) == .leaveMarkup)
        #expect(a(region: true) == .clearRegion)
        #expect(a() == .cancel)
    }

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
    private func key(_ w: NSWindow, _ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        _ = w.performKeyEquivalent(with: e)
    }
    private func toggle(_ w: NSWindow) { key(w, "a", 0, [.command, .shift]) }
    private func esc(_ w: NSWindow) { key(w, "\u{1b}", 53, []) }

    @Test func shortcutTogglesOnlyInImageSessions() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "text", richRTFD: nil))
        let w = host(f); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        toggle(w); try await Task.sleep(for: .milliseconds(150))
        #expect(!f.model.markupModeOnScreen, "no markup mode in a text session")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        try await Task.sleep(for: .milliseconds(150))
        toggle(w)
        #expect(await f.eventually { f.model.markupModeOnScreen })
        toggle(w)
        #expect(await f.eventually { !f.model.markupModeOnScreen })
    }

    @Test func escLeavesMarkupThenCancels() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let w = host(f); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        toggle(w)
        #expect(await f.eventually { f.model.markupModeOnScreen })
        esc(w)
        #expect(await f.eventually { !f.model.markupModeOnScreen })
        #expect(f.model.document != nil, "the first Esc only left markup mode")
        esc(w)
        #expect(await f.eventually { f.model.document == nil })
    }

    @Test func aSessionBoundaryLeavesMarkup() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let w = host(f); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        toggle(w)
        #expect(await f.eventually { f.model.markupModeOnScreen })
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        #expect(await f.eventually { !f.model.markupModeOnScreen })
    }
}
