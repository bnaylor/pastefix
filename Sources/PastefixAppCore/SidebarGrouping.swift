import Foundation
import PastefixCore

public struct SidebarSection: Identifiable, Sendable {
    public let title: String
    public let transformers: [any Transformer]
    /// True for the Favorites section (#26). Its identity isn't its title, so a script category
    /// that happens to be called "Favorites" can't collide with it.
    public var isFavorites = false
    public var id: String { isFavorites ? "\u{0}favorites" : title }

    public init(title: String, transformers: [any Transformer], isFavorites: Bool = false) {
        self.title = title
        self.transformers = transformers
        self.isFavorites = isFavorites
    }
}

/// Groups transforms for the sidebar: built-in categories in their fixed order, then any
/// custom categories alphabetically in user-facing order (`localizedStandardCompare`, so
/// "Alpha" precedes "beta" and "item10" follows "item2"), then "Scripts" (the bucket for
/// transforms with no category). Order within a section is the incoming (user) order.
public enum SidebarGrouping {
    public static let favoritesTitle = "Favorites"

    /// `favorites` (#26): transformer ids, in the order the user added them. Those present in
    /// `transformers` — so enabled and applicable here — lead in a Favorites section, and stay in
    /// their own category as well. None present, no section.
    public static func sections(_ transformers: [any Transformer], favorites: [String] = []) -> [SidebarSection] {
        let byID = Dictionary(transformers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favorite = favorites.compactMap { byID[$0] }
        let head = favorite.isEmpty ? [] : [SidebarSection(title: favoritesTitle, transformers: favorite, isFavorites: true)]
        return head + categorySections(transformers)
    }

    private static func categorySections(_ transformers: [any Transformer]) -> [SidebarSection] {
        var buckets: [String: [any Transformer]] = [:]
        for t in transformers {
            buckets[t.category ?? TransformCategory.scripts, default: []].append(t)
        }
        let builtin = TransformCategory.builtinOrder.filter { buckets[$0] != nil }
        let custom = buckets.keys
            .filter { !TransformCategory.builtinOrder.contains($0) && $0 != TransformCategory.scripts }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let tail = buckets[TransformCategory.scripts] == nil ? [] : [TransformCategory.scripts]
        return (builtin + custom + tail).map { SidebarSection(title: $0, transformers: buckets[$0] ?? []) }
    }
}
