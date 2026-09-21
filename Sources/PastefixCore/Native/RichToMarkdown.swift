import Foundation
import AppKit

public struct RichToMarkdown: Transformer {
    public let id = "builtin.richtomarkdown"
    public let name = "Rich → Markdown"
    public let requiresRichInput = true
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.richText

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        guard let data = input.richRTFD else {
            throw TransformError.richInputUnavailable
        }
        return try MarkdownFromRich.convert(rtfd: data)
    }
}
