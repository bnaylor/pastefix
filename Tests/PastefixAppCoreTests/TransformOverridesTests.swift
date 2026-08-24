import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

private struct StubTransformer: Transformer {
    let id: String
    let name: String
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite struct TransformOverridesTests {
    private let loaded: [any Transformer] = [
        StubTransformer(id: "a", name: "A"),
        StubTransformer(id: "b", name: "B"),
        StubTransformer(id: "c", name: "C"),
    ]

    @Test func noOverridesKeepsLoadOrder() {
        let out = TransformOverrides.apply(to: loaded, enabled: [:], order: [:])
        #expect(out.map(\.id) == ["a", "b", "c"])
    }

    @Test func disabledEntryIsRemoved() {
        let out = TransformOverrides.apply(to: loaded, enabled: ["b": false], order: [:])
        #expect(out.map(\.id) == ["a", "c"])
    }

    @Test func missingEnabledMeansKept() {
        let out = TransformOverrides.apply(to: loaded, enabled: ["a": true], order: [:])
        #expect(out.map(\.id) == ["a", "b", "c"])
    }

    @Test func explicitOrderOverridesLoadOrderElsePositionHeld() {
        // c gets order 0 (front); a,b have no order → hold their load positions after.
        let out = TransformOverrides.apply(to: loaded, enabled: [:], order: ["c": 0])
        #expect(out.first?.id == "c")
    }

    @Test func fullReorder() {
        let out = TransformOverrides.apply(to: loaded, enabled: [:], order: ["a": 30, "b": 20, "c": 10])
        #expect(out.map(\.id) == ["c", "b", "a"])
    }
}
