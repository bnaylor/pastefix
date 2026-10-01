import Foundation
import AppKit
import OSLog
import Combine
import SwiftUI
import PastefixCore
import PastefixAppCore

/// `log stream --predicate 'subsystem == "net.scromp.Pastefix" && category == "undo"' --debug`
private let undoLog = Logger(subsystem: "net.scromp.Pastefix", category: "undo")

/// A span to select once the buffer it indexes is on screen (#25): after a scoped apply, and on the
/// undo and redo of one. UTF-16, with the `detectionRevision` of the buffer it belongs to, so the
/// view selects it only in that buffer. The single owner of post-apply selection: carried by
/// `PanelView.carrySelection`, never `requestedSelection` (which the landing path clears).
struct PendingSelection: Equatable {
    let range: NSRange
    let revision: Int
}

/// The image region to restore once the image entry it was drawn on is back on screen (crop spec):
/// set when ⌘Z undoes a transform that was applied with a region up. Consumed by `PanelView`.
struct PendingImageRegion: Equatable {
    let region: ImageRegion
    let revision: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var document: PasteDocument?
    @Published var errorMessage: String?
    /// Separate from `errorMessage` on purpose: an error reports that something failed, a notice
    /// reports a refusal in which nothing was lost (the clipboard is untouched). Conflating them
    /// (as `noteRefusedImage` used to, through `errorMessage`) taught a user that an intact
    /// clipboard looks exactly like a broken one — same red strip, same warning triangle.
    ///
    /// The two channels are independent, deliberately — not lockstep. `noticeMessage` is a
    /// standing fact about the session's *origin* ("that image is too large to open") and stays
    /// true for the session's whole life; `errorMessage` reports a
    /// transient failure (an apply, a Markdown render) that can come and go many times within
    /// that same session. Only the four session boundaries — `summon`, `refresh`, `load` and
    /// `endSession` — clear both together, and each does it the same way: by assigning nil to both
    /// channels itself, because only there does the standing fact itself change. `setWorking`
    /// clears neither, deliberately — typing is not a new origin. Elsewhere — `apply`'s completion,
    /// `save`'s Markdown size refusal and its render failure — a failure sets
    /// `errorMessage` without touching `noticeMessage`, so the two *can* both be non-nil at once
    /// mid-session: a still-true notice must survive an unrelated transient error, not be wiped
    /// out by it. `PanelView` shows only one banner at a time and picks the error when both are
    /// set — a priority for the single slot, not evidence that both can't happen — so nothing is
    /// lost: the notice reappears as soon as the error clears (a later successful transform sets
    /// `errorMessage = nil`).
    @Published var noticeMessage: String?
    /// A transform's sentence about what it just did or why it did nothing ("Removed location and
    /// camera details.", "This image has no location or camera details to remove."), Plan 20.
    /// **Not** `noticeMessage`: that is a standing fact about the origin, cleared only at session
    /// boundaries, and a transform's sentence left there would outlive the ⌘Z that makes it false.
    /// It follows the entry it describes through undo and redo (`PasteDocument.currentNote`) — a
    /// stripped image looks identical to its original, so this is how the user tells them apart —
    /// and is cleared by the next apply and every session boundary. A "nothing to do" sentence has
    /// no entry, so undo or redo clears it. `PanelView` shows one banner: error first, then this,
    /// then the notice.
    @Published var transformNote: String?
    @Published private(set) var isApplying = false
    /// The panel window, set by `WindowUndoBinding`. Its undo manager is the ONE stack for the
    /// editor's typing and for transforms (#103): the TextEditor's typing undo already lives there,
    /// so transforms register there too, and ⌘Z — Edit ▸ Undo, up the responder chain — walks both in
    /// the order they happened, with or without an editor on screen.
    weak var panelWindow: NSWindow? { didSet { observeUndoManager() } }
    var undoManager: UndoManager? { panelWindow?.undoManager }
    /// The toolbar's Undo/Redo, mirrored from `undoManager` (which SwiftUI can't observe). Not
    /// `document.canUndo`: after an undo and some typing the manager has dropped the redo while the
    /// model still holds entries past its cursor. Its own object, never republished here — see
    /// `UndoState`.
    let undoState = UndoState()
    private var undoObservers: [NSObjectProtocol] = []
    /// Identifies the apply in flight; bumped to drop a result that must not land (⌘Z cancelled it,
    /// or the session moved on).
    private var applyID = 0
    @Published private(set) var transformers: [any Transformer] = []
    @Published private(set) var allTransformers: [any Transformer] = []

    /// Set by the ⌘⇧V hotkey; PanelView opens the history overlay and resets it.
    @Published var historyOverlayRequested = false

    /// Set by the ⌘⇧U hotkey. One-shot, cleared as it is consumed, exactly like
    /// `historyOverlayRequested` — left set, it would reopen the overlay by itself on the next
    /// summon.
    @Published var uploadOverlayRequested = false

    /// A one-shot request to move the editor's selection, written by the secrets badge and
    /// cleared by `PanelView` as soon as it consumes it.
    ///
    /// The *live* selection deliberately does not live here — it is `PanelView`'s own `@State`.
    /// A `TextEditor` writes its selection back through the binding whenever the caret moves or
    /// focus changes, so a binding into this object published on the model, re-rendered the whole
    /// panel and re-applied the selection to the editor, which took first responder back from the
    /// ⌘K palette's search field the instant it appeared.
    @Published var requestedSelection: TextSelection?
    /// See `PendingSelection`. Consumed (and cleared) by `PanelView`; cleared at session boundaries.
    @Published var pendingSelection: PendingSelection?
    /// The region ⌘Z restores on the image entry it names (crop spec); `PanelView` consumes it.
    @Published var pendingImageRegion: PendingImageRegion?
    /// Markup marks waiting to be burned in (annotate spec), in order. The head applies when no apply
    /// is running; each is one undo step. Never dropped by a fast second stroke, emptied at session
    /// boundaries (`resetUndo`).
    @Published private(set) var pendingMarks: [ImageMark] = []
    /// True while the head of `pendingMarks` is the apply in flight.
    private var markInFlight = false
    /// The lane `AnnotateImage` runs on: the shared image lane; tests give it a private one.
    var annotateLane: ImageTransformLane.Lane = ImageTransformLane.shared
    /// The markup tool and colour, for the app's run (not saved, not published: `PanelView` owns
    /// the live copies and writes them back).
    var markupTool: ImageMark.Tool = .box
    var markupColor: ImageMark.Color = .red
    var markupTextSize: ImageMark.TextSize = .m
    /// A write-only mirror of `PanelView`'s markup mode, for the hosted tests (as `imageRegionOnScreen`).
    var markupModeOnScreen = false
    /// Whether `PanelView` has a markup label open: a write-only mirror for the hosted tests.
    var markupTextDraftOnScreen = false
    /// A transform the user chose is running (not a mark). Markup drawing is off then: its result
    /// can move or resize the pixels a mark drawn meanwhile was placed on (annotate final review I2).
    var isApplyingNonMark: Bool { isApplying && !markInFlight }

