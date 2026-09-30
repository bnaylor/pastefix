import SwiftUI
import PastefixAppCore

/// Whether the editor's selection scopes a transform (#25), and to what: exactly one non-empty range
/// that isn't the whole buffer. A caret, a multi-range selection (⌘-drag) and select-all run on the
/// whole buffer. The one predicate behind both the "Applies to selection" hint and apply, so the two
/// can't disagree.
enum SelectionScope {
    static func scope(for selection: TextSelection?, in text: String) -> TransformScope? {
        guard case .selection(let range) = selection?.indices else { return nil }
        return TextScope.make(selected: range, in: text).map(TransformScope.text)
    }
}
