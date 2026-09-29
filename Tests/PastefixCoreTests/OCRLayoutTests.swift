import Testing
import Foundation
import CoreGraphics
@testable import PastefixCore

@Suite("OCRLayout (#19)")
struct OCRLayoutTests {
    private func o(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 100, h: CGFloat = 20) -> OCRObservation {
        OCRObservation(text: text, box: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test("observations on one line join left to right; lines run top to bottom")
    func lines() {
        let obs = [o("world", x: 120, y: 12), o("second line", x: 10, y: 60), o("hello", x: 10, y: 10)]
        #expect(OCRLayout.lines(obs) == ["hello world", "second line"])
    }

    // Review Focus 2: row-based reassembly joins side-by-side columns into one line. Right for a
    // terminal; a known limitation for true columns. Pinned so a change is deliberate.
    @Test("two columns at the same height join into one line")
    func columns() {
        #expect(OCRLayout.lines([o("right", x: 600, y: 10), o("left", x: 10, y: 11)]) == ["left right"])
    }

    @Test("a token Vision split across observations comes out whole on one line")
    func splitToken() {
        #expect(OCRLayout.lines([o("export TOKEN=xoxb-", x: 10, y: 10), o("1234abcd", x: 220, y: 9)])
                == ["export TOKEN=xoxb- 1234abcd"])
    }

    @Test("tiles cover the image, overlap by 768 px, and clip at the edges")
    func tiles() {
        #expect(OCRLayout.tiles(width: 1000, height: 800) == [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        let t = OCRLayout.tiles(width: 5000, height: 1400)
        #expect(t.map(\.minX) == [0, 1280, 2560, 3840])                  // step 2048 - 768
        #expect(t.last == CGRect(x: 3840, y: 0, width: 1160, height: 1400))
        #expect(t.allSatisfy { $0.maxX <= 5000 && $0.maxY <= 1400 })
    }

    /// An observation with one box per character, evenly spaced from `x`, as Vision reports them.
    private func chars(_ text: String, x: CGFloat, y: CGFloat = 10, charWidth: CGFloat = 17, h: CGFloat = 20) -> OCRObservation {
        let boxes = (0..<text.count).map { CGRect(x: x + CGFloat($0) * charWidth, y: y, width: charWidth, height: h) }
        return OCRObservation(text: text, box: CGRect(x: x, y: y, width: CGFloat(text.count) * charWidth, height: h),
                              characterBoxes: boxes)
    }

    // #105 review, measured on real tiled Vision output: a token across the 1984–2048 overlap came
    // out as two halves, overlap characters duplicated, a space inside the token — and each tile
    // misread the glyph its edge cut. Each tile now owns its half of the overlap, per character.
    @Test("a token across a tile boundary: each tile keeps only the characters it owns, and the halves join with no space")
    func ownershipJoinsAStraddlingToken() {
        let token = "ghp_aB3cD5eF7gH9iJkLmNpQrStUvWxYz"            // 34 chars, 17 px each
        let start: CGFloat = 1700                                  // straddles the 2016 midline
        // Left tile [0, 2048): sees the token up to its edge; its last glyph is cut and misread.
        let leftSeen = String(token.prefix(20)) + "!"               // 21 chars: 1700…2057, clipped reading
        // Right tile [1984, …): starts mid-glyph, with a misread first glyph.
        let skip = Int((1984 - start) / 17)                         // first whole char index in the right tile
        let rightSeen = ")" + String(token.dropFirst(skip + 1))
        let left = OCRLayout.owned([chars(leftSeen, x: start)],
                                   tile: CGRect(x: 0, y: 0, width: 2048, height: 2048), imageWidth: 5120, imageHeight: 1400, overlap: 64)
        let right = OCRLayout.owned([chars(rightSeen, x: start + CGFloat(skip) * 17)],
                                    tile: CGRect(x: 1984, y: 0, width: 2048, height: 2048), imageWidth: 5120, imageHeight: 1400, overlap: 64)
        let line = OCRLayout.lines(left + right)
        #expect(line == [token])
    }

    /// Boxes as Vision `.accurate` really reports them (measured, #105 review): every character of a
    /// word carries the WORD's box, and a space carries an empty one.
    private func wordBoxed(_ words: [(String, CGFloat, CGFloat)], y: CGFloat = 10, h: CGFloat = 20) -> OCRObservation {
        var text = "", boxes: [CGRect] = []
        for (i, (word, minX, maxX)) in words.enumerated() {
            if i > 0 { text += " "; boxes.append(.zero) }
            text += word
            boxes += Array(repeating: CGRect(x: minX, y: y, width: maxX - minX, height: h), count: word.count)
        }
        let all = boxes.filter { $0 != .zero }.reduce(CGRect.null) { $0.union($1) }
        return OCRObservation(text: text, box: all, characterBoxes: boxes)
    }

    // The measured case, as Vision really boxed it: left tile's word "GITHUB_TOKEN=ghp_aB3cD5eFi"
    // at 1614–2045 (its "i" a misread of the glyph its edge cut), right tile's "5eF7gH9iJkMnPqRsTuVwXyZ23"
    // at 1984–2417. Characters are spread across their word's box, and each tile keeps its own.
    @Test("word-level boxes (what Vision reports): the straddling token comes out whole, spaces kept")
    func ownershipWithWordLevelBoxes() {
        let leftTile = CGRect(x: 0, y: 0, width: 2048, height: 1400)
        let rightTile = CGRect(x: 1984, y: 0, width: 2048, height: 1400)
        let left = OCRLayout.owned([wordBoxed([("export", 1497, 1610), ("GITHUB_TOKEN=ghp_aB3cD5eFi", 1614, 2045)])],
                                   tile: leftTile, imageWidth: 5120, imageHeight: 1400, overlap: 64)
        let right = OCRLayout.owned([wordBoxed([("5eF7gH9iJkMnPqRsTuVwXyZ23", 1984, 2417), ("#", 2421, 2450), ("trailing", 2454, 2594)])],
                                    tile: rightTile, imageWidth: 5120, imageHeight: 1400, overlap: 64)
        #expect(OCRLayout.lines(left + right) == ["export GITHUB_TOKEN=ghp_aB3cD5eF7gH9iJkMnPqRsTuVwXyZ23 # trailing"])
    }

    @Test("an observation without character boxes is owned by the tile holding its centre")
    func ownershipWithoutCharacterBoxes() {
        let tile = CGRect(x: 1984, y: 0, width: 2048, height: 2048)
        #expect(OCRLayout.owned([o("left of the midline", x: 1900, y: 10, w: 100)], tile: tile, imageWidth: 5120, imageHeight: 1400, overlap: 64).isEmpty)
        #expect(OCRLayout.owned([o("right of it", x: 2100, y: 10, w: 100)], tile: tile, imageWidth: 5120, imageHeight: 1400, overlap: 64).count == 1)
    }

    @Test("the image's own edges are owned outright; only shared overlaps are split")
    func ownershipAtImageEdges() {
        let only = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(OCRLayout.owned([chars("edge", x: 0), chars("tail", x: 930)], tile: only, imageWidth: 1000, imageHeight: 800, overlap: 64)
                    .map(\.text) == ["edge", "tail"])
    }

    // #105 review, second sweep: estimating character positions left a one-character error at the
    // seam in 30 of 105 lines. With an overlap wider than a word, every word is whole in at least one
    // tile — keep Vision's own word, never estimate.
    private let left = CGRect(x: 0, y: 0, width: 2048, height: 1400)
    private let right = CGRect(x: 1280, y: 0, width: 2048, height: 1400)
    private func merged(_ l: [OCRObservation], _ r: [OCRObservation]) -> [String] {
        OCRLayout.lines(OCRLayout.merged([(left, l), (right, r)], imageWidth: 3328, imageHeight: 1400))
    }

    @Test("a word cut by one tile's edge is taken whole from the tile that holds it")
    func cutWordFromTheOtherTile() {
        // Left tile cuts "ghp_token…" at its edge (2048) and misreads the cut glyph; right holds it.
        let l = [wordBoxed([("before", 1500, 1600), ("ghp_tokenAB!", 1700, 2046)])]
        let r = [wordBoxed([("before", 1500, 1600), ("ghp_tokenABCDEFG", 1700, 2150)])]
        #expect(merged(l, r) == ["before ghp_tokenABCDEFG"])
    }

    @Test("a word whole in both tiles is kept once")
    func wholeInBoth() {
        #expect(merged([wordBoxed([("shared", 1500, 1700)])], [wordBoxed([("shared", 1501, 1699)])]) == ["shared"])
    }

    @Test("a word longer than the overlap is cut in both tiles, and falls back to the owned halves")
    func overlongWord() {
        // 1100–2300: left view cut at 2048, right view cut at 1280. Monospace, 20 px a character.
        let token = String(repeating: "abcdefghij", count: 6)          // 60 chars, 1200 px
        let l = [wordBoxed([(String(token.prefix(47)), 1100, 2046)])]
        let r = [wordBoxed([(String(token.dropFirst(9)), 1280, 2300)])]
        #expect(merged(l, r) == [token])
    }

    // The sweep's two seam failures (Menlo 28 and Times 30, shift −150): each tile split the text into
    // words differently. The left tile read "…ghp_aB3dE5f" whole and "G7hJ…" cut at its edge; the
    // right tile read one fragment cut at ITS edge covering both. That fragment overlapped the whole
    // word by just over half, was taken for a duplicate, and the rest of the token was lost.
    // Whole words are authoritative; fragments fill only the gaps between them.
    @Test("a fragment fills the gap next to a whole word instead of being dropped as its duplicate")
    func fragmentFillsTheGap() {
        // The sweep's geometry: 17 px a character, "export " at 1150, so "GITHUB…" starts at 1269 and
        // the 47-character word runs to 2068 — past the left tile's edge (2048). Left tile
        // [0, 2048), right tile [1280, 3328), midline 1664.
        let l = [wordBoxed([("export", 1150, 1252), ("GITHUB_TOKEN=ghp_aB3dE5f", 1269, 1677),
                            ("G7hJ9mNqR2tA4bD6eF8g", 1677, 2045)])]
        let r = [wordBoxed([("ITHUB_TOKEN=ghp_aB3dE5fG7hJ9mNqR2tA4bD6eF8gHn", 1286, 2068), ("#", 2085, 2102)])]
        #expect(merged(l, r) == ["export GITHUB_TOKEN=ghp_aB3dE5fG7hJ9mNqR2tA4bD6eF8gHn #"])
    }

    @Test("whole wins unless it is empty or tiled beats it by more than 5%")
    func choiceMargin() throws {
        let whole = [o(String(repeating: "x", count: 262), x: 0, y: 0)]
        let tiled3 = [o(String(repeating: "y", count: 271), x: 0, y: 0)]      // +3%: seam duplicates
        let tiledMore = [o(String(repeating: "z", count: 400), x: 0, y: 0)]
        #expect(try OCRLayout.recognize(width: 5120, height: 1400, whole: { whole }, tiled: { tiled3 }) == whole)
        #expect(try OCRLayout.recognize(width: 5120, height: 1400, whole: { whole }, tiled: { tiledMore }) == tiledMore)
        #expect(try OCRLayout.recognize(width: 5120, height: 1400, whole: { [] }, tiled: { tiled3 }) == tiled3)
    }

    @Test("separate words keep their space")
    func wordsKeepTheirSpace() {
        #expect(OCRLayout.lines([chars("hello", x: 10), chars("world", x: 10 + 5 * 17 + 17)]) == ["hello world"])
    }

    @Test("under 4096 px: whole only, and tiles only when the whole pass is empty")
    func strategySmall() throws {
        var tiledRan = false
        let found = try OCRLayout.recognize(width: 3000, height: 2000,
                                            whole: { [o("hi", x: 0, y: 0)] },
                                            tiled: { tiledRan = true; return [] })
        #expect(found.map(\.text) == ["hi"] && !tiledRan)
    }

    // Review Focus 1: the owner measured .accurate returning zero lines at 4095×1200, just under
    // the dual-pass threshold. The empty-result fallback is what catches it.
    @Test("the measured 4095×1200 silent-empty case falls back to tiles")
    func strategyFallback() throws {
        let found = try OCRLayout.recognize(width: 4095, height: 1200, whole: { [] },
                                            tiled: { [o("found", x: 0, y: 0)] })
        #expect(found.map(\.text) == ["found"])
    }

    @Test("over 4096 px: both passes, keeping whichever recovers more characters")
    func strategyLarge() throws {
        let partialWhole = [o("127 lines, few tokens", x: 0, y: 0)]
        let fuller = [o("127 lines, few tokens", x: 0, y: 0), o("and the tokens too", x: 0, y: 40)]
        #expect(try OCRLayout.recognize(width: 5120, height: 2880, whole: { partialWhole }, tiled: { fuller }) == fuller)
        #expect(try OCRLayout.recognize(width: 5120, height: 2880, whole: { fuller }, tiled: { partialWhole }) == fuller)
    }
}
