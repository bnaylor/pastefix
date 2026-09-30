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

    /// Whether `transformer` can run on a selection. Rich transforms convert the origin's rich copy,
    /// output-mode transforms arm Save for the whole buffer, and image transforms don't take text:
    /// they run on the whole buffer even with a selection (#25).
    public static func canScope(_ transformer: any Transformer) -> Bool {
        !transformer.requiresRichInput
            && !(transformer is any OutputModeTransformer)
            && transformer.acceptedForms.contains(.text)
    }

    public static func staleSelectionMessage(_ name: String) -> String {
        "The selection changed before \(name) could run. Select the text again."
    }

    /// `apply(_:to:)` scoped to `scope` when there is one and the transformer can scope (#25): the
    /// transform sees only the selected text, its result is spliced back as one undo entry, and the
    /// third element is the span the result occupies (UTF-16), non-nil only when an entry was pushed.
    /// Without a usable scope it is exactly `apply(_:to:)`.
    public static func apply(
        _ transformer: any Transformer,
        to document: PasteDocument,
        scope: TransformScope?
    ) async -> (PasteDocument, TransformOutcome, NSRange?) {
        guard let scope, canScope(transformer), document.currentImage == nil else {
            let (doc, outcome) = await apply(transformer, to: document)
            return (doc, outcome, nil)
        }
        var doc = document
        let whole = doc.working
        guard let range = scope.selected(in: whole) else {
            return (doc, .failed(staleSelectionMessage(transformer.name)), nil)
        }
        let selected = String(whole[range])
        guard selected.utf8.count <= transformer.maxInputBytes else {
            return (doc, .failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of text."), nil)
        }
        let input = TransformInput(text: selected, richRTFD: doc.origin.richRTFD)
        do {
            let output = try await Deadline.run(seconds: transformer.timeout) { try await transformer.transform(input) }
            switch output {
            case .nothingToDo(let sentence):
                return (doc, .nothingToDo(sentence), nil)
            case .image:
                return (doc, .failed("\(transformer.name) produced an image, which can't replace selected text."), nil)
            case .text(let result):
                let spliced = String(whole[..<range.lowerBound]) + result + String(whole[range.upperBound...])
                guard spliced != whole else { doc.pushState(spliced); return (doc, .unchanged, nil) }
                doc.pushState(spliced)
                return (doc, .applied, NSRange(location: scope.range.location, length: (result as NSString).length))
            }
        } catch {
            return (doc, .failed(failureMessage(error)), nil)
        }
    }

    /// The `.failed` sentence for an error a transform threw — shared by both `apply` paths.
    static func failureMessage(_ error: Error) -> String {
        switch error {
        case let error as TransformError: return message(for: error)
        case is CancellationError: return "The transform was cancelled."
        default: return error.localizedDescription
        }
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
                if let arming = transformer as? any OutputModeTransformer { doc.outputMode = arming.outputMode }
                // The outcome is decided before the push, but the push happens either way: on equal
                // text `pushState` adds no entry and doesn't truncate the redo stack — it only marks
                // detection pending and bumps the revision, requesting the scan, which is still the
                // only thing that resyncs `detectedKinds`/`secretMatches` after a manual
                // `setWorking` edit. Short-circuiting here (as this used to) made that unreachable,
                // so a secret typed into the editor kept an empty badge until the next real push,
                // undo, redo or refresh. Compared as entries: from an image entry, "" is a change.
                let outcome: TransformOutcome =
                    .text(result) == doc.currentEntry && !(transformer is any OutputModeTransformer) ? .unchanged : .applied
                doc.pushState(result)
                return (doc, outcome)
            }
        } catch {
            return (doc, .failed(failureMessage(error)))
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
