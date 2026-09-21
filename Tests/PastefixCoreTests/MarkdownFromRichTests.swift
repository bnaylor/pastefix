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
    /// The shape browser content actually arrives in: WebKit bakes list markers into the text
    /// and styles them with the item's own font, which RTF serialisation then throws away.
    func html(_ source: String) throws -> NSAttributedString {
        try NSAttributedString(
            data: Data(source.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }
    func rtfdRoundTripped(_ a: NSAttributedString) throws -> String {
        let d = try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        return try MarkdownFromRich.convert(rtfd: d)
    }

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
        let a = try html("<h1>Title</h1><ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol><li>first</li><li>second</li></ol>")
        #expect(MarkdownFromRich.convert(a) == "# Title\n\n- one\n- two\n  - nested\n1. first\n2. second")
    }
    /// Only the tab-delimited marker AppKit bakes in is stripped. The RTF writer drops that
    /// marker text entirely, so an RTFD list item is *all* content — a looser pattern would
    /// silently eat the year out of "2024 was a year".
    @Test func listItemsStartingWithANumberKeepIt() throws {
        let source = try html("<ul><li>2024 was a year</li><li>3 things happened</li><li>normal item</li></ul>")
        #expect(try rtfdRoundTripped(source) == "- 2024 was a year\n- 3 things happened\n- normal item")
    }
    /// The marker has to come off the attributed string before styling: WebKit gives it the
    /// item's own font, so a string-level strip would be staring at "**•\tall bold item**".
    @Test func markerIsStrippedOutOfAWhollyStyledItem() throws {
        let a = try html("<ul><li><b>all bold item</b></li><li><i>italic item</i></li></ul>")
        #expect(MarkdownFromRich.convert(a) == "- **all bold item**\n- *italic item*")
    }
    /// A child indents past its *parent's* marker — three columns under "1. ", two under "- ".
    /// Two spaces under an ordered parent is one short and cmark flattens the whole list.
    @Test func nestedOrderedListIndentsToTheParentMarkerWidth() throws {
        let a = try html("<ol><li>a<ol><li>x</li><li>y</li></ol></li><li>b</li></ol>")
        let markdown = MarkdownFromRich.convert(a)
        #expect(markdown == "1. a\n   1. x\n   2. y\n2. b")
        #expect(try MarkdownHTML.render(markdown) == "<ol><li>a<ol><li>x</li><li>y</li></ol></li><li>b</li></ol>")
    }
    /// A heading is bold *because* it is a heading, so the hashes carry that and the `**` is
    /// dropped — but only the bold. Everything else inside the line still has to survive.
    @Test func headingSuppressesBoldButKeepsOtherStyling() throws {
        let big = NSFont.boldSystemFont(ofSize: 26)
        let m = NSMutableAttributedString(string: "Head ", attributes: [.font: big])
        m.append(NSAttributedString(string: "x", attributes: [.font: NSFontManager.shared.convert(big, toHaveTrait: .italicFontMask)]))
        m.append(NSAttributedString(string: " tail\n", attributes: [.font: big]))
        m.append(para("body"))
        #expect(MarkdownFromRich.convert(m) == "# Head *x* tail\n\nbody")
        #expect(MarkdownFromRich.convert(try html("<h2>See <a href=\"https://x.y\">docs</a> now</h2><p>body</p>"))
                == "## See [docs](https://x.y/) now\n\nbody")
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
    @Test func attachmentsDroppedAndTablesFlattened() throws {
        let att = NSAttributedString(attachment: NSTextAttachment())
        let m = NSMutableAttributedString(attributedString: para("before")); m.append(att); m.append(para("after"))
        #expect(MarkdownFromRich.convert(m) == "before\n\nafter")

        // Each cell is its own paragraph; cells sharing a row are rejoined with " | ".
        let table = NSTextTable()
        func cell(_ s: String, row: Int, column: Int) -> NSAttributedString {
            let ps = NSMutableParagraphStyle()
            ps.textBlocks = [NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)]
            return NSAttributedString(string: s + "\n", attributes: [.font: body, .paragraphStyle: ps])
        }
        #expect(MarkdownFromRich.convert(cell("cell", row: 0, column: 0)) == "cell")
        #expect(md([cell("a", row: 0, column: 0), cell("b", row: 0, column: 1)]) == "a | b")
        // No header separator: RTF has no notion of a header row, so we don't invent one.
        #expect(MarkdownFromRich.convert(try html("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>"))
                == "a | b\nc | d")
    }
    /// A cell is identified by row *and* column, so its paragraphs stay one column wide, an
    /// empty one holds its place, and a literal pipe can't forge a column break.
    @Test func tableCellsKeepTheirColumns() throws {
        #expect(MarkdownFromRich.convert(try html("<table><tr><td>a<br>b</td><td>c</td></tr><tr><td>d</td><td>e</td></tr></table>"))
                == "a b | c\nd | e")
        #expect(MarkdownFromRich.convert(try html("<table><tr><td>a</td><td></td></tr><tr><td>c</td><td>d</td></tr></table>"))
                == "a |\nc | d")
        #expect(MarkdownFromRich.convert(try html("<table><tr><td>x|y</td><td>z</td></tr></table>"))
                == #"x\|y | z"#)
    }
    @Test func rtfdRoundTrip() throws {
        // headerLevel does not survive RTF serialisation; a round-tripped heading is big bold text.
        let a = doc([para("Title", font: NSFont.boldSystemFont(ofSize: 26)), para("body")])
        let d = try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        #expect(try MarkdownFromRich.convert(rtfd: d).hasPrefix("# Title"))
    }
}
