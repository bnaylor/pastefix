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

    /// nil for: `public.file-url` present (a Finder file copy, not an image the user copied — see
    /// below); no image type offered; a type offered whose data is nil (advertised but never
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
    ///   - hasFileURL: whether the pasteboard carries `public.file-url`. Checked first and
    ///     unconditionally: a Finder file copy puts a `public.tiff` on the pasteboard that is a
    ///     1024×1024 rendering of the file's *icon*, and an icon is not an image the user copied.
    ///     Without this rule a summon-then-save round trip silently replaces the file reference
    ///     with its icon as a PNG — text-wins only hid this by accident, because a file copy
    ///     happens to also carry the filename as text, and that protection evaporates for any
    ///     source that writes a TIFF with no text. `public.file-url` is a fact about the *source*
    ///     (Finder), not about the image types on offer, so it is its own closure rather than a
    ///     third member of `imageTypes`.
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
        hasFileURL: () -> Bool,
        available: (Set<String>) -> String?,
        data: (String) -> Data?,
        decodePNG: (Data) -> Data?
    ) -> Data? {
        // Checked before anything else, and before any bytes are read: a file copy is refused
        // outright rather than merely low-priority against the two image types below. Scope
        // note: this only decides "no image" for the session; the pre-existing loss of
        // `file-url`/`filenames`/`noderef` on Save is #71, not this rule's job.
        guard !hasFileURL() else { return nil }
        // The "only .png and .tiff count" rule is enforced here rather than left to the adapter,
        // so it holds for every caller and is testable in one place.
        guard let offered = available(imageTypes), imageTypes.contains(offered) else { return nil }
        // Empty bytes are refused before the decoder sees them. Independent of what any decoder
        // does with zero bytes, and it is the case that must never survive as `Data()`.
        guard let bytes = data(offered), !bytes.isEmpty else { return nil }
        return decodePNG(bytes)
    }
}
