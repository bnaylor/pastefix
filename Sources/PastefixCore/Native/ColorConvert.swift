import Foundation

/// Rewrites a colour literal in another CSS/Swift notation.
public struct ColorConvert: Transformer {
    public enum Style: Sendable { case hex, rgb, hsl, swift }
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.color]
    public let category: String? = TransformCategory.colors
    public let style: Style

    public init(style: Style) {
        self.style = style
        switch style {
        case .hex:   id = "builtin.color.hex";   name = "Color → CSS Hex"
        case .rgb:   id = "builtin.color.rgb";   name = "Color → CSS rgb()"
        case .hsl:   id = "builtin.color.hsl";   name = "Color → CSS hsl()"
        case .swift: id = "builtin.color.swift"; name = "Color → SwiftUI Color"
        }
    }

    public func apply(_ input: TransformInput) async throws -> String {
        guard let c = ColorLiteral.parse(input.text) else { throw TransformError.invalidInput("Not a color literal") }
        switch style {
        case .hex: return c.cssHex
        case .rgb: return c.cssRGB
        case .hsl: return c.cssHSL
        case .swift: return c.swiftUI
        }
    }
}
