import Testing
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

@Suite struct TransformSearchTests {
    let list: [any Transformer] = [
        T(id: "wrap", name: "Wrap & Reflow"),
        T(id: "ws", name: "Whitespace Cleanup"),
        T(id: "clean", name: "Clean URL Tracking", applicableKinds: [.url]),
        T(id: "md", name: "URL → Markdown Link", applicableKinds: [.url]),
        T(id: "camel", name: "camelCase"),
        T(id: "cafe", name: "Café Filter"),
    ]
    private func ids(_ q: String, kinds: Set<ContentKind> = []) -> [String] { TransformSearch.rank(query: q, in: list, kinds: kinds).map(\.id) }
    private func highlighted(_ q: String, _ id: String) -> [String] {
        let r = TransformSearch.rank(query: q, in: list, kinds: []).first { $0.id == id }!
        return r.matchedRanges.map { String(r.transformer.name[$0]) }
    }

    @Test func emptyQueryIsPaletteOrder() {
        let r = TransformSearch.rank(query: "   ", in: list, kinds: [.url])
        #expect(r.map(\.id) == ["clean", "md", "wrap", "ws", "camel", "cafe"])
        #expect(r.allSatisfy { $0.tier == 0 && $0.matchedRanges.isEmpty })
    }
    @Test func prefixBeatsWordStartBeatsSubsequence() {
        // "url": prefix of "URL → Markdown Link"; word start in "Clean URL Tracking"; subsequence nowhere else.
        #expect(ids("url") == ["md", "clean"])
        let tiers = TransformSearch.rank(query: "url", in: list, kinds: []).map(\.tier)
        #expect(tiers == [1, 2])
    }
    @Test func subsequenceMatchesAndHighlightsEachCharacter() {
        #expect(ids("cut").contains("clean"))
        #expect(highlighted("cut", "clean") == ["C", "U", "T"])   // C(lean) U(RL) T(racking)
    }
    @Test func contiguousHighlightForPrefixAndWordStart() {
        #expect(highlighted("url", "md") == ["URL"])
        #expect(highlighted("url", "clean") == ["URL"])
    }
    @Test func caseAndDiacriticInsensitive() {
        #expect(ids("CLEAN") == ["clean", "ws"])   // prefix, then "Cleanup" word start
        #expect(ids("cafe") == ["cafe"])
        #expect(highlighted("cafe", "cafe") == ["Café"])
    }
    @Test func nonMatchExcluded() { #expect(ids("zzz").isEmpty) }
    @Test func applicableFirstWithinTier() {
        // "c" is a prefix of camelCase, Clean URL Tracking, Café Filter; only Clean is applicable to url.
        // "c" is also a word-start match (tier 2) on "Whitespace Cleanup" ("Cleanup"), same rule
        // exercised by caseAndDiacriticInsensitive's "CLEAN" -> ws case, so it trails the tier-1 hits.
        #expect(ids("c", kinds: [.url]) == ["clean", "camel", "cafe", "ws"])
        #expect(ids("c") == ["clean", "camel", "cafe", "ws"])   // no kinds: input order among prefix matches, then tier-2 word-start
    }
    @Test func rangesAreValidIndicesOfOriginalName() {
        for r in TransformSearch.rank(query: "a", in: list, kinds: []) {
            for range in r.matchedRanges {
                #expect(range.lowerBound >= r.transformer.name.startIndex && range.upperBound <= r.transformer.name.endIndex)
            }
        }
    }
}
