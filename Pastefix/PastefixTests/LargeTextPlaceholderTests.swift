import Testing
import AppKit
import SwiftUI
import PastefixAppCore
@testable import Pastefix

/// Over 1 MB the panel shows a placeholder instead of laying the text out (#52, #62). Layout was
/// ~1 s per MB on the main thread (measured in this host: 1.0 s at 1 MB, 19 s at 17 MB).
@MainActor
@Suite("large buffers show a placeholder, not a laid-out editor (#52)")
struct LargeTextPlaceholderTests {
    private func hasTextView(_ view: NSView) -> Bool {
        view is NSTextView || view.subviews.contains { hasTextView($0) }
    }

    private func host(_ f: ModelFixture) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.contentView = view
        return (window, view)
    }

    @Test("3 MB renders without an editor, fast, and shrinking the text brings the editor back")
    func placeholder() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let line = "lorem ipsum dolor sit amet, consectetur\n"
        f.model.beginSession(from: ClipboardSnapshot(
            plainText: String(repeating: line, count: 3 * 1_048_576 / line.utf8.count), richRTFD: nil))
        let (window, view) = host(f)
        defer { window.orderOut(nil) }
        let shown = ContinuousClock().measure {
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
        }
        // ~3 s with the editor laid out; the bound leaves room for the parallel suite.
        #expect(shown < .seconds(1), "the panel took \(shown) to show a 3 MB buffer")
        #expect(!hasTextView(view), "the editor was laid out anyway")

        f.model.setWorking("short now")
        #expect(await f.eventually { self.hasTextView(view) }, "under the limit, the editor is back")
    }

    @Test("under the limit, the editor is there as always")
    func smallBufferHasEditor() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let (window, view) = host(f)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        #expect(await f.eventually { self.hasTextView(view) })
    }
}
