import Foundation
import PastefixCore

/// Applies the user's app-local enable/reorder preferences on top of the
/// registry's loaded transformers. Pure; does not touch disk or the engine.
public enum TransformOverrides {
    public static func apply(
        to loaded: [any Transformer],
        enabled: [String: Bool],
        order: [String: Int]
    ) -> [any Transformer] {
        let kept = loaded.enumerated().filter { enabled[$0.element.id] != false }
        // Sort key: explicit order if present, else a large sentinel; ties by load index.
        let sentinel = Int.max
        return kept
            .sorted { lhs, rhs in
                let lo = order[lhs.element.id] ?? sentinel
                let ro = order[rhs.element.id] ?? sentinel
                if lo != ro { return lo < ro }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
