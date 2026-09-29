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

    /// How Vision reads a line through a tile, simulated: the characters wholly inside the tile, and
    /// a misread glyph wherever the tile's interior edge cuts one ("!" on the right, ")" on the left)
    /// — both measured behaviours (#105 review). 17 px a character.
    private func readings(_ lines: [(text: String, x: CGFloat, y: CGFloat)], tiles: [CGRect],
                          imageWidth: CGFloat, imageHeight: CGFloat) -> [(tile: CGRect, observations: [OCRObservation])] {
        let w: CGFloat = 17, h: CGFloat = 20
        return tiles.map { tile in
            let obs: [OCRObservation] = lines.compactMap { line in
                guard line.y >= tile.minY, line.y + h <= tile.maxY else { return nil }
                var text = "", minX = CGFloat.infinity, maxX = -CGFloat.infinity
                for (k, ch) in line.text.enumerated() {
                    let x0 = line.x + CGFloat(k) * w, x1 = x0 + w
                    if x0 >= tile.minX, x1 <= tile.maxX {
                        text.append(ch); minX = min(minX, x0); maxX = max(maxX, x1)
                    } else if x0 < tile.minX, x1 > tile.minX, tile.minX > 0 {
                        text.append(")"); minX = min(minX, tile.minX)
                    } else if x0 < tile.maxX, x1 > tile.maxX, tile.maxX < imageWidth {
                        text.append("!"); maxX = max(maxX, tile.maxX)
                    }
                }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return OCRObservation(text: trimmed, box: CGRect(x: minX, y: line.y, width: maxX - minX, height: h))
            }
            return (tile, obs)
        }
    }

    private let row = [CGRect(x: 0, y: 0, width: 2048, height: 1400), CGRect(x: 1280, y: 0, width: 2048, height: 1400)]
    private func spliced(_ lines: [(text: String, x: CGFloat, y: CGFloat)], tiles: [CGRect]? = nil,
                         width: CGFloat = 3328, height: CGFloat = 1400) -> [String] {
        let perTile = readings(lines, tiles: tiles ?? row, imageWidth: width, imageHeight: height)
        return OCRLayout.lines(OCRLayout.merged(perTile, imageWidth: Int(width), imageHeight: Int(height)))
    }

    // #106: splice on content. Each tile's reading ends (or starts) with the glyph its edge cut,
    // misread; the two readings share the overlap's ~45 characters, and the splice sits mid-run.
    @Test("a token across a tile boundary comes out exact, misread edge glyphs discarded")
    func spliceStraddlingToken() {
        let line = "export GITHUB_TOKEN=ghp_aB3dE5fG7hJ9mNqR2tA4bD6eF8gHn # after"
        #expect(spliced([(line, 1150, 100)]) == [line])
    }

    // #106 acceptance: a one-character word in the overlap was doubled ("## straddles").
    @Test("a one-character word inside the overlap appears once")
    func oneCharacterWord() {
        let line = "before the seam we have words and then # straddles the overlap here"
        #expect(spliced([(line, 1200, 100)]) == [line])
    }

    // #106 acceptance: a whole word beside a fragment lost its space, gluing an AKIA key to the next
    // token so the key scanned clean.
    @Test("a word beside the seam keeps its space")
    func spaceBesideTheSeam() {
        let line = "keys AKIAIOSFODNN7EXAMPLE wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY end"
        for x in stride(from: CGFloat(1000), through: 1500, by: 50) {
            #expect(spliced([(line, x, 100)]) == [line], "at x \(x)")
        }
    }

    @Test("a line crossing three tiles splices at both seams")
    func threeTiles() {
        let tiles = [CGRect(x: 0, y: 0, width: 2048, height: 1400), CGRect(x: 1280, y: 0, width: 2048, height: 1400),
                     CGRect(x: 2560, y: 0, width: 2048, height: 1400)]
        let line = String(repeating: "token-\u{41}bc123 ", count: 14) + "end"          // ~3900 px wide
        #expect(spliced([(line, 300, 100)], tiles: tiles, width: 4608) == [line])
    }

    // A middle tile holds the line whole, starting where the left tile's cut reading starts: the
    // cut reading must not become the continuation.
    @Test("a reading held whole by one tile is not truncated by another tile's cut reading")
    func wholeReadingWins() {
        let whole = OCRObservation(text: "export GITHUB_TOKEN=ghp_aB3dE5fG7hJ9mNqR2tA4bD6eF8gHn # after",
                                   box: CGRect(x: 1450, y: 100, width: 1037, height: 20))
        let cut = OCRObservation(text: "export GITHUB_TOKEN=ghp_aB3dE5fG7hJ!",
                                 box: CGRect(x: 1450, y: 100, width: 598, height: 20))
        for order in [[(row[1], [whole]), (row[0], [cut])], [(row[0], [cut]), (row[1], [whole])]] {
            #expect(OCRLayout.lines(OCRLayout.merged(order, imageWidth: 3328, imageHeight: 1400)) == [whole.text])
        }
    }

    @Test("a line wholly inside the overlap, read by both tiles, appears once")
    func insideTheOverlap() {
        #expect(spliced([("only in the overlap", 1400, 100)]) == ["only in the overlap"])
    }

    @Test("a line in a vertical overlap is taken from one tile row")
    func verticalOverlap() {
        let column = [CGRect(x: 0, y: 0, width: 2048, height: 2048), CGRect(x: 0, y: 1280, width: 2048, height: 2048)]
        #expect(spliced([("above", 10, 900), ("in both rows", 10, 1500), ("below", 10, 2600)],
                        tiles: column, width: 2048, height: 3328) == ["above", "in both rows", "below"])
    }

    @Test("lines at different heights stay separate lines")
    func separateLines() {
        #expect(spliced([("first line of text here", 1500, 100), ("second line of text", 1500, 200)])
                == ["first line of text here", "second line of text"])
    }

    // No common run: text longer than the overlap that Vision read differently in the two tiles.
    // Geometry decides: each reading up to the overlap's midline (1664).
    @Test("with no common run, each reading is cut at the overlap's midline")
    func noCommonRun() {
        let left = OCRObservation(text: String(repeating: "a", count: 50), box: CGRect(x: 1198, y: 100, width: 850, height: 20))
        let right = OCRObservation(text: String(repeating: "b", count: 50), box: CGRect(x: 1280, y: 100, width: 850, height: 20))
        let merged = OCRLayout.merged([(row[0], [left]), (row[1], [right])], imageWidth: 3328, imageHeight: 1400)
        #expect(OCRLayout.lines(merged) == [String(repeating: "a", count: 27) + String(repeating: "b", count: 27)])
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
