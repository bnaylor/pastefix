import Foundation
import PastefixCore

/// Stable partition of the palette: transforms whose `applicableKinds` intersect the
/// detected kinds first, then everything else, each group in its incoming order.
/// Nothing is hidden; this sits on top of the user's enable/reorder settings.
public enum PaletteOrdering {
    public static func order(_ transformers: [any Transformer], for kinds: Set<ContentKind>) -> [any Transformer] {
        guard !kinds.isEmpty else { return transformers }
        var front: [any Transformer] = []
        var back: [any Transformer] = []
        for t in transformers {
            if let k = t.applicableKinds, !k.isDisjoint(with: kinds) { front.append(t) } else { back.append(t) }
        }
        return front + back
    }
}
