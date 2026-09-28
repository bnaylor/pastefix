import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Swap: ImageTransformer {
    let id = "test.swap"; let name = "Swap"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.swap")
    let to: Data
    func transformImage(_ png: Data) throws -> TransformOutput { .image(to, note: "swapped") }
}

private struct Upper: Transformer {
    let id = "test.upper"; let name = "Upper"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text.uppercased() }
}

/// ⌘Z / ⌘⇧Z undo and redo while an image is showing (Plan 20 GUI pass: nothing bound ⌘Z to
/// Pastefix's undo, and an image session has no editor to take it). A text session keeps ⌘Z for the
/// editor's typing undo.
@MainActor
@Suite("⌘Z and ⌘⇧Z in an image session (Plan 20)")
struct ImageUndoShortcutTests {
    private func host(_ f: ModelFixture) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Presses until `landed` holds, for up to ~3 s. A disabled button takes no key equivalent,
    /// and the model being ready (`isApplying` false, `canUndo` true) says nothing about whether
    /// SwiftUI has re-rendered the button yet — the first draft pressed once, too early, and failed
    /// one run in two; the rendered SwiftUI buttons aren't `NSButton`s a test can inspect. Retrying
    /// is safe **only because the history here has one step**: once ⌘Z lands on the original a
    /// further ⌘Z is a no-op (`canUndo` false), and likewise ⌘⇧Z at the end.
    private func press(_ window: NSWindow, shift: Bool = false, until landed: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            press(window, shift: shift)
            try? await Task.sleep(nanoseconds: 50_000_000)
            if landed() { return true }
        }
        return false
    }

    private func press(_ window: NSWindow, shift: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: shift ? [.command, .shift] : .command,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     // The lowercase key plus the Shift flag, as the ⌘⇧M tests
                                     // build theirs: SwiftUI's matcher did not take a synthetic
                                     // "Z" (measured). Real-keyboard ⌘⇧Z is the GUI pass's check.
                                     characters: shift ? "Z" : "z", charactersIgnoringModifiers: "z",
                                     isARepeat: false, keyCode: 6)!
        _ = window.performKeyEquivalent(with: event)
    }

    @Test("⌘Z undoes and ⌘⇧Z redoes an image transform")
    func imageUndoRedo() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        let other = try #require(Pixels.encoded(width: 30, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        let window = host(f); defer { window.orderOut(nil) }
        f.model.apply(Swap(to: other))
        #expect(await f.eventually { f.model.document?.imagePNG == other })
        #expect(await press(window) { f.model.document?.imagePNG == png }, "⌘Z")
        #expect(await press(window, shift: true) { f.model.document?.imagePNG == other }, "⌘⇧Z")
        #expect(f.model.transformNote == "swapped")
    }

    @Test("in a text session ⌘Z is left to the editor and does not undo a transform")
    func textSessionUnaffected() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        f.model.apply(Upper())
        #expect(await f.eventually { f.model.document?.working == "HELLO" })
        press(window)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(f.model.document?.working == "HELLO")
    }
}
