import AppKit

/// Whether a pasteboard's type list carries an image Pastefix would treat as one.
///
/// **Nothing calls this any more, and the reasoning that produced it no longer holds.** It was
/// written when `ClipboardBridge.snapshot()` never read image data, which left an image-only
/// clipboard indistinguishable at the buffer level from an empty one; the upload overlay poked
/// `NSPasteboard.general.types` through here to tell those apart for its empty-state message
/// (issue #14). Since #18, a session carries its own image (`PasteDocument.imagePNG`,
/// `displaysAsImage`), so the overlay asks the document — a better answer in two ways: it is right
/// for a history item loaded into the panel, where the live pasteboard describes bytes this buffer
/// never came from, and it cannot disagree with what the panel is showing.
///
/// Kept, not deleted, and deliberately: it is Plan 13 code, its rationale has been corrected
/// rather than quietly removed, and the argument for removing it belongs in review (Task 4 report)
/// rather than in a commit that was about something else. If nothing has claimed it by then, it
/// should go with its tests.
///
/// Pure over a type list rather than a pasteboard, so it is testable without any real pasteboard
/// or AppKit run loop involved.
public enum ZiplinePasteboardImage {
    public static func typesIndicateImage(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(.tiff) || types.contains(.png)
    }
}
