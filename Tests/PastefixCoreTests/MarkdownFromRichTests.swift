import Testing
import AppKit
@testable import PastefixCore

@Suite struct MarkdownFromRichTests {
    let body = NSFont.systemFont(ofSize: 13)
    func para(_ s: String, font: NSFont? = nil, header: Int = 0, lists: [NSTextList] = [], link: String? = nil, strike: Bool = false) -> NSAttributedString {
        let ps = NSMutableParagraphStyle(); ps.headerLevel = header; ps.textLists = lists
        var attrs: [NSAttributedString.Key: Any] = [.font: font ?? body, .paragraphStyle: ps]
        if let link { attrs[.link] = URL(string: link)! }
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: s + "\n", attributes: attrs)
    }
    func doc(_ parts: [NSAttributedString]) -> NSAttributedString { let m = NSMutableAttributedString(); parts.forEach(m.append); return m }
    func md(_ parts: [NSAttributedString]) -> String { MarkdownFromRich.convert(doc(parts)) }

    @Test func headerLevelBecomesHashes() {
        #expect(md([para("Title", header: 2), para("body")]) == "## Title\n\nbody")
    }
    @Test func sizeHeuristicForRTF() {
        let big = NSFont.boldSystemFont(ofSize: 26), mid = NSFont.boldSystemFont(ofSize: 19)
        #expect(md([para("Big", font: big), para("Mid", font: mid), para("body"), para("body two")]) == "# Big\n\n## Mid\n\nbody\n\nbody two")
    }
    @Test func bulletAndNestedLists() {
        let l1 = NSTextList(markerFormat: .disc, options: 0), l2 = NSTextList(markerFormat: .circle, options: 0)
        #expect(md([para("\t•\tone", lists: [l1]), para("\t◦\ttwo", lists: [l1, l2]), para("\t•\tthree", lists: [l1])]) == "- one\n  - two\n- three")
    }
    @Test func numberedList() {
        let l = NSTextList(markerFormat: .decimal, options: 0)
        #expect(md([para("\t1.\tfirst", lists: [l]), para("\t2.\tsecond", lists: [l])]) == "1. first\n2. second")
    }
    /// WebKit writes an ordered-list marker as a bare number, so the "1." form alone isn't enough.
    @Test func listMarkersFromHTMLAreStripped() throws {
        let html = "<h1>Title</h1><ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol><li>first</li><li>second</li></ol>"
        let a = try NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        #expect(MarkdownFromRich.convert(a) == "# Title\n\n- one\n- two\n  - nested\n1. first\n2. second")
    }
    @Test func boldItalicWithEdgeSpaces() {
        let m = NSMutableAttributedString(string: "plain ", attributes: [.font: body])
        m.append(NSAttributedString(string: "bold ", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        m.append(NSAttributedString(string: "italic", attributes: [.font: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)]))
        m.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        #expect(MarkdownFromRich.convert(m) == "plain **bold** *italic*")
    }
    @Test func linkStrikeAndInlineCode() {
        let m = NSMutableAttributedString(string: "see ", attributes: [.font: body])
        m.append(para("docs", link: "https://x.y/d").attributedSubstring(from: NSRange(location: 0, length: 4)))
        m.append(NSAttributedString(string: " or ", attributes: [.font: body]))
        m.append(NSAttributedString(string: "x", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        m.append(NSAttributedString(string: " gone", attributes: [.font: body, .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        m.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        #expect(MarkdownFromRich.convert(m) == "see [docs](https://x.y/d) or `x` ~~gone~~")
    }
    @Test func monoParagraphsBecomeOneFence() {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        #expect(md([para("intro"), para("let a = 1", font: mono), para("let b = 2", font: mono), para("after")]) == "intro\n\n```\nlet a = 1\nlet b = 2\n```\n\nafter")
    }
    @Test func attachmentsDroppedAndTablesFlattened() {
        let att = NSAttributedString(attachment: NSTextAttachment())
        let m = NSMutableAttributedString(attributedString: para("before")); m.append(att); m.append(para("after"))
        #expect(MarkdownFromRich.convert(m) == "before\n\nafter")
        let ps = NSMutableParagraphStyle(); ps.textBlocks = [NSTextTableBlock(table: NSTextTable(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)]
        let cell = NSAttributedString(string: "cell\n", attributes: [.font: body, .paragraphStyle: ps])
        #expect(MarkdownFromRich.convert(cell) == "cell")
    }
    @Test func rtfdRoundTrip() throws {
        // headerLevel does not survive RTF serialisation; a round-tripped heading is big bold text.
        let a = doc([para("Title", font: NSFont.boldSystemFont(ofSize: 26)), para("body")])
        let d = try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        #expect(try MarkdownFromRich.convert(rtfd: d).hasPrefix("# Title"))
    }
}
