import Foundation
import CoreGraphics

/// Where the panel sits (#26): its size, and its position as a fraction of the room it has to move
/// in on its display — 0 at the left/bottom edge, 1 at the right/top — rather than in points. So
/// a panel dragged to the top-right corner of one display opens in the top-right corner of
/// another, whatever their sizes. Saved when the user moves or resizes the panel; applied to the
/// display with the mouse on each summon.
public struct PanelPlacement: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    /// Position within the free space, each clamped to 0...1.
    public var x: Double
    public var y: Double

    /// The placement of `frame` on a display whose usable area is `visible`.
    public init(frame: CGRect, in visible: CGRect) {
        width = frame.width
        height = frame.height
        let size = Self.fitted(CGSize(width: frame.width, height: frame.height), in: visible)
        x = Self.fraction(frame.minX - visible.minX, room: visible.width - size.width)
        y = Self.fraction(frame.minY - visible.minY, room: visible.height - size.height)
    }

    /// The frame this placement gives on a display whose usable area is `visible`: the saved
    /// size, shrunk to fit if the display is smaller, at the same relative position.
    public func frame(in visible: CGRect) -> CGRect {
        let size = Self.fitted(CGSize(width: width, height: height), in: visible)
        return CGRect(x: visible.minX + x * (visible.width - size.width),
                      y: visible.minY + y * (visible.height - size.height),
                      width: size.width, height: size.height)
    }

    /// With nothing saved: `size` (fitted), centred — what `NSWindow.center()` did on every summon.
    public static func centred(size: CGSize, in visible: CGRect) -> CGRect {
        let fitted = fitted(size, in: visible)
        return CGRect(x: visible.midX - fitted.width / 2, y: visible.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private static func fitted(_ size: CGSize, in visible: CGRect) -> CGSize {
        CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    }

    private static func fraction(_ offset: Double, room: Double) -> Double {
        guard room > 0 else { return 0.5 }
        return min(max(offset / room, 0), 1)
    }
}
