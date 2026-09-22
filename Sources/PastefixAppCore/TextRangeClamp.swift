import Foundation

/// Carries a text selection across a buffer replacement.
///
/// The app binds `AppModel.editorSelection` into a macOS 15 `TextEditor(text:selection:)`, and a
/// `TextSelection` holds `Range<String.Index>` values — indices into the exact string they were
/// made from. When a transform, an undo or a redo swaps a new buffer in underneath, those indices
/// are stale: applying them to a shorter string is undefined and traps. Clearing the selection
/// avoids the trap but throws the caret to the start of the buffer on every apply, so instead the
/// selection is re-expressed against the new text at the same UTF-16 offsets, and only dropped
/// when those offsets don't exist there.
///
/// Lives here rather than in the app target so it is reachable from `swift test`; it deliberately
/// knows nothing about `TextSelection` (a SwiftUI type), which the caller unwraps and rebuilds.
public enum TextRangeClamp {
    /// Re-expresses `range` — a range of `old` — at the same UTF-16 offsets in `new`.
    ///
    /// Returns nil when the offsets don't fit `new`, when `range` isn't within `old` at all, or
    /// when an offset lands inside a surrogate pair or a grapheme in `new` (no `String.Index`
    /// exists there, and a selection that splits a character is not one the editor can use).
    /// Offsets, not content: the clamp makes no claim that the text under the selection survived
    /// the replacement, only that the selection is expressible and safe.
    public static func remap(_ range: Range<String.Index>, from old: String, to new: String) -> Range<String.Index>? {
        // Comparing indices is offset arithmetic and is safe even across strings; *measuring* a
        // distance to an out-of-bounds index is not, so bound the range before touching the view.
        guard range.upperBound <= old.endIndex else { return nil }
        let lower = old.utf16.distance(from: old.utf16.startIndex, to: range.lowerBound)
        let upper = old.utf16.distance(from: old.utf16.startIndex, to: range.upperBound)
        let u = new.utf16
        guard lower >= 0, upper <= u.count else { return nil }
        guard let lo = u.index(u.startIndex, offsetBy: lower, limitedBy: u.endIndex)?.samePosition(in: new),
              let hi = u.index(u.startIndex, offsetBy: upper, limitedBy: u.endIndex)?.samePosition(in: new),
              lo <= hi else { return nil }
        return lo..<hi
    }
}
