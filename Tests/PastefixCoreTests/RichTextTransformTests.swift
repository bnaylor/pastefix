import Testing
import AppKit
@testable import PastefixCore

@Suite struct RichTextTransformTests {
    @Test func richToMarkdownUsesRTFD() async throws {
        // RTF carries no heading concept — headerLevel is dropped on write — so an RTFD
        // heading is large bold text and only the size heuristic can recover it.
        let a = NSAttributedString(string: "Hello\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 26)])
        let d = try a.data(from: NSRange(location: 0, length: 6), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let out = try await RichToMarkdown().apply(TransformInput(text: "Hello", richRTFD: d))
        #expect(out == "# Hello")
        await #expect(throws: TransformError.richInputUnavailable) { try await RichToMarkdown().apply(TransformInput(text: "x")) }
    }
    @Test func markdownToRichArmsWithoutChangingText() async throws {
        let t = MarkdownToRich()
        #expect(t.outputMode == .renderedMarkdown && t.applicableKinds == [.markdown] && t.category == TransformCategory.richText)
        #expect(try await t.apply(TransformInput(text: "# hi\n\n- a")) == "# hi\n\n- a")
    }
}
