import Foundation

/// Decides whether a pasteboard offers a usable standalone image, given only a type list and a
/// way to fetch bytes for a type. Pure, so the three "no image" rules are testable without a
/// pasteboard: `ClipboardBridge` passes real `NSPasteboard` closures, tests pass dictionaries.
public enum ClipboardImageRead {
    /// The two types that count as a standalone image (spec, Decisions). These are the raw values
    /// of `NSPasteboard.PasteboardType.png` and `.tiff`, spelled as strings so this decision needs
    /// neither AppKit nor a pasteboard to be exercised.
    public static let pngType = "public.png"
    public static let tiffType = "public.tiff"
    /// What `available` is asked about, and the only answers it may give.
    public static let imageTypes: Set<String> = [pngType, tiffType]

    /// nil for: no image type offered; a type offered whose data is nil (advertised but never
    /// materialised by its provider); or bytes that do not decode. Never an empty `Data` — that
    /// would be written back over the user's clipboard as a zero-byte image.
    ///
    /// - Parameters:
    ///   - available: which of `imageTypes` the pasteboard offers, or nil for none. It is handed
    ///     the whole set and answers with one member; preference between the two, when both are
    ///     offered, belongs to the pasteboard adapter (`NSPasteboard.availableType(from:)` takes
    ///     an ordered list and `ClipboardBridge` orders it PNG first).
    ///   - data: the bytes for a type, or nil when the provider never materialised them.
    ///   - decodePNG: PNG bytes for the given image bytes, or nil when they do not decode. It is
    ///     both the validator and the TIFF converter: an already-PNG input comes back unchanged,
    ///     so the user's own bytes are what `Save` writes, and a TIFF comes back re-encoded.
    ///     Returning the input unchanged is the adapter's promise, not something enforced here;
    ///     what *is* enforced is that nil means no image.
    ///
    /// There is deliberately no fallback from one type to the other: a provider that advertises a
    /// type and then hands back nil is broken, and guessing at its other promise is not a better
    /// answer than "this clipboard has no image we can use".
    public static func imagePNG(
        available: (Set<String>) -> String?,
        data: (String) -> Data?,
        decodePNG: (Data) -> Data?
    ) -> Data? {
        // The "only .png and .tiff count" rule is enforced here rather than left to the adapter,
        // so it holds for every caller and is testable in one place.
        guard let offered = available(imageTypes), imageTypes.contains(offered) else { return nil }
        // Empty bytes are refused before the decoder sees them. Independent of what any decoder
        // does with zero bytes, and it is the case that must never survive as `Data()`.
        guard let bytes = data(offered), !bytes.isEmpty else { return nil }
        return decodePNG(bytes)
    }
}
