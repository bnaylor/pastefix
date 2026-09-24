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

    /// A heading or fence line is decisive on its own and returns `true` immediately, as before.
    /// Otherwise five *weak* signals (list, quote, table, link, inline emphasis/code) are each
    /// counted only when they reach density: a signal qualifies when the lines it matched are at
    /// least 10% of the non-blank lines scanned, and `looksLikeMarkdown` returns `true` only when
    /// at least two distinct signals qualify.
    ///
    /// The presence-only version of this rule ("two distinct weak signals matched anywhere in the
    /// scanned head") mistook a 427 KB `%`-separated fortunes file for Markdown: its dialogue
    /// dashes and `> `-prefixed lines occasionally look like a list item or a blockquote, and
    /// scattered across the file that is only ~4% and ~1% of lines respectively — but the old rule
    /// fired the instant one of each turned up anywhere in the scanned window, however rare. The
    /// 10% density floor requires a signal to actually recur before it counts in long text (10% of
    /// 400 lines is 40 matches), while genuinely Markdown-shaped text stays as it was: a short
    /// snippet such as two list items and one link line is 33% link lines, so the floor is a
    /// proportion on purpose and not an absolute minimum.
    ///
    /// Density is measured over the same scanned head as before: at most `maxBytes` (64 KB) of the
    /// buffer and at most `maxLines` (400) lines of it. A signal that only shows up past that
    /// window is invisible to this function exactly as it always was.
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        var head = text
        if head.utf8.count > maxBytes { head = String(decoding: head.utf8.prefix(maxBytes), as: UTF8.self) }
        // Swift treats "\r\n" as a single Character, so splitting on "\n" alone never
        // breaks CRLF text into lines and every signal past the first is missed.
        head = head.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A shebang is as unambiguous a "this is a script" signal as exists: scripts are pasted
        // often and their `# comment` lines would otherwise satisfy the one-signal heading rule.
        if head.drop(while: { $0.isWhitespace }).hasPrefix("#!") { return false }
        var nonEmptyLines = 0
        var listLines = 0, quoteLines = 0, tableLines = 0, linkLines = 0, inlineLines = 0
        for (i, lineSub) in head.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i >= maxLines { break }
            if lineSub.allSatisfy(\.isWhitespace) { continue }   // blank lines do not dilute density
            nonEmptyLines += 1
            let line = String(lineSub)
            let r = NSRange(location: 0, length: (line as NSString).length)
            if heading.firstMatch(in: line, range: r) != nil || fence.firstMatch(in: line, range: r) != nil { return true }
            if list.firstMatch(in: line, range: r) != nil { listLines += 1 }
            if quote.firstMatch(in: line, range: r) != nil { quoteLines += 1 }
            if table.firstMatch(in: line, range: r) != nil { tableLines += 1 }
            if line.utf16.count <= maxScannedLineLength {
                if link.firstMatch(in: line, range: r) != nil { linkLines += 1 }
                if inline.firstMatch(in: line, range: r) != nil { inlineLines += 1 }
            }
        }
        func qualifies(_ matchedLines: Int) -> Bool { matchedLines > 0 && matchedLines * 10 >= nonEmptyLines }
        let qualifying = [listLines, quoteLines, tableLines, linkLines, inlineLines].filter(qualifies).count
        return qualifying >= 2
    }
}
