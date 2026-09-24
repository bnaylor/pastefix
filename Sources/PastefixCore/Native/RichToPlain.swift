import Foundation
import AppKit

public struct RichToPlain: Transformer {
    public let id = "builtin.richtoplain"
    public let name = "Rich → Plain Text"
    public let requiresRichInput = true
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.richText
    // RTFD, images included, is routinely megabytes; 4 MB of RTFD imports in well under the 3 s
    // budget. The bound is on the rich data because that is what this transform reads.
    public let maxInputBytes = 4 * 1_048_576

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        guard let data = input.richRTFD else {
            throw TransformError.richInputUnavailable
        }
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        return attributed.string
    }
}
