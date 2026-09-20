import Foundation
import PastefixCore

public struct SidebarSection: Identifiable, Sendable {
    public let title: String
    public var id: String { title }
    public let transformers: [any Transformer]
}

/// Groups transforms for the sidebar: built-in categories in their fixed order, then any
/// custom categories alphabetically, then "Scripts" (the bucket for transforms with no
/// category). Order within a section is the incoming (user) order.
public enum SidebarGrouping {
    public static func sections(_ transformers: [any Transformer]) -> [SidebarSection] {
        var buckets: [String: [any Transformer]] = [:]
        for t in transformers {
            buckets[t.category ?? TransformCategory.scripts, default: []].append(t)
        }
        let builtin = TransformCategory.builtinOrder.filter { buckets[$0] != nil }
        let custom = buckets.keys
            .filter { !TransformCategory.builtinOrder.contains($0) && $0 != TransformCategory.scripts }
            .sorted()
        let tail = buckets[TransformCategory.scripts] == nil ? [] : [TransformCategory.scripts]
        return (builtin + custom + tail).map { SidebarSection(title: $0, transformers: buckets[$0] ?? []) }
    }
}
