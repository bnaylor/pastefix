import Foundation

/// How often, and how recently, a transform was used (#26). Recorded when an apply changes the
/// buffer, stored locally with the other transform settings, and used by the ⌘K palette only to
/// break ties — never to outrank match quality or fit with the detected content.
public struct TransformUsage: Codable, Equatable, Sendable {
    public var count: Int
    public var lastUsed: Date

    public init(count: Int, lastUsed: Date) {
        self.count = count
        self.lastUsed = lastUsed
    }

    /// Frequency that fades: `count × 0.5^(days since last use ÷ 14)`. A transform used ten times
    /// a month ago ranks with one used about two and a half times today. A last-used date in the
    /// future (a clock moved back) counts as now, so it never inflates a score.
    public static func score(_ usage: TransformUsage?, now: Date) -> Double {
        guard let usage else { return 0 }
        let days = max(0, now.timeIntervalSince(usage.lastUsed)) / 86_400
        return Double(usage.count) * pow(0.5, days / halfLifeDays)
    }

    public static let halfLifeDays = 14.0
}
