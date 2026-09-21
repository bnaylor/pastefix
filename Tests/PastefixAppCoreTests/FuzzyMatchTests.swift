import Testing
@testable import PastefixAppCore

@Suite struct FuzzyMatchTests {
    private func m(_ q: String, _ hay: String) -> (Int, [String])? {
        guard let (tier, ranges) = FuzzyMatch.match(Array(FuzzyMatch.fold(q)), in: hay) else { return nil }
        return (tier, ranges.map { String(hay[$0]) })
    }
    @Test func tiers() {
        #expect(m("inv", "Invoice 2026")! == (1, ["Inv"]))
        #expect(m("2026", "Invoice 2026")! == (2, ["2026"]))
        // Greedy-leftmost subsequence match (same algorithm TransformSearchTests relies on):
        // the lowercase "i" of "Invoice" at index 4 is skipped in favor of the leading "I" at
        // index 0, since matching is first-available-character, not optimal/backtracking.
        #expect(m("ice6", "Invoice 2026")! == (3, ["I", "ce", "6"]))
        #expect(m("zzz", "Invoice 2026") == nil)
    }
    @Test func camelAndSeparators() {
        #expect(m("case", "camelCase")!.0 == 2)
        #expect(m("b", "a/b")!.0 == 2)
    }
    @Test func diacriticsAndCase() { #expect(m("cafe", "Café")! == (1, ["Café"])) }
    @Test func emptyHaystack() { #expect(m("a", "") == nil) }
}
