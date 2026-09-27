import Foundation

/// What one Save puts on the clipboard, decided from the document and nothing else.
///
/// It exists so that **what Save writes and what Save refuses to write are read off the same
/// value.** "Is there anything here?" used to be a condition written out by hand next to the write,
/// agreeing with it only because someone wrote the two to agree — the shape that produced the defect
/// this type was introduced to close, a rule enforced on one of two readers. The refusal itself is
/// `PasteDocument.saveWouldLoseContent`, which asks this type the emptiness half of its question.
/// #71 will grow the write (carrying a file reference back), and a hand-written emptiness test
/// would then refuse a write that had become legitimate. Here, growing `SavePayload` grows both.
///
/// **Scope, deliberately narrow.** This covers every Save but the armed-Markdown one, which
/// renders HTML and RTF through `RichOutputRenderer` — throwing, main-actor, and able to fail
/// after the decision is made, so it stays where it is, in the app target. That branch is
/// unreachable for an unedited document anyway (`PasteDocument.isUnedited` requires
/// `outputMode == .plain`), so it never meets the refusal this type decides.
///
/// Pure and in the package on purpose: `AppModel.save()` is app-target code with no test host
/// (#68), so the spec's one rule that "needs a test rather than a comment" — a mixed session
/// whose text was edited writes the edited text *and* the original image — is only testable if
/// the decision lives here. `SavePayloadTests` is that test. What stays uncovered is the
/// `NSPasteboard` call itself, which is `ClipboardBridge`'s and GUI-verified.
public struct SavePayload: Sendable, Equatable {
    /// The string to write, or nil to declare no `public.string` at all.
    ///
    /// The distinction is not cosmetic. An image session with an empty buffer writes nil, because
    /// declaring an empty `.string` alongside the image offers a text target *nothing* where it
    /// could otherwise have taken the picture. A text session writes its buffer verbatim,
    /// empty included: a user who selects all, deletes and saves means "clear the clipboard", and
    /// that is a write, not an accident.
    public let text: String?
    /// Rich content to write. Always nil today — Save's purpose is putting plain text back, and
    /// none of the non-Markdown paths has ever written the origin's RTFD. It is a field rather
    /// than an omission so that `isEmpty` already accounts for it when something does write one.
    public let richRTFD: Data?
    /// The session's standalone image, or nil. Never empty `Data`: zero bytes under `public.png`
    /// is the write this whole area of the code exists to prevent, and this is the backstop for
    /// it, not the primary guard (that is `ClipboardImageRead` and `ImageBytes` at the two entry
    /// points). A backstop that trusted the thing it backs up would be decoration.
    public let imagePNG: Data?

    public init(text: String?, richRTFD: Data? = nil, imagePNG: Data? = nil) {
        self.text = text
        self.richRTFD = richRTFD
        self.imagePNG = imagePNG.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The payload for a Save of this document as it stands.
    public init(document: PasteDocument) {
        let image = document.imagePNG.flatMap { $0.isEmpty ? nil : $0 }
        self.init(text: image == nil ? document.working
                                     : (document.working.isEmpty ? nil : document.working),
                  richRTFD: nil,
                  imagePNG: image)
    }

    /// True when writing this would put **less than nothing** on the clipboard: it declares no
    /// content, so the only thing the write would accomplish is the `clearContents()` in front of
    /// it, destroying whatever the clipboard held.
    ///
    /// "No text" is blank once trimmed, the same rule `PasteDocument.displaysAsImage`,
    /// `PendingImage.resolve` and `HistoryStore.record` use; a codebase where the capture path and
    /// the save path disagree about whether a buffer has text gives two answers for one clipboard.
    /// Empty `Data` counts as no image and no rich content for the same reason.
    ///
    /// This is one of the two ways `PasteDocument.saveWouldLoseContent` can be true — the other is
    /// an origin carrying `refusedImagePixels`, an image the session holds no bytes for, which makes
    /// *any* write lossy however full the payload is. Both are gated on `isUnedited` there: an empty
    /// payload from a document the user *edited* is a deliberate clear and must still be written.
    public var isEmpty: Bool {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (imagePNG?.isEmpty ?? true)
            && (richRTFD?.isEmpty ?? true)
    }
}