    func enqueueMark(_ mark: ImageMark) {
        pendingMarks.append(mark)
        drainMarks()
    }

    /// Applies the queue's head if nothing is applying. Called on enqueue and whenever an apply ends.
    private func drainMarks() {
        guard !isApplying, !markInFlight, let next = pendingMarks.first, document != nil else { return }
        markInFlight = true
        apply(AnnotateImage(next, lane: annotateLane))
        if !isApplying { markInFlight = false }   // apply refused it; the mark stays queued
    }

    /// The apply that just LANDED was a mark: it's done (landed or failed — a failed one is dropped,
    /// its error shown as usual); on to the next. Only the landing path calls this. A cancel (⌘Z)
    /// or an abandon (session switch) clears `markInFlight` without draining: draining there started
    /// the next mark on the document that was about to be replaced, leaving the new session stuck
    /// "applying", or landed a mark on top of the undo (annotate final review C1).
    private func markLanded() {
        guard markInFlight else { return }
        markInFlight = false
        if !pendingMarks.isEmpty { pendingMarks.removeFirst() }
        drainMarks()
    }
    /// A write-only mirror of the region `PanelView` holds, for the hosted tests: SwiftUI builds no
    /// accessibility tree in-process, so they can't read the footer. The app never reads it, and it
    /// isn't `@Published`, so writing it re-renders nothing (the #25 lesson about selection state).
    var imageRegionOnScreen: ImageRegion?

    /// Cycle position for `selectNextSecret`, reset wherever `document` is replaced.
    private var nextSecretIndex = 0

    let settings: SettingsStore
    let history: HistoryStore
    var onEndSession: (() -> Void)?

    /// The app to paste a snippet into once Pastefix hides, supplied by the delegate from
    /// `FrontmostAppTracker`. A closure rather than a stored app so the value is read at paste
    /// time, not at whatever moment the model happened to be wired up.
    var previousAppProvider: () -> NSRunningApplication? = { nil }

    /// Bumped on every summon and every dismissal. An in-flight transform captures the
    /// value it started under, so a result from a session the user has since dismissed
    /// can't land in a newer one — `document != nil` alone doesn't catch a dismiss-then-
    /// re-summon inside the apply window.
    ///
    /// Published because it is also the panel's reset signal: it moves monotonically, so a
    /// `PanelView` that never got to render between a session ending and the next one starting
    /// still sees the change (a derived `document == nil` reads the same on both sides of a
    /// skipped render and the overlay stays open over a fresh session).
    @Published private(set) var sessionGeneration = 0

    /// Off-main detection lane; results land through `detectionFinished`.
    private lazy var detection = DetectionScheduler { [weak self] req, result in self?.detectionFinished(req, result) }
    /// The in-flight apply, cancelled wherever the session changes so a slow transform does not
    /// keep running for a buffer nobody can see.
    private var applyTask: Task<Void, Never>?

    /// The one lane every image upload preparation runs through (#48): strip, byte cap, Vision.
    ///
    /// `static`, not per instance — "a per-instance lane is not a lane" (#46). A CG decode cannot
    /// be cancelled, so the bound on concurrent ~330 MB decodes has to be one per *process*.
    /// `nonisolated` so the work closure formed here is not main-actor isolated: the target builds
    /// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a main-actor closure run on the
    /// lane's queue would either hop back to the main thread or trap (the `TIFFConversionSlot`
    /// trap, spelled out there).
    nonisolated private static let imagePreparationLane =
        SingleSlotLane<Data, ImageUploadPreparation.Outcome>(label: "net.scromp.Pastefix.upload.image-preparation") { png in
            ImageUploadPreparation.prepare(png)
        }

    /// This session's image preparation, in flight or finished. A repeat ⌘⇧U rebuilds the upload
    /// overlay, and the rebuilt overlay gets this same task rather than starting another decode.
    /// Cleared at every session boundary (`abandonInFlightWork`).
    private lazy var imagePreparations = SessionPreparationCache(lane: Self.imagePreparationLane)

    /// The preparation for `png` — the upload overlay's snapshot of this session's `imagePNG` —
    /// shared by every overlay opened on the same session and bytes. nil from the task means the
    /// lane skipped it for a newer image.
    func imageUploadPreparation(for png: Data) -> Task<ImageUploadPreparation.Outcome?, Never> {
        imagePreparations.preparation(for: png, generation: sessionGeneration)
    }

    /// True until the current buffer's scan lands. The Zipline upload gate (#14) must wait for
    /// this before treating an empty `secretMatches` as "no secrets". A gate should observe
    /// `$document` and re-check this rather than spin on the Bool: `document == nil` reads the
    /// same `false` as a completed scan but means "no buffer", not "clean". The real tri-state
    /// lives on `PasteDocument.detection` (`.pending` or `.complete`, the latter carrying
    /// `secretScanSkipped` for an over-cap buffer).
    var isDetecting: Bool { document?.isDetecting ?? false }

    /// Every clipboard read and write the model makes goes through this. `.general` in the app;
    /// a uniquely named pasteboard in tests (#68), so a test run never touches the user's clipboard.
    let pasteboard: NSPasteboard

