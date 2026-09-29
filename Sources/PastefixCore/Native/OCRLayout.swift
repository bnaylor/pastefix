import Foundation
import CoreGraphics

/// One piece of recognised text and where it sits, in image pixels with the origin at the top left.
/// `characterBoxes` holds one box per `Character` when Vision supplied them (empty otherwise); tiling
/// uses them to decide, character by character, which tile owns what an overlap saw twice.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public let characterBoxes: [CGRect]
    /// A piece of one word that a tile's edge cut, trimmed to what its tile owns (`owned`). Two
    /// fragments that meet are one word and join with no space; everything else is separated by a
    /// space, as Vision's own word breaks say — its word boxes take in half the space beside them,
    /// so a gap between boxes cannot tell words apart (measured: 4 px between "export" and the next
    /// word in 28 pt Menlo).
    public let isFragment: Bool
    public init(text: String, box: CGRect, characterBoxes: [CGRect] = [], isFragment: Bool = false) {
        self.text = text; self.box = box; self.characterBoxes = characterBoxes; self.isFragment = isFragment
    }
}

/// The pure half of OCR (#19): how observations become lines, how an image is tiled, and when to
/// tile. Kept apart from Vision so every rule is tested on constructed observations.
public enum OCRLayout {
    public static let tileSize = 2048
    /// Wider than the longest token worth protecting — a 40-character key in 28 pt Menlo is ~670 px
    /// — so every ordinary word lies whole inside at least one tile and is never split or estimated
    /// (#105 review: at 64 px, estimating positions at the seam left a one-character error in 30 of
    /// 105 swept lines). Costs roughly a third more tile area.
    public static let tileOverlap = 768
    /// Over this longest side both passes run (spec, part 2): on the owner's measurements,
    /// always-tiling lost recall on a real capture while a synthetic 5K render needed tiles.
    public static let dualPassThreshold = 4096

