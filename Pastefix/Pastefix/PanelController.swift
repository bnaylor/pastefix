import AppKit

/// Owns the floating panel that hosts the SwiftUI editor. A panel (not a window)
/// so it can appear over full-screen apps without switching Spaces.
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    var onResignKey: (() -> Void)?   // wired for Plan 2b auto-hide-on-blur

    /// Last value handed to `setSidebarVisible`, so repeated calls are no-ops.
    private var sidebarVisible = false
    /// True only when *this* code grew the frame to make room for the sidebar. Hiding the
    /// sidebar hands that width back only if we took it; a panel the user sized (or one that
    /// was already wide enough) keeps its width, so toggling is never lossy.
    private var didWidenForSidebar = false

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
        panel.minSize = NSSize(width: PanelMetrics.minContentWidth, height: PanelMetrics.minContentHeight)
        panel.contentView = rootView
        super.init()
        panel.delegate = self
    }

    /// Widens the panel to make room for the transforms sidebar and narrows it again when
    /// the sidebar goes away, keeping the top-left corner fixed. Idempotent: calling it with
    /// the value already applied does nothing, so a settings write that doesn't flip the
    /// flag never nudges the frame. The SwiftUI `minWidth` alone can't do this — AppKit
    /// won't grow a window past its current frame just because its content wants more.
    func setSidebarVisible(_ visible: Bool, width: CGFloat = PanelMetrics.sidebarWidth) {
        // The floor tracks the content on *every* call, even the idempotent ones: SwiftUI's
        // `minWidth` states what the content needs, but only `minSize` stops the user dragging
        // the panel narrower than that and squeezing the editor to nothing behind the sidebar.
        panel.minSize = NSSize(
            width: visible ? PanelMetrics.minContentWidthWithSidebar : PanelMetrics.minContentWidth,
            height: PanelMetrics.minContentHeight
        )
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible

        let frame = panel.frame
        let contentWidth = panel.contentRect(forFrameRect: frame).width
        let targetContentWidth: CGFloat
        if visible {
            // Already wide enough to hold editor + sidebar: leave the user's size alone.
            guard contentWidth < PanelMetrics.minContentWidth + width else { return }
            targetContentWidth = contentWidth + width
            didWidenForSidebar = true
        } else {
            // Only hand back width we added, and only if it is still there to hand back.
            guard didWidenForSidebar, contentWidth >= PanelMetrics.minContentWidth + width else { return }
            didWidenForSidebar = false
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
