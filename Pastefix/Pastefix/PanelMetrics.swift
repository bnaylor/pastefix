import CoreGraphics

/// Sizes shared by the SwiftUI panel views and the AppKit `PanelController`.
///
/// These numbers have to agree: SwiftUI states the content's minimum via `.frame(minWidth:)`,
/// AppKit enforces it via `NSPanel.minSize`, and `setSidebarVisible` resizes the frame by
/// exactly the sidebar's width. When they drift, the sidebar squeezes the editor or the
/// window can be dragged narrower than its content — so they live here, in one place.
enum PanelMetrics {
    /// Narrowest content the editor alone is usable at.
    static let minContentWidth: CGFloat = 560
    /// Shortest content the editor is usable at.
    static let minContentHeight: CGFloat = 380
    /// Width of the transforms sidebar column.
    static let sidebarWidth: CGFloat = 220
    /// Narrowest content that fits the editor *and* the sidebar.
    static var minContentWidthWithSidebar: CGFloat { minContentWidth + sidebarWidth }
    /// Widest the ⌘K palette card grows to; it shrinks below this on a narrow panel.
    static let paletteCardWidth: CGFloat = 520
}
