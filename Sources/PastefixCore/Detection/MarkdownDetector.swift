import Foundation

/// Conservative Markdown sniff for the Detected badge and palette promotion.
public enum MarkdownDetector {
    static let maxBytes = 65_536
    static let maxLines = 400

    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6} \S"#)
    private static let fence = try! NSRegularExpression(pattern: #"^(```|~~~)"#)
    private static let list = try! NSRegularExpression(pattern: #"^\s{0,3}([-*+]|\d+[.)]) \S"#)
    private static let quote = try! NSRegularExpression(pattern: #"^> "#)
    private static let table = try! NSRegularExpression(pattern: #"^\|.+\|\s*$"#)
    // Quantifiers are bounded ({1,300} / {1,1000}) so a line with many unclosed
    // "[" can't force quadratic backtracking (unbounded "+" tries a full-length
    // scan from every "[").
    private static let link = try! NSRegularExpression(pattern: #"\[[^\]]{1,300}\]\([^)\s]{1,1000}\)"#)
    private static let inline = try! NSRegularExpression(pattern: #"(\*\*|__)\S.{0,300}?\S(\*\*|__)|`[^`\n]+`"#)
    // Lines longer than this skip the link/inline scans below (still O(line) each,
    // but not worth paying even that on a pathological single giant line); the
    // anchored single-shot patterns above (heading/fence/list/quote/table) stay
    // linear regardless of length, so they still run.
    private static let maxScannedLineLength = 4_096

    public static func looksLikeMarkdown(_ text: String) -> Bool {
        var head = text
        if head.utf8.count > maxBytes { head = String(decoding: head.utf8.prefix(maxBytes), as: UTF8.self) }
        // Swift treats "\r\n" as a single Character, so splitting on "\n" alone never
        // breaks CRLF text into lines and every signal past the first is missed.
        head = head.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A shebang is as unambiguous a "this is a script" signal as exists: scripts are pasted
        // often and their `# comment` lines would otherwise satisfy the one-signal heading rule.
        if head.drop(while: { $0.isWhitespace }).hasPrefix("#!") { return false }
        var signals: Set<String> = []
        for (i, lineSub) in head.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i >= maxLines { break }
            let line = String(lineSub)
            let r = NSRange(location: 0, length: (line as NSString).length)
            if heading.firstMatch(in: line, range: r) != nil || fence.firstMatch(in: line, range: r) != nil { return true }
            if list.firstMatch(in: line, range: r) != nil { signals.insert("list") }
            if quote.firstMatch(in: line, range: r) != nil { signals.insert("quote") }
            if table.firstMatch(in: line, range: r) != nil { signals.insert("table") }
            if line.utf16.count <= maxScannedLineLength {
                if link.firstMatch(in: line, range: r) != nil { signals.insert("link") }
                if inline.firstMatch(in: line, range: r) != nil { signals.insert("inline") }
            }
            if signals.count >= 2 { return true }
        }
        return false
    }
}
