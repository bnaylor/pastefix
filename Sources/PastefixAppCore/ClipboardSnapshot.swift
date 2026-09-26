import Foundation
import AppKit

/// An immutable capture of the clipboard at summon time. `plainText` seeds the
/// editor; `richRTFD` is the original rich content (as RTFD data) that the
/// rich->plain transform reads.
public struct ClipboardSnapshot: Sendable {
    public let plainText: String?
    public let richRTFD: Data?
    /// A standalone pasteboard image, normalised to PNG.
    ///
    /// Nil covers three different "no image" cases deliberately, because none of them should
    /// become an empty `Data`: the pasteboard had no image type; it advertised one whose provider
    /// never materialised the promised data; or the bytes did not decode. An empty `Data` here
    /// would be written back over the user's clipboard as a zero-byte image by `Save`.
    ///
    /// An image embedded inside `richRTFD` is **not** this. This field means a standalone
    /// pasteboard image type; without that rule every rich paste from a web page would become an
    /// image session (spec, Decisions).
    public let imagePNG: Data?
    /// `NSPasteboard.changeCount` at the instant this was captured, or nil when the snapshot did
    /// not come from a pasteboard at all (a history item re-opened into the panel, a test).
    ///
    /// It exists so a later reader can ask "has the clipboard moved on since this was taken?"
    /// without comparing text — which would answer "no" for a re-copy of identical bytes and,
    /// worse, would need the clipboard read (and its macOS access prompt) to ask at all. nil is
    /// not "unchanged": it is "this buffer was never the clipboard", and callers must treat it as
    /// a reason *not* to claim the clipboard as the source.
    public let changeCount: Int?

    public init(plainText: String?, richRTFD: Data?, imagePNG: Data? = nil, changeCount: Int? = nil) {
        self.plainText = plainText
        self.richRTFD = richRTFD
        self.imagePNG = imagePNG
        self.changeCount = changeCount
    }

    public init(plainText: String?, rich: NSAttributedString?, imagePNG: Data? = nil, changeCount: Int? = nil) {
        self.plainText = plainText
        self.imagePNG = imagePNG
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
