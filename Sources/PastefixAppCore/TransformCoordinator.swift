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
        do {
            let result = try await transformer.apply(input)
            if result == doc.working { return (doc, .unchanged) }
            doc.pushState(result)
            return (doc, .applied)
        } catch let error as TransformError {
            return (doc, .failed(message(for: error)))
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
