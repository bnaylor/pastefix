import Testing
import Foundation
@testable import PastefixAppCore

@Suite struct TextRangeClampTests {
    /// The ordinary case: a transform shortens the buffer but the selection's offsets still exist,
    /// so the caret keeps its place instead of being thrown back to the start.
    @Test func inBoundsRangeSurvives() {
        let old = "token=abcdefgh trailing note"
        let new = "token=XY and more text after the change"
        let range = old.range(of: "trailing")!          // UTF-16 offsets 15..<23
        let remapped = TextRangeClamp.remap(range, from: old, to: new)
        #expect(remapped != nil)
        // Offsets are preserved, not content.
        #expect(remapped.map { new.distance(from: new.startIndex, to: $0.lowerBound) } == 15)
        #expect(remapped.map { String(new[$0]) } == "re text ")
        // A caret (empty range) at the very end of a same-length buffer is still expressible.
        let end = old.endIndex..<old.endIndex
        #expect(TextRangeClamp.remap(end, from: old, to: old).map { $0 == end } == true)
    }

    /// The trap this exists to prevent: a selection made against a long buffer, applied to the
    /// short one a redaction left behind.
    @Test func outOfBoundsRangeIsDropped() {
        let old = "password=aB3xY9zQ7wE1rT5u and more text after it"
        let new = "password=[REDACTED credential]"
        #expect(TextRangeClamp.remap(old.range(of: "after it")!, from: old, to: new) == nil)
        #expect(TextRangeClamp.remap(old.startIndex..<old.endIndex, from: old, to: new) == nil)
        // A range that isn't inside `old` in the first place is refused rather than measured.
        let longer = old + " and yet more"
        #expect(TextRangeClamp.remap(longer.range(of: "yet more")!, from: old, to: longer) == nil)
        // An offset inside a surrogate pair has no String.Index in the new buffer.
        let ascii = "ab"
        let firstCharacter = ascii.startIndex..<ascii.index(after: ascii.startIndex)
        #expect(TextRangeClamp.remap(firstCharacter, from: ascii, to: "\u{1F600}x") == nil)
    }
}
