import Testing
import AppKit
import SwiftUI
import PastefixAppCore
@testable import Pastefix

/// ⌘Y toggles the history overlay, every time (#73).
///
/// It used to work twice: ⌘Y opened, ⌘Y closed, and every later ⌘Y did nothing until some other
/// overlay cycle. The close went through a hidden ⌘Y button inside the overlay while the toolbar
/// dropped its own ⌘Y and re-added it in the same update, and SwiftUI lost the re-added toolbar
/// registration. Measured here, not reasoned about: the loss follows the button's *position in
/// the view tree* (in the action bar the same swap survived), not its style, the key, the
/// animation, or the overlay's content. So the fix is not to swap: the toolbar keeps ⌘Y while the
/// overlay is open and toggles it.
///
/// The overlay is observed through its search field in the view tree, not through the key event's
/// "handled" answer: any handler claiming ⌘Y returns true, so a string of trues proves nothing
/// about open and closed.
@MainActor
@Suite("⌘Y toggles the history overlay every time (#73)")
struct HistoryShortcutTests {
    private func textFields(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField { out.append(field.placeholderString ?? "") }
        for sub in view.subviews { out += textFields(in: sub) }
        return out
    }

    private func hasEditor(in view: NSView) -> Bool {
        view is NSTextView || view.subviews.contains { hasEditor(in: $0) }
    }

    private func press(_ chars: String, keyCode: UInt16, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: keyCode)!
        _ = window.performKeyEquivalent(with: event)
    }

    @Test("⌘Y opens and closes the overlay, repeatedly, and still does after a ⌘K cycle")
    func toggles() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let historyOpen = { self.textFields(in: host).contains("Search clipboard history") }
        // A positive readiness signal, not "the overlay is absent": absence is true before the
        // first render too, when no shortcut is registered yet and a press goes nowhere. Every
        // later "closed" check follows an asserted "open", so none of them can pass vacuously.
        #expect(await f.eventually { self.hasEditor(in: host) }, "the panel rendered")
        #expect(!historyOpen(), "starts closed")

        // Six presses, because the failure was the third: open, close, then dead.
        for (step, expectOpen) in [true, false, true, false, true, false].enumerated() {
            press("y", keyCode: 16, in: window)
            #expect(await f.eventually { historyOpen() == expectOpen },
                    "⌘Y #\(step + 1) should leave the overlay \(expectOpen ? "open" : "closed")")
        }
        // The old recovery path must not be needed, and must not break it either.
        // Each press waits for its own effect: two back-to-back presses both land before the
        // palette renders, and the "cycle" never happens.
        let paletteOpen = { self.textFields(in: host).contains("Transform…") }
        press("k", keyCode: 40, in: window)
        #expect(await f.eventually { paletteOpen() }, "⌘K opens the palette")
        press("k", keyCode: 40, in: window)
        #expect(await f.eventually { !paletteOpen() }, "⌘K closes it")
        press("y", keyCode: 16, in: window)
        #expect(await f.eventually { historyOpen() }, "⌘Y after a ⌘K cycle opens")
        press("y", keyCode: 16, in: window)
        #expect(await f.eventually { !historyOpen() }, "and closes")
    }
}
