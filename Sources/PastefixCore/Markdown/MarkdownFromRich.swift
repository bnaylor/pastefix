import Foundation
import AppKit

/// RTFD → GitHub-flavoured Markdown. Best effort: headings, lists, emphasis, links, code;
/// tables become pipe-separated rows without a header separator, attachments are dropped.
///
/// Two things are worth knowing about the source material. RTF carries no heading concept
/// — `NSParagraphStyle.headerLevel` survives an HTML→attributed conversion (how browser
/// content reaches us) but is *not* serialised into RTF/RTFD — so anything arriving as RTFD
/// only shows a heading as large bold text, and the size heuristic below is the only way to
/// recover it. And list paragraphs arrive with their marker glyph baked into the text
/// (`"\t•\tone"`), which has to be stripped before the Markdown marker is prepended.
public enum MarkdownFromRich {
    public static func convert(rtfd: Data) throws -> String {
        let a = try NSAttributedString(
            data: rtfd,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        return convert(a)
    }

    /// Which table cell a line came from, so `join` can put a row back on one line. The
    /// column matters as much as the row: a cell holding two paragraphs (`<td>a<br>b</td>`)
    /// produces two lines with the same ref, and those are one cell, not two columns.
    struct CellRef: Equatable { var table: ObjectIdentifier; var row: Int; var column: Int }

    struct Line {
        var text: String
        var isCode = false
        var isList = false
        var cell: CellRef?
    }

    static func convert(_ a: NSAttributedString) -> String {
        let ns = a.string as NSString
        let bodySize = dominantPointSize(a)
        var lines: [Line] = []
        var listCounters: [ObjectIdentifier: Int] = [:]
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            guard pr.length > 0 else { break }
            defer { loc = NSMaxRange(pr) }
            let content = NSRange(location: pr.location, length: pr.length - newlineSuffixLength(ns, pr))
            // Read the style off the paragraph's first character rather than its content: an
            // empty cell is a bare newline, and its table block only lives on that newline.
            let attrs = a.attributes(at: pr.location, effectiveRange: nil)
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let sub = a.attributedSubstring(from: content)

            // A table cell is its own paragraph; `join` stitches a row back together from the
            // block's table identity, row and column. No header separator is emitted — RTF has
            // no notion of a header row, so guessing one would misrepresent the table. This is
            // checked before the empty-content guard so an empty cell holds its column open
            // instead of dropping out and shifting everything after it one place left.
            if !(ps?.textBlocks.isEmpty ?? true) {
                let block = ps?.textBlocks.compactMap { $0 as? NSTextTableBlock }.last
                let cell = block.map { CellRef(table: ObjectIdentifier($0.table), row: $0.startingRow, column: $0.startingColumn) }
                var text = content.length > 0 ? inlineMarkdown(sub) : ""
                // A literal pipe would otherwise read as a column break once the row is joined.
                if cell != nil { text = text.replacingOccurrences(of: "|", with: #"\|"#) }
                lines.append(Line(text: text, cell: cell)); continue
            }
            guard content.length > 0 else { lines.append(Line(text: "")); continue }
            if isWholly(sub, where: isMono) {
                lines.append(Line(text: sub.string, isCode: true)); continue
            }
            if let lists = ps?.textLists, let list = lists.last {
                // Strip the baked marker from the *attributed* string, before styling: when the
                // marker shares the item's run (WebKit gives it the item's own font) a later
                // string-level strip would be looking at "**•\tall bold item**" and miss it.
                var text = inlineMarkdown(strippingMarker(sub))
                let indent = String(repeating: " ", count: lists.dropLast().reduce(0) { $0 + markerWidth($1) })
                if isOrdered(list) {
                    let n = (listCounters[ObjectIdentifier(list)] ?? (list.startingItemNumber - 1)) + 1
                    listCounters[ObjectIdentifier(list)] = n
                    text = "\(indent)\(n). \(text)"
                } else {
                    text = "\(indent)- \(text)"
                }
                lines.append(Line(text: text, isList: true)); continue
            }
            let level = headingLevel(sub, headerLevel: ps?.headerLevel ?? 0, bodySize: bodySize)
            // The paragraph being wholly bold is what made it a heading, so re-emitting that
            // bold as `**` would just be noise; italic, code, strikethrough and links stay.
            var text = inlineMarkdown(sub, suppressingBold: level > 0)
            if level > 0 { text = String(repeating: "#", count: level) + " " + text }
            lines.append(Line(text: text))
        }
        return join(lines)
    }

    // MARK: - Blocks

    /// Paragraph ranges include their terminator; CRLF is two UTF-16 units, not one.
    private static func newlineSuffixLength(_ ns: NSString, _ pr: NSRange) -> Int {
        guard pr.length > 0 else { return 0 }
        let last = ns.character(at: NSMaxRange(pr) - 1)
        guard last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029 else { return 0 }
        if last == 0x0A, pr.length > 1, ns.character(at: NSMaxRange(pr) - 2) == 0x0D { return 2 }
        return 1
    }

    /// Consecutive code paragraphs collapse into one fence and consecutive list items stay
    /// single-spaced; everything else is separated by a blank line. Empty paragraphs only
    /// separate — they never survive as a line of their own.
    private static func join(_ lines: [Line]) -> String {
        var blocks: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let first = line.cell {
                var rows: [String] = []
                var row: [String] = []
                var paragraphs: [String] = []          // the paragraphs of the cell being built
                var current = first
                func closeCell() { row.append(paragraphs.filter { !$0.isEmpty }.joined(separator: " ")); paragraphs = [] }
                while i < lines.count, let cell = lines[i].cell, cell.table == first.table {
                    if cell != current {
                        closeCell()
                        if cell.row != current.row { rows.append(row.joined(separator: " | ")); row = [] }
                        current = cell
                    }
                    paragraphs.append(trimTrailing(lines[i].text))
                    i += 1
                }
                closeCell()
                rows.append(row.joined(separator: " | "))
                blocks.append(rows.map(trimTrailing).joined(separator: "\n"))
                continue
            }
            if line.isCode {
                var block = ["```"]
                while i < lines.count, lines[i].isCode { block.append(lines[i].text); i += 1 }
                block.append("```")
                blocks.append(block.joined(separator: "\n"))
                continue
            }
            if line.isList {
                var block: [String] = []
                while i < lines.count, lines[i].isList { block.append(trimTrailing(lines[i].text)); i += 1 }
                blocks.append(block.joined(separator: "\n"))
                continue
            }
            i += 1
            let text = trimTrailing(line.text)
            if !text.isEmpty { blocks.append(text) }
        }
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimTrailing(_ s: String) -> String {
        var out = Substring(s)
        while let last = out.last, last.isWhitespace { out = out.dropLast() }
        return String(out)
    }

    // MARK: - Inline

    /// The inline styling of one run. Adjacent runs that compare equal are merged before
    /// wrapping, so a font change that carries no Markdown meaning can't split `**bold**`
    /// into `**bo****ld**`.
    private struct Style: Equatable {
        var mono = false
        var bold = false
        var italic = false
        var strike = false
        var link: String?

        var isPlain: Bool { !mono && !bold && !italic && !strike && link == nil }
    }

    /// `suppressingBold` is set for headings. Dropping bold from the style *before* the runs
    /// are merged is what makes `bold("Head ") + boldItalic("x") + bold(" tail")` collapse to
    /// `Head *x* tail`: the two plain runs now compare equal to nothing in between them.
    private static func inlineMarkdown(_ s: NSAttributedString, suppressingBold: Bool = false) -> String {
        let ns = s.string as NSString
        var runs: [(style: Style, text: String)] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            let text = ns.substring(with: range)
            // Attachments (images, files) are placeholder characters with no text of their own.
            if text.allSatisfy({ $0 == "\u{FFFC}" }) { return }
            var style = Style()
            if let font = attrs[.font] as? NSFont {
                style.mono = isMono(font)
                style.bold = isBold(font) && !suppressingBold
                style.italic = isItalic(font)
            }
            if let raw = attrs[.strikethroughStyle] as? Int, raw != 0 { style.strike = true }
            if let url = attrs[.link] as? URL { style.link = url.absoluteString }
            else if let str = attrs[.link] as? String { style.link = str }

            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append((style, text))
            }
        }
        return runs.map { wrap($0.text, in: $0.style) }.joined()
    }

