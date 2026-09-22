import Testing
import AppKit
@testable import PastefixAppCore

@MainActor
@Suite struct MarkdownPreviewTests {
    private func runs(_ s: NSAttributedString) -> [(String, [NSAttributedString.Key: Any])] {
        var out: [(String, [NSAttributedString.Key: Any])] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            out.append(((s.string as NSString).substring(with: range), attrs))
        }
        return out
    }
    private func font(_ attrs: [NSAttributedString.Key: Any]) -> NSFont? { attrs[.font] as? NSFont }

    // The size assertions pin the *stylesheet*, not the importer: h1 is larger than body text
    // even unstyled, so a test that only compares the two stays green with `stylesheet = ""`.
    @Test func headingIsLargerThanBody() {
        let s = MarkdownPreview.attributedString(markdown: "# Title\n\nbody text")
        let all = runs(s)
        let h = all.first { $0.0.contains("Title") }.flatMap { font($0.1) }
        let b = all.first { $0.0.contains("body") }.flatMap { font($0.1) }
        #expect(h != nil && b != nil && h!.pointSize > b!.pointSize)
        #expect(h?.pointSize == 22, "h1 should come from the stylesheet, not the importer's default")
    }
    // Likewise: `<code>` imports as Courier carrying `.monoSpace` with no stylesheet at all, so
    // the family name is what proves our `code{font-family:Menlo}` rule survived the import.
    @Test func inlineCodeIsMonospaced() {
        let s = MarkdownPreview.attributedString(markdown: "call `foo()` now")
        let code = runs(s).first { $0.0 == "foo()" }.flatMap { font($0.1) }
        #expect(code != nil && code!.fontDescriptor.symbolicTraits.contains(.monoSpace))
        // Bound to a local first: `#expect` on an optional-chained receiver expands to a call
        // check whose result is discarded, and the expectation then never fails.
        let family = code?.familyName ?? "nil"
        #expect(family.contains("Menlo"), "expected the stylesheet's Menlo, got \(family)")
    }
    @Test func foregroundColoursStrippedExceptLinks() {
        let s = MarkdownPreview.attributedString(markdown: "plain **bold** and [site](https://a.b)")
        for (text, attrs) in runs(s) {
            if attrs[.link] != nil { #expect(text == "site") }
            else { #expect(attrs[.foregroundColor] == nil, "run \(text) still carries a colour") }
        }
        // The exception half of the name: without the carve-out in `stripForegroundColors` the
        // link run comes back colourless like everything else.
        let link = runs(s).first { $0.1[.link] != nil }
        #expect(link != nil)
        #expect(link?.1[.foregroundColor] != nil, "the link run should keep its colour")
    }
    @Test func overCapReturnsNotice() {
        let s = MarkdownPreview.attributedString(markdown: String(repeating: "a", count: MarkdownPreview.maxBytes + 1))
        #expect(s.string == MarkdownPreview.notice)
        #expect(MarkdownPreview.notice.contains("16 KB") && MarkdownPreview.notice.contains("200 list items"))
    }
    // Bytes are not the cost driver — list structure is, and a list can blow the time budget
    // well inside the byte cap.
    @Test func overListCapReturnsNotice() {
        let list = (1...(MarkdownPreview.maxListItems + 1)).map { "- item \($0)" }.joined(separator: "\n")
        #expect(list.utf8.count <= MarkdownPreview.maxBytes, "this case must be under the byte cap to test the list cap")
        #expect(MarkdownPreview.attributedString(markdown: list).string == MarkdownPreview.notice)
        let justUnder = (1...MarkdownPreview.maxListItems).map { "- item \($0)" }.joined(separator: "\n")
        #expect(MarkdownPreview.attributedString(markdown: justUnder).string != MarkdownPreview.notice)
    }
    @Test func malformedStillRendersSomething() {
        let s = MarkdownPreview.attributedString(markdown: "[unclosed(\n\n**bold")
        #expect(!s.string.isEmpty && s.string.contains("bold"))
    }
    // The importer writes each marker twice — literal "\t•\t" text plus an NSTextList that
    // TextKit 2 draws itself — so a list rendered with two bullets until the styles were cleaned.
    @Test func listsCarryNoTextList() {
        let s = MarkdownPreview.attributedString(markdown: "- one\n- two")
        var lists: [NSTextList] = []
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            lists += (value as? NSParagraphStyle)?.textLists ?? []
        }
        #expect(lists.isEmpty)
        #expect(s.string.contains("one"))
    }
    @Test func imagesProduceNoAttachment() {
        let s = MarkdownPreview.attributedString(markdown: "![p](https://example.invalid/pixel.png) text")
        #expect(!s.string.contains("\u{FFFC}") && s.string.contains("text"))
    }
}
