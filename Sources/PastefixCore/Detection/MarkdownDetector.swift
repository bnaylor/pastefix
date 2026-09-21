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
    private static let link = try! NSRegularExpression(pattern: #"\[[^\]]+\]\([^)\s]+\)"#)
    private static let inline = try! NSRegularExpression(pattern: #"(\*\*|__)\S.*?\S(\*\*|__)|`[^`\n]+`"#)

    public static func looksLikeMarkdown(_ text: String) -> Bool {
        var head = text
        if head.utf8.count > maxBytes { head = String(decoding: head.utf8.prefix(maxBytes), as: UTF8.self) }
        // Swift treats "\r\n" as a single Character, so splitting on "\n" alone never
        // breaks CRLF text into lines and every signal past the first is missed.
        head = head.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var signals: Set<String> = []
        for (i, lineSub) in head.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i >= maxLines { break }
            let line = String(lineSub)
            let r = NSRange(location: 0, length: (line as NSString).length)
            if heading.firstMatch(in: line, range: r) != nil || fence.firstMatch(in: line, range: r) != nil { return true }
            if list.firstMatch(in: line, range: r) != nil { signals.insert("list") }
            if quote.firstMatch(in: line, range: r) != nil { signals.insert("quote") }
            if table.firstMatch(in: line, range: r) != nil { signals.insert("table") }
            if link.firstMatch(in: line, range: r) != nil { signals.insert("link") }
            if inline.firstMatch(in: line, range: r) != nil { signals.insert("inline") }
            if signals.count >= 2 { return true }
        }
        return false
    }
}
