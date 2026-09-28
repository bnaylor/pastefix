import Foundation
import PastefixCore

public enum TransformOutcome: Sendable, Equatable {
    case applied
    /// Applied, with a sentence for the user ("Removed location and camera details."), Plan 20.
    case appliedWithNote(String)
    case unchanged
    /// The transform had nothing to do and pushed nothing; the sentence says so (Plan 20).
    case nothingToDo(String)
    case failed(String)
}

public enum TransformCoordinator {
    public static func isEnabled(_ transformer: any Transformer, for document: PasteDocument) -> Bool {
        // Two independent gates. Form asks whether this transform can run on what the session is
        // showing at all; rich input asks whether the original clipboard carried rich content.
        // An image session fails the first for a text transform and the second for a rich one,
        // for different reasons, and neither subsumes the other.
        let form: ContentForm = document.displaysAsImage ? .image : .text
        guard transformer.acceptedForms.contains(form) else { return false }
        // Rich transforms read the *origin's* rich content, which an image origin can carry too
        // (Chrome's "Copy Image" writes HTML beside it). After OCR such a session is showing text,
        // and Rich → Plain would replace the recognised text with a rendering of that HTML.
        if transformer.requiresRichInput { return !document.openedAsImage && document.origin.hasRichContent }
        return true
    }

    public static func apply(
        _ transformer: any Transformer,
        to document: PasteDocument
    ) async -> (PasteDocument, TransformOutcome) {
        var doc = document
        let image = doc.currentImage
        let input = TransformInput(text: doc.working, richRTFD: doc.origin.richRTFD, image: image)
        // Refuse before running: the cap is the only bound on a body inside an uninterruptible
        // Foundation call, and the user is told the limit rather than watching a spinner. A
        // transform that reads `input.richRTFD` (RichToPlain, RichToMarkdown) is measured on that
        // data, not on `input.text`, which it never touches.
        // An image is bounded by the pixel ceiling, not the 1 MB text cap, and never downscaled
        // (Plan 20); its branch comes first because its `input.text` is "".
        if let image {
            let pixels = ImageBytes.pixelSize(of: image)
                .flatMap { ImageBytes.pixelCount(width: $0.width, height: $0.height) } ?? ImageBytes.unmeasurablePixels
            guard pixels <= ImageBytes.maxConvertiblePixels else {
                return (doc, .failed("\(transformer.name) works on images up to \(ImageBytes.megapixelLabel(ImageBytes.maxConvertiblePixels)); this one is \(ImageBytes.megapixelLabel(pixels))."))
            }
        } else if transformer.requiresRichInput {
            guard (input.richRTFD?.count ?? 0) <= transformer.maxInputBytes else {
                return (doc, .failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of rich text."))
            }
        } else {
            guard input.text.utf8.count <= transformer.maxInputBytes else {
                return (doc, .failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of text."))
            }
        }
        do {
            // A wall-clock bound per transform: the caller resumes at the transform's own
            // deadline even when the body is uninterruptible, and cancelling the caller cancels
            // the body too.
            let output = try await Deadline.run(seconds: transformer.timeout) { try await transformer.transform(input) }
            switch output {
            case .nothingToDo(let sentence):
                return (doc, .nothingToDo(sentence))
            case .image(let png, let note):
                guard ImageBytes.isPNG(png) else {
                    return (doc, .failed("\(transformer.name) didn't produce a usable image."))
                }
                guard PasteDocument.Entry.image(png) != doc.currentEntry else { return (doc, .unchanged) }
                doc.push(.image(png), note: note)
                return (doc, note.map(TransformOutcome.appliedWithNote) ?? .applied)
            case .text(let result):
                if let arming = transformer as? OutputModeTransformer { doc.outputMode = arming.outputMode }
                // The outcome is decided before the push, but the push happens either way: on equal
                // text `pushState` adds no entry and doesn't truncate the redo stack — it only marks
                // detection pending and bumps the revision, requesting the scan, which is still the
                // only thing that resyncs `detectedKinds`/`secretMatches` after a manual
                // `setWorking` edit. Short-circuiting here (as this used to) made that unreachable,
                // so a secret typed into the editor kept an empty badge until the next real push,
                // undo, redo or refresh. Compared as entries: from an image entry, "" is a change.
                let outcome: TransformOutcome =
                    .text(result) == doc.currentEntry && !(transformer is OutputModeTransformer) ? .unchanged : .applied
                doc.pushState(result)
                return (doc, outcome)
            }
        } catch let error as TransformError {
            return (doc, .failed(message(for: error)))
        } catch is CancellationError {
            return (doc, .failed("The transform was cancelled."))
        } catch {
            return (doc, .failed(error.localizedDescription))
        }
    }

    /// Maps a `TransformError` to a human-readable message.
    ///
    /// This method is intentionally internal. Error messages reach the UI through the
    /// `.failed(String)` case of `TransformOutcome` returned by `apply(_:to:)`, not by
    /// calling this method directly.
    static func message(for error: TransformError) -> String {
        switch error {
        case .richInputUnavailable: return "No rich text available to convert."
        case .timeout: return "The transform timed out."
        case .nonZeroExit(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Script failed (exit \(code))." : "Script failed (exit \(code)): \(detail)"
        case .scriptFailed(let msg): return "Script error: \(msg)"
        case .invalidInput(let msg): return msg
        }
    }
}
