import Foundation
import PastefixCore

/// The editing session for one summon: the origin clipboard snapshot plus a
/// linear history of working-text states with an undo/redo cursor.
public struct PasteDocument: Sendable {
    public let origin: ClipboardSnapshot
    public private(set) var history: [String]
    public private(set) var cursor: Int
    public private(set) var detectedKinds: Set<ContentKind>
    /// How Save should write the buffer. Set by an `OutputModeTransformer`; reset to
    /// `.plain` whenever the document is re-armed for a new summon (`refresh`).
    public var outputMode: OutputMode = .plain

    public init(origin: ClipboardSnapshot) {
        self.origin = origin
        self.history = [origin.plainText ?? ""]
        self.cursor = 0
        self.detectedKinds = ContentDetector.detect(history[0])
        self.outputMode = .plain
    }

    public var working: String { history[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count - 1 }

    /// Append a new state (e.g. a transform result). No-op if unchanged.
    public mutating func pushState(_ text: String) {
        guard text != working else { return }
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
        detectedKinds = ContentDetector.detect(working)
    }
}
