import Foundation
import CoreGraphics

/// One piece of recognised text and where it sits, in image pixels with the origin at the top left.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public init(text: String, box: CGRect) { self.text = text; self.box = box }
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
        return groups.map { $0.members.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
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

    /// Drops what the overlaps recognised twice: the same text in boxes that mostly coincide, and a
    /// fragment whose box lies mostly inside a longer observation that contains its text.
    public static func deduplicated(_ observations: [OCRObservation]) -> [OCRObservation] {
        var kept: [OCRObservation] = []
        for obs in observations.sorted(by: { $0.text.count > $1.text.count }) {
            let duplicate = kept.contains { k in
                let shared = k.box.intersection(obs.box)
                guard !shared.isNull else { return false }
                let area = shared.width * shared.height
                let sameText = k.text == obs.text && area >= 0.5 * min(k.box.width * k.box.height, obs.box.width * obs.box.height)
                let fragment = k.text.contains(obs.text) && area >= 0.8 * obs.box.width * obs.box.height
                return sameText || fragment
            }
            if !duplicate { kept.append(obs) }
        }
        return kept
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
