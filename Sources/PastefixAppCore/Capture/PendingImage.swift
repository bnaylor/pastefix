import Foundation

/// What survives when a capture's image could only be produced *after* the read.
///
/// The monitor reads a TIFF-only pasteboard image without converting it and does the decode and
/// PNG re-encode off the main actor (#32), so by the time the PNG exists — or fails to exist, or
/// comes out over the image budget — the decision "is there still anything worth recording here"
/// has to be made separately from the read. That decision is this type; the surrounding
/// re-checks (change count, filters) are app glue and live in `PasteboardMonitor`.
public enum PendingImage {
    /// The candidate to record once a deferred TIFF→PNG conversion has finished, or nil when
    /// nothing is left worth recording.
    ///
    /// `png == nil` means the conversion failed. An over-budget PNG is dropped here rather than
    /// left for `HistoryStore.record` to drop: the two agree on the outcome, but the caller needs
    /// to know *before* it records whether this is still an image capture or a text-only one.
    ///
    /// The whitespace rule mirrors `record`: text that is blank once trimmed is not text, so a
    /// failed conversion of an image copied with an empty string alongside it records nothing
    /// rather than an empty row.
    public static func resolve(_ candidate: CaptureCandidate, png: Data?,
                               pixelWidth: Int?, pixelHeight: Int?,
                               maxImageBytes: Int) -> CaptureCandidate? {
        var out = candidate
        // Never inherit image fields from the pre-conversion candidate: the only image this
        // candidate can have is the one the conversion just produced.
        out.imagePNG = nil; out.imagePixelWidth = nil; out.imagePixelHeight = nil
        if let png, png.count <= maxImageBytes {
            out.imagePNG = png
            out.imagePixelWidth = pixelWidth
            out.imagePixelHeight = pixelHeight
        }
        let hasText = out.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasText || out.imagePNG != nil else { return nil }
        return out
    }
}
