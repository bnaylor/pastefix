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

    @Test("an observation seen twice in an overlap is kept once; a fragment inside a whole is dropped")
    func dedupe() {
        let a = o("same", x: 2000, y: 10, w: 60), b = o("same", x: 2002, y: 11, w: 60)
        let whole = o("abcdef", x: 1990, y: 50, w: 120), fragment = o("abc", x: 1990, y: 50, w: 55)
        let kept = OCRLayout.deduplicated([a, b, whole, fragment, o("other", x: 10, y: 10)])
        #expect(kept.map(\.text).sorted() == ["abcdef", "other", "same"])
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
