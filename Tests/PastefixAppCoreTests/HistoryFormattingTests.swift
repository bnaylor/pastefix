import Testing
import Foundation
@testable import PastefixAppCore

@Suite struct HistoryFormattingTests {
    @Test func previewCollapsesToTwoLines() {
        let item = HistoryItem(plainText: "  first   line \n\n second\tline\nthird")
        #expect(HistoryFormatting.previewText(for: item) == "first line\nsecond line…")
    }
    @Test func previewTruncatesAt160() {
        let item = HistoryItem(plainText: String(repeating: "a", count: 200))
        let p = HistoryFormatting.previewText(for: item)
        #expect(p.count == 160 && p.hasSuffix("…"))
    }
    @Test func previewKeepsExactly160Chars() {
        let s = String(repeating: "b", count: 160)
        #expect(HistoryFormatting.previewText(for: HistoryItem(plainText: s)) == s)
    }
    /// The preview only ever shows two lines of at most 160 characters, so it must not walk a
    /// whole 256 KB item to produce them: the input is bounded to the search haystack limit first.
    @Test func previewBoundsItsInput() {
        let item = HistoryItem(plainText: String(repeating: "a", count: 100_000))
        #expect(HistoryFormatting.previewText(for: item) == String(repeating: "a", count: 159) + "…")
    }
    @Test func previewForImage() {
        #expect(HistoryFormatting.previewText(for: HistoryItem(imageFile: "x.png", imagePixelWidth: 1280, imagePixelHeight: 800)) == "Image 1280×800")
        #expect(HistoryFormatting.previewText(for: HistoryItem(imageFile: "x.png")) == "Image")
    }
    @Test func relativeAges() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 12))!
        func age(_ s: TimeInterval) -> String { HistoryFormatting.relativeAge(from: now.addingTimeInterval(-s), to: now) }
        #expect(age(2) == "now"); #expect(age(45) == "45s"); #expect(age(180) == "3m"); #expect(age(7200) == "2h")
        #expect(age(30 * 3600) == "yesterday"); #expect(age(3 * 86400) == "3d")
        #expect(age(20 * 86400) == "Sep 1")
    }
    @Test func byteLabels() {
        #expect(HistoryFormatting.byteLabel(12) == "12 B")
        #expect(HistoryFormatting.byteLabel(348_160) == "340 KB")
        #expect(HistoryFormatting.byteLabel(1_258_291) == "1.2 MB")
    }
}
