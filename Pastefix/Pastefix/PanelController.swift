import AppKit

/// Owns the floating panel that hosts the SwiftUI editor. A panel (not a window)
/// so it can appear over full-screen apps without switching Spaces.
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    var onResignKey: (() -> Void)?   // wired for Plan 2b auto-hide-on-blur

    /// Narrowest content the editor is usable at; mirrors PanelView's `minWidth`.
    private static let minContentWidth: CGFloat = 560
    /// Last value handed to `setSidebarVisible`, so repeated calls are no-ops.
    private var sidebarVisible = false

    init(rootView: NSView) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.minSize = NSSize(width: Self.minContentWidth, height: 380)
        panel.contentView = rootView
        super.init()
        panel.delegate = self
    }

    /// Widens the panel to make room for the transforms sidebar and narrows it again when
    /// the sidebar goes away, keeping the top-left corner fixed. Idempotent: calling it with
    /// the value already applied does nothing, so a settings write that doesn't flip the
    /// flag never nudges the frame. The SwiftUI `minWidth` alone can't do this — AppKit
    /// won't grow a window past its current frame just because its content wants more.
    func setSidebarVisible(_ visible: Bool, width: CGFloat = 220) {
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible

        let frame = panel.frame
        let contentWidth = panel.contentRect(forFrameRect: frame).width
        let targetContentWidth: CGFloat
        if visible {
            // Already wide enough to hold editor + sidebar: leave the user's size alone.
            guard contentWidth < Self.minContentWidth + width else { return }
            targetContentWidth = contentWidth + width
        } else {
            // Only hand the space back if it's actually there to hand back.
            guard contentWidth >= Self.minContentWidth + width else { return }
            targetContentWidth = contentWidth - width
        }

        var newFrame = frame
        newFrame.size.width = panel.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: targetContentWidth, height: 0)
        ).width
        // Height is unchanged; pin the top edge explicitly so the panel grows rightwards only.
        newFrame.origin.y = frame.maxY - newFrame.height

        // Stay on screen: never wider than the visible frame, and slide left rather than
        // hang off the right edge.
        if let visibleFrame = panel.screen?.visibleFrame {
            newFrame.size.width = min(newFrame.width, visibleFrame.width)
            if newFrame.maxX > visibleFrame.maxX {
                newFrame.origin.x = visibleFrame.maxX - newFrame.width
            }
            if newFrame.minX < visibleFrame.minX {
                newFrame.origin.x = visibleFrame.minX
            }
        }

        panel.setFrame(newFrame, display: true, animate: panel.isVisible)
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }
}
