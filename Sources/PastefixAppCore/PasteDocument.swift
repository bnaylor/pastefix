import Foundation
import PastefixCore

/// The editing session for one summon: the origin clipboard snapshot plus a
/// linear history of working-text states with an undo/redo cursor.
public struct PasteDocument: Sendable {
    public let origin: ClipboardSnapshot
    public private(set) var history: [String]
    public private(set) var cursor: Int
    public private(set) var detectedKinds: Set<ContentKind>
    /// Secret matches in `working`, recomputed on the same discrete events as `detectedKinds`
    /// (init, push, undo/redo, refresh) so a redact transform pins to the same ranges the
    /// palette was built from, rather than re-scanning after every keystroke.
    public private(set) var secretMatches: [SecretMatch]
    /// How Save should write the buffer. Set by an `OutputModeTransformer`; reset to
    /// `.plain` whenever the document is re-armed for a new summon (`refresh`).
    public var outputMode: OutputMode = .plain

    public init(origin: ClipboardSnapshot) {
        self.origin = origin
        self.history = [origin.plainText ?? ""]
        self.cursor = 0
        // One scan, two consumers: `ContentDetector.detect(_:)` would otherwise run its own.
        let secrets = SecretDetector.scan(history[0])
        self.detectedKinds = ContentDetector.detect(history[0], secrets: secrets)
        self.secretMatches = secrets
        self.outputMode = .plain
    }

    public var working: String { history[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count - 1 }

    /// Append a new state (e.g. a transform result). Leaves `history`/`cursor` untouched if
    /// unchanged, but still redetects: a push is a discrete event even when it lands on text a
    /// prior `setWorking` already coalesced in, so detection resyncs to what's actually working.
    public mutating func pushState(_ text: String) {
        guard text != working else { redetect(); return }
        history = Array(history.prefix(cursor + 1))
        history.append(text)
        cursor = history.count - 1
        redetect()
    }

    /// Coalesce a manual edit into the current state (no new history entry).
    /// Deliberately does **not** re-detect: kinds are recomputed only on the discrete
    /// events (init, push, undo/redo, refresh), so the palette order stays pinned while
    /// the user types and detection isn't run per keystroke.
    public mutating func setWorking(_ text: String) {
        history[cursor] = text
    }

    public mutating func undo() {
        if canUndo {
            cursor -= 1
            redetect()
        }
    }

    public mutating func redo() {
        if canRedo {
            cursor += 1
            redetect()
        }
    }

    public mutating func refresh(origin: ClipboardSnapshot) {
        self = PasteDocument(origin: origin)
    }

    private mutating func redetect() {
        let secrets = SecretDetector.scan(working)
        detectedKinds = ContentDetector.detect(working, secrets: secrets)
        secretMatches = secrets
    }
}
