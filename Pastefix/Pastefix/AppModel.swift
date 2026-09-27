import Foundation
import AppKit
import Combine
import SwiftUI
import PastefixCore
import PastefixAppCore

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
    @Published private(set) var isApplying = false
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

    init(settings: SettingsStore, history: HistoryStore, pasteboard: NSPasteboard = .general) {
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
        detection.cancelAll()
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

    func summon() {
        errorMessage = nil
        noticeMessage = nil
        resetSecretSelection()
        abandonInFlightWork()
        sessionGeneration &+= 1
        let origin = ClipboardBridge.snapshot(from: pasteboard)
        document = PasteDocument(origin: origin)
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

    func apply(_ transformer: any Transformer) {
        guard let current = document, !isApplying else { return }
        isApplying = true
        let generation = sessionGeneration
        applyTask = Task {
            let (updated, outcome) = await TransformCoordinator.apply(transformer, to: current)
            // The session can end (Save/Cancel/auto-hide) while a slow transform is in
            // flight, and the user can summon a fresh one before it finishes. Drop the
            // result unless we are still in the session that asked for it.
            // `abandonInFlightWork()`/`endSession()` own `isApplying` for that path.
            guard self.document != nil, self.sessionGeneration == generation else {
                return
            }
            self.document = updated
            // The failure path returns `current` unchanged (same revision), so only request a
            // scan when the buffer actually moved — re-requesting on every refused click would
            // cancel and restart an in-flight summon scan for no reason.
            if updated.detectionRevision != current.detectionRevision { self.requestDetection() }
            // The caret is `PanelView`'s to carry across the new buffer; the badge's cycle
            // restarts here because the match list belongs to the buffer that just went away.
            self.resetSecretSelection()
            switch outcome {
            case .applied, .unchanged: self.errorMessage = nil
            case .failed(let message): self.errorMessage = message
            }
            self.isApplying = false
            self.applyTask = nil
        }
    }

    func setWorking(_ text: String) {
        guard var doc = document else { return }
        doc.setWorking(text)
        document = doc
    }

    func undo() {
        guard var doc = document else { return }
        let before = doc.detectionRevision
        doc.undo()
        document = doc
        if doc.detectionRevision != before { requestDetection() }
        resetSecretSelection()
    }

    func redo() {
        guard var doc = document else { return }
        let before = doc.detectionRevision
        doc.redo()
        document = doc
        if doc.detectionRevision != before { requestDetection() }
        resetSecretSelection()
    }

    func refresh() {
        guard var doc = document else { return }
        let origin = ClipboardBridge.snapshot(from: pasteboard)
        doc.refresh(origin: origin)
        document = doc
        // A refresh can replace the image without a new session generation. The cache key
        // includes the bytes, so a stale preparation is never *served* — but it would still be
        // *held* (up to 16 MB) until the next request, so it is dropped here.
        imagePreparations.clear()
        requestDetection()
        errorMessage = nil
        noticeMessage = nil
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
        if doc.outputMode == .renderedMarkdown {
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
    var isRichOutputArmed: Bool { document?.outputMode == .renderedMarkdown }

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
        errorMessage = nil
        noticeMessage = nil
        resetSecretSelection()
        abandonInFlightWork()
        sessionGeneration &+= 1
        let origin = historyOrigin(for: item)
        document = PasteDocument(origin: origin)
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

    private func endSession() {
        abandonInFlightWork()
        document = nil
        errorMessage = nil
        noticeMessage = nil
        resetSecretSelection()
        sessionGeneration &+= 1
        onEndSession?()
    }
}
