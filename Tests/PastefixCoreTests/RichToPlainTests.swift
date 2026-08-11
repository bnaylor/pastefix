import Testing
import AppKit
@testable import PastefixCore

@Suite struct RichToPlainTests {
    let subject = RichToPlain()

    private func rtfd(_ attributed: NSAttributedString) throws -> Data {
        try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    @Test func flattensStyledTextToPlain() async throws {
        let styled = NSAttributedString(
            string: "Bold Title",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.red]
        )
        let out = try await subject.apply(.init(text: "ignored", richRTFD: try rtfd(styled)))
        #expect(out == "Bold Title")
    }

    @Test func throwsWhenNoRichInput() async throws {
        await #expect(throws: TransformError.richInputUnavailable) {
            try await subject.apply(.init(text: "plain only", richRTFD: nil))
        }
    }

    @Test func metadata() {
        #expect(subject.requiresRichInput == true)
    }
}
