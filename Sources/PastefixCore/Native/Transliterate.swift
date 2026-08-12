import Foundation

public struct Transliterate: Transformer {
    public let id = "builtin.transliterate"
    public let name = "Transliterate to ASCII"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        Self.transliterate(input.text)
    }

    static let punctuation: [(String, String)] = [
        ("\u{2018}", "'"), ("\u{2019}", "'"),        // ' '
        ("\u{201C}", "\""), ("\u{201D}", "\""),      // " "
        ("\u{2013}", "-"), ("\u{2014}", "--"),       // – —
        ("\u{2026}", "..."),                          // …
        ("\u{00A0}", " "),                            // nbsp
    ]

    static func transliterate(_ text: String) -> String {
        var s = text
        for (from, to) in punctuation {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // é → e, ü → u, etc.
        let stripped = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        // Drop anything still outside ASCII (dingbats, CJK, emoji).
        let scalars = stripped.unicodeScalars.filter { $0.isASCII }
        return String(String.UnicodeScalarView(scalars))
    }
}
