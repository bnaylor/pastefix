import Testing
import Foundation
@testable import PastefixAppCore

@Suite struct HistorySearchTests {
    private let items: [HistoryItem] = [
        HistoryItem(plainText: "Invoice 2026 draft", sourceAppName: "Pages"),          // newest
        HistoryItem(plainText: "meeting notes\nagenda invoice", sourceAppName: "Notes"),
        HistoryItem(imageFile: "a.png", imagePixelWidth: 10, imagePixelHeight: 10, sourceAppName: "Screenshot"),
        HistoryItem(plainText: String(repeating: "x", count: 3000) + " needle"),        // needle beyond the 2 KB haystack
    ]
    private func ids(_ q: String) -> [String] { HistorySearch.rank(query: q, in: items).map { $0.item.sourceAppName ?? ($0.item.plainText.map { String($0.prefix(3)) } ?? "?") } }

    @Test func emptyQueryIsRecency() {
        let r = HistorySearch.rank(query: "  ", in: items)
        #expect(r.map(\.id) == items.map(\.id) && r.allSatisfy { $0.tier == 0 })
    }
    @Test func tiersAndRecencyTies() {
        #expect(ids("invoice") == ["Pages", "Notes"])     // prefix beats subsequence/word-start; ties keep recency
    }
    @Test func imageItemsMatchImageAndApp() {
        #expect(ids("image").first == "Screenshot")
        #expect(ids("screen").first == "Screenshot")
    }
    @Test func haystackCappedAt2K() { #expect(HistorySearch.rank(query: "needle", in: items).isEmpty) }
    @Test func highlightRangesIndexThePreview() {
        let r = HistorySearch.rank(query: "notes", in: items).first { $0.item.sourceAppName == "Notes" }!
        let preview = HistoryFormatting.previewText(for: r.item)
        #expect(r.matchedRanges.map { String(preview[$0]) } == ["notes"])
    }
    @Test func pinsComeFirstAndTitlesMatch() {
        var pinned = HistoryItem(plainText: "zeta body", sourceAppName: "Notes"); pinned.pinned = true; pinned.pinnedAt = Date(); pinned.title = "Signature"
        let plain = HistoryItem(plainText: "alpha body")
        let items = [plain, pinned]                                   // capture order: plain newest
        #expect(HistorySearch.rank(query: "", in: items).map(\.id) == [pinned.id, plain.id])
        #expect(HistorySearch.rank(query: "signat", in: items).first?.id == pinned.id)
        #expect(HistorySearch.rank(query: "body", in: items).map(\.id) == [pinned.id, plain.id])   // tie -> pin first
    }
}
