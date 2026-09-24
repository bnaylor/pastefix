import Testing
import Foundation
@testable import PastefixCore

private struct Bare: Transformer {
    let id = "t.bare"; let name = "Bare"; let requiresRichInput = false
    let source = TransformerSource.builtin
    func apply(_ i: TransformInput) async throws -> String { i.text }
}

@Suite struct TransformerLimitsTests {
    @Test func defaultsApplyToAConformerThatDeclaresNothing() {
        #expect(Bare().maxInputBytes == TransformLimits.defaultMaxInputBytes)
        #expect(Bare().timeout == TransformLimits.defaultTimeout)
    }

    @Test func everyRegisteredTransformerDeclaresTheSpecTable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let preset = RegexPreset(name: "p", pattern: "a", replacement: "b")
        let all = TransformerRegistry(config: RegistryConfig(scriptsDirectory: dir, presets: [preset])).load()
        #expect(all.count >= 28)
        let table: [String: (bytes: Int, seconds: TimeInterval)] = [
            "builtin.markdowntorich": (65_536, 3),
            "builtin.urlclean": (262_144, 3),
            "builtin.markdownlink": (262_144, 6),
            "builtin.redactsecrets": (262_144, 3),
            "builtin.richtoplain": (4_194_304, 3),
            "builtin.richtomarkdown": (4_194_304, 3),
            RegexPresetTransformer.transformerID(for: preset.id): (262_144, 3),
        ]
        #expect(Set(all.map(\.id)).isSuperset(of: table.keys))
        for t in all {
            let expected = table[t.id] ?? (TransformLimits.defaultMaxInputBytes, TransformLimits.defaultTimeout)
            #expect(t.maxInputBytes == expected.bytes, "\(t.id) maxInputBytes")
            #expect(t.timeout == expected.seconds, "\(t.id) timeout")
        }
    }

    @Test func markdownLinkTimeoutTracksItsFetchTimeout() {
        #expect(MarkdownLink(fetchTimeout: 1).timeout == 3)
    }

    @Test func shellTransformerTimeoutHasAMarginOverTheRunner() {
        let t = ShellTransformer(url: URL(fileURLWithPath: "/tmp/x.sh"), metadata: ScriptMetadata.parse(""), timeout: 3)
        #expect(t.timeout == 4)
    }

    @Test func jsTransformerTimeoutHasAMarginOverTheRunner() {
        let t = JSTransformer(url: URL(fileURLWithPath: "/tmp/x.js"), metadata: ScriptMetadata.parse(""), timeout: 3)
        #expect(t.timeout == 4)
    }
}
