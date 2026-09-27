import Foundation

/// Decides whether a pasteboard offers a usable standalone image, given only a type list and a
/// way to fetch bytes for a type. Pure, so the four "no image" rules are testable without a
/// pasteboard: `ClipboardBridge` passes real `NSPasteboard` closures, tests pass dictionaries.
public enum ClipboardImageRead {
    /// The two types that count as a standalone image (spec, Decisions). These are the raw values
    /// of `NSPasteboard.PasteboardType.png` and `.tiff`, spelled as strings so this decision needs
    /// neither AppKit nor a pasteboard to be exercised.
    public static let pngType = "public.png"
    public static let tiffType = "public.tiff"
    /// What `available` is asked about, and the only answers it may give.
    public static let imageTypes: Set<String> = [pngType, tiffType]

    /// nil for: a file copy (`refusesAsFileCopy`, not an image the user copied); no image type offered; a type offered whose data is nil (advertised but never
    /// materialised by its provider); empty bytes; or bytes `decodePNG` rejects. Never an empty
    /// `Data` — that would be written back over the user's clipboard as a zero-byte image.
    ///
    /// **What "rejects" covers is asymmetric, and the asymmetry is deliberate.** The adapter's
    /// `decodePNG` is `ImageBytes.normalise`, which *decodes* a TIFF (it has to, to convert it) but
    /// validates a PNG by reading its header and its pixel dimensions only, keeping the user's own
    /// bytes for `Save`. So a header-valid, body-corrupt PNG is accepted here and fails later where
    /// it is drawn; only a TIFF is rejected for failing to decode. This seam enforces "nil means no
    /// image", not "everything non-nil draws".
    ///
    /// One consequence, named because it is a real loss and not implementing a fallback is the
    /// choice: a pasteboard offering a corrupt `public.png` *and* a good `public.tiff` is read as
    /// the PNG, because the adapter orders PNG first, and the TIFF is never consulted. The session
    /// shows the failure placeholder and `Save` writes the corrupt PNG over that good TIFF. The
    /// price of PNG-first ordering (which is what keeps every ordinary screenshot free of a
    /// decode), paid in a case that needs a source that is broken in one representation and fine
    /// in another.
    ///
    /// - Parameters:
    ///   - refusesAsFileCopy: whether the pasteboard is a *file copy* — see
    ///     `refusesAsFileCopy(declaredTypes:)`, which both adapters call with the pasteboard's
    ///     declared types. Checked first, before any bytes are read.
    ///   - available: which of `imageTypes` the pasteboard offers, or nil for none. It is handed
    ///     the whole set and answers with one member; preference between the two, when both are
    ///     offered, belongs to the pasteboard adapter (`NSPasteboard.availableType(from:)` takes
    ///     an ordered list and `ClipboardBridge` orders it PNG first).
    ///   - data: the bytes for a type, or nil when the provider never materialised them.
    ///   - decodePNG: PNG bytes for the given image bytes, or nil when it will not have them. It
    ///     is both the validator and the TIFF converter: an already-PNG input comes back unchanged
    ///     after a header check, so the user's own bytes are what `Save` writes, and a TIFF comes
    ///     back re-encoded or not at all. Returning the input unchanged is the adapter's promise,
    ///     not something enforced here; what *is* enforced is that nil means no image.
    ///
    /// There is deliberately no fallback from one type to the other, in either failure: a provider
    /// that advertises a type and then hands back nil is broken, and guessing at its other promise
    /// is not a better answer than "this clipboard has no image we can use" — and the
    /// corrupt-PNG-beside-good-TIFF case above is the same rule costing something real.
    public static func imagePNG(
        refusesAsFileCopy: () -> Bool,
        available: (Set<String>) -> String?,
        data: (String) -> Data?,
        decodePNG: (Data) -> Data?
    ) -> Data? {
        // Checked before anything else, and before any bytes are read: a file copy is refused
        // outright rather than merely low-priority against the two image types below. Scope
        // note: this only decides "no image" for the session; what an unedited Save does over
        // a file copy is `ClipboardSnapshot.fileReferenceTypes` (#71), not this rule's job.
        guard !refusesAsFileCopy() else { return nil }
        // The "only .png and .tiff count" rule is enforced here rather than left to the adapter,
        // so it holds for every caller and is testable in one place.
        guard let offered = available(imageTypes), imageTypes.contains(offered) else { return nil }
        // Empty bytes are refused before the decoder sees them. Independent of what any decoder
        // does with zero bytes, and it is the case that must never survive as `Data()`.
        guard let bytes = data(offered), !bytes.isEmpty else { return nil }
        return decodePNG(bytes)
    }

