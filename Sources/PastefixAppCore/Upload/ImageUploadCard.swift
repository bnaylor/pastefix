import Foundation
import PastefixCore

/// What the ⌘⇧U image card says and allows, decided as values so they can be tested (#48).
///
/// The card itself lives in the app target, which has no test host (#68). Everything here is a
/// decision the view would otherwise make inline: which words go with which outcome, whether
/// Upload is enabled, and which button — if any — Return presses. The view only lays these out.
///
/// The two rules this type exists to pin:
/// - **"Not scanned" is never "clean"** (Invariant 13). The not-checked verdict is shown for every
///   image, and nothing here can say "no text found": `hasText == false` means *not detected*,
///   and an 11 px line is measured to produce no regions at all.
/// - **Return never uploads an image.** `defaultAction(for:)` has no case that names Upload.
public enum ImageUploadCard {
    /// The image half of the overlay's state. Shares nothing with the text card's `ScanState`.
    public enum State: Equatable, Sendable {
        /// The strip, byte cap and text-region detection have not resolved yet.
        case preparing
        /// `hasText` escalates the wording; it never quiets it.
        case ready(SanitizedImage, hasText: Bool)
        case refused(ImageUploadPreparation.Refusal)
        /// The process-wide lane skipped this preparation before it started, because a newer
        /// image's preparation replaced it. Only reachable when the session's image changed while
        /// this card was open; nothing was prepared, so nothing can be sent.
        case superseded

        /// `nil` is the lane's "superseded" answer.
        public init(_ outcome: ImageUploadPreparation.Outcome?) {
            switch outcome {
            case .ready(let image, let hasText): self = .ready(image, hasText: hasText)
            case .refused(let refusal): self = .refused(refusal)
            case nil: self = .superseded
            }
        }

        /// The only bytes an image upload can send. There is deliberately no path from `State`
        /// to the session's original `imagePNG`.
        public var sanitized: SanitizedImage? {
            if case .ready(let image, _) = self { return image }
            return nil
        }

        public var hasText: Bool {
            if case .ready(_, let hasText) = self { return hasText }
            return false
        }
    }

    /// Which button Return presses. There is no `.upload`: an unscanned image never gets the
    /// affordance the text path earns by having scanned.
    public enum DefaultAction: Equatable, Sendable {
        case none
        case cancel
    }

    public static func defaultAction(for state: State) -> DefaultAction {
        state.hasText ? .cancel : .none
    }

    public static func canUpload(_ state: State) -> Bool {
        state.sanitized != nil
    }

    // MARK: Wording

    /// Always shown for an image, as prominently as a finding.
    public static let notCheckedVerdict = "Images are not checked for secrets."
    /// The escalation when Vision found text regions (or failed, which counts as found).
    public static let containsText = "This image contains text."
    public static let metadataRemoved = "Any location and camera details removed."
    public static let preparing = "Preparing the image…"
    /// The done state's extra line: the URL replaced the image via `writePlain`, which the text
    /// path never had to say because it never destroyed its source.
    public static let clipboardReplaced = "The image is no longer on your clipboard."
    /// Under every refusal, so the absence of the ready rows cannot read as anything else.
    public static let refusalDetail = "Nothing was sent."

    /// "1.2 MB of the 16 MB limit" — the stripped size, which is what goes on the wire.
    public static func sizeLine(bytes: Int, limit: Int = UploadLimits.maxPayloadBytes) -> String {
        "\(HistoryFormatting.byteLabel(bytes)) after preparing, of the \(ByteLimit.describe(limit)) limit"
    }

    /// The header's detail after "the clipboard — ": the size appears only once there are
    /// prepared bytes to measure, because the header states what Upload will send.
    public static func headerDetail(for state: State) -> String {
        guard let image = state.sanitized else { return "image" }
        return "image · \(HistoryFormatting.byteLabel(image.png.count))"
    }

    public static func sendTitle(hasText: Bool, isRetry: Bool) -> String {
        switch (hasText, isRetry) {
        case (true, false): return "Upload without checking"
        case (true, true): return "Retry without checking"
        case (false, false): return "Upload"
        case (false, true): return "Retry"
        }
    }

    public static func refusal(_ refusal: ImageUploadPreparation.Refusal,
                               maxPixels: Int = PixelLimits.maxConvertiblePixels,
                               maxBytes: Int = UploadLimits.maxPayloadBytes) -> String {
        switch refusal {
        case .tooManyPixels(let pixels):
            return "Too large to upload — \(ImageBytes.megapixelLabel(pixels)); the limit is \(ImageBytes.megapixelLabel(maxPixels))."
        case .tooManyBytes(let bytes):
            return "\(HistoryFormatting.byteLabel(bytes)) after preparing; the limit is \(ByteLimit.describe(maxBytes)). Uploading as JPEG (#21) would be smaller."
        case .unusable:
            return "This image couldn't be prepared for upload."
        }
    }

    public static let supersededMessage =
        "The session's image changed before this one was prepared. Press ⌘⇧U again to upload the new one."

    /// The footer hint while composing or after a failure. Upload is never on Return.
    public static func keyHint(for state: State) -> String {
        switch defaultAction(for: state) {
        case .cancel: return "↵ Cancel   esc Close"
        case .none: return "esc Close"
        }
    }
}
