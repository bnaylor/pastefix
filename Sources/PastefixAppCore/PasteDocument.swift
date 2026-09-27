import Foundation
import PastefixCore

/// The editing session for one summon: the origin clipboard snapshot plus a
/// linear history of working-text states with an undo/redo cursor.
public struct PasteDocument: Sendable {
    public let origin: ClipboardSnapshot
    public private(set) var history: [String]
    public private(set) var cursor: Int
    /// Detection for `working`. Pending after every discrete event (init, push, undo, redo,
    /// refresh) until the scheduler delivers a result for `detectionRevision`; the struct never
    /// scans on its own, because every caller is on the main actor.
    public private(set) var detection: DetectionState = .pending
    /// Incremented on every event that invalidates `detection`. A result carries the revision it
    /// was computed for and is refused if the document has moved on.
    public private(set) var detectionRevision = 0

    public var isDetecting: Bool { if case .pending = detection { return true } else { return false } }
    public var detectedKinds: Set<ContentKind> { if case .complete(let r) = detection { return r.kinds } else { return [] } }
    public var secretMatches: [SecretMatch] { if case .complete(let r) = detection { return r.secretMatches } else { return [] } }
    /// False while pending: an unscanned-yet buffer is not the same as an over-cap one, and the
    /// grey badge is for the latter.
    public var secretScanSkipped: Bool { if case .complete(let r) = detection { return r.secretScanSkipped } else { return false } }
    /// How Save should write the buffer. Set by an `OutputModeTransformer`; reset to
    /// `.plain` whenever the document is re-armed for a new summon (`refresh`).
    public var outputMode: OutputMode = .plain

