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

    @Test func headingIsLargerThanBody() {
        let s = MarkdownPreview.attributedString(markdown: "# Title\n\nbody text")
        let all = runs(s)
        let h = all.first { $0.0.contains("Title") }.flatMap { font($0.1) }
        let b = all.first { $0.0.contains("body") }.flatMap { font($0.1) }
        #expect(h != nil && b != nil && h!.pointSize > b!.pointSize)
    }
    @Test func inlineCodeIsMonospaced() {
        let s = MarkdownPreview.attributedString(markdown: "call `foo()` now")
        let code = runs(s).first { $0.0 == "foo()" }.flatMap { font($0.1) }
        #expect(code != nil && (code!.fontDescriptor.symbolicTraits.contains(.monoSpace) || (code!.familyName ?? "").contains("Menlo")))
    }
    @Test func foregroundColoursStrippedExceptLinks() {
        let s = MarkdownPreview.attributedString(markdown: "plain **bold** and [site](https://a.b)")
        for (text, attrs) in runs(s) {
            if attrs[.link] != nil { #expect(text == "site") }
            else { #expect(attrs[.foregroundColor] == nil, "run \(text) still carries a colour") }
        }
        #expect(runs(s).contains { $0.1[.link] != nil })
    }
    @Test func overCapReturnsNotice() {
        let s = MarkdownPreview.attributedString(markdown: String(repeating: "a", count: MarkdownPreview.maxBytes + 1))
        #expect(s.string == "Preview is limited to 64 KB of Markdown.")
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
