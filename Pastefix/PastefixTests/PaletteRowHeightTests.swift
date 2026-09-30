import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// #26: the palette's list was sized as `rows × 44`, but a row renders 47 pt at the default text
/// size (measured), so the eighth row was always clipped. The list is sized from the real rows.
@MainActor
@Suite("palette list fits its rows (#26)")
struct PaletteRowHeightTests {
    private func tables(in v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables) }

    @Test func eightRowsShowWhole() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: CommandPaletteView(model: f.model, scope: nil, onClose: {}))
        window.makeKeyAndOrderFront(nil)
        #expect(await f.eventually { (self.tables(in: window.contentView!).first?.numberOfRows ?? 0) >= 8 })
        let table = try #require(tables(in: window.contentView!).first)
        let needed = (0..<8).map { table.rect(ofRow: $0).height }.reduce(0, +)
        #expect(await f.eventually {
            let visible = table.enclosingScrollView?.contentView.bounds.height ?? 0
            return visible >= needed - 0.5 && visible <= needed + 0.5
        }, "visible \(table.enclosingScrollView?.contentView.bounds.height ?? -1) for rows needing \(needed)")
    }
}
