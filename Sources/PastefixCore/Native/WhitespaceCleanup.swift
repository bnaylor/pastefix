import Foundation

public struct WhitespaceCleanup: Transformer {
    public let id = "builtin.whitespace"
    public let name = "Whitespace Cleanup"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        Self.clean(input.text)
    }

    static func clean(_ text: String) -> String {
        var out: [String] = []
        var previousBlank = false
        for rawLine in text.components(separatedBy: "\n") {
            var line = Substring(rawLine)
            while let f = line.first, f == " " || f == "\t" { line = line.dropFirst() }
            while let l = line.last, l == " " || l == "\t" { line = line.dropLast() }
            let blank = line.isEmpty
            if blank && previousBlank { continue }
            out.append(String(line))
            previousBlank = blank
        }
        return out.joined(separator: "\n")
    }
}
