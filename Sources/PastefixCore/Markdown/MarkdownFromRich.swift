import Foundation
import AppKit

/// RTFD → GitHub-flavoured Markdown. Best effort: headings, lists, emphasis, links, code;
/// tables flattened, attachments dropped.
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

    struct Line { var text: String; var isCode: Bool; var isList: Bool }

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
            guard content.length > 0 else { lines.append(Line(text: "", isCode: false, isList: false)); continue }
            let attrs = a.attributes(at: content.location, effectiveRange: nil)
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let sub = a.attributedSubstring(from: content)

            // Table cells are flattened to plain lines; Markdown tables need a shape RTF
            // doesn't reliably give us (header row, column count), so we don't guess.
            if !(ps?.textBlocks.isEmpty ?? true) {
                lines.append(Line(text: inlineMarkdown(sub), isCode: false, isList: false)); continue
            }
            if isWholly(sub, where: isMono) {
                lines.append(Line(text: sub.string, isCode: true, isList: false)); continue
            }
            var text = inlineMarkdown(sub)
            if let lists = ps?.textLists, let list = lists.last {
                text = stripMarker(text)
                let indent = String(repeating: "  ", count: lists.count - 1)
                if list.markerFormat.rawValue.contains("decimal") {
                    let n = (listCounters[ObjectIdentifier(list)] ?? (list.startingItemNumber - 1)) + 1
                    listCounters[ObjectIdentifier(list)] = n
                    text = "\(indent)\(n). \(text)"
                } else {
                    text = "\(indent)- \(text)"
                }
                lines.append(Line(text: text, isCode: false, isList: true)); continue
            }
            let level = headingLevel(sub, headerLevel: ps?.headerLevel ?? 0, bodySize: bodySize)
            if level > 0 { text = String(repeating: "#", count: level) + " " + stripEmphasis(text) }
            lines.append(Line(text: text, isCode: false, isList: false))
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

    private static func inlineMarkdown(_ s: NSAttributedString) -> String {
        let ns = s.string as NSString
        var runs: [(style: Style, text: String)] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            let text = ns.substring(with: range)
            // Attachments (images, files) are placeholder characters with no text of their own.
            if text.allSatisfy({ $0 == "\u{FFFC}" }) { return }
            var style = Style()
            if let font = attrs[.font] as? NSFont {
                style.mono = isMono(font)
                style.bold = isBold(font)
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

    // MARK: - Text fixups

    /// A wholly bold heading has already been wrapped in `**` by `inlineMarkdown`; the
    /// hashes say "heading" on their own.
    static func stripEmphasis(_ text: String) -> String {
        var s = text
        for marker in ["**", "*", "~~"] {
            while s.hasPrefix(marker), s.hasSuffix(marker), s.count > 2 * marker.count {
                s = String(s.dropFirst(marker.count).dropLast(marker.count))
            }
        }
        return s
    }

    // The trailing "." / ")" is optional because WebKit's HTML → attributed conversion writes
    // an ordered-list marker as a bare number ("\t1\tfirst"), not "\t1.\tfirst".
    private static let markerPattern = try! NSRegularExpression(pattern: #"^[\t ]*([•◦▪‣\-\*]|\d+[.)]?)?[\t ]+"#)

    /// AppKit bakes the list marker into the paragraph text (`"\t1.\tfirst"`); we re-emit
    /// our own, so the original has to go. Only ever called on list paragraphs — on ordinary
    /// prose the number branch would happily eat a leading year.
    static func stripMarker(_ text: String) -> String {
        let ns = text as NSString
        guard let m = markerPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        return ns.substring(from: NSMaxRange(m.range))
    }
}
