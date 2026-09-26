import AppKit

/// Whether a pasteboard's type list carries an image Pastefix would otherwise treat as one.
///
/// `ClipboardBridge.snapshot()` never reads image data (image upload is #48, out of scope for
/// Plan 13), so an image-only clipboard yields an empty `working` buffer — indistinguishable, at
/// the buffer level, from a clipboard that is genuinely empty. The upload overlay needs to tell
/// those two apart to give the right empty-state message (issue #14, "must report that image
/// upload isn't supported yet — explicitly, not by doing nothing"), and this is the cheap way to
/// ask: `.tiff` and `.png` are the two types `PasteboardMonitor.read` and `HistoryStore` already
/// treat as an image elsewhere, and checking the type list costs nothing — no image bytes are
/// read, which is the cost this check exists to avoid paying on a path that runs on every ⌘⇧U.
///
/// Pure over a type list rather than a pasteboard, so it is testable without any real pasteboard
/// or AppKit run loop involved.
public enum ZiplinePasteboardImage {
    public static func typesIndicateImage(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(.tiff) || types.contains(.png)
    }
}
