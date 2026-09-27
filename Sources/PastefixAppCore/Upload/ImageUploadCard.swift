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
/// - **Return uploads only when nothing looked like text.** The owner's decision (2026-09-27):
///   this is a best-effort helper, Return should work, and a secret in an image that detection
///   cannot see is the user's responsibility. With text detected, Return cancels instead — that is
///   the case where secrets are likely, and the check that decides it works. The not-checked
///   verdict is shown either way, so the fast path never claims the image was checked.
public enum ImageUploadCard {
    /// The image half of the overlay's state. Shares nothing with the text card's `ScanState`.
    public enum State: Equatable, Sendable {
        /// The strip, byte cap and text-region detection have not resolved yet.
        case preparing
        /// `hasText` escalates the wording; it never quiets it.
        case ready(PreparedImage, hasText: Bool)
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

        /// The only bytes an image upload can send — the chosen format, or the PNG after "Send as
        /// PNG instead". There is deliberately no path from `State` to the session's original
        /// `imagePNG`.
        public var sanitized: SanitizedImage? {
            if case .ready(let prepared, _) = self { return prepared.toSend }
            return nil
        }

        public var prepared: PreparedImage? {
            if case .ready(let prepared, _) = self { return prepared }
            return nil
        }

        /// "Send as PNG instead" and back (#21). Changes which `SanitizedImage` `sanitized`
        /// returns; nothing outside a ready state with a PNG alternative is affected.
        public mutating func toggleFormat() {
            guard case .ready(var prepared, let hasText) = self else { return }
            prepared.toggleFormat()
            self = .ready(prepared, hasText: hasText)
        }

        public var hasText: Bool {
            if case .ready(_, let hasText) = self { return hasText }
            return false
        }
    }

    /// Which button Return presses.
    public enum DefaultAction: Equatable, Sendable {
        case none
        case cancel
        case upload
    }

    /// Upload only for a ready image with no text detected; Cancel when text was detected; nothing
    /// in a state that cannot upload (preparing, refused, superseded).
    public static func defaultAction(for state: State) -> DefaultAction {
        guard case .ready(_, let hasText) = state else { return .none }
        return hasText ? .cancel : .upload
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
        return "image · \(HistoryFormatting.byteLabel(image.data.count))"
    }

    /// What the card says about the format (#21), or nil for a plain PNG — the case that has
    /// nothing to explain. A format change the user cannot see would be a second silent
    /// transformation, so every JPEG says so, with the PNG's size beside it.
    public static func formatLine(for prepared: PreparedImage,
                                  maxBytes: Int = UploadLimits.maxPayloadBytes) -> String? {
        let png = HistoryFormatting.byteLabel(prepared.pngByteCount)
        let jpeg = HistoryFormatting.byteLabel(prepared.chosen.data.count)
        switch prepared.choice {
        case .jpegWithPNGEscape:
            return prepared.sendsPNGInstead
                ? "Sending as PNG (\(png); as JPEG it would be \(jpeg))"
                : "Sending as JPEG (\(jpeg); as PNG it would be \(png))"
        case .jpegForcedByCap:
            return "Sending as JPEG (\(jpeg)). As PNG it would be \(png), over the \(ByteLimit.describe(maxBytes)) limit"
        case .png, .refused:
            return nil
        }
    }

    /// The escape's title, or nil when there is no escape (a PNG, or a JPEG forced by the cap).
    public static func formatSwitchTitle(for prepared: PreparedImage) -> String? {
        guard prepared.choice.offersPNGEscape else { return nil }
        return prepared.sendsPNGInstead ? "Send as JPEG instead" : "Send as PNG instead"
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
        case .tooManyBytes(let bytes, .png):
            // Only an image with a non-opaque pixel is refused as PNG: an opaque one would have
            // gone as JPEG (`ImageFormatChoice`).
            return "\(HistoryFormatting.byteLabel(bytes)) after preparing; the limit is \(ByteLimit.describe(maxBytes)). It has transparency, so it can't be sent as JPEG."
        case .tooManyBytes(let bytes, .jpeg):
            return "\(HistoryFormatting.byteLabel(bytes)) even as JPEG; the limit is \(ByteLimit.describe(maxBytes))."
        case .unusable:
            return "This image couldn't be prepared for upload."
        }
    }

    public static let supersededMessage =
        "The session's image changed before this one was prepared. Press ⌘⇧U again to upload the new one."

    /// The footer hint while composing or after a failure.
    public static func keyHint(for state: State) -> String {
        switch defaultAction(for: state) {
        case .cancel: return "↵ Cancel   esc Close"
        case .upload: return "↵ Upload   esc Close"
        case .none: return "esc Close"
        }
    }
}
