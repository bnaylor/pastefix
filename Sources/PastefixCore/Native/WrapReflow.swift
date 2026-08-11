import Foundation

public struct WrapReflow: Transformer {
    public let id = "builtin.wrapreflow"
    public let name = "Wrap & Reflow"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let width: Int

    public init(width: Int) {
        self.width = width
    }

    public func apply(_ input: TransformInput) async throws -> String {
        Self.reflow(input.text, width: width)
    }

    private static func reflow(_ text: String, width: Int) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let wrapped = paragraphs.map { reflowParagraph($0, width: width) }
        return wrapped.joined(separator: "\n\n")
    }

    private static func reflowParagraph(_ para: String, width: Int) -> String {
        let words = para.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count > width {
                lines.append(current)
                current = String(word)
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}