    init(settings: SettingsStore, history: HistoryStore, pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        self.settings = settings
        self.history = history
        reload()
    }

    private func requestDetection() {
        guard let doc = document, doc.isDetecting else { return }
        detection.request(.init(text: doc.working, revision: doc.detectionRevision, generation: sessionGeneration))
    }

    private func detectionFinished(_ req: DetectionScheduler.Request, _ result: DetectionResult) {
        guard sessionGeneration == req.generation, var doc = document else { return }
        if doc.applyDetection(result, revision: req.revision) { document = doc }
    }

    /// Stops work that belonged to the buffer being replaced.
    private func abandonInFlightWork() {
        applyTask?.cancel()
        applyTask = nil
        applyID &+= 1
        detection.cancelAll()
        markInFlight = false   // the queue is emptied by the boundary's resetUndo; never drained here
        isApplying = false
        // Every caller also bumps `sessionGeneration`, so the cached preparation is no longer
        // anyone's; dropping it skips it on the lane if it has not started.
        imagePreparations.clear()
    }

    /// Rebuild the transformer list from current settings (scripts dir, wrap
    /// width, regex presets) and apply the user's enable/reorder overrides. Safe to call any
    /// time (e.g. on a script-directory change, a preset edit, or a settings edit).
    func reload() {
        let config = RegistryConfig(
            scriptsDirectory: settings.scriptsDirectoryURL,
            wrapWidth: settings.wrapWidth,
            presets: settings.regexPresets
        )
        let loaded = TransformerRegistry(config: config).load()
        // Unfiltered (for the Settings list): order applied, nothing removed.
        allTransformers = TransformOverrides.apply(to: loaded, enabled: [:], order: settings.transformOrder)
        // Filtered + ordered (for the palette).
        transformers = TransformOverrides.apply(
            to: loaded,
            enabled: settings.transformEnabled,
            order: settings.transformOrder
        )
    }

    /// ⌘⇧U's one decision: does the upload need a fresh snapshot of the clipboard, or does the
    /// open session stand? Fresh when there is no session, or when the session is unedited and the
    /// user has copied something since it was captured. Pastefix's own writes — the short URL an
    /// upload puts on the clipboard — are not the user copying, or a second ⌘⇧U would offer to
    /// upload the link to what was just uploaded. Moved here from `AppDelegate.summonUpload` so it
    /// is testable (#68): that stale-buffer rule is the one defect of Plan 13 that reached the user.
    func uploadNeedsFreshSnapshot() -> Bool {
        guard let document else { return true }
        let changeCount = pasteboard.changeCount
        let userCopiedSomethingNew = !ClipboardBridge.clipboardIsSelfWritten(changeCount: changeCount, on: pasteboard)
        return userCopiedSomethingNew && document.isStale(comparedToPasteboardChangeCount: changeCount)
    }

    func summon() {
        beginSession(from: ClipboardBridge.snapshot(from: pasteboard))
    }

    /// A new session over `origin`. `summon` is this over a fresh pasteboard snapshot; tests (#68)
    /// use it directly to start from a snapshot the pasteboard path would never produce — which is
    /// how a defect that validation upstream now hides stays pinned downstream.
    func beginSession(from origin: ClipboardSnapshot) {
        endComposition()
        errorMessage = nil
        noticeMessage = nil
        transformNote = nil
        resetSecretSelection()
        abandonInFlightWork()
        sessionGeneration &+= 1
        document = PasteDocument(origin: origin)
        resetUndo()
        noteRefusedImage(origin)
        requestDetection()
    }

    /// Says so when the clipboard held an image the snapshot declined to open.
    ///
    /// Without this the panel comes up as an empty text session and nothing anywhere says why —
    /// the user copied a picture and got a blank editor. A 30 MP photo out of Preview is enough to
    /// hit the ceiling, so this is a path real people reach, and silence on it is the house
    /// anti-pattern (the upload overlay's "image, not supported yet" exists for the same reason).
    ///
    /// The clipboard is untouched, which the message says, because "too large" invites the
    /// assumption that something was lost. But it says it **conditionally** — "until you save text
    /// over it" — because that is exactly the guarantee: `PasteDocument.saveWouldLoseContent` makes
    /// ⌘S a no-op for as long as the session is untouched, text in the buffer or not, and just as
    /// deliberately stops doing so once the user has typed, since typing and then saving is an
    /// instruction. A banner promising the picture is safe full stop would be a promise ⌘S can break
    /// one keystroke later.
    ///
    /// Kept short, and ordered so the instruction comes before the numbers: the banner is
    /// `.lineLimit(2)` at `.callout` in a 560 pt panel, so at larger Dynamic Type sizes the tail is
    /// what disappears. The megapixel figures are the expendable half; "paste it directly" is not.
    private func noteRefusedImage(_ origin: ClipboardSnapshot) {
        guard let pixels = origin.refusedImagePixels else { return }
        noticeMessage = "That image is too large to open — paste it directly, it's on your clipboard until you save text over it. (\(ImageBytes.megapixelLabel(pixels)); limit \(ImageBytes.megapixelLabel(ImageBytes.maxConvertiblePixels)))"
    }

    /// Palette list: enabled transforms in the user's order, with those applicable to the
    /// detected content first. Settings uses `allTransformers`, which detection never reorders.
    func enabledTransformers() -> [any Transformer] {
        guard let document else { return [] }
        return enabledTransformers(for: document.detectedKinds)
    }

    /// Same as `enabledTransformers()`, but ranked against a caller-supplied set of kinds instead
    /// of the live document — `CommandPaletteView` freezes this at the moment the palette opens so
    /// the list order does not move under the cursor when detection lands mid-navigation.
    func enabledTransformers(for kinds: Set<ContentKind>) -> [any Transformer] {
        guard let document else { return [] }
        let enabled = transformers.filter { TransformCoordinator.isEnabled($0, for: document) }
        return PaletteOrdering.order(enabled, for: kinds)
    }

