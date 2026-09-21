import Foundation

/// Shared fuzzy matcher: prefix/word-start(incl. camel)/subsequence tiers + highlight ranges.
/// Extracted from `TransformSearch` (⌘K palette) so it can also rank clipboard history.
enum FuzzyMatch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static let wordSeparators: Set<Character> = [" ", "_", "-", "→", "&", "/"]

    /// Matches per character so highlight ranges map 1:1 onto the original name: each
    /// character of `name` is folded on its own and compared by its first character.
    /// Camel-case boundaries (a lowercase letter or digit followed by an uppercase
    /// letter, the same rule `CaseConvert.words` uses) count as word starts alongside
    /// separators. Characters whose fold expands to more than one character (e.g. "ß"
    /// -> "ss", "ﬁ" -> "fi") are matched by their first folded character only.
    static func match(_ q: [Character], in name: String) -> (tier: Int, ranges: [Range<String.Index>])? {
        let chars = Array(name)
        let folded: [Character] = chars.map { fold(String($0)).first ?? $0 }
        let indices = Array(name.indices) + [name.endIndex]
        func range(_ from: Int, _ to: Int) -> Range<String.Index> { indices[from]..<indices[to] }
        func hasPrefix(at start: Int) -> Bool {
            guard start + q.count <= folded.count else { return false }
            return Array(folded[start..<start + q.count]) == q
        }
        func isWordStart(at i: Int) -> Bool {
            if wordSeparators.contains(chars[i - 1]) && !wordSeparators.contains(chars[i]) { return true }
            if chars[i].isUppercase, chars[i - 1].isLowercase || chars[i - 1].isNumber { return true }
            return false
        }
        if hasPrefix(at: 0) { return (1, [range(0, q.count)]) }
        for i in 1..<max(1, chars.count) where isWordStart(at: i) {
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
