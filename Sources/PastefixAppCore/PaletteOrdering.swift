import Foundation
import PastefixCore

/// Stable partition of the palette: transforms whose `applicableKinds` intersect the
/// detected kinds first, then everything else, each group in its incoming order.
/// Nothing is hidden; this sits on top of the user's enable/reorder settings.
public enum PaletteOrdering {
    /// `usage` (#26) only reorders within each group — transforms that fit the detected content
    /// stay ahead of those that don't — and ties keep the configured order.
    public static func order(_ transformers: [any Transformer], for kinds: Set<ContentKind>,
                             usage: [String: TransformUsage] = [:], now: Date = Date()) -> [any Transformer] {
        var front: [any Transformer] = []
        var back: [any Transformer] = []
        for t in transformers {
            if !kinds.isEmpty, let k = t.applicableKinds, !k.isDisjoint(with: kinds) { front.append(t) } else { back.append(t) }
        }
        guard !usage.isEmpty else { return front + back }
        return byUsage(front, usage, now) + byUsage(back, usage, now)
    }

    /// Highest score first; equal scores (including never used) keep their order.
    private static func byUsage(_ items: [any Transformer], _ usage: [String: TransformUsage], _ now: Date) -> [any Transformer] {
        items.enumerated()
            .map { (index: $0.offset, t: $0.element, score: TransformUsage.score(usage[$0.element.id], now: now)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.t)
    }
}