    /// Enabled transforms in the user's order, without detection-based promotion — for browse
    /// surfaces (the sidebar) that should not reshuffle with the clipboard.
    func browsableTransformers() -> [any Transformer] {
        guard let document else { return [] }
        return transformers.filter { TransformCoordinator.isEnabled($0, for: document) }
    }

    /// "URL", "URL, JSON", or nil when nothing was detected. Never lists "Secrets": the orange
    /// badge next to it already says so, in the one place that can act on it.
    var detectedSummary: String? {
        guard let kinds = document?.detectedKinds else { return nil }
        let names = ContentKind.allCases.filter { $0 != .secret && kinds.contains($0) }.map(\.displayName)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Credentials found when the buffer was captured or refreshed; drives the action-bar badge.
    var secretMatches: [SecretMatch] { document?.secretMatches ?? [] }

    /// True when the buffer was too large to scan, so `secretMatches` is empty for want of a scan
    /// rather than for want of secrets. Drives the grey "Not scanned for secrets" badge: an
    /// unscanned buffer must not look like a clean one.
    var secretScanSkipped: Bool { document?.secretScanSkipped ?? false }

    /// Selects the next detected secret in the editor, cycling back to the first.
    ///
    /// Re-scans the *live* buffer rather than reusing `document.secretMatches`: those ranges were
    /// pinned when the document was captured or refreshed and index a string the user may have
    /// edited since, so selecting one could highlight unrelated text — or trap on an index the
    /// buffer no longer has. If the edits removed every match there is nothing to select and the
    /// click is a no-op; the badge keeps the pinned count until the document refreshes.
    func selectNextSecret() {
        guard let doc = document else { return }
        let live = SecretDetector.scan(doc.working)
        guard !live.isEmpty else { return }
        nextSecretIndex %= live.count
        requestedSelection = TextSelection(range: live[nextSecretIndex].range)
        nextSecretIndex += 1
    }

    /// The parsed colour when the buffer is a colour literal; drives the action-bar swatch.
    /// This re-parses live while `detectedKinds` stays frozen during a manual edit, so the swatch
    /// can disappear a keystroke before the badge does — intentional: the swatch must never show a
    /// colour the buffer no longer parses as.
    var detectedColor: ColorLiteral? {
        guard let document, document.detectedKinds.contains(.color) else { return nil }
        return ColorLiteral.parse(document.working)
    }

    /// `scope`: the selected span to transform instead of the whole buffer (#25), taken by the view
    /// before this call. Checked by content after `settleComposition()`, which can change the text.
    func apply(_ transformer: any Transformer, scope: TransformScope? = nil) {
        guard !isApplying else { return }
        settleComposition()
        guard let current = document else { return }
        transformNote = nil
        isApplying = true
        let generation = sessionGeneration
        applyID &+= 1
        let id = applyID
        applyTask = Task {
            let (updated, outcome, span) = await TransformCoordinator.apply(transformer, to: current, scope: scope)
            // What to select once this lands (#25): the new span of a scoped apply; or, when a
            // whole-only transform (rich, output-mode) ran while text was selected, a caret where the
            // selection started — the old offsets index a different buffer now and would select
            // unrelated characters (GUI pass: "a be"). The undo step restores the user's selection.
            let selectAfter: NSRange? = span ?? {
                guard let scope = scope?.text, updated.cursor != current.cursor else { return nil }
                return NSRange(location: min(scope.range.location, (updated.working as NSString).length), length: 0)
            }()
            // The session can end (Save/Cancel/auto-hide) while a slow transform is in
            // flight, and the user can summon a fresh one before it finishes; ⌘Z cancels it
            // (`observeUndoManager`).
            // Drop the result unless this is still the apply that was asked for.
            // `abandonInFlightWork()`, `endSession()` and `cancelApply()` own `isApplying` then.
            guard self.document != nil, self.sessionGeneration == generation, self.applyID == id else {
                return
            }
            self.document = updated
            // Registered on landing, and only when something was pushed: nothing to do, a failure
            // and the same text leave nothing to undo. (Registering when the apply starts and
            // removing it on a no-op doesn't work: `removeAllActions(withTarget:)` leaves the empty
            // group behind, `canUndo` stays true, and the next ⌘Z does nothing — measured.)
            if updated.cursor != current.cursor {
                self.breakTypingCoalescing()
                self.registerUndo(TransformStep(name: transformer.name, generation: generation,
                                                before: selectAfter == nil ? nil : scope?.text?.range, after: selectAfter,
                                                regionBefore: scope?.imageRegion))
            }
            // The failure path returns `current` unchanged (same revision), so only request a
            // scan when the buffer actually moved — re-requesting on every refused click would
            // cancel and restart an in-flight summon scan for no reason.
            if updated.detectionRevision != current.detectionRevision { self.requestDetection() }
            // The caret is `PanelView`'s to carry across the new buffer; the badge's cycle
            // restarts here because the match list belongs to the buffer that just went away.
            self.resetSecretSelection()
            // After the reset, not before: `resetSecretSelection()` clears `requestedSelection`, and
            // the span is its own channel anyway (see `PendingSelection`).
            if let selectAfter { self.pendingSelection = PendingSelection(range: selectAfter, revision: updated.detectionRevision) }
            // Only an apply that changed something is a use (#26): failures, "nothing to do" and an
            // unchanged buffer don't make a transform rank higher.
            switch outcome {
            case .applied, .appliedWithNote:
                // A markup mark isn't a transform the user chose from a list (annotate spec).
                if !(transformer is AnnotateImage) { self.settings.recordTransformUse(transformer.id) }
            case .unchanged, .nothingToDo, .failed: break
            }
            switch outcome {
            case .applied, .unchanged:
                self.errorMessage = nil
                // Whatever entry is current now carries its own note (or none): the note
                // follows its entry, here as on undo and redo (#104 review).
                self.transformNote = updated.currentNote
            case .appliedWithNote(let note), .nothingToDo(let note):
                self.errorMessage = nil
                self.transformNote = note
            case .failed(let message):
                self.errorMessage = message
                self.transformNote = updated.currentNote
            }
            self.isApplying = false
            self.applyTask = nil
            self.markLanded()
        }
    }

    func setWorking(_ text: String) {
        guard var doc = document else { return }
        if let echo = endedSessionText, text != doc.working {
            endedSessionText = nil
            if text == echo { return }
        }
        doc.setWorking(text)
        document = doc
    }

    /// The model half of undoing a transform: the window's undo stack calls this (`stepBack`). UI
    /// goes through `undoManager`, never here, or the stack and the model disagree about what's next.
    func undo() {
        guard var doc = document else { return }
        let before = doc.detectionRevision
        doc.undo()
        document = doc
        // The note follows the entry it describes: undo to the original shows none.
        transformNote = doc.currentNote
        if doc.detectionRevision != before { requestDetection() }
        resetSecretSelection()
    }

    /// The model half of redoing a transform; see `undo()`.
    func redo() {
        guard var doc = document else { return }
        let before = doc.detectionRevision
        doc.redo()
        document = doc
        transformNote = doc.currentNote
        if doc.detectionRevision != before { requestDetection() }
        resetSecretSelection()
    }

    func refresh() {
        endComposition()
        guard var doc = document else { return }
        let origin = ClipboardBridge.snapshot(from: pasteboard)
        doc.refresh(origin: origin)
        document = doc
        resetUndo()
        // A refresh can replace the image without a new session generation. The cache key
        // includes the bytes, so a stale preparation is never *served* — but it would still be
        // *held* (up to 16 MB) until the next request, so it is dropped here.
        imagePreparations.clear()
        requestDetection()
        errorMessage = nil
        noticeMessage = nil
        transformNote = nil
        // After the clear, not before: a refused image is news about the buffer that was just
        // installed, and clearing afterwards would throw it away.
        noteRefusedImage(origin)
        resetSecretSelection()
    }

    /// Drops any pending badge request and restarts its cycle.
    ///
    /// Called wherever the buffer is replaced — a new session (summon, load, refresh, end of
    /// session) and a landed transform, undo or redo. A request carries `String.Index` values
    /// into the buffer it was made against, and applying one to a shorter string is undefined and
    /// traps, so a request that hasn't been consumed by the time the buffer moves is dropped
    /// rather than carried. The live caret is `PanelView`'s and is clamped there
    /// (`TextRangeClamp.remap`) so an ordinary transform doesn't throw it back to the start.
    private func resetSecretSelection() {
        requestedSelection = nil
        nextSecretIndex = 0
    }

    func save() {
        settleComposition()
        guard let doc = document else { endSession(); return }
        // **Save on an unedited session is at best a no-op and at worst destructive, so it must be
        // a no-op whenever the session cannot reproduce everything the clipboard still holds.**
        // An unedited buffer means the clipboard already has everything this session has, so the
        // most a write can achieve is putting the same bytes back — while `clearContents()` in
        // front of it can silently drop what the session was never given: the over-ceiling image
        // the notice on screen is about, and (#71) a file reference. The predicate and the whole
        // argument live in `PasteDocument.saveWouldLoseContent`, where they are testable (#68) and
        // where the next case to appear extends one rule rather than this list.
        if doc.saveWouldLoseContent { endSession(); return }
        // What this Save writes, decided once, in one pure place, so the write below and the
        // refusal above cannot disagree about what the session holds (see `SavePayload`).
        let payload = SavePayload(document: doc)
        if doc.effectiveOutputMode == .renderedMarkdown {
            // MarkdownToRich's own cap only bounds arming (the transform ran against a buffer at
            // or under it), but the buffer can grow afterwards — further edits, or a preset that
            // amplifies text — and this render runs synchronously on the main actor, same as the
            // rest of Save.
            guard doc.working.utf8.count <= MarkdownToRich.maxInputBytes else {
                errorMessage = "Markdown → Rich Text is limited to \(ByteLimit.describe(MarkdownToRich.maxInputBytes)) of text. Click the badge to save as plain text instead."
                return
            }
            do {
                let rich = try RichOutputRenderer.render(markdown: doc.working)
                // The same `payload` as the branch below, plus the two renderings of its text.
                // Arming Markdown → Rich Text is a statement about how the *text* is written, not
                // permission to drop an image the session was handed and the user never touched —
                // and passing the payload rather than `doc.imagePNG` is what stops this branch
                // bypassing the empty-`Data` backstop and writing a zero-byte `public.png`
                // (see `ClipboardBridge.writeRich`).
                ClipboardBridge.writeRich(payload, html: rich.html, rtf: rich.rtf, to: pasteboard)
            } catch {
                // Keep the session open and the mode armed: the user can read the error and
                // either fix the Markdown or disarm the badge and save plain text instead.
                errorMessage = "Couldn't render Markdown: \(error.localizedDescription)"
                return
            }
        } else {
            // Text and image, exactly as `SavePayload` decided them: a mixed session whose text was
            // edited writes the edited text *and* the original image, and an image session writes
            // the image back unchanged, which is the whole point of being able to open one.
            //
            // `richRTFD` is nil, and that is a policy rather than an oversight: putting *plain*
            // text back is what this app is for, and no non-Markdown save has ever written the
            // origin's rich content back (`writePlain` did the same before image sessions existed).
            // So "Save writes everything the session holds" means the text as edited and the image
            // unchanged — not every representation the clipboard arrived with. Arming
            // Markdown → Rich Text is how a user asks for formatted output.
            ClipboardBridge.write(text: payload.text, richRTFD: payload.richRTFD,
                                  imagePNG: payload.imagePNG, to: pasteboard)
        }
        endSession()
    }

    /// True while Save would write HTML + RTF; drives the action-bar badge and the Save tooltip.
    var isRichOutputArmed: Bool { document?.effectiveOutputMode == .renderedMarkdown }

    /// Back to a plain-text Save. `document` is `private(set)`, so mutate a copy and reassign
    /// to publish the change.
    func disarmRichOutput() {
        guard var doc = document else { return }
        doc.outputMode = .plain
        document = doc
    }

    func cancel() { endSession() }

    /// Starts a new session from a history item (rich data and image attached when present).
    ///
    /// Every item opens into a session now, image-only ones included: the snapshot carries the
    /// image, `PasteDocument.displaysAsImage` makes the panel show it, and Save writes it back —
    /// so an image-only item is an image session rather than something a session would discard.
    /// An item with both text and an image opens as a text session that still carries the image
    /// through to Save.
    func load(_ item: HistoryItem) {
        endComposition()
        errorMessage = nil
        noticeMessage = nil
        transformNote = nil
        resetSecretSelection()
        abandonInFlightWork()
        sessionGeneration &+= 1
        let origin = historyOrigin(for: item)
        document = PasteDocument(origin: origin)
        resetUndo()
        // After the clears, for the same reason `refresh` notes its refusal afterwards: this is
        // news about the buffer that was just installed.
        noteUnopenableImage(in: item, origin)
        requestDetection()
    }

    /// The snapshot a history item opens into, with its stored image put through the *same*
    /// validation the pasteboard paths use.
    ///
    /// This is the second entry point into an image session, and the rule it has to keep is the
    /// increment's central one: `ClipboardSnapshot.imagePNG` is nil or valid bytes, **never**
    /// `Data()` and never bytes nothing has looked at, because `save()` hands it straight to
    /// `NSPasteboard`. `HistoryStore.imagePNG` is `try? Data(contentsOf:)` and validates nothing,
    /// so without this a zero-byte or corrupt blob became a zero-byte or corrupt `public.png`
    /// written over the user's clipboard — and `HistoryStore.repair` checks that a blob file
    /// *exists*, not that it holds an image, so such a blob survives a restart with its index
    /// entry intact.
    ///
    /// `ImageBytes.normalise` is the one conversion and the one ceiling, shared with
    /// `ClipboardBridge.snapshot` and the capture path, so a blob that is really a TIFF is
    /// converted here rather than republished under a PNG's name, and one over the ceiling is
    /// *refused out loud* through the same `refusedImagePixels` channel a summon uses. A missing or
    /// unreadable file is simply no image. `changeCount` stays nil: a history item was never the
    /// clipboard, and `PasteDocument.isStale` depends on that distinction.
    private func historyOrigin(for item: HistoryItem) -> ClipboardSnapshot {
        var image: Data?
        var refusedPixels: Int?
        if let blob = history.imagePNG(for: item) {
            switch ImageBytes.normalise(blob) {
            case .png(let png): image = png
            case .tooLarge(let pixels): refusedPixels = pixels
            case .unusable: break
            }
        }
        return ClipboardSnapshot(plainText: item.plainText ?? "",
                                 richRTFD: history.richRTFD(for: item),
                                 imagePNG: image,
                                 refusedImagePixels: refusedPixels)
    }

    /// Says so when an item that has a picture opened without one.
    ///
    /// The silence this replaces was the bad part: an image-only row whose blob had gone missing
    /// opened a blank editor with no explanation, which reads as a broken app — and the same
    /// anti-pattern `noteRefusedImage` exists to prevent on the summon path. Same channel, two
    /// messages, because the two causes call for different things from the user: a picture too
    /// large to *open* is still intact in history, and one whose file is gone is not.
    private func noteUnopenableImage(in item: HistoryItem, _ origin: ClipboardSnapshot) {
        guard item.imageFile != nil, origin.imagePNG == nil else { return }
        if let pixels = origin.refusedImagePixels {
            noticeMessage = "That image is too large to open — it's still in your history. (\(ImageBytes.megapixelLabel(pixels)); limit \(ImageBytes.megapixelLabel(ImageBytes.maxConvertiblePixels)))"
        } else {
            noticeMessage = "That image couldn't be opened — its saved file is missing or unreadable."
        }
    }

    /// Puts the whole item back on the clipboard and ends the session.
    func copyBack(_ item: HistoryItem) {
        ClipboardBridge.write(text: item.plainText, richRTFD: history.richRTFD(for: item), imagePNG: history.imagePNG(for: item), to: pasteboard)
        endSession()
    }

    // MARK: Pinned snippets

    /// Pin or unpin from a browse surface (the history overlay). The store publishes the
    /// change, so the overlay's items observer re-ranks and the row re-renders.
    func togglePin(_ item: HistoryItem) {
        item.pinned ? history.unpin(item.id) : history.pin(item.id)
    }

    /// Why a pin didn't happen. The store returns one nil for two very different refusals, and
    /// the popover has to tell the user which: "Nothing to pin" is a state they can see, "Too
    /// large" is one they can't.
    enum PinOutcome: Equatable { case pinned, nothingToPin, tooLarge }

    /// Pins the editor buffer, carrying the origin's rich data so a pinned snippet pastes back
    /// with its formatting.
    @discardableResult
    func pinCurrentBuffer(title: String?) -> PinOutcome {
        // No session at all, or a buffer that is empty or all whitespace: `HistoryStore.record`
        // refuses both, so rule them out here rather than reporting them as a size problem.
        guard let doc = document,
              !doc.working.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingToPin }
        return history.pinText(doc.working, richRTFD: doc.origin.richRTFD, title: title) != nil
            ? .pinned : .tooLarge
    }

