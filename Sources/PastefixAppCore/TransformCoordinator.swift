import Foundation
import PastefixCore

public enum TransformOutcome: Sendable, Equatable {
    case applied
    case unchanged
    case failed(String)
}

public enum TransformCoordinator {
    public static func isEnabled(_ transformer: any Transformer, for document: PasteDocument) -> Bool {
        if transformer.requiresRichInput { return document.origin.hasRichContent }
        return true
    }

    public static func apply(
        _ transformer: any Transformer,
        to document: PasteDocument
    ) async -> (PasteDocument, TransformOutcome) {
        var doc = document
        let input = TransformInput(text: doc.working, richRTFD: doc.origin.richRTFD)
        // Refuse before running: the cap is the only bound on a body inside an uninterruptible
        // Foundation call, and the user is told the limit rather than watching a spinner. A
        // transform that reads `input.richRTFD` (RichToPlain, RichToMarkdown) is measured on that
        // data, not on `input.text`, which it never touches.
        if transformer.requiresRichInput {
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
            let result = try await Deadline.run(seconds: transformer.timeout) { try await transformer.apply(input) }
            if let arming = transformer as? OutputModeTransformer { doc.outputMode = arming.outputMode }
            // The outcome is decided before the push, but the push happens either way: on equal
            // text `pushState` adds no history entry and doesn't truncate the redo stack — it now
            // only marks detection pending and bumps the revision, requesting the scan, which is
            // still the only thing that resyncs `detectedKinds`/`secretMatches` after a manual
            // `setWorking` edit. Short-circuiting here (as this used to) made that unreachable, so
            // a secret typed into the editor kept an empty badge until the next real push, undo,
            // redo or refresh.
            let outcome: TransformOutcome =
                result == doc.working && !(transformer is OutputModeTransformer) ? .unchanged : .applied
            doc.pushState(result)
            return (doc, outcome)
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