    /// Observations rebuilt into lines: grouped by overlapping vertical extent, top to bottom,
    /// each group joined left to right. A token Vision split across two observations comes out whole.
    public static func lines(_ observations: [OCRObservation]) -> [String] {
        var groups: [(minY: CGFloat, maxY: CGFloat, members: [OCRObservation])] = []
        for obs in observations.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let i = groups.indices.last,
               verticalOverlap(groups[i].minY, groups[i].maxY, obs.box.minY, obs.box.maxY)
                >= 0.5 * min(groups[i].maxY - groups[i].minY, obs.box.height) {
                groups[i].minY = min(groups[i].minY, obs.box.minY)
                groups[i].maxY = max(groups[i].maxY, obs.box.maxY)
                groups[i].members.append(obs)
            } else {
                groups.append((obs.box.minY, obs.box.maxY, [obs]))
            }
        }
        return groups.map { group in
            // A fragment meeting its neighbour (within half a character — estimated positions carry
            // some slop) is part of the word a tile boundary cut, and joins it with no space: another
            // fragment, or the whole word whose gap it filled. Anything else gets a space.
            var line = "", previous: OCRObservation?
            for obs in group.members.sorted(by: { $0.box.minX < $1.box.minX }) {
                if let previous {
                    let charWidth = obs.box.width / CGFloat(max(obs.text.count, 1))
                    let halves = (previous.isFragment || obs.isFragment) && obs.box.minX - previous.box.maxX < charWidth / 2
                    line += halves ? "" : " "
                }
                line += obs.text
                previous = obs
            }
            return line
        }
    }

    private static func verticalOverlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// Tiles of `tileSize` stepping by `tileSize - tileOverlap`, clipped to the image.
    public static func tiles(width: Int, height: Int) -> [CGRect] {
        func starts(_ length: Int) -> [Int] {
            guard length > tileSize else { return [0] }
            return Array(stride(from: 0, to: length - tileOverlap, by: tileSize - tileOverlap))
        }
        return starts(height).flatMap { y in
            starts(width).map { x in
                CGRect(x: x, y: y, width: min(tileSize, width - x), height: min(tileSize, height - y))
            }
        }
    }

    /// The observations a tile *owns*. Each tile shares half of every overlap with its neighbour
    /// (the image's own edges are owned outright), so every character belongs to exactly one tile:
    /// a character is kept when its box's centre lies in the owned region. That drops what an overlap
    /// saw twice, and the glyph a tile's edge cut in half — which each tile misreads differently, so
    /// no text comparison could match the two halves (#105 review, measured on real tiled output).
    /// An observation without character boxes is kept whole when its centre is owned.
    public static func owned(_ observations: [OCRObservation], tile: CGRect, imageWidth: Int, imageHeight: Int,
                             overlap: Int = tileOverlap) -> [OCRObservation] {
        let half = CGFloat(overlap) / 2
        let region = CGRect(
            x: tile.minX > 0 ? tile.minX + half : tile.minX,
            y: tile.minY > 0 ? tile.minY + half : tile.minY,
            width: 0, height: 0)
        let maxX = tile.maxX < CGFloat(imageWidth) ? tile.maxX - half : .infinity
        let maxY = tile.maxY < CGFloat(imageHeight) ? tile.maxY - half : .infinity
        func isOwned(_ box: CGRect) -> Bool {
            box.midX >= region.minX && box.midX < maxX && box.midY >= region.minY && box.midY < maxY
        }
        return observations.compactMap { obs in
            guard obs.characterBoxes.count == obs.text.count else { return isOwned(obs.box) ? obs : nil }
            let characters = Array(obs.text)
            let estimated = estimatedBoxes(characters, obs.characterBoxes)
            // A space has no box worth judging (Vision gives it an empty one), so it goes with the
            // character before it — or, at the start, the first character after it that has a box.
            var decisions: [Bool] = estimated.map { $0.map(isOwned) ?? false }
            for i in characters.indices where estimated[i] == nil {
                let before = characters.indices.prefix(i).last { estimated[$0] != nil }
                let after = characters.indices.suffix(from: i + 1).first { estimated[$0] != nil }
                decisions[i] = (before ?? after).map { decisions[$0] } ?? false
            }
            let kept = characters.indices.filter { decisions[$0] }
            guard let box = kept.compactMap({ estimated[$0] }).reduce(nil, { (acc: CGRect?, r) in acc.map { $0.union(r) } ?? r })
            else { return nil }
            // A fragment only if the trim actually cut something off.
            return OCRObservation(text: String(kept.map { characters[$0] }), box: box,
                                  characterBoxes: kept.map { estimated[$0] ?? box },
                                  isFragment: kept.count < characters.count)
        }
    }

    /// Where each character really is. Vision's `.accurate` recogniser gives every character of a
    /// word the WORD's box (measured, #105 review), so a run of characters sharing one box is spread
    /// evenly across it — exact for monospace, close for proportional text. Whitespace, whose box
    /// Vision leaves empty, gets nil and inherits its neighbour's ownership.
    static func estimatedBoxes(_ characters: [Character], _ boxes: [CGRect]) -> [CGRect?] {
        var out = [CGRect?](repeating: nil, count: characters.count)
        var i = 0
        while i < characters.count {
            if characters[i].isWhitespace || boxes[i].width <= 0 { i += 1; continue }
            var j = i
            while j + 1 < characters.count, !characters[j + 1].isWhitespace, boxes[j + 1] == boxes[i] { j += 1 }
            let run = boxes[i], count = CGFloat(j - i + 1), step = run.width / count
            for k in i...j {
                out[k] = CGRect(x: run.minX + CGFloat(k - i) * step, y: run.minY, width: step, height: run.height)
            }
            i = j + 1
        }
        return out
    }

    /// A Vision observation as its words: runs of characters sharing one box (Vision's `.accurate`
    /// boxes are per word), split at whitespace. An observation without character boxes is one word.
    static func words(_ obs: OCRObservation) -> [OCRObservation] {
        guard obs.characterBoxes.count == obs.text.count else { return [obs] }
        var words: [OCRObservation] = [], text = "", boxes: [CGRect] = []
        func flush() {
            guard !text.isEmpty, let first = boxes.first else { return }
            words.append(OCRObservation(text: text, box: boxes.dropFirst().reduce(first) { $0.union($1) }, characterBoxes: boxes))
            text = ""; boxes = []
        }
        for (character, box) in zip(obs.text, obs.characterBoxes) {
            if character.isWhitespace || box.width <= 0 { flush(); continue }
            if let last = boxes.last, last != box { flush() }
            text.append(character); boxes.append(box)
        }
        flush()
        return words
    }

    /// Whether a tile's interior edge cut this word: its box comes within one character of that
    /// edge. Not a pixel or two — Vision's box for a cut word can stop short of the edge (measured:
    /// 2045 against 2048). Erring towards "cut" is safe: with the overlap wider than a word, a word
    /// that really was whole here is whole in the neighbouring tile too.
    private static func isCut(_ word: OCRObservation, by tile: CGRect, imageWidth: Int, imageHeight: Int) -> Bool {
        let box = word.box
        let margin = max(2, box.width / CGFloat(max(word.text.count, 1)))
        return (tile.minX > 0 && box.minX <= tile.minX + margin)
            || (tile.maxX < CGFloat(imageWidth) && box.maxX >= tile.maxX - margin)
            || (tile.minY > 0 && box.minY <= tile.minY + margin)
            || (tile.maxY < CGFloat(imageHeight) && box.maxY >= tile.maxY - margin)
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Every tile's words, merged into one reading of the image (#105 review). A word Vision read
    /// **whole** in some tile is taken from there as Vision read it — nothing split, nothing
    /// estimated — and one read whole by two tiles is kept once, matched by position (IoU), never by
    /// text, since two tiles can misread the same word differently; the tile owning its centre wins.
    /// Views of a word that a tile's edge cut are dropped when a whole reading covers them. What is
    /// left is a word longer than the overlap, cut in every tile: only there are character positions
    /// estimated (`owned`), so its halves join.
    public static func merged(_ perTile: [(tile: CGRect, observations: [OCRObservation])],
                              imageWidth: Int, imageHeight: Int) -> [OCRObservation] {
        var whole: [(word: OCRObservation, ownsCentre: Bool)] = []
        var cut: [(word: OCRObservation, tile: CGRect)] = []
        for (tile, observations) in perTile {
            for word in observations.flatMap(words) {
                if isCut(word, by: tile, imageWidth: imageWidth, imageHeight: imageHeight) {
                    cut.append((word, tile))
                } else {
                    let centre = OCRObservation(text: "·", box: CGRect(x: word.box.midX, y: word.box.midY, width: 0, height: 0))
                    let owns = !owned([centre], tile: tile, imageWidth: imageWidth, imageHeight: imageHeight).isEmpty
                    whole.append((word, owns))
                }
            }
        }
        var kept: [OCRObservation] = []
        for (word, _) in whole.sorted(by: { $0.ownsCentre && !$1.ownsCentre }) {
            let seen = kept.contains { k in
                let shared = area(k.box.intersection(word.box))
                return shared > 0.5 * (area(k.box) + area(word.box) - shared)
            }
            if !seen { kept.append(word) }
        }
        // Cut words fill only the gaps the whole words leave. Tiles split text into words differently
        // (measured: one tile read "…E5f" whole and "G7hJ…" cut, the other one fragment spanning
        // both), so a fragment is neither kept nor dropped whole: it keeps the characters its tile
        // owns, minus any lying inside a whole word on the same line. (A "mostly covered, so it's a
        // duplicate" rule dropped the only reading of the token's second half.)
        let wholeWords = kept
        for (word, tile) in cut {
            for piece in owned([word], tile: tile, imageWidth: imageWidth, imageHeight: imageHeight) {
                let characters = Array(piece.text)
                // Within half a character of a whole word's edge counts as inside it: estimated
                // positions drift (a word box's padding stretches the pitch; measured 17.38 px for
                // 17 px glyphs), and a character sitting on the seam is the whole word's.
                let slack = piece.box.width / CGFloat(max(characters.count, 1)) / 2
                let free = characters.indices.filter { i in
                    let c = piece.characterBoxes[i]
                    return !wholeWords.contains { w in
                        c.midX >= w.box.minX - slack && c.midX < w.box.maxX + slack
                            && min(c.maxY, w.box.maxY) - max(c.minY, w.box.minY) >= 0.5 * min(c.height, w.box.height)
                    }
                }
                guard let first = free.first else { continue }
                let boxes = free.map { piece.characterBoxes[$0] }
                kept.append(OCRObservation(text: String(free.map { characters[$0] }),
                                           box: boxes.dropFirst().reduce(piece.characterBoxes[first]) { $0.union($1) },
                                           characterBoxes: boxes, isFragment: true))
            }
        }
        return kept
    }

    public static func characterCount(_ observations: [OCRObservation]) -> Int {
        observations.reduce(0) { $0 + $1.text.count }
    }

    /// The size-dependent strategy. Over `dualPassThreshold` both passes run, and tiled wins only
    /// when the whole pass is empty or tiled recovers more than 5% more characters. Otherwise the whole pass, with tiles only
    /// when it returned nothing — `.accurate` can return zero lines, silently, on an image full of
    /// text (the owner measured 4095×1200, just under the threshold).
    public static func recognize(width: Int, height: Int,
                                 whole: () throws -> [OCRObservation],
                                 tiled: () throws -> [OCRObservation]) rethrows -> [OCRObservation] {
        if max(width, height) > dualPassThreshold {
            let a = try whole(), b = try tiled()
            // Whole unless it is empty or tiled recovers clearly more (> 5%): a few extra characters
            // are likelier seam artefacts than recall (#105 review), and the whole pass has no seams.
            if a.isEmpty { return b }
            return Double(characterCount(b)) > Double(characterCount(a)) * 1.05 ? b : a
        }
        let a = try whole()
        return a.isEmpty ? try tiled() : a
    }
}