    // MARK: File copies (#78)

    /// Every spelling of "this pasteboard carries a file reference": the modern UTI and the two
    /// legacy flavours some sources write instead of (or beside) it.
    public static let fileURLTypes: Set<String> = [
        "public.file-url", "CorePasteboardFlavorType 0x6675726C", "NSFilenamesPboardType",
    ]
    /// Finder's own markers. Only Finder was measured writing them.
    public static let finderMarkerTypes: Set<String> = ["com.apple.icns", "com.apple.finder.noderef"]
    /// Image formats a *photo* source offers and Finder never does. Finder writes the same 16
    /// types for every file it copies — a JPEG, a PNG and a .txt alike — and its only image is a
    /// `public.tiff` rendering of the file's icon; it never offers the file's own format.
    public static let realImageFormats: Set<String> = ["public.png", "public.jpeg", "public.heic"]

    /// Whether a pasteboard is a *file copy* — something whose image representation is an icon,
    /// not a picture the user copied — decided from its declared types alone.
    ///
    /// `public.file-url` on its own does not decide it. Finder's copy and a Photos.app copy both
    /// carry one; only Finder's image is an icon (1024×1024, identical for every file). Photos
    /// offers the photograph itself as `public.jpeg` beside its file-url. So (#78, both type lists
    /// measured and used as test fixtures):
    ///
    /// 1. Finder's markers (`com.apple.icns`, `com.apple.finder.noderef`) → refused. Positive
    ///    refusal, so a false match fails safe: no image session rather than an icon in one.
    /// 2. A file-url with no real image format offered → refused. This arm stands on its own, so
    ///    a future rename of Finder's markers cannot reopen the icon bug.
    /// 3. Otherwise → not a file copy (including every pasteboard with no file-url at all).
    ///
    /// `public.jpeg` is an eligibility **signal**, never a **source**: no reader takes bytes from it.
    /// A Photos copy is read through its TIFF, whose conversion strips GPS
    /// (`ConversionStripsLocationTests`). Reading the JPEG verbatim would carry the photo's
    /// location into the session, and from there into an upload.
    ///
    /// Eligibility is "a real image format is **offered**", not "one we can **read**". Whether
    /// the image can be read is a separate question, already answered by `imagePNG`'s rule that
    /// no readable type means no image — so a HEIC-only copy is eligible here and still yields
    /// nothing. Do not narrow `realImageFormats` to what is readable: that would fold two
    /// questions into one and turn "cannot read it" into "it is a file copy".
    ///
    /// **Known residual, unmeasured:** a third-party file manager that writes a file-url plus a
    /// **PNG of the icon** and neither Finder marker would be accepted by arm 3, so the icon would
    /// open as an image session. It would not be written over the file copy: the file-url alone
    /// makes an unedited ⌘S a no-op (`ClipboardSnapshot.fileReferenceTypes`, #71). No such source
    /// has been observed (none was installed to measure); recorded so it is recognised if it is.
    public static func refusesAsFileCopy(declaredTypes types: Set<String>) -> Bool {
        if !types.isDisjoint(with: finderMarkerTypes) { return true }
        if types.isDisjoint(with: fileURLTypes) { return false }
        return types.isDisjoint(with: realImageFormats)
    }
}
