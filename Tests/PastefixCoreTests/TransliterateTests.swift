import Testing
@testable import PastefixCore

@Suite struct TransliterateTests {
    let subject = Transliterate()

    @Test func normalizesSmartPunctuation() async throws {
        let out = try await subject.apply(.init(text: "\u{201C}quote\u{201D} \u{2018}x\u{2019} en\u{2013}dash em\u{2014}dash \u{2026}"))
        #expect(out == "\"quote\" 'x' en-dash em--dash ...")
    }

    @Test func stripsDiacritics() async throws {
        let out = try await subject.apply(.init(text: "café résumé naïve"))
        #expect(out == "cafe resume naive")
    }

    @Test func dropsNonASCIIRemnants() async throws {
        // Dingbats and CJK have no ASCII equivalent → removed entirely.
        // Input has 3 spaces (after "hi", after ❤, after "日本"), all preserved as ASCII passes through.
        let out = try await subject.apply(.init(text: "hi \u{2764} 日本 bye"))
        #expect(out == "hi   bye")
    }

    @Test func passesPlainASCIIThrough() async throws {
        let out = try await subject.apply(.init(text: "already ascii"))
        #expect(out == "already ascii")
    }

    @Test func metadata() {
        #expect(subject.id == "builtin.transliterate")
        #expect(subject.source == .builtin)
        #expect(subject.category == TransformCategory.characters)
    }
}
