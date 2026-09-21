import Foundation

public struct HistorySearchResult: Identifiable, Sendable {
    public let item: HistoryItem
    public var id: UUID { item.id }
    /// Ranges into `HistoryFormatting.previewText(for: item)`; empty when the match is not visible there.
    public let matchedRanges: [Range<String.Index>]
    public let tier: Int
}

public enum HistorySearch {
    static let haystackLimit = 2048

    public static func rank(query: String, in items: [HistoryItem]) -> [HistorySearchResult] {
        let q = FuzzyMatch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else {
            // No query: pins first (newest pin first), then the rest in recency order.
            let pins = items.filter(\.pinned).sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
            return (pins + items.filter { !$0.pinned }).map { HistorySearchResult(item: $0, matchedRanges: [], tier: 0) }
        }
        let qChars = Array(q)
        var hits: [(HistorySearchResult, Int)] = []
        for (index, item) in items.enumerated() {
            // Rank with the fold-once `tier`: the haystack is up to 2 KB per item and this runs
            // for every item on every keystroke. `match` is paid only for the ranges, and only
            // over the preview (<= 160 characters).
            guard let tier = FuzzyMatch.tier(qChars, in: haystack(for: item)) else { continue }
            let preview = HistoryFormatting.previewText(for: item)
            let ranges = FuzzyMatch.match(qChars, in: preview)?.ranges ?? []
            hits.append((HistorySearchResult(item: item, matchedRanges: ranges, tier: tier), index))
        }
        // Tier first, then pins ahead of history at the same tier, then capture order.
        return hits.sorted { a, b in
            if a.0.tier != b.0.tier { return a.0.tier < b.0.tier }
            if a.0.item.pinned != b.0.item.pinned { return a.0.item.pinned }
            return a.1 < b.1
        }.map(\.0)
    }

    /// The title is searched alongside the body, so a renamed pin is findable by its label.
    static func haystack(for item: HistoryItem) -> String {
        let title = item.title.map { $0 + "\n" } ?? ""
        if item.hasText, let t = item.plainText { return title + String(t.prefix(haystackLimit)) }
        return title + "image \(item.sourceAppName ?? "")"
    }
}
