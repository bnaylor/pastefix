import Testing
@testable import PastefixCore

@Suite struct WhitespaceCleanupTests {
    let subject = WhitespaceCleanup()

    @Test func stripsLeadingSpacesAndTabs() async throws {
        let out = try await subject.apply(.init(text: "   hello\n\tworld"))
        #expect(out == "hello\nworld")
    }

    @Test func trimsTrailingWhitespace() async throws {
        let out = try await subject.apply(.init(text: "hello   \nworld\t"))
        #expect(out == "hello\nworld")
    }

    @Test func collapsesRepeatedBlankLines() async throws {
        let out = try await subject.apply(.init(text: "a\n\n\n\nb"))
        #expect(out == "a\n\nb")
    }

    @Test func metadata() {
        #expect(subject.id == "builtin.whitespace")
        #expect(subject.requiresRichInput == false)
        #expect(subject.source == .builtin)
    }
}
