import Foundation
import AppKit

/// An immutable capture of the clipboard at summon time. `plainText` seeds the
/// editor; `richRTFD` is the original rich content (as RTFD data) that the
/// rich->plain transform reads.
public struct ClipboardSnapshot: Sendable {
    public let plainText: String?
    public let richRTFD: Data?
    /// `NSPasteboard.changeCount` at the instant this was captured, or nil when the snapshot did
    /// not come from a pasteboard at all (a history item re-opened into the panel, a test).
    ///
    /// It exists so a later reader can ask "has the clipboard moved on since this was taken?"
    /// without comparing text — which would answer "no" for a re-copy of identical bytes and,
    /// worse, would need the clipboard read (and its macOS access prompt) to ask at all. nil is
    /// not "unchanged": it is "this buffer was never the clipboard", and callers must treat it as
    /// a reason *not* to claim the clipboard as the source.
    public let changeCount: Int?

    public init(plainText: String?, richRTFD: Data?, changeCount: Int? = nil) {
        self.plainText = plainText
        self.richRTFD = richRTFD
        self.changeCount = changeCount
    }

    public init(plainText: String?, rich: NSAttributedString?, changeCount: Int? = nil) {
        self.plainText = plainText
        self.changeCount = changeCount
        self.richRTFD = rich.flatMap { attributed in
            try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )
        }
    }

    public var hasRichContent: Bool { richRTFD != nil }
}
