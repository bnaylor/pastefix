import Testing
import AppKit
import PastefixAppCore
@testable import Pastefix

/// #26: the panel opened centred on every summon. It now opens where the user last put it, at the
/// same relative spot on the display with the mouse, and saves each move.
@MainActor
@Suite("panel remembers where it was put (#26)")
struct PanelPositionTests {
    private func mouseScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    @Test func opensAtTheSavedPlacement() throws {
        let visible = try #require(mouseScreen()).visibleFrame
        let saved = PanelPlacement(frame: CGRect(x: visible.maxX - 700, y: visible.maxY - 500, width: 700, height: 500), in: visible)
        let controller = PanelController(rootView: NSView())
        controller.loadPlacement = { saved }
        controller.show(); defer { controller.hide() }
        #expect(controller.panel.frame == saved.frame(in: visible))
    }

    @Test func centresWhenNothingIsSaved() throws {
        let visible = try #require(mouseScreen()).visibleFrame
        let controller = PanelController(rootView: NSView())
        let size = controller.panel.frame.size
        controller.show(); defer { controller.hide() }
        #expect(controller.panel.frame == PanelPlacement.centred(size: size, in: visible))
    }

    @Test func aMoveIsSaved() throws {
        let controller = PanelController(rootView: NSView())
        var saved: PanelPlacement?
        controller.savePlacement = { saved = $0 }
        controller.show(); defer { controller.hide() }
        let visible = try #require(controller.panel.screen).visibleFrame
        controller.panel.setFrameOrigin(NSPoint(x: visible.minX + 5, y: visible.minY + 5))
        #expect(saved == PanelPlacement(frame: controller.panel.frame, in: visible))
    }

    /// GUI pass: with the sidebar shown at launch (`setSidebarVisible(true)` widens the default size
    /// and remembers that it did), a restored placement was treated as if the sidebar had widened
    /// it — the first hide took the sidebar's width out of a size the user chose, and #126 then
    /// saved the smaller size. A restored size is the user's: hiding the sidebar keeps it.
    @Test func hidingTheSidebarKeepsARestoredSize() throws {
        let visible = try #require(mouseScreen()).visibleFrame
        let chosen = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 946, height: 560)
        let controller = PanelController(rootView: NSView())
        controller.loadPlacement = { PanelPlacement(frame: chosen, in: visible) }
        controller.setSidebarVisible(true)                  // as at launch, before any summon
        controller.show(); defer { controller.hide() }
        #expect(controller.panel.frame.width == 946)
        controller.setSidebarVisible(false)
        #expect(controller.panel.frame.width == 946, "hiding the sidebar took width from the user's size")
    }
}
