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
        guard !q.isEmpty else { return items.map { HistorySearchResult(item: $0, matchedRanges: [], tier: 0) } }
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
        return hits.sorted { a, b in a.0.tier != b.0.tier ? a.0.tier < b.0.tier : a.1 < b.1 }.map(\.0)
    }

    static func haystack(for item: HistoryItem) -> String {
        if item.hasText, let t = item.plainText { return String(t.prefix(haystackLimit)) }
        return "image \(item.sourceAppName ?? "")"
    }
}