    /// Copies the item, pastes it into the app the user came from, and hides the panel.
    ///
    /// Both the target read and the paste happen *before* `endSession()`, and the order is
    /// load-bearing rather than tidy. `endSession()` hides the panel synchronously, so afterwards
    /// the provider would report whatever the window server promoted in our place, and — the part
    /// that actually breaks — `SnippetPaster` would be asking for cooperative activation as a
    /// background agent that no longer owns it, which macOS 14+ is entitled to refuse. Hiding
    /// after is safe: `paste` only requests activation and schedules the ⌘V, which re-checks the
    /// frontmost app before it fires.
    ///
    /// The `.copiedOnly` outcome is deliberately ignored — without Accessibility the snippet is
    /// still on the clipboard, which is a silent fallback by design; Settings shows the permission
    /// state rather than interrupting the paste. `onGaveUp` is different, and gets the same beep
    /// `SnippetHotkeys.fire` uses: a chain that expires after `paste` already predicted `.pasted`
    /// has closed the panel and pasted nothing, with nothing left on screen to say so. ⇧↵ is in
    /// fact the likelier of the two paths to expire — shift is itself a blocking modifier, so the
    /// chain cannot post until the user lets go of the very key they pressed.
    func pasteIntoPreviousApp(_ item: HistoryItem) {
        // Nothing to paste as text (an image-only row): behave exactly like ⌘↵. Writing an empty
        // pasteboard would destroy whatever the user had copied, and the ⌘V that followed would
        // replace the target's selection with nothing — a silent delete they never asked for.
        // `copyBack` writes the image and ends the session.
        guard item.hasText, let text = item.plainText else { copyBack(item); return }
        let rich = history.richRTFD(for: item)
        _ = SnippetPaster.paste(text: text, richRTFD: rich, into: previousAppProvider(),
                                onGaveUp: { NSSound.beep() })
        endSession()
    }

