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
}
