import Foundation
import PastefixCore

/// The span a transform is scoped to (#25): a UTF-16 range, and the text it covered when the user
/// chose the transform. UTF-16, never `String.Index`: an index is only meaningful in the string it
/// was taken from, and applying one to another string traps (the #111 caret crash). The text is
/// how a stale range is caught: ending an IME composition can change the buffer between the click
/// and the apply, and a range can still convert in bounds while covering different characters.
public struct TransformScope: Sendable, Equatable {
    public let range: NSRange
    public let expected: String

    public init(range: NSRange, expected: String) {
        self.range = range
        self.expected = expected
    }

    /// The scope for `selected` in `text`, or nil when it doesn't scope: a caret (empty), the whole
    /// buffer (select-all is the unscoped case), or a range that isn't expressible in `text`.
    public static func make(selected: Range<String.Index>, in text: String) -> TransformScope? {
        guard !selected.isEmpty, TextRangeClamp.remap(selected, from: text, to: text) != nil else { return nil }
        let ns = NSRange(selected, in: text)
        guard ns.length > 0, ns.length < (text as NSString).length else { return nil }
        return TransformScope(range: ns, expected: String(text[selected]))
    }

    /// The range this scope covers in `text` now, or nil when it's stale: out of bounds, off a
    /// character boundary, or covering something other than `expected`.
    func selected(in text: String) -> Range<String.Index>? {
        guard let r = Range(range, in: text), text[r] == expected else { return nil }
        return r
    }

    /// Selections up to this size rank the palette by their own content. Detection is ~40 ms at
    /// 64 KB (measured, debug and release) — a visible hitch as ⌘K opens — and linear, so ~5 ms here.
    public static let rankingLimitBytes = 8 * 1024

    /// The kinds the ⌘K palette ranks by: the selection's, when there is one within the limit, else
    /// the document's. Runs on the main actor, bounded by `rankingLimitBytes` (AGENTS.md exception).
    public static func rankingKinds(scope: TransformScope?, documentKinds: Set<ContentKind>) -> Set<ContentKind> {
        guard let scope, scope.expected.utf8.count <= rankingLimitBytes else { return documentKinds }
        return ContentDetector.detect(scope.expected)
    }
}
