import Foundation

public struct MarkdownToRich: OutputModeTransformer {
    public let id = "builtin.markdowntorich"
    public let name = "Markdown → Rich Text"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.richText
    public let applicableKinds: Set<ContentKind>? = [.markdown]
    public let outputMode: OutputMode = .renderedMarkdown
    // Same MarkdownHTML.render pipeline MarkdownPreview caps at 16 KB for display; ~1.1 s at
    // 64 KB of list-heavy input (Plan 10 measurement) is the most the 3 s budget should be
    // asked to cover.
    public let maxInputBytes = 65_536

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
