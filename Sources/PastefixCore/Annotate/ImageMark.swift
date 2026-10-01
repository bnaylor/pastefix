import Foundation

/// A point on an image in its oriented pixels, origin top-left (the space `ImageRegion` uses).
public struct ImagePoint: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// One markup mark (annotate spec): what markup mode hands `AnnotateImage` to burn in.
/// Box, arrow and highlight use two points (press, release); freehand the stroke's points;
/// text one point (the text box's top-left) and `text`.
public struct ImageMark: Sendable, Equatable, Codable {
    public enum Tool: String, Sendable, Codable, CaseIterable { case box, arrow, text, highlight, freehand }
    public enum Color: String, Sendable, Codable, CaseIterable { case red, yellow, blue, black, white }
    /// A label's size (#135): S/M/L/XL, multiples of the base text size. M is the default.
    public enum TextSize: String, Sendable, Codable, CaseIterable { case s, m, l, xl }

    public let tool: Tool
    public let color: Color
    public let points: [ImagePoint]
    public let text: String?
    /// The label's size, chosen when the label was drawn: a queued label is burned at it even if the
    /// strip's size has changed since. (Undo and redo restore image snapshots; they don't re-render.)
    /// Ignored by shapes.
    public let textSize: TextSize

    public init(tool: Tool, color: Color, points: [ImagePoint], text: String? = nil, textSize: TextSize = .m) {
        self.tool = tool; self.color = color; self.points = points; self.text = text; self.textSize = textSize
    }
}

public extension ImageMark.Tool {
    /// The transform's name, which is also the undo action's.
    var name: String {
        switch self {
        case .box: "Box"
        case .arrow: "Arrow"
        case .text: "Text"
        case .highlight: "Highlight"
        case .freehand: "Freehand"
        }
    }
    var note: String {
        switch self {
        case .box: "Box added."
        case .arrow: "Arrow added."
        case .text: "Text added."
        case .highlight: "Highlight added."
        case .freehand: "Drawing added."
        }
    }
}

public extension ImageMark.TextSize {
    var scale: Double {
        switch self {
        case .s: 1
        case .m: 1.5
        case .l: 2
        case .xl: 3
        }
    }
    var label: String { rawValue.uppercased() }
}

public extension ImageMark.Color {
    /// sRGB components.
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: (0.92, 0.20, 0.18)
        case .yellow: (1.00, 0.80, 0.00)
        case .blue: (0.16, 0.45, 0.96)
        case .black: (0, 0, 0)
        case .white: (1, 1, 1)
        }
    }
    /// The text halo: white under dark colours, black under light ones.
    var halo: ImageMark.Color { self == .yellow || self == .white ? .black : .white }
}
