import Foundation
import PastefixCore

public struct SearchResult: Identifiable, Sendable {
    public let transformer: any Transformer
    public var id: String { transformer.id }
    /// Ranges into `transformer.name` to highlight. Empty for an empty query.
    public let matchedRanges: [Range<String.Index>]
    /// 0 = no query (palette order), 1 = prefix, 2 = word start, 3 = subsequence.
    public let tier: Int
}

/// Ranks transforms for the ⌘K palette. Pure; the view only renders the result.
public enum TransformSearch {
    public static func rank(query: String, in transformers: [any Transformer], kinds: Set<ContentKind>) -> [SearchResult] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else {
            return PaletteOrdering.order(transformers, for: kinds).map { SearchResult(transformer: $0, matchedRanges: [], tier: 0) }
        }
        let qChars = Array(q)
        var hits: [(result: SearchResult, applicable: Bool, index: Int)] = []
        for (index, t) in transformers.enumerated() {
            guard let (tier, ranges) = FuzzyMatch.match(qChars, in: t.name) else { continue }
            let applicable = t.applicableKinds.map { !$0.isDisjoint(with: kinds) } ?? false
            hits.append((SearchResult(transformer: t, matchedRanges: ranges, tier: tier), applicable, index))
        }
        return hits.sorted { a, b in
            if a.result.tier != b.result.tier { return a.result.tier < b.result.tier }
            if a.applicable != b.applicable { return a.applicable }
            return a.index < b.index
        }.map(\.result)
    }

    static func fold(_ s: String) -> String { FuzzyMatch.fold(s) }
}
