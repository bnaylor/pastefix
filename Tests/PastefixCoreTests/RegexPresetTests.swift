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

    @Test func previewReportsOutputAndMatchCount() throws {
        let p = RegexPreset(name: "o", pattern: "o", replacement: "0")
        let r = try RegexPresetTransformer.preview("foo boo", preset: p, deadline: .now + .seconds(1))
        #expect(r.output == "f00 b00" && r.matches == 4)
        var once = p; once.replaceAll = false
        #expect(try RegexPresetTransformer.preview("foo boo", preset: once, deadline: .now + .seconds(1)).matches == 1)
    }

    @Test func decodingToleratesMissingFlags() throws {
        // A payload from an older (or hand-edited) build: only the three required keys. A
        // synthesized decoder throws here, and `SettingsStore` reads the array with `try?`, so
        // one such element would silently wipe every preset the user has.
        let id = UUID()
        let json = Data(#"{"id":"\#(id.uuidString)","name":"n","pattern":"a"}"#.utf8)
        let p = try JSONDecoder().decode(RegexPreset.self, from: json)
        #expect(p == RegexPreset(id: id, name: "n", pattern: "a"))
        #expect(p.replacement.isEmpty && p.replaceAll && p.anchorsMatchLines
                && !p.caseInsensitive && !p.dotMatchesNewlines)
        // Round-tripping a full value still works.
        let full = RegexPreset(name: "f", pattern: "x", replacement: "y", caseInsensitive: true,
                               anchorsMatchLines: false, dotMatchesNewlines: true, replaceAll: false)
        #expect(try JSONDecoder().decode(RegexPreset.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func identity() {
        let p = RegexPreset(name: "n", pattern: "a", replacement: "b")
        let t = RegexPresetTransformer(preset: p)
        #expect(t.id == "preset:\(p.id.uuidString)" && t.name == "n" && t.category == TransformCategory.presets && t.source == .preset(p.id) && !t.requiresRichInput)
    }
}
