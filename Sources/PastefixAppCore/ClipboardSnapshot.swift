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

    // MARK: What a Save can and cannot put back

    /// One thing a clipboard can hold, named so that "would this Save lose something?" can be
    /// answered as a set rather than as an expression nobody can extend safely.
    ///
    /// Not one case per stored property: `richRTFD` is dropped by policy and so can never appear
    /// here, and `changeCount` is metadata. `wholeClipboard` is the opposite — it is no property at
    /// all. The mapping from properties to buckets is `storedPropertyClasses`, and a test enforces
    /// that every stored property appears in it.
    public enum Representation: Hashable, Sendable {
        /// The origin's text, which the payload does not write back.
        case plainText
        /// The origin's standalone image, which the payload does not write back.
        case image
        /// A standalone image the clipboard holds and this snapshot has no bytes for
        /// (`refusedImagePixels`). No payload can ever reproduce it, so its presence alone makes
        /// any write lossy — that is the whole reason the notice on screen can promise the picture
        /// is still there.
        case refusedImage
        /// Everything on the clipboard that no snapshot enumerates: a Finder file copy, a custom
        /// type some app wrote, `NSFilenamesPboardType`, a promise. Counted as lost exactly when
        /// the payload would write nothing at all, because then the write is `clearContents()` and
        /// nothing else — there is no content to weigh the loss against. When the payload *does*
        /// write something, an unedited Save is accepted as the user asking for that write, which
        /// is the behaviour that predates image sessions.
        case wholeClipboard
    }

    /// Which of the four buckets each stored property of this type falls into.
    ///
    /// It exists to be enforced: `ClipboardSnapshotClassificationTests` enumerates the stored
    /// properties with `Mirror` and fails on any property missing from here (and on any key here
    /// that is no longer a property). So #71 adding a file reference cannot compile-and-pass
    /// without someone deciding what a Save owes it — which is the failure mode the old
    /// "the principle already covers it" claim actually had: the principle covered nothing,
    /// `unreproduced(by:)` would not have mentioned the new field, and Save would have written
    /// over a file reference it could not reproduce.
    ///
    /// The buckets are exhaustive by construction — every property is reproduced by the payload,
    /// deliberately dropped, not content at all, or unreproducible-if-present.
    public enum RepresentationClass: String, Hashable, Sendable, CaseIterable {
        /// `SavePayload` carries it, so a Save puts it back.
        case reproducedByPayload
        /// A Save deliberately does not write it. Today that is `richRTFD` only, and the policy is
        /// named where the predicate reads it (`PasteDocument.saveWouldLoseContent`): summon + ⌘S
        /// as "strip formatting" is behaviour users rely on and it predates image sessions.
        case droppedByPolicy
        /// Not clipboard content: bookkeeping about the capture itself.
        case metadata
        /// Content the clipboard holds that this snapshot has no bytes for, so no payload can
        /// reproduce it. Present ⇒ any write is lossy.
        case lossIfPresent
    }

    public static let storedPropertyClasses: [String: RepresentationClass] = [
        "plainText": .reproducedByPayload,
        "richRTFD": .droppedByPolicy,
        "imagePNG": .reproducedByPayload,
        "refusedImagePixels": .lossIfPresent,
        "changeCount": .metadata,
    ]

    /// **Does this snapshot hold a representation that `payload` does not reproduce and that Save
    /// does not drop on purpose?** The question `PasteDocument.saveWouldLoseContent` asks, as a
    /// set, so that a new field on this type extends one classification instead of being forgotten
    /// by two predicates that happened to agree.
    ///
    /// Blank-once-trimmed text and empty `Data` are *not* representations: they are the absence of
    /// one, the same rule `SavePayload.isEmpty`, `PasteDocument.displaysAsImage` and
    /// `HistoryStore.record` use. Reproduction is byte-for-byte equality with what the payload
    /// would write — which is why this is only meaningful for an *unedited* document: for an edited
    /// one the payload is *supposed* to differ, and the caller gates on `isUnedited` for exactly
    /// that reason.
    public func unreproduced(by payload: SavePayload) -> Set<Representation> {
        var lost: Set<Representation> = []
        if let text = plainText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           payload.text != text {
            lost.insert(.plainText)
        }
        if let image = imagePNG, !image.isEmpty, payload.imagePNG != image {
            lost.insert(.image)
        }
        if refusedImagePixels != nil {
            lost.insert(.refusedImage)
        }
        // `richRTFD` is absent from this function on purpose (`.droppedByPolicy`) — see
        // `PasteDocument.saveWouldLoseContent` for why removing that exception breaks
        // strip-formatting. `changeCount` is `.metadata` and not content at all.
        if payload.isEmpty {
            lost.insert(.wholeClipboard)
        }
        return lost
    }
}
