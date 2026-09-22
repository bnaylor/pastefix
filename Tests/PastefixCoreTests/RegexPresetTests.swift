import Testing
import Foundation
@testable import PastefixCore

@Suite struct RegexPresetTests {
    func run(_ p: RegexPreset, _ text: String) async throws -> String {
        try await RegexPresetTransformer(preset: p).apply(TransformInput(text: text))
    }

    @Test func groupsAndTemplate() async throws {
        let p = RegexPreset(name: "swap", pattern: #"(\w+) (\w+)"#, replacement: "$2 $1")
        #expect(try await run(p, "hello world") == "world hello")
    }

    @Test func escapesInReplacement() async throws {
        let p = RegexPreset(name: "nl", pattern: ", ", replacement: #"\n"#)
        #expect(try await run(p, "a, b, c") == "a\nb\nc")
        #expect(RegexPreset.expandEscapes(#"\\n"#) == #"\n"#)      // escaped backslash stays literal
        #expect(RegexPreset.expandEscapes(#"x\ty"#) == "x\ty")
    }

    @Test func flags() async throws {
        #expect(try await run(RegexPreset(name: "ci", pattern: "abc", replacement: "X", caseInsensitive: true), "ABC abc") == "X X")
        #expect(try await run(RegexPreset(name: "anch", pattern: "^b", replacement: "X", anchorsMatchLines: true), "a\nb") == "a\nX")
        #expect(try await run(RegexPreset(name: "noanch", pattern: "^b", replacement: "X", anchorsMatchLines: false), "a\nb") == "a\nb")
        #expect(try await run(RegexPreset(name: "dot", pattern: "a.b", replacement: "X", dotMatchesNewlines: true), "a\nb") == "X")
        #expect(try await run(RegexPreset(name: "first", pattern: "o", replacement: "0", replaceAll: false), "foo boo") == "f0o boo")
    }

    @Test func invalidPatternThrows() async {
        let p = RegexPreset(name: "bad", pattern: "(", replacement: "")
        await #expect(throws: TransformError.self) { try await run(p, "x") }
        #expect(throws: TransformError.self) { try p.compile() }
    }

    @Test func inputCap() async {
        let p = RegexPreset(name: "any", pattern: "a", replacement: "b")
        await #expect(throws: TransformError.invalidInput("Text is too large for a regex preset (limit 256 KB)")) {
            try await run(p, String(repeating: "a", count: RegexPresetTransformer.maxBytes + 1))
        }
    }

    @Test func deadlineIsHonoured() throws {
        let evil = RegexPreset(name: "evil", pattern: "(a+)+$", replacement: "x")
        let text = String(repeating: "a", count: 28) + "!"
        let start = ContinuousClock.now
        #expect(throws: TransformError.timeout) {
            try RegexPresetTransformer.replace(text, preset: evil, deadline: start + .milliseconds(50))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func identity() {
        let p = RegexPreset(name: "n", pattern: "a", replacement: "b")
        let t = RegexPresetTransformer(preset: p)
        #expect(t.id == "preset:\(p.id.uuidString)" && t.name == "n" && t.category == TransformCategory.presets && t.source == .preset(p.id) && !t.requiresRichInput)
    }
}
