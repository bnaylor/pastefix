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
    /// Nil covers every "no image" case deliberately, because none of them should become an empty
    /// `Data`: the pasteboard carried `public.file-url` (a Finder file copy, so the TIFF on offer
    /// is the file's icon); it had no image type at all; it advertised one whose provider never
    /// materialised the promised data; the bytes were empty; or the bytes were unusable. An empty
    /// `Data` here would be written back over the user's clipboard as a zero-byte image by `Save`.
    ///
    /// "Unusable" is narrower than "does not decode", and the difference is worth knowing before
    /// trusting these bytes: `ImageBytes.normalise` decodes a TIFF (conversion requires it) but
    /// validates a PNG from its header and pixel dimensions alone, so the user's own bytes are what
    /// `Save` writes. A PNG with an intact header and a corrupt body therefore arrives here
    /// non-nil and fails where it is drawn (`ImageSessionView` has a state for it). The guarantee
    /// is "non-nil means real bytes we accepted", not "non-nil means it will draw".
    ///
    /// An image embedded inside `richRTFD` is **not** this. This field means a standalone
    /// pasteboard image type; without that rule every rich paste from a web page would become an
    /// image session (spec, Decisions).
    public let imagePNG: Data?
    /// The pixel count of a standalone image this snapshot *declined* to carry, or nil when there
    /// was nothing to decline.
    ///
    /// One thing sets it, from either of the two paths that can open a session: an image over
    /// `ImageBytes.maxConvertiblePixels` that would need converting — which `ClipboardBridge.snapshot`
    /// will not decode synchronously on the summon path, and which `AppModel.load` will not decode
    /// out of a history blob either. `imagePNG` is nil in that case — and an image silently becoming no image is the failure this codebase
    /// treats as a defect, so the panel says so instead (a 30 MP photo copied out of Preview is
    /// enough to hit it). It is a number rather than a flag so the message can quote the size in
    /// the unit the limit is expressed in.
    public let refusedImagePixels: Int?
    /// `NSPasteboard.changeCount` at the instant this was captured, or nil when the snapshot did
    /// not come from a pasteboard at all (a history item re-opened into the panel, a test).
    ///
    /// It exists so a later reader can ask "has the clipboard moved on since this was taken?"
    /// without comparing text — which would answer "no" for a re-copy of identical bytes and,
    /// worse, would need the clipboard read (and its macOS access prompt) to ask at all. nil is
    /// not "unchanged": it is "this buffer was never the clipboard", and callers must treat it as
    /// a reason *not* to claim the clipboard as the source.
    public let changeCount: Int?

    public init(plainText: String?, richRTFD: Data?, imagePNG: Data? = nil,
                refusedImagePixels: Int? = nil, changeCount: Int? = nil) {
        self.plainText = plainText
        self.richRTFD = richRTFD
        self.imagePNG = imagePNG
        self.refusedImagePixels = refusedImagePixels
        self.changeCount = changeCount
    }

    public init(plainText: String?, rich: NSAttributedString?, imagePNG: Data? = nil,
                refusedImagePixels: Int? = nil, changeCount: Int? = nil) {
        self.plainText = plainText
        self.imagePNG = imagePNG
        self.refusedImagePixels = refusedImagePixels
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
