import Foundation

/// Rewrites each line as one identifier phrase in the chosen case style.
/// Splits on separators and camel boundaries; keeps digits with their word; keeps
/// non-ASCII letters (Transliterate owns ASCII folding).
public struct CaseConvert: Transformer {
    public enum Style: Sendable { case camel, snake, kebab, constant }

    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = nil
    public let category: String? = TransformCategory.case
    public let style: Style

    public init(style: Style) {
        self.style = style
        switch style {
        case .camel:    id = "builtin.case.camel";    name = "camelCase"
        case .snake:    id = "builtin.case.snake";    name = "snake_case"
        case .kebab:    id = "builtin.case.kebab";    name = "kebab-case"
        case .constant: id = "builtin.case.constant"; name = "CONSTANT_CASE"
        }
    }

    public func apply(_ input: TransformInput) async throws -> String {
        Self.convert(input.text, style: style)
    }

    static func convert(_ text: String, style: Style) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let trail = line.reversed().prefix { $0 == " " || $0 == "\t" || $0 == "\r" }
            let core = line.dropFirst(lead.count).dropLast(trail.count)
            let ws = words(in: String(core))
            guard !ws.isEmpty else { return line }
            return String(lead) + join(ws, style: style) + String(trail.reversed())
        }.joined(separator: "\n")
    }

    /// Lower-cased tokens. Boundaries: any non-letter/digit; lower→Upper; Upper-run→Upper+lower;
    /// digit→Upper. Letter↔digit inside a run does not split ("v2", "utf8").
    static func words(in line: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(line)
        func flush() { if !current.isEmpty { words.append(current.lowercased()); current = "" } }
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else { flush(); continue }
            if c.isUppercase, !current.isEmpty {
                let prev = chars[i - 1]
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if prev.isLowercase || prev.isNumber {
                    flush()
                } else if prev.isUppercase, let n = next, n.isLowercase {
                    flush()
                }
            }
            current.append(c)
        }
        flush()
        return words
    }

    private static func join(_ words: [String], style: Style) -> String {
        switch style {
        case .camel:
            guard let first = words.first else { return "" }
            return first + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case .snake: return words.joined(separator: "_")
        case .kebab: return words.joined(separator: "-")
        case .constant: return words.map { $0.uppercased() }.joined(separator: "_")
        }
    }
}
