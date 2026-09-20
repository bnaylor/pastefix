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
            guard let (tier, ranges) = match(qChars, in: t.name) else { continue }
            let applicable = t.applicableKinds.map { !$0.isDisjoint(with: kinds) } ?? false
            hits.append((SearchResult(transformer: t, matchedRanges: ranges, tier: tier), applicable, index))
        }
        return hits.sorted { a, b in
            if a.result.tier != b.result.tier { return a.result.tier < b.result.tier }
            if a.applicable != b.applicable { return a.applicable }
            return a.index < b.index
        }.map(\.result)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static let wordSeparators: Set<Character> = [" ", "_", "-", "→", "&", "/"]

    /// Matches per character so highlight ranges map 1:1 onto the original name: each
    /// character of `name` is folded on its own and compared by its first scalar.
    static func match(_ q: [Character], in name: String) -> (tier: Int, ranges: [Range<String.Index>])? {
        let chars = Array(name)
        let folded: [Character] = chars.map { fold(String($0)).first ?? $0 }
        let indices = Array(name.indices) + [name.endIndex]
        func range(_ from: Int, _ to: Int) -> Range<String.Index> { indices[from]..<indices[to] }
        func hasPrefix(at start: Int) -> Bool {
            guard start + q.count <= folded.count else { return false }
            return Array(folded[start..<start + q.count]) == q
        }
        if hasPrefix(at: 0) { return (1, [range(0, q.count)]) }
        for i in 1..<max(1, chars.count) where wordSeparators.contains(chars[i - 1]) && !wordSeparators.contains(chars[i]) {
            if hasPrefix(at: i) { return (2, [range(i, i + q.count)]) }
        }
        var matched: [Int] = []
        var qi = 0
        for (ci, c) in folded.enumerated() where qi < q.count && c == q[qi] {
            matched.append(ci); qi += 1
        }
        guard qi == q.count else { return nil }
        var ranges: [Range<String.Index>] = []
        var runStart = matched[0], prev = matched[0]
        for m in matched.dropFirst() {
            if m == prev + 1 { prev = m; continue }
            ranges.append(range(runStart, prev + 1)); runStart = m; prev = m
        }
        ranges.append(range(runStart, prev + 1))
        return (3, ranges)
    }
}
