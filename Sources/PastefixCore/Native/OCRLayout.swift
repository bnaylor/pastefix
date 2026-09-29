import Foundation
import CoreGraphics

/// One piece of recognised text and where it sits, in image pixels with the origin at the top left.
/// `characterBoxes` holds one box per `Character` when Vision supplied them (empty otherwise); tiling
/// uses them to decide, character by character, which tile owns what an overlap saw twice.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public let characterBoxes: [CGRect]
    public init(text: String, box: CGRect, characterBoxes: [CGRect] = []) {
        self.text = text; self.box = box; self.characterBoxes = characterBoxes
    }
}

/// The pure half of OCR (#19): how observations become lines, how an image is tiled, and when to
/// tile. Kept apart from Vision so every rule is tested on constructed observations.
public enum OCRLayout {
    public static let tileSize = 2048
    public static let tileOverlap = 64
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
            // Fragments whose boxes meet (a gap under half a character — estimated positions carry
            // some slop) are one token cut by a tile boundary and join with no space; anything further
            // apart, a real space being a whole character wide, is separate words.
            var line = "", previous: OCRObservation?
            for obs in group.members.sorted(by: { $0.box.minX < $1.box.minX }) {
                if let previous {
                    let charWidth = obs.box.width / CGFloat(max(obs.text.count, 1))
                    line += obs.box.minX - previous.box.maxX < charWidth / 2 ? "" : " "
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
    public static func owned(_ observations: [OCRObservation], tile: CGRect, imageWidth: Int, imageHeight: Int) -> [OCRObservation] {
        let half = CGFloat(tileOverlap) / 2
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
            return OCRObservation(text: String(kept.map { characters[$0] }), box: box,
                                  characterBoxes: kept.map { estimated[$0] ?? box })
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

    public static func characterCount(_ observations: [OCRObservation]) -> Int {
        observations.reduce(0) { $0 + $1.text.count }
    }

    /// The size-dependent strategy. Over `dualPassThreshold` both passes run and the one recovering
    /// more characters wins (a tie keeps the whole pass). Otherwise the whole pass, with tiles only
    /// when it returned nothing — `.accurate` can return zero lines, silently, on an image full of
    /// text (the owner measured 4095×1200, just under the threshold).
    public static func recognize(width: Int, height: Int,
                                 whole: () throws -> [OCRObservation],
                                 tiled: () throws -> [OCRObservation]) rethrows -> [OCRObservation] {
        if max(width, height) > dualPassThreshold {
            let a = try whole(), b = try tiled()
            return characterCount(b) > characterCount(a) ? b : a
        }
        let a = try whole()
        return a.isEmpty ? try tiled() : a
    }
}
