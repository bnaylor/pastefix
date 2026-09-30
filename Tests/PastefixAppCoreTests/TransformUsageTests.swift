import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

private struct T: Transformer {
    let id: String
    let name: String
    var applicableKinds: Set<ContentKind>? = nil
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

/// #26: transforms you use often or recently break ties in the ⌘K palette. Usage never outranks
/// match quality or fit with the detected content.
@Suite struct TransformUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func scoreHalvesEveryFourteenDays() {
        #expect(TransformUsage.score(nil, now: now) == 0)
        #expect(TransformUsage.score(TransformUsage(count: 4, lastUsed: now), now: now) == 4)
        #expect(abs(TransformUsage.score(TransformUsage(count: 4, lastUsed: daysAgo(14)), now: now) - 2) < 1e-9)
        #expect(abs(TransformUsage.score(TransformUsage(count: 4, lastUsed: daysAgo(28)), now: now) - 1) < 1e-9)
        // A clock that moved backwards never inflates a score.
        #expect(TransformUsage.score(TransformUsage(count: 4, lastUsed: now.addingTimeInterval(86_400)), now: now) == 4)
    }

    @Test func emptyQueryUsageBreaksTiesWithinEachGroup() {
        let a = T(id: "a", name: "Alpha")
        let b = T(id: "b", name: "Beta")
        let json = T(id: "j", name: "JSON Prettify", applicableKinds: [.json])
        let usage = ["b": TransformUsage(count: 9, lastUsed: now)]
        // No detected content: B, used often, moves ahead of A.
        let plain = TransformSearch.rank(query: "", in: [a, b], kinds: [], usage: usage, now: now)
        #expect(plain.map(\.transformer.id) == ["b", "a"])
        // Detected JSON: the JSON transform still leads, even though B is used more.
        let onJSON = TransformSearch.rank(query: "", in: [a, b, json], kinds: [.json], usage: usage, now: now)
        #expect(onJSON.map(\.transformer.id) == ["j", "b", "a"])
    }

    @Test func typedQueryMatchQualityStillWins() {
        let prefix = T(id: "p", name: "Base64 Encode")
        let wordStart = T(id: "w", name: "URL Base Cleanup")
        let prefix2 = T(id: "p2", name: "Base64 Decode")
        let usage = ["w": TransformUsage(count: 50, lastUsed: now), "p2": TransformUsage(count: 3, lastUsed: now)]
        let ranked = TransformSearch.rank(query: "base", in: [prefix, wordStart, prefix2], kinds: [], usage: usage, now: now)
        // Both prefix matches beat the word-start match however much it is used; between the two
        // prefix matches, the used one comes first.
        #expect(ranked.map(\.transformer.id) == ["p2", "p", "w"])
    }

    @Test func noUsageKeepsTheConfiguredOrder() {
        let items = [T(id: "1", name: "One"), T(id: "2", name: "Two"), T(id: "3", name: "Three")]
        #expect(TransformSearch.rank(query: "", in: items, kinds: [], usage: [:], now: now).map(\.transformer.id) == ["1", "2", "3"])
    }
}

@MainActor
@Suite(.serialized) struct TransformUsageSettingsTests {
    private func withFreshDefaults(_ body: @MainActor (UserDefaults) -> Void) {
        let iso = IsolatedDefaults()
        defer { iso.remove() }
        body(iso.defaults)
    }

    @Test func recordingCountsAndPersists() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            s.recordTransformUse("builtin.whitespace", at: t0)
            s.recordTransformUse("builtin.whitespace", at: t0.addingTimeInterval(60))
            #expect(s.transformUsage["builtin.whitespace"] == TransformUsage(count: 2, lastUsed: t0.addingTimeInterval(60)))
            #expect(SettingsStore(defaults: d).transformUsage == s.transformUsage)
        }
    }

    @Test func resetClearsUsage() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            s.recordTransformUse("builtin.whitespace", at: Date())
            s.resetTransformUsage()
            #expect(s.transformUsage.isEmpty && SettingsStore(defaults: d).transformUsage.isEmpty)
        }
    }

    @Test func removingAPresetForgetsItsUsage() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            let preset = RegexPreset(name: "P", pattern: "a", replacement: "b")
            s.regexPresets = [preset]
            let id = RegexPresetTransformer.transformerID(for: preset.id)
            s.recordTransformUse(id, at: Date())
            s.removePreset(id: preset.id)
            #expect(s.transformUsage[id] == nil)
        }
    }
}
