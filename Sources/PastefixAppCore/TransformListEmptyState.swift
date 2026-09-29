import Foundation

/// The sentence an empty transform list shows instead of a blank grey column, which reads as a
/// broken panel. Shared by the ⌘K palette and the sidebar so the two never disagree.
///
/// Two causes: a search that matched nothing, and a Settings list with none of this session's
/// transforms left enabled. Image sessions have transforms of their own (Strip Image Metadata,
/// Extract Text), so an empty image list means they were turned off, not that none exist.
public enum TransformListEmptyState {
    public static func message(query: String, showsImage: Bool) -> String {
        // Blank is not a search: `TransformSearch.rank` trims the same way and lists everything.
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching transforms" }
        return showsImage ? "No image transforms enabled" : "No transforms enabled"
    }
}