    /// Markdown emphasis markers must hug the text: `"bold "` has to become `"**bold** "`,
    /// not `"**bold **"`, which most parsers won't close.
    private static func wrap(_ text: String, in style: Style) -> String {
        guard !style.isPlain else { return text }
        var core = Substring(text)
        let lead = core.prefix { $0.isWhitespace }
        core = core.dropFirst(lead.count)
        var trailCount = 0
        while let last = core.last, last.isWhitespace { core = core.dropLast(); trailCount += 1 }
        guard !core.isEmpty else { return text }

        var out = String(core)
        if style.mono { out = "`\(out)`" }
        if style.bold { out = "**\(out)**" }
        if style.italic { out = "*\(out)*" }
        if style.strike { out = "~~\(out)~~" }
        if let link = style.link { out = "[\(out)](\(link))" }
        return lead + out + text.suffix(trailCount)
    }

    // MARK: - Fonts

    static func isMono(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let family = font.familyName ?? ""
        return ["Menlo", "Monaco", "Courier", "Mono"].contains { family.contains($0) }
    }

    static func isBold(_ font: NSFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(.bold) }
    static func isItalic(_ font: NSFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(.italic) }

    private static func isWholly(_ s: NSAttributedString, where predicate: (NSFont) -> Bool) -> Bool {
        guard s.length > 0 else { return false }
        var all = true
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            guard let font = value as? NSFont, predicate(font) else { all = false; stop.pointee = true; return }
        }
        return all
    }

    /// The body text size, used as the denominator of the heading heuristic. Bold text is
    /// excluded because headings *are* the bold text — letting them vote would make a
    /// document whose only paragraph is a heading its own baseline, and nothing would ever
    /// look large. 13 (the system body size) when there is no unbolded text to measure.
    static func dominantPointSize(_ a: NSAttributedString) -> CGFloat {
        var tally: [CGFloat: Int] = [:]
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { value, range, _ in
            guard let font = value as? NSFont, !isBold(font) else { return }
            tally[font.pointSize, default: 0] += range.length
        }
        // Ties break towards the larger size so the baseline can't drift small.
        return tally.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 13
    }

    private static func maxPointSize(_ s: NSAttributedString) -> CGFloat {
        var maximum: CGFloat = 0
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let font = value as? NSFont { maximum = max(maximum, font.pointSize) }
        }
        return maximum
    }

    static func headingLevel(_ s: NSAttributedString, headerLevel: Int, bodySize: CGFloat) -> Int {
        if headerLevel > 0 { return min(headerLevel, 6) }
        guard isWholly(s, where: isBold) else { return 0 }
        let size = maxPointSize(s)
        if size >= bodySize * 1.8 { return 1 }
        if size >= bodySize * 1.4 { return 2 }
        if size >= bodySize * 1.15 { return 3 }
        return 0
    }

    // MARK: - List markers

    static func isOrdered(_ list: NSTextList) -> Bool { list.markerFormat.rawValue.contains("decimal") }

    /// The content column of the Markdown marker we emit: `"1. "` is three, `"- "` is two.
    /// A nested item has to be indented past its *parent's* marker or cmark reads it as a
    /// sibling rather than a child — two spaces under an ordered parent flattens the list.
    private static func markerWidth(_ list: NSTextList) -> Int { isOrdered(list) ? 3 : 2 }

    // Deliberately narrow: a marker glyph or number *delimited by a tab*, which is the only
    // shape AppKit and WebKit produce ("\t•\tone", "\t1.\tfirst", and WebKit's unpunctuated
    // "\t1\tfirst"). Anything looser eats real content, because the RTF writer drops the baked
    // marker entirely — an RTFD list item reading "2024 was a year" is all content.
    private static let markerPattern = try! NSRegularExpression(pattern: #"^\t?(?:[•◦▪‣\-\*]|\d+[.)]?)\t"#)

    /// Removes AppKit's baked-in list marker, attributes and all, so inline styling sees only
    /// the item's own text.
    static func strippingMarker(_ s: NSAttributedString) -> NSAttributedString {
        let ns = s.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = markerPattern.firstMatch(in: s.string, range: full) else { return s }
        return s.attributedSubstring(from: NSRange(location: m.range.length, length: ns.length - m.range.length))
    }
}