    // MARK: - One undo stack (#103)

    /// One transform on the window's undo stack. Carries its session so a handler that outlived it
    /// does nothing: the manager outlives sessions (measured), and every boundary empties it, so
    /// this is insurance for a boundary that someday forgets to.
    private struct TransformStep {
        let name: String
        let generation: Int
        /// The scoped span before and after (#25), for re-selection on ⌘Z and ⌘⇧Z. Nil when unscoped.
        var before: NSRange? = nil
        var after: NSRange? = nil
        /// The image region that was up when it was applied (crop spec), whatever the transform:
        /// ⌘Z restores it. ⌘⇧Z doesn't — after a crop the selection is clear.
        var regionBefore: ImageRegion? = nil
    }

    private func registerUndo(_ step: TransformStep) {
        guard let um = undoManager else { return }
        // A transform lands from a task, not an event, and `groupsByEvent` only groups events: at
        // grouping level 0 the registration throws ("must begin a group before registering undo",
        // measured), and inside a group some event left open the user's next keystroke would join
        // the transform and one ⌘Z would undo both. An explicit group of its own, closed now. Not
        // while undoing or redoing: the manager groups those itself.
        let closesOwnGroup = um.groupingLevel == 0 && !um.isUndoing && !um.isRedoing
        // Diagnostics for the GUI pass: a registration inside someone else's open group is how
        // typing could end up undone together with a transform.
        undoLog.debug("register \(step.name, privacy: .public): level \(um.groupingLevel) undoing \(um.isUndoing) redoing \(um.isRedoing)")
        // …and with `groupsByEvent` off while it is open: with it on, `beginUndoGrouping` at level
        // 0 first opens an automatic OUTER group that the matching end doesn't close, and that
        // outer group stayed open until the next event ended — the user's next keystroke, which
        // joined the transform's step (GUI pass 5: 4/4; measured in-process: level 1 left open).
        let byEvent = um.groupsByEvent
        if closesOwnGroup { um.groupsByEvent = false; um.beginUndoGrouping() }
        defer { if closesOwnGroup { um.endUndoGrouping(); um.groupsByEvent = byEvent } }
        // The target is the model, not the step: the manager does not retain its targets, and a
        // step object held only by the stack was freed under it (measured: a crash in popAndInvoke).
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.stepBack(step) }
        }
        um.setActionName(step.name)
        refreshUndoState()
    }

    private func registerRedo(_ step: TransformStep) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.stepForward(step) }
        }
        um.setActionName(step.name)
        refreshUndoState()
    }

    /// Undoes `step`. Registering the inverse while the manager is undoing puts it on the redo stack.
    private func stepBack(_ step: TransformStep) {
        guard step.generation == sessionGeneration else { return }
        undo()
        if let before = step.before, let doc = document {
            pendingSelection = PendingSelection(range: before, revision: doc.detectionRevision)
        }
        if let region = step.regionBefore, let doc = document {
            pendingImageRegion = PendingImageRegion(region: region, revision: doc.detectionRevision)
        }
        breakTypingCoalescing()
        registerRedo(step)
    }

    private func stepForward(_ step: TransformStep) {
        guard step.generation == sessionGeneration else { return }
        redo()
        if let after = step.after, let doc = document {
            pendingSelection = PendingSelection(range: after, revision: doc.detectionRevision)
        }
        breakTypingCoalescing()
        registerUndo(step)
    }

    private func cancelApply() {
        applyTask?.cancel()
        applyTask = nil
        applyID &+= 1
        // A cancelled mark stays at the queue's head, not landed and not dropped; the queue resumes
        // once the undo or redo that cancelled it has moved the document (`observeUndoManager`).
        markInFlight = false
        isApplying = false
    }

    /// Empties the stack at a session boundary. The typing and transforms on it describe a buffer
    /// that is gone; left there, ⌘Z would replay them against the new one.
    private func resetUndo() {
        pendingSelection = nil
        pendingImageRegion = nil
        pendingMarks = []
        markInFlight = false
        undoManager?.removeAllActions()
        breakTypingCoalescing()
        refreshUndoState()
    }

    /// Ends any IME composition (a dead key's "´", an unfinished CJK word) before something reads
    /// the buffer — a transform, Save, the upload snapshot — and writes what the editor then holds
    /// to the model.
    ///
    /// Marked text is in the editor and on the undo stack but never in the TextEditor's binding, so
    /// a transform over a live composition worked on text without it, and the marked insert's undo,
    /// recorded against text the model never had, later replayed at a stale range (GUI pass: it
    /// deleted a newline).
    ///
    /// **And empties the undo stack when it ends one.** Four GUI passes tried to have AppKit settle
    /// the marked insert's own undo record (unmark, the input context's discard, a focus change);
    /// from inside the apply path it survived each time, and after the transform was undone it
    /// replayed at a stale offset and deleted a newline. Emptying the stack is deterministic, and
    /// costs undo history in a rare case — an accent half-typed when a transform is chosen — never
    /// text. A landed apply gives the editor its focus back.
    func settleComposition() {
        var ended = false
        for text in editors() where text.hasMarkedText() {
            endComposition(in: text)
            setWorking(text.string)
            ended = true
        }
        guard ended else { return }
        undoLog.debug("settled a composition: emptying the stack (level \(self.undoManager?.groupingLevel ?? -1))")
        undoManager?.removeAllActions()
        refreshUndoState()
    }

    /// Ends a composition the way a focus change does: through the input context, which tells the
    /// input method and settles the undo stack. `unmarkText()` alone does neither — measured with a
    /// real dead key: the "´" was dropped, the method kept composing (the next key extended it), and
    /// the marked insert's undo stayed on the stack, later deleting a newline. For a dead key the
    /// accent is discarded, as it is when you click elsewhere; an input method may commit instead.
    ///
    /// By taking first responder away — the one path GUI-measured clean. Calling
    /// `inputContext.discardMarkedText()` from here dropped the accent but left the marked insert's
    /// undo on the stack (it still deleted a newline); a real focus change (the ⌘K field taking it)
    /// settled both. Whoever needs the editor afterwards gives it focus back, as a landed apply does.
    private func endComposition(in text: NSTextView) {
        if text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        if text.hasMarkedText() {                           // no input method (a test host)
            text.inputContext?.discardMarkedText()
            if text.hasMarkedText() { text.unmarkText() }
        }
    }

    /// The editor's whole text while it holds marked text, else nil. `PanelView`'s binding reads
    /// this first: SwiftUI's TextEditor re-sets its text from the binding on every re-render of
    /// the panel (⌘K opening, a sidebar click), and the binding never holds marked text, so each
    /// re-render discarded the composition — with no undo record, leaving the marked insert's undo
    /// to delete whatever later sat at its offset (GUI pass 2: a newline; measured in-process).
    func composingEditorText() -> String? {
        editors().first { $0.hasMarkedText() }?.string
    }

    /// The editor's own selection while it holds marked text, else nil. `PanelView`'s selection
    /// binding reads this first, for the same reason as `composingEditorText`: on a re-render
    /// SwiftUI re-applies the selection binding (`setSelectedRanges` → `_NSClearMarkedRange`), and a
    /// selection the binding hadn't caught up with ended the composition — the "´" was dropped
    /// (a 1-in-10 flake of `compositionSurvivesARerender`, caught with a stack of the edit).
    func composingEditorSelection() -> TextSelection? {
        guard let text = editors().first(where: { $0.hasMarkedText() }),
              let range = Range(text.selectedRange(), in: text.string) else { return nil }
        return TextSelection(range: range)
    }

    /// Ends any composition at a session boundary, BEFORE the document is replaced: unmarking
    /// writes the text through the binding, which must land in the session that is ending, not
    /// the new one (measured: a refresh mid-composition put "cafe´" into the fresh session). It also
    /// has to precede `resetUndo`, because clearing a marked range registers an action of its own.
    private func endComposition() {
        for text in editors() where text.hasMarkedText() {
            let focused = text.window?.firstResponder === text
            endComposition(in: text)
            endedSessionText = text.string
            // Ending it took focus away; the session that follows keeps it (GUI pass 4: a Refresh
            // mid-composition left the editor unfocused and the next keystroke went nowhere). A turn
            // later, once the new text is in; skipped if the editor has gone (an image session).
            if focused {
                Task { @MainActor [weak self, weak text] in
                    guard let text, let window = text.window, window.firstResponder !== text else { return }
                    window.makeFirstResponder(text)
                    // Becoming first responder again restores the selection it resigned with — an
                    // offset into the old session's text (GUI pass 5: "fresqh clip"). Where a Refresh
                    // without a composition leaves it: at the end of the new text.
                    if text.string == self?.document?.working {
                        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
                    }
                }
            }
        }
    }

    /// The editor's text when a composition was ended at a session boundary. Ending it makes the
    /// editor write that text through the binding — sometimes only after the new document is
    /// installed (GUI pass 3: a refreshed session showed and saved the old buffer). The first write
    /// equal to it is that late echo and is dropped; any other write retires it.
    private var endedSessionText: String?

    /// The panel's editable text views: the TextEditor's, never a field editor.
    private func editors() -> [NSTextView] {
        guard let root = panelWindow?.contentView else { return [] }
        var found: [NSTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { found.append(text) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Closes the editor's open typing group whenever the buffer is replaced programmatically, so
    /// the next keystroke registers a new action rather than extending one recorded against the
    /// text that just left — which would put typing ranges for one buffer on top of, or under, a
    /// transform's step to another.
    private func breakTypingCoalescing() {
        editors().forEach { $0.breakUndoCoalescing() }
    }

    /// Re-reads the manager into `undoState`.
    func refreshUndoState() {
        let undo = undoManager?.canUndo ?? false, redo = undoManager?.canRedo ?? false
        undoState.update(canUndo: undo, canRedo: redo)
    }

    /// Mirrors the manager into `canUndo`/`canRedo`. `removeAllActions` posts nothing, so its
    /// callers refresh by hand; so does the editor's teardown (`PanelView`), which removes the
    /// editor's typing actions.
    ///
    /// And ⌘Z or ⌘⇧Z while a transform is running cancels it, before the undo runs, so its result
    /// can't land on top of whatever the undo restores. The undo itself then goes ahead on the
    /// previous step (⌘⇧Z brings that back). Cancelling rather than refusing: a typing action on top
    /// of the stack runs whatever the first responder is, so refusing can't be made to hold.
    private func observeUndoManager() {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
        refreshUndoState()
        guard let um = undoManager else { return }
        let names: [Notification.Name] = [.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup]
        undoObservers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: um, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndoState() }
            }
        }
        // Marks queued when an undo or redo cancelled one resume on the document it produced.
        undoObservers += [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: um, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.drainMarks() }
            }
        }
        undoObservers += [Notification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: um, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isApplying else { return }
                    self.cancelApply()
                }
            }
        }
    }

    private func endSession() {
        endComposition()
        abandonInFlightWork()
        document = nil
        resetUndo()
        errorMessage = nil
        noticeMessage = nil
        transformNote = nil
        resetSecretSelection()
        sessionGeneration &+= 1
        onEndSession?()
    }
}