    public init(origin: ClipboardSnapshot) {
        self.origin = origin
        self.history = [origin.plainText ?? ""]
        self.cursor = 0
        self.outputMode = .plain
        self.displaysAsImage = origin.imagePNG != nil
            && (origin.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var working: String { history[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count - 1 }

    /// The session's standalone image, if the clipboard had one. Carried whatever the session
    /// displays as, so an image-aware action reaches it even from a text session.
    public var imagePNG: Data? { origin.imagePNG }

    /// True when this session renders as an image rather than the editor: the origin carried an
    /// image and carried no real text.
    ///
    /// **Decided once, at init, and sticky for the session** — it is a `let`, and deliberately not
    /// derived from `working`. A live derivation is what the spec originally asked for and it is
    /// unshippable: `setWorking` pushes no history, so in a *mixed* session (image + text) ⌘A then
    /// Delete would blank `working`, flip this true on that keystroke, and replace the `TextEditor`
    /// with the image view — with `canUndo` false, so ⌘Z could not bring the editor back and the
    /// user could not type again for the rest of the session. Clearing the text in a mixed session
    /// leaves you in the editor.
    ///
    /// Sticky in both directions, and the other one costs nothing: an image session has no editor
    /// to type into and no transform that accepts an image, so `working` cannot gain text.
    ///
    /// A new origin is a new decision, not a mutation of this one: `refresh(origin:)` replaces the
    /// whole document, so ⌘R re-derives this from the clipboard it just read.
    ///
    /// "No real text" is blank-once-trimmed, which is the rule `PendingImage.resolve` and
    /// `HistoryStore.record` already use. Reusing it rather than writing a second one is the
    /// point: a capture path and a session path that disagree about whether a buffer has text
    /// give two different answers for one clipboard, and nobody notices until they do.
    public let displaysAsImage: Bool

    /// True when this session has nothing on screen but the refused-image notice: the clipboard
    /// carried an image too large to convert, and there is no real text in the editor either.
    ///
    /// The panel uses it to *withhold* editor focus, which is why it must not be the weaker
    /// condition "this session had a refused image". A **mixed** session — real text plus an
    /// over-ceiling image — is an ordinary text session with a banner over it, and suppressing
    /// focus there leaves a user unable to type after closing an overlay or landing a transform
    /// without first clicking into the editor. Emptiness is the whole reason to withhold focus: a
    /// blinking caret in an empty editor invites the one keystroke that makes `save()` write over
    /// the picture the banner has just promised is still on the clipboard.
    ///
    /// Emptiness is `SavePayload(document:).isEmpty` rather than a fourth spelling of "blank once
    /// trimmed", so the focus rule and Save's refusal cannot drift apart. It reads `working`, so a
    /// user who does type gets focus back for the rest of the session.
    public var isEmptyRefusedImageSession: Bool {
        origin.refusedImagePixels != nil && SavePayload(document: self).isEmpty
    }

    /// **Save must write nothing when this is true.**
    ///
    /// Save on an *unedited* session is at best a no-op and at worst destructive: the clipboard
    /// already holds everything the session has, so the best a write can do is put the same content
    /// back, and the worst it can do is `clearContents()` and then fail to reproduce something the
    /// clipboard was holding. So the rule is not "is the payload empty" but **the session must be
    /// able to reproduce everything the clipboard still holds** — and when it cannot, Save is a
    /// no-op and the session simply ends.
    ///
    /// Two ways it cannot, today. The payload is empty, so the write is `clearContents()` and
    /// nothing else. Or the origin carries `refusedImagePixels`: the clipboard holds an image this
    /// session was never given the bytes for, so *any* write drops it — including a write of real
    /// text in a mixed session, which is why "empty payload" alone was the wrong predicate and lost
    /// the picture the banner on screen promises is safe. #71 adds a third (a file reference the
    /// session cannot reproduce), and the principle already covers it; a list of cases would not.
    ///
    /// `isUnedited` is the other half and it is what keeps deliberate destruction working: select
    /// all, delete, ⌘S is an edited document, and that write happens. Losing an image that way is a
    /// consequence of something the user did, not something ⌘S did to them for summoning the panel.
    public var saveWouldLoseContent: Bool {
        guard isUnedited else { return false }
        return SavePayload(document: self).isEmpty || origin.refusedImagePixels != nil
    }

    /// True when nothing has happened to this document since it was captured: no transform
    /// pushed, nothing typed, nothing to redo, and no output mode armed.
    ///
    /// Deliberately stricter than `working == origin.plainText`, and every extra clause is a way
    /// a user action can leave the text alone:
    /// - An applied-then-undone transform sits at cursor 0 with the same text, but still holds
    ///   that transform in `history` as a redo.
    /// - An armed output mode (`MarkdownToRich`) changes how Save writes the buffer and not the
    ///   buffer itself, so `pushState` no-ops and `history.count` stays 1. Without this clause a
    ///   re-snapshot would silently disarm it.
    ///
    /// Both callers below ask "may I replace this document?", where a false negative costs a
    /// re-snapshot that does not happen and a false positive costs the user something they did.
    public var isUnedited: Bool {
        history.count == 1 && cursor == 0 && history[0] == (origin.plainText ?? "") && outputMode == .plain
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
    /// unchanged, but still invalidates detection: a push is a discrete event even when it lands
    /// on text a prior `setWorking` already coalesced in, so the scheduler resyncs to what's
    /// actually working.
    public mutating func pushState(_ text: String) {
        guard text != working else { invalidateDetection(); return }
        history = Array(history.prefix(cursor + 1))
        history.append(text)
        cursor = history.count - 1
        invalidateDetection()
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
            invalidateDetection()
        }
    }

    public mutating func redo() {
        if canRedo {
            cursor += 1
            invalidateDetection()
        }
    }

    public mutating func refresh(origin: ClipboardSnapshot) {
        // Carry the revision forward across the reset instead of restarting it at 0: a fresh
        // `PasteDocument` starts at revision 0, so a naive reset makes a pre-refresh revision-0
        // result indistinguishable from a post-refresh one, and `applyDetection` would accept a
        // stale result for the wrong document. Bumping past the old value keeps every revision
        // this document has ever reported unique for its lifetime.
        let next = detectionRevision + 1
        self = PasteDocument(origin: origin)
        detectionRevision = next
    }

    /// Installs `result` if it was computed for the current revision and nothing has been
    /// installed for it yet. Returns whether it applied.
    @discardableResult
    public mutating func applyDetection(_ result: DetectionResult, revision: Int) -> Bool {
        guard revision == detectionRevision, isDetecting else { return false }
        detection = .complete(result)
        return true
    }

    private mutating func invalidateDetection() {
        detection = .pending
        detectionRevision += 1
    }
}
