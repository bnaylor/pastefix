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

    @Test("tiles cover the image, overlap by 64 px, and clip at the edges")
    func tiles() {
        #expect(OCRLayout.tiles(width: 1000, height: 800) == [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        let t = OCRLayout.tiles(width: 5000, height: 2100)
        #expect(t.count == 3 * 2)
        #expect(t.contains(CGRect(x: 0, y: 0, width: 2048, height: 2048)))
        #expect(t.contains(CGRect(x: 1984, y: 0, width: 2048, height: 2048)))       // 2048 - 64
        #expect(t.contains(CGRect(x: 3968, y: 1984, width: 1032, height: 116)))     // clipped
        #expect(t.allSatisfy { $0.maxX <= 5000 && $0.maxY <= 2100 })
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
                                   tile: CGRect(x: 0, y: 0, width: 2048, height: 2048), imageWidth: 5120, imageHeight: 1400)
        let right = OCRLayout.owned([chars(rightSeen, x: start + CGFloat(skip) * 17)],
                                    tile: CGRect(x: 1984, y: 0, width: 2048, height: 2048), imageWidth: 5120, imageHeight: 1400)
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
                                   tile: leftTile, imageWidth: 5120, imageHeight: 1400)
        let right = OCRLayout.owned([wordBoxed([("5eF7gH9iJkMnPqRsTuVwXyZ23", 1984, 2417), ("#", 2421, 2450), ("trailing", 2454, 2594)])],
                                    tile: rightTile, imageWidth: 5120, imageHeight: 1400)
        #expect(OCRLayout.lines(left + right) == ["export GITHUB_TOKEN=ghp_aB3cD5eF7gH9iJkMnPqRsTuVwXyZ23 # trailing"])
    }

    @Test("an observation without character boxes is owned by the tile holding its centre")
    func ownershipWithoutCharacterBoxes() {
        let tile = CGRect(x: 1984, y: 0, width: 2048, height: 2048)
        #expect(OCRLayout.owned([o("left of the midline", x: 1900, y: 10, w: 100)], tile: tile, imageWidth: 5120, imageHeight: 1400).isEmpty)
        #expect(OCRLayout.owned([o("right of it", x: 2100, y: 10, w: 100)], tile: tile, imageWidth: 5120, imageHeight: 1400).count == 1)
    }

    @Test("the image's own edges are owned outright; only shared overlaps are split")
    func ownershipAtImageEdges() {
        let only = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(OCRLayout.owned([chars("edge", x: 0), chars("tail", x: 930)], tile: only, imageWidth: 1000, imageHeight: 800)
                    .map(\.text) == ["edge", "tail"])
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
