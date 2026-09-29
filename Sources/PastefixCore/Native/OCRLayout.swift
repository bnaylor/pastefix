import Foundation
import CoreGraphics

/// One piece of recognised text and where it sits, in image pixels with the origin at the top left.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public init(text: String, box: CGRect) { self.text = text; self.box = box }
}

/// The pure half of OCR (#19): how observations become lines, how an image is tiled, how tiles'
/// readings are joined back into one, and when to tile. Kept apart from Vision so every rule is
/// tested on constructed readings.
public enum OCRLayout {
    public static let tileSize = 2048
    /// Wide enough that any line crossing a seam is read by both tiles over ~45 characters at 28 pt,
    /// which is what the splice aligns on (#106). Costs roughly a third more tile area than a thin
    /// overlap.
    public static let tileOverlap = 768
    /// Over this longest side both passes run (spec, part 2): on the owner's measurements,
    /// always-tiling lost recall on a real capture while a synthetic 5K render needed tiles.
    public static let dualPassThreshold = 4096
    /// The shortest run of matching characters a splice may align on.
    static let minimumRun = 4

    /// Observations rebuilt into lines: grouped by overlapping vertical extent, top to bottom, each
    /// group joined left to right with a space.
    public static func lines(_ observations: [OCRObservation]) -> [String] {
        lineGroups(observations).map(\.text)
    }

    static func lineGroups(_ observations: [OCRObservation]) -> [OCRObservation] {
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
            let members = group.members.sorted { $0.box.minX < $1.box.minX }
            let box = members.dropFirst().reduce(members[0].box) { $0.union($1.box) }
            return OCRObservation(text: members.map(\.text).joined(separator: " "), box: box)
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

    /// One tile's reading of one physical line.
    private struct Reading {
        let text: [Character]
        let box: CGRect
        let tile: CGRect
        var charWidth: CGFloat { box.width / CGFloat(max(text.count, 1)) }
    }

    /// Every tile's readings joined into one reading of the image (#106), on **content**, not word
    /// geometry. Merging words across tiles leaked at every seam, because each tile segments the same
    /// text into words differently and Vision's per-character boxes are really per word (measured,
    /// #105 review: 30 → 9 of 105 swept lines still wrong after three fixes).
    ///
    /// 1. Each tile's observations become lines; a line is kept only by the tile row that owns its
    ///    vertical centre (half of each vertical overlap), so each physical line comes from one row.
    /// 2. Readings of the same physical line from horizontally adjacent tiles are spliced left to
    ///    right. With the overlap wide, both contain the overlap's text; they are aligned on the
    ///    longest run of matching characters near where geometry puts the alignment, and joined in
    ///    the middle of that run — away from the glyph each tile's edge cut and misread, which sits at
    ///    the far ends. Geometry narrows, content pins: plain longest-common-substring would align
    ///    repetitive text ("=====", a repeated pattern) a period off.
    /// 3. With no run of `minimumRun` characters, geometry alone cuts each reading at the overlap's
    ///    midline.
    public static func merged(_ perTile: [(tile: CGRect, observations: [OCRObservation])],
                              imageWidth: Int, imageHeight: Int) -> [OCRObservation] {
        let half = CGFloat(tileOverlap) / 2
        var readings: [Reading] = []
        for (tile, observations) in perTile {
            let ownedMinY = tile.minY > 0 ? tile.minY + half : -.infinity
            let ownedMaxY = tile.maxY < CGFloat(imageHeight) ? tile.maxY - half : .infinity
            for line in lineGroups(observations) where line.box.midY >= ownedMinY && line.box.midY < ownedMaxY {
                readings.append(Reading(text: Array(line.text), box: line.box, tile: tile))
            }
        }
        // Readings of one physical line overlap vertically; distinct lines don't.
        var clusters: [[Reading]] = []
        for reading in readings.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let i = clusters.indices.last, let rep = clusters[i].first,
               verticalOverlap(rep.box.minY, rep.box.maxY, reading.box.minY, reading.box.maxY)
                >= 0.5 * min(rep.box.height, reading.box.height) {
                clusters[i].append(reading)
            } else {
                clusters.append([reading])
            }
        }
        return clusters.map { spliced($0.sorted { $0.box.minX < $1.box.minX }) }
    }

    /// One physical line from its readings, left to right.
    private static func spliced(_ readings: [Reading]) -> OCRObservation {
        var head: [Character] = []
        var tail = readings[0], tailStart = 0
        var box = readings[0].box
        for next in readings.dropFirst() {
            box = box.union(next.box)
            // A reading ending no further right than the one before it adds nothing: a tile that held
            // the whole line starts where the cut reading does, and taking the cut one as the
            // continuation lost everything past its edge (measured: lines truncated at a tile edge
            // whenever a middle tile held them whole).
            if next.box.maxX <= tail.box.maxX { continue }
            guard next.box.minX < tail.box.maxX else {
                // Side by side, not overlapping: separate words on one line.
                head += tail.text[tailStart...] + [" "]
                tail = next; tailStart = 0
                continue
            }
            if let (offset, split) = alignment(tail, next), offset + split >= tailStart {
                head += tail.text[tailStart..<(offset + split)]
                tailStart = split
            } else {
                // No common run: each reading up to the overlap's midline.
                let midline = (next.tile.minX + tail.tile.maxX) / 2
                let cutTail = max(tailStart, characters(of: tail, before: midline))
                head += tail.text[tailStart..<cutTail]
                tailStart = characters(of: next, before: midline)
            }
            tail = next
        }
        head += tail.text[min(tailStart, tail.text.count)...]
        return OCRObservation(text: String(head).trimmingCharacters(in: .whitespaces), box: box)
    }

    /// How many of a reading's characters have their (evenly spread) centre before `x`.
    private static func characters(of reading: Reading, before x: CGFloat) -> Int {
        let n = reading.text.count
        guard n > 0, reading.box.width > 0 else { return 0 }
        let k = Int(((x - reading.box.minX) / reading.charWidth - 0.5).rounded(.up))
        return min(max(k, 0), n)
    }

    /// Where `next` lines up with `tail`: `offset` is the index in `tail` of `next`'s first character,
    /// and `split` the index in `next` to switch readings at — the middle of the longest matching
    /// run. Only offsets within a few characters of where geometry puts `next` are tried.
    private static func alignment(_ tail: Reading, _ next: Reading) -> (offset: Int, split: Int)? {
        let expected = Int(((next.box.minX - tail.box.minX) / tail.charWidth).rounded())
        let window = max(6, tail.text.count / 10)
        var best: (offset: Int, start: Int, length: Int)?
        for offset in max(0, expected - window)...max(0, expected + window) where offset < tail.text.count {
            var run = 0
            for k in 0..<min(next.text.count, tail.text.count - offset) {
                if tail.text[offset + k] == next.text[k] {
                    run += 1
                    let start = k - run + 1
                    let better = best.map { run > $0.length || (run == $0.length && abs(offset - expected) < abs($0.offset - expected)) } ?? true
                    if better { best = (offset, start, run) }
                } else {
                    run = 0
                }
            }
        }
        guard let best, best.length >= minimumRun else { return nil }
        return (best.offset, best.start + best.length / 2)
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
