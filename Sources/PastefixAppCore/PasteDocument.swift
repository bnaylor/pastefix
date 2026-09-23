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
    /// True when `working` was over `SecretDetector.maxBytes` and so was never examined. An empty
    /// `secretMatches` then means "unknown", not "clean", and the UI must say so — silence reads
    /// as a clean bill of health. Recomputed on exactly the same events as `secretMatches`.
    public private(set) var secretScanSkipped: Bool
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
        self.secretScanSkipped = !SecretDetector.isScannable(history[0])
        self.outputMode = .plain
    }

    public var working: String { history[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count - 1 }

    /// True when nothing has happened to this document since it was captured: no transform
    /// pushed, nothing typed, nothing to redo.
    ///
    /// Deliberately stricter than `working == origin.plainText`. A document sitting at cursor 0
    /// with an applied-then-undone transform still holds that transform in `history` as a redo,
    /// and that is work the user did — this returns false for it. The only caller is the
    /// "may I replace this document?" question below, where a false negative costs a re-snapshot
    /// that does not happen and a false positive costs the user their work.
    public var isUnedited: Bool {
        history.count == 1 && cursor == 0 && history[0] == (origin.plainText ?? "")
    }

    /// Whether this document should be thrown away and re-captured from a pasteboard now holding
    /// `changeCount`.
    ///
    /// Two conditions, and both matter. The buffer has to be *older than the clipboard*, because
    /// someone who copies and then presses a global hotkey means the thing they just copied —
    /// scanning and uploading the previous buffer instead reports a verdict about text nobody
    /// asked about. And it has to be *unedited*, because the only thing worse than uploading the
    /// wrong text is silently discarding text the user typed; an edited document is kept however
    /// stale it is, and the surface that opens says which one it got.
    ///
    /// An origin with no `changeCount` (a history item loaded into the panel) is never stale: it
    /// was never a copy of the clipboard, so "the clipboard moved on" says nothing about it, and
    /// the user chose it explicitly.
    public func isStale(comparedToPasteboardChangeCount changeCount: Int) -> Bool {
        guard let captured = origin.changeCount else { return false }
        return captured != changeCount && isUnedited
    }

    /// True when `working` is exactly what a pasteboard at `changeCount` holds — i.e. the panel
    /// is showing the current clipboard, untouched. What the upload overlay uses to name its
    /// source honestly: anything else is the panel's own buffer, not the clipboard.
    public func matchesPasteboard(changeCount: Int) -> Bool {
        origin.changeCount == changeCount && isUnedited
    }

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
        secretScanSkipped = !SecretDetector.isScannable(working)
    }
}
