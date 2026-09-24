import Foundation
import AppKit

public struct RichToMarkdown: Transformer {
    public let id = "builtin.richtomarkdown"
    public let name = "Rich → Markdown"
    public let requiresRichInput = true
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.richText
    // RTFD, images included, is routinely megabytes; the bound is on the rich data because that
    // is what this transform reads. Measured on text-heavy RTF (many alternating bold/regular
    // 20-char runs, not one big image — the worst case for import cost, not for byte count):
    // 1 MB → 0.02 s, 2 MB → 0.05 s, 4 MB → 0.09 s on an Apple M4 Pro. All three are far under the
    // 1.5 s half-budget (half of the 3 s timeout, since the import observes no cancellation and
    // the cap is the only bound), so the cap stays the largest of the three candidates measured.
    public let maxInputBytes = 4 * 1_048_576

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        guard let data = input.richRTFD else {
            throw TransformError.richInputUnavailable
        }
        return try MarkdownFromRich.convert(rtfd: data)
    }
}
