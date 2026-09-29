import Foundation
import PastefixCore

/// The editing session for one summon: the origin clipboard snapshot plus a
/// linear history of working-text states with an undo/redo cursor.
public struct PasteDocument: Sendable {
    public let origin: ClipboardSnapshot
    /// One undo state: text, or an image (PNG bytes, never empty). Plan 20: transforms can turn
    /// one into the other, and one cursor walks both.
    public enum Entry: Sendable, Equatable {
        case text(String)
        case image(Data)
    }
    public private(set) var entries: [Entry]
    /// Each entry's text size in UTF-8 bytes (0 for an image), kept beside `entries` and updated
    /// wherever they change, so the working text's size is a read rather than a measurement — see
    /// `workingByteCount`.
    private var entryByteCounts: [Int]
    /// The sentence a transform left with the entry it produced ("Removed location details."),
    /// kept beside `entries` so it follows that entry through undo and redo. A stripped image looks
    /// identical to its original, so this is how the user can tell which one they are on — and it
    /// can never be stale, because it describes the entry it sits beside (Plan 20, GUI pass).
    private var entryNotes: [String?]
    /// Whether each entry has been typed into since it was pushed. Only `setWorking` with
    /// *different* text sets it — the TextEditor writes the same text back on focus and at the end
    /// of editing, and that is not typing. Decides `undoRestoresImage` (Plan 21).
    private var entryEdited: [Bool]
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
        let first = Self.initialEntry(for: origin)
        self.openedAsImage = { if case .image = first { return true }; return false }()
        self.entries = [first]
        self.entryByteCounts = [Self.byteCount(of: first)]
        self.entryNotes = [nil]
        self.entryEdited = [false]
        self.cursor = 0
        self.outputMode = .plain
    }

    /// What a fresh session over `origin` shows first: an image when the origin carried one and no
    /// real text (blank once trimmed), text otherwise. One rule, used by `init` and `isUnedited`.
    static func initialEntry(for origin: ClipboardSnapshot) -> Entry {
        let blank = (origin.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let png = origin.imagePNG, blank { return .image(png) }
        return .text(origin.plainText ?? "")
    }

    private static func byteCount(of entry: Entry) -> Int {
        if case .text(let text) = entry { return text.utf8.count }
        return 0
    }

    public var currentEntry: Entry { entries[cursor] }
    /// True when ⌘Z should restore an image rather than undo typing: the current entry is text a
    /// transform pushed over an image entry (OCR), and the user hasn't typed into it. In a text
    /// session ⌘Z is the editor's typing undo (#103); until there is typing to undo, the image is
    /// what the user expects back. Typing back to the original text still counts as edited.
    public var undoRestoresImage: Bool {
        guard cursor > 0, case .text = currentEntry, case .image = entries[cursor - 1] else { return false }
        return !entryEdited[cursor]
    }

    /// The note the transform that produced the current entry left, if any.
    public var currentNote: String? { entryNotes[cursor] }
    /// The current entry's text, or `""` on an image entry — what an image session has always
    /// effectively had, so detection sees nothing there.
    public var working: String {
        if case .text(let text) = currentEntry { return text }
        return ""
    }
    /// The current entry's PNG when it is an image.
    public var currentImage: Data? {
        if case .image(let png) = currentEntry { return png }
        return nil
    }

    /// The working text's UTF-8 size, stored rather than measured. `utf8.count` is O(1) only on a
    /// native string, and bridged ones reach `working`: the TextEditor's write-back through
    /// `setWorking`, non-ASCII pasteboard text, JS transform output — ~1 ms per MB, measured in
    /// the #101 review. The panel reads this on every render; storing it means a keystroke pays
    /// once instead of every render paying again.
    public var workingByteCount: Int { entryByteCounts[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < entries.count - 1 }

    /// The image Save, upload and the view use. A session that **opened as an image** holds its
    /// image in its entries: the current one, and nil on a text entry — that is what makes OCR
    /// *replace* the image (Plan 20). A session that opened as text or mixed carries the origin's
    /// image through every text transform, as it always has, so an image-aware action reaches it
    /// even from a text session.
    public var imagePNG: Data? { openedAsImage ? currentImage : origin.imagePNG }

    /// How Save writes this document right now. An armed mode is document-wide and survives undo,
    /// so on an image entry it is ignored: otherwise OCR → Markdown → Rich → ⌘Z would render
    /// `working` (`""`) and write empty HTML/RTF beside the PNG, which rich-aware targets prefer —
    /// an empty paste. Redo back onto the text entry arms it again.
    public var effectiveOutputMode: OutputMode { displaysAsImage ? .plain : outputMode }

    /// The init rule, fixed for the session: the origin carried an image and no real text. Decides
    /// the first entry, which image `imagePNG` means, and whether rich transforms may run.
    public let openedAsImage: Bool

    /// True when the current entry is an image, so the panel shows `ImageSessionView`.
    ///
    /// **Derived, and safe to derive** — the opposite of what this doc said before Plan 20, so
    /// read why. The trap AGENTS.md records ("a derived display rule is a trap when what it
    /// derives from is editable") was deriving the display from *editable text*: in a mixed
    /// session, ⌘A then Delete blanked `working`, flipped the view to the image on that keystroke,
    /// and `setWorking` pushes no undo, so the editor could not come back. This derives from the
    /// *form of the current entry*, which only a transform, undo or redo changes — each an undo
    /// record — and `setWorking` is ignored on an image entry, so no keystroke can flip it. Clearing
    /// the text of a mixed session still leaves you in the editor: its entry is `.text("")`.
    /// `refresh` changes the form with no undo record, as it replaces the whole document, which it
    /// always has; `PanelView`'s `onChange(of: displaysAsImage)` handles the preview then.
    public var displaysAsImage: Bool { currentImage != nil }

    /// The most working text the panel lays out in its editor (#52). Layout is ~1 s per MB
    /// (measured: 0.28 s at 256 KB, 1.0 s at 1 MB, 19 s at 17 MB) and blocks the main thread, so
    /// a huge clipboard kept every overlay waiting on text nobody was going to read — ⌘⇧U took
    /// ~9 s to say "too large to upload" (#62). The same 1 MB as `ContentDetector.maxBytes`, above
    /// which detection already stops.
    public static let editorDisplayLimitBytes = ContentDetector.maxBytes

    /// True when the working text is over `editorDisplayLimitBytes`: the panel shows a placeholder
    /// in place of the editor (the Markdown preview caps itself at 16 KB already), unless the user asks to see it anyway.
    /// Save and upload still act on all of it; most transforms refuse at their own input cap
    /// (`TransformLimits.defaultMaxInputBytes`, the same 1 MB). Computed from the stored
    /// `workingByteCount`, so it follows transforms, undo and edits — a transform that shrinks the
    /// text brings the editor back — at no cost per render.
    public var displaysAsLargeText: Bool {
        !displaysAsImage && workingByteCount > Self.editorDisplayLimitBytes
    }

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
    /// clipboard was holding. So the rule is not "is the payload empty" but: **the session must be
    /// able to reproduce everything the clipboard still holds, except the representations Save
    /// drops by policy** — and when it cannot, Save is a no-op and the session simply ends.
    ///
    /// **The policy exception is rich content, and it is wanted.** An unedited rich-text copy has
    /// `origin.richRTFD`, the payload writes plain text only (`SavePayload.richRTFD` is nil by
    /// policy), and `clearContents()` drops the RTF/HTML the clipboard was holding — so this Save
    /// *does* lose something the session could have reproduced, and it proceeds anyway. Summon + ⌘S
    /// as "strip formatting" predates image sessions and is plausibly relied on; removing the
    /// exception to make the words "everything the clipboard holds" literally true would break it.
    /// Anyone tempted to tighten this predicate to match a simpler sentence is removing a feature.
    /// The exception is recorded as a bucket, not as prose: `richRTFD` is
    /// `ClipboardSnapshot.RepresentationClass.droppedByPolicy`.
    ///
    /// The question is asked once, on the snapshot: `unreproduced(by:)` classifies **every** stored
    /// property of `ClipboardSnapshot` as reproduced-by-payload, dropped-by-policy, metadata, or
    /// loss-if-present, a `Mirror`-based test fails on any property that is in none of them, and for
    /// the loss-if-present bucket the classification **is** the predicate — that function reads
    /// `storedPropertyClasses` rather than naming fields. So #71's recorded file reference could not
    /// slip through: the earlier claim that "the principle already covers it" was false, and so was
    /// its first replacement, a bucket nothing read — a field classified correctly with
    /// `unreproduced(by:)` left alone passed every test while Save cleared the clipboard and dropped
    /// the reference. Now classifying it `.lossIfPresent` refuses the Save, and the one thing still
    /// left to a human is the comparison for a `.reproducedByPayload` field, which no reflection can
    /// write.
    ///
    /// Three ways it can be true today: the payload declares nothing at all, so the write is
    /// `clearContents()` and nothing else (`.wholeClipboard` — including whatever the clipboard
    /// holds that no snapshot reads, such as a custom type or a file promise, which an unedited
    /// Save with a non-empty payload drops by policy); the origin carries a `.lossIfPresent`
    /// property — today `refusedImagePixels`, an image the session has no bytes for, which makes
    /// *any* write lossy even in a mixed session with real text to write (the regression that
    /// proved "empty payload" was the wrong predicate), or `fileReferenceTypes`, a copied file no
    /// write can put back (#71); or the payload simply does not carry a representation the origin
    /// has.
    ///
    /// `isUnedited` is the other half and it is what keeps deliberate destruction working: select
    /// all, delete, ⌘S is an edited document, and that write happens. Losing an image that way is a
    /// consequence of something the user did, not something ⌘S did to them for summoning the panel.
    public var saveWouldLoseContent: Bool {
        guard isUnedited else { return false }
        return !origin.unreproduced(by: SavePayload(document: self)).isEmpty
    }

    /// True when nothing has happened to this document since it was captured: no transform
    /// pushed, nothing typed, nothing to redo, and no output mode armed.
    ///
    /// Deliberately stricter than `working == origin.plainText`, and every extra clause is a way
    /// a user action can leave the text alone:
    /// - An applied-then-undone transform sits at cursor 0 with the same entry, but still holds
    ///   that transform in `entries` as a redo.
    /// - "The same entry" is the init rule's (`initialEntry`), not `origin.plainText`: an
    ///   image-first document's first entry is the image (Plan 20).
    /// - An armed output mode (`MarkdownToRich`) changes how Save writes the buffer and not the
    ///   buffer itself, so `pushState` no-ops and `history.count` stays 1. Without this clause a
    ///   re-snapshot would silently disarm it.
    ///
    /// Both callers below ask "may I replace this document?", where a false negative costs a
    /// re-snapshot that does not happen and a false positive costs the user something they did.
    public var isUnedited: Bool {
        entries.count == 1 && cursor == 0 && entries[0] == Self.initialEntry(for: origin) && outputMode == .plain
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

    /// Append a new state (e.g. a transform result). Leaves `entries`/`cursor` untouched if it
    /// equals the current entry, but still invalidates detection: a push is a discrete event even
    /// when it lands on text a prior `setWorking` already coalesced in, so the scheduler resyncs to
    /// what's actually working. Compares *entries*: on an image entry `working` is `""`, so
    /// comparing text would silently drop a pushed `.text("")`.
    public mutating func push(_ entry: Entry, note: String? = nil) {
        guard entry != currentEntry else { invalidateDetection(); return }
        entries = Array(entries.prefix(cursor + 1))
        entries.append(entry)
        entryByteCounts = Array(entryByteCounts.prefix(cursor + 1))
        entryByteCounts.append(Self.byteCount(of: entry))
        entryNotes = Array(entryNotes.prefix(cursor + 1))
        entryNotes.append(note)
        entryEdited = Array(entryEdited.prefix(cursor + 1))
        entryEdited.append(false)
        cursor = entries.count - 1
        invalidateDetection()
    }

    /// A text result (e.g. a transform's). See `push`.
    public mutating func pushState(_ text: String) { push(.text(text)) }

    /// Coalesce a manual edit into the current text entry (no new entry). Ignored on an image
    /// entry: there is no editor on screen, and this is how a stale TextEditor write-back landing
    /// after ⌘Z moved onto an image is made harmless (Plan 20). Deliberately does **not**
    /// re-detect: kinds are recomputed only on the discrete events (init, push, undo/redo,
    /// refresh), so the palette order stays pinned while the user types.
    public mutating func setWorking(_ text: String) {
        guard case .text(let current) = currentEntry else { return }
        if current != text { entryEdited[cursor] = true }
        entries[cursor] = .text(text)
        entryByteCounts[cursor] = text.utf8.count
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
