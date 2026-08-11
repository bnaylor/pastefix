import Testing
@testable import PastefixCore

@Suite struct WrapReflowTests {
    @Test func wrapsLongLineOnSpaces() async throws {
        let subject = WrapReflow(width: 10)
        let out = try await subject.apply(.init(text: "one two three four five"))
        #expect(out == "one two\nthree four\nfive")
    }

    @Test func reflowsSoftBreaksWithinParagraph() async throws {
        let subject = WrapReflow(width: 20)
        let out = try await subject.apply(.init(text: "hello\nworld\nfoo"))
        #expect(out == "hello world foo")
    }

    @Test func preservesParagraphBreaks() async throws {
        let subject = WrapReflow(width: 20)
        let out = try await subject.apply(.init(text: "para one here\n\npara two here"))
        #expect(out == "para one here\n\npara two here")
    }

    @Test func overflowsWordLongerThanWidth() async throws {
        let subject = WrapReflow(width: 5)
        let out = try await subject.apply(.init(text: "supercalifragilistic ok"))
        #expect(out == "supercalifragilistic\nok")
    }
}
