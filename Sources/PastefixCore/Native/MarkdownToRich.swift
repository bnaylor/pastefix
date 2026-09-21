import Foundation

public struct MarkdownToRich: OutputModeTransformer {
    public let id = "builtin.markdowntorich"
    public let name = "Markdown → Rich Text"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.richText
    public let applicableKinds: Set<ContentKind>? = [.markdown]
    public let outputMode: OutputMode = .renderedMarkdown

    public init() {}

    /// Validates the buffer parses; the text is returned unchanged — the effect is the armed output mode.
    public func apply(_ input: TransformInput) async throws -> String {
        do {
            _ = try MarkdownHTML.render(input.text)
        } catch {
            throw TransformError.invalidInput("Couldn't parse this as Markdown")
        }
        return input.text
    }
}
