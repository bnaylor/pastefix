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
    /// The file-reference types the pasteboard declared (`public.file-url`, its legacy flavours),
    /// or nil when it declared none — a Finder file copy, or a Photos.app copy (#71).
    ///
    /// Pastefix cannot write a file reference back, so an **unedited** Save over one would replace
    /// the user's copied file with its name as text. Classified `.lossIfPresent`: the generic
    /// `unreproduced(by:)` then makes that Save a no-op — the owner's decision, and what macOS
    /// itself does. Editing the text is deliberate and still writes. Declared types only, never
    /// the URL: nothing here reads the file or resolves the reference (Invariant 13's pointer rule).
    public let fileReferenceTypes: [String]?
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
                refusedImagePixels: Int? = nil, fileReferenceTypes: [String]? = nil, changeCount: Int? = nil) {
        self.plainText = plainText
        self.richRTFD = richRTFD
        self.imagePNG = imagePNG
        self.refusedImagePixels = refusedImagePixels
        self.fileReferenceTypes = fileReferenceTypes
        self.changeCount = changeCount
    }

    public init(plainText: String?, rich: NSAttributedString?, imagePNG: Data? = nil,
                refusedImagePixels: Int? = nil, fileReferenceTypes: [String]? = nil, changeCount: Int? = nil) {
        self.plainText = plainText
        self.imagePNG = imagePNG
        self.refusedImagePixels = refusedImagePixels
        self.fileReferenceTypes = fileReferenceTypes
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
    /// all. The mapping from properties to buckets is `storedPropertyClasses`; a test enforces that
    /// every stored property appears in it, and `unreproduced(by:)` *reads* it for the
    /// `.lossIfPresent` bucket rather than naming those fields, so the classification is the
    /// implementation and not a label beside one.
    public enum Representation: Hashable, Sendable {
        /// The origin's text, which the payload does not write back.
        case plainText
        /// The origin's standalone image, which the payload does not write back.
        case image
        /// Something the clipboard holds that this snapshot has no bytes for, named by the stored
        /// property that recorded it — `lossIfPresent("refusedImagePixels")` for an image over the
        /// conversion ceiling, `lossIfPresent("fileReferenceTypes")` for a copied file (#71). No
        /// payload can ever reproduce such a thing, so its presence alone makes any write lossy —
        /// that is the whole reason the notice on screen can promise the picture is still there.
        ///
        /// It carries the property name rather than being one case per field so that **this enum
        /// does not need editing when a field is added**: `unreproduced(by:)` builds these by
        /// walking `storedPropertyClasses` for `.lossIfPresent` keys, so classifying a new field
        /// *is* reporting it. A case per field would put the extension back where it was — a second
        /// place to remember.
        case lossIfPresent(String)
        /// Everything on the clipboard that no snapshot enumerates: a custom type some app wrote,
        /// a file promise, any representation no stored property records. Counted as lost exactly when
        /// the payload would write nothing at all, because then the write is `clearContents()` and
        /// nothing else — there is no content to weigh the loss against.
        ///
        /// When the payload *does* write something, an unedited Save is accepted as the user asking
        /// for that write — and the other half of that, which this case leaves unsaid until now:
        /// **everything the snapshot does not model is then dropped by policy.** That is the same
        /// order of judgement as the rich-text exception rather than a law of nature. A Finder file
        /// copy was its most visible casualty — an unedited ⌘S replaced the file on the clipboard
        /// with its filename — until #71 modelled it: `fileReferenceTypes` is `.lossIfPresent`, is
        /// reported by name above, and is no longer covered by this case at all. The next
        /// representation someone notices being dropped leaves this case the same way.
        case wholeClipboard
    }

    /// Which of the four buckets each stored property of this type falls into.
    ///
    /// **It is read, not just enforced.** `unreproduced(by:)` walks this dictionary for the
    /// `.lossIfPresent` bucket, so for that bucket the entry below is the behaviour: classifying
    /// `fileReferenceTypes` `.lossIfPresent` is the whole of what made an unedited Save over a
    /// copied file a no-op (#71), with no second edit to forget. That is the fix for what this dictionary was when it was introduced —
    /// a label beside a hard-coded predicate, which made the test below enforce only that someone
    /// had typed a bucket name. A correctly classified field with `unreproduced(by:)` left alone
    /// passed everything and lost the data anyway.
    ///
    /// It is also enforced: `ClipboardSnapshotClassificationTests` enumerates the stored properties
    /// with `Mirror` and fails on any property missing from here (and on any key here that is no
    /// longer a property), and `ClipboardSnapshotLossIfPresentTests` fails if a `.lossIfPresent`
    /// property goes unreported. So a new field cannot compile-and-pass without someone deciding
    /// what a Save owes it. The one step still on the author is a comparison for a
    /// `.reproducedByPayload` field, which cannot be generated — `unreproduced(by:)` says so.
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
        ///
        /// This is the one bucket that is **self-enacting**: `unreproduced(by:)` finds these
        /// properties by reflection over this dictionary, so writing the classification down is the
        /// only step. Nothing else to remember, and nothing that can be classified here and then
        /// quietly not reported.
        case lossIfPresent
    }

    public static let storedPropertyClasses: [String: RepresentationClass] = [
        "plainText": .reproducedByPayload,
        "richRTFD": .droppedByPolicy,
        "imagePNG": .reproducedByPayload,
        "refusedImagePixels": .lossIfPresent,
        "fileReferenceTypes": .lossIfPresent,
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
    ///
    /// **The `.lossIfPresent` half is the classification, not a copy of it.** The bucket used to be
    /// a label beside a hard-coded `refusedImagePixels != nil`, which meant the enforcing test only
    /// checked that someone had typed a bucket name: adding a field, classifying it correctly, and
    /// forgetting this function left every test green while an unedited Save dropped the field.
    /// Here the loop *is* the rule — classify a field `.lossIfPresent` and it is reported, with no
    /// second site to remember.
    ///
    /// **What this does not close.** `.reproducedByPayload` stays written out by hand, because
    /// comparing a field against the payload cannot be generic: there is no mechanical way to know
    /// that `imagePNG` is answered by `payload.imagePNG` and that the comparison is byte equality
    /// after an empty-`Data` exclusion. So the residual risk is a new field classified
    /// `.reproducedByPayload`, `SavePayload` grown to carry it, and the comparison below never
    /// written — which reports no loss for a payload that reproduces the field wrongly or not at
    /// all. Adding a case there is a deliberate three-step job and nothing here checks the third
    /// step; this fix closes the `.lossIfPresent` hole and not that one.
    public func unreproduced(by payload: SavePayload) -> Set<Representation> {
        unreproduced(by: payload, classifiedBy: Self.storedPropertyClasses)
    }

    /// The body of `unreproduced(by:)` with its classification injected, which exists so a test can
    /// hand it a bucketing of a property this function does not name and check that the property is
    /// reported anyway. That is the difference between "the `.lossIfPresent` bucket is honoured" and
    /// "today's `.lossIfPresent` fields happen to be reported": the public entry point can only be
    /// handed fields that exist, so a body naming `refusedImagePixels` and `fileReferenceTypes`
    /// passes every test of it, and only a field this function never heard of tells the two
    /// apart. Internal, and every
    /// production caller goes through `unreproduced(by:)` with the real dictionary.
    func unreproduced(by payload: SavePayload,
                      classifiedBy classes: [String: RepresentationClass]) -> Set<Representation> {
        var lost: Set<Representation> = []
        // `.reproducedByPayload`, one clause per field, deliberately not generic — see above.
        if let text = plainText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           payload.text != text {
            lost.insert(.plainText)
        }
        if let image = imagePNG, !image.isEmpty, payload.imagePNG != image {
            lost.insert(.image)
        }
        // `.lossIfPresent`, read off the classification: no payload can reproduce any of these, so
        // presence is the entire test and reflection can do it for a field this code never heard of.
        // Six children on a Save-time predicate costs nothing worth caching.
        for child in Mirror(reflecting: self).children {
            guard let label = child.label,
                  classes[label] == .lossIfPresent,
                  Self.isPresent(child.value) else { continue }
            lost.insert(.lossIfPresent(label))
        }
        // `richRTFD` is absent from this function on purpose (`.droppedByPolicy`) — see
        // `PasteDocument.saveWouldLoseContent` for why removing that exception breaks
        // strip-formatting. `changeCount` is `.metadata` and not content at all.
        if payload.isEmpty {
            lost.insert(.wholeClipboard)
        }
        return lost
    }

    /// Whether a `Mirror` child holds something rather than nothing.
    ///
    /// An `Optional` reflects as its own `Mirror` with `displayStyle == .optional` and one child
    /// when non-nil, none when nil — so unwrapping it is the check. Comparing
    /// `String(describing:)` against `"nil"` would be the same check written to also accept the
    /// string `"nil"` and any type whose description happens to be that.
    ///
    /// A non-`Optional` property is present by existing. Nothing is `.lossIfPresent` and
    /// non-`Optional` today; if something ever is, "the clipboard holds this" would have to be a
    /// property of its value and belong in a clause of its own, not here.
    private static func isPresent(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return true }
        return mirror.children.isEmpty == false
    }
}
