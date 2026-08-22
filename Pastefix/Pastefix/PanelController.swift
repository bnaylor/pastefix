import AppKit

/// Owns the floating panel that hosts the SwiftUI editor. A panel (not a window)
/// so it can appear over full-screen apps without switching Spaces.
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    var onResignKey: (() -> Void)?   // wired for Plan 2b auto-hide-on-blur

    init(rootView: NSView) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.contentView = rootView
        super.init()
        panel.delegate = self
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
