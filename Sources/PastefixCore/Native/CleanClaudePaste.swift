import Foundation

/// Cleans text copied out of a Claude Code terminal session for pasting into Slack, Google Chat or a
/// doc: every line carries a 2-space margin, paragraphs and bullets are hard-wrapped at the
/// terminal's width, and UI chrome (⏺ markers, "✻ Churned for 11s" status lines, "(ctrl+o to
/// expand)") comes along. This undoes all three and leaves the real structure alone.
///
/// Unwrapping is the careful part. A line is joined to the one before it only when BOTH hold:
/// - the previous line was full: its width + a space + the next line's first word would not fit in
///   the wrap width, taken as the widest line in the paste — so the terminal broke it there;
/// - the line is indented exactly as that paragraph's or list item's continuation.
/// Anything that starts structure (a bullet, a numbered item, a heading, a quote, a table row, a code
/// fence) always starts a new line, and nothing inside a ``` fence is joined.
///
/// Known limit: a deliberate line break right after the widest line, with the next line at the same
/// indent, looks exactly like a wrap and is joined. Claude Code renders Markdown, so a hard break
/// inside a paragraph is rare; list items always break correctly.
public struct CleanClaudePaste: Transformer {
    public let id = "builtin.claudepaste"
    public let name = "Clean Claude Code Paste"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.layout

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        Self.clean(input.text)
    }

    /// Below this, a paste is too narrow to have come from a terminal wrap at all.
    static let minimumWrapWidth = 40

    private static let structural = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+•]\s|\d+[.)]\s|#{1,6}\s|>|\||│|┌|├|└|```)"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^(\s*)((?:[-*+•]|\d+[.)])\s+)"#)
    private static let statusLine = try! NSRegularExpression(pattern: #"^\s*✻ "#)
    private static let expandHint = try! NSRegularExpression(pattern: #"\(ctrl\+\w to [\w ]+\)\s*$"#)

    static func clean(_ text: String) -> String {
        // 1. Chrome. Markers become spaces, not nothing, so continuation lines keep lining up.
        var kept: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if matches(statusLine, raw) || matches(expandHint, raw) { continue }
            var line = replacingPrefix(raw, marker: "⏺ ", with: "  ")
            line = replacingPrefix(line, marker: "⎿  ", with: "   ")
            line = replacingPrefix(line, marker: "⎿ ", with: "   ")
            line = replacingPrefix(line, marker: "❯ ", with: "> ")
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            kept.append(line)
        }

        // 2. The wrap width: the widest line, measured before anything moves.
        let wrap = kept.map(\.count).max() ?? 0

        // 3. Unwrap, tracking the continuation indent of the logical line being built and the
        //    width of its last physical segment.
        var out: [String] = []
        var inFence = false
        var continuationIndent: Int?
        var lastSegment = 0
        for line in kept {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```")
            if isFence { inFence.toggle() }
            if !inFence, !trimmed.isEmpty, !out.isEmpty, let indent = continuationIndent,
               wrap >= minimumWrapWidth, !matches(structural, line), indentOf(line) == indent,
               lastSegment + 1 + firstWord(trimmed).count > wrap {
                out[out.count - 1] += " " + trimmed
                lastSegment = line.count
                continue
            }
            out.append(line)
            lastSegment = line.count
            if trimmed.isEmpty || isFence || inFence { continuationIndent = nil; continue }
            continuationIndent = listContinuationIndent(line) ?? indentOf(line)
        }

        // 4. Drop the common margin (the replies'; a "> " prompt line sits at column 0), then tidy
        //    blank lines.
        let margin = out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("> ") }
            .map(indentOf).min() ?? 0
        var result: [String] = []
        for line in out {
            let dropped = String(line.dropFirst(min(margin, indentOf(line))))
            if dropped.isEmpty, result.last?.isEmpty ?? true { continue }   // collapse blank runs
            result.append(dropped)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.isEmpty ? "" : result.joined(separator: "\n") + "\n"
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `marker` after leading whitespace, replaced by `replacement`.
    private static func replacingPrefix(_ s: String, marker: String, with replacement: String) -> String {
        let indent = s.prefix { $0 == " " }
        guard s.dropFirst(indent.count).hasPrefix(marker) else { return s }
        return indent + replacement + s.dropFirst(indent.count + marker.count)
    }

    private static func indentOf(_ s: String) -> Int { s.prefix { $0 == " " || $0 == "\t" }.count }

    private static func firstWord(_ trimmed: String) -> Substring {
        trimmed.prefix { !$0.isWhitespace }
    }

    /// For "  - item" or "  12. item", the column the item's wrapped text continues at.
    private static func listContinuationIndent(_ line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = listMarker.firstMatch(in: line, range: range),
              let whole = Range(m.range, in: line) else { return nil }
        return line[whole].count
    }
}
