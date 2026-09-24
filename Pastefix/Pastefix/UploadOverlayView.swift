import SwiftUI
import AppKit
import PastefixCore
import PastefixAppCore

/// ⌘⇧U overlay: upload the working buffer to Zipline and put the short URL on the clipboard.
///
/// Deliberately shaped like `CommandPaletteView` and `HistoryOverlayView` — same backdrop, card,
/// metrics and footer — so the three overlays read as one surface. Its key-handling rule is
/// theirs too: every handler reads `@State` at call time, never a value captured while `body`
/// ran (the ⌘K Return bug, `7f67d41`).
///
/// The one thing this overlay owns that the other two do not is a decision about bytes leaving
/// the machine, which is why the order of its states matters: *configured?* is answered before
/// anything else is drawn, and *what is in the text?* is answered before Upload is enabled.
struct UploadOverlayView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    /// Injected rather than constructed inline so this view has no hard dependency on URLSession
    /// or the real login keychain — the same shape `URLSessionTitleFetcher` is used with.
    let uploader: any ZiplineUploading
    let tokenStore: any ZiplineTokenStore

    /// The buffer as it was when the overlay opened, snapshotted once and never re-read.
    ///
    /// Not an optimisation. `SecretMatch.range` is a `Range<String.Index>` into the exact string
    /// it was scanned against, and handing those indices to `SecretRedactor.redact` together with
    /// any other string is undefined — so the scan and the upload have to be looking at the same
    /// bytes. It is also the honest contract to offer: what was scanned is what gets sent.
    @State private var source: String
    /// Whether `source` is the clipboard as it stands right now, or the panel's own buffer
    /// (edited here, or loaded from history). Decided once in `init` for the same reason `source`
    /// is snapshotted once: a label that re-derived itself later would start describing a
    /// clipboard the bytes below it no longer came from. It is the header's claim about what is
    /// about to be scanned and sent, so it has to be pinned to the same instant as the bytes.
    @State private var sourceIsClipboard: Bool
    /// Whether `source` is empty **because** the clipboard holds only an image — `.tiff` or
    /// `.png`, the two types `PasteboardMonitor` and `HistoryStore` already treat as one. Decided
    /// once in `init`, from the same snapshot instant as `source` and `sourceIsClipboard`: only
    /// `NSPasteboard.general.types` is read, never image bytes, matching `ClipboardBridge.snapshot()`
    /// itself never reading them (image upload is #48, out of scope here).
    ///
    /// Gated on `sourceIsClipboard` so an edited panel buffer that happens to be empty — the
    /// user's own choice, nothing to do with whatever the clipboard currently holds — never
    /// borrows this explanation. See `ZiplinePasteboardImage`.
    @State private var clipboardHasUnsupportedImage: Bool
    @State private var phase: Phase
    @State private var scanState: ScanState = .scanning
    /// `source` with its findings redacted, measured in bytes — nil until the scan lands, and nil
    /// for ever when it found nothing. Measured in the scan's own detached task because that is
    /// where the matches and the string are already in hand and no main-actor work is being held
    /// up; see `payloadByteCount` for why the header needs it.
    @State private var redactedByteCount: Int?
    /// Only true once the scan has been running long enough to be worth mentioning; see
    /// `startScan`.
    @State private var showScanProgress = false
    @State private var disposition: SecretDisposition = .redact
    /// "never", "1h", "1d", "7d" — the raw setting spelling, so `SettingsStore.expiry(fromRaw:)`
    /// stays the single place that maps a string to a `ZiplineExpiry`.
    @State private var expiryTag: String
    @State private var burnOnRead: Bool
    @State private var fileExtension: String
    /// Whether the user has typed in the "File type" field by hand.
    ///
    /// The one thing a late detection result must not do is overwrite a choice someone made, so
    /// this is the flag that stops it. It is written *only* by `extensionField`'s setter, which is
    /// the only path a keystroke can reach `fileExtension` by — the seed assigns the `@State`
    /// directly and deliberately leaves this alone. Anything that watched
    /// `onChange(of: fileExtension)` instead could not tell the two apart and would latch on the
    /// seed's own write.
    @State private var extensionEdited = false
    /// `onAppear` can fire more than once for one view instance, and a second `startScan` would
    /// orphan the first task — which then lands its own result on top of the newer one.
    @State private var scanStarted = false
    /// Which part of the overlay holds first responder. It has to hold it *somewhere*: this
    /// overlay uploads a snapshot taken when it opened, so a keystroke that reached the buffer
    /// behind the backdrop would make the uploaded text differ from the text on screen, and one
    /// that reached the extension field would silently rewrite the filename.
    ///
    /// The card takes it, and does hold it: an Accessibility-automation pass at the panel's
    /// minimum height typed into both the ready and the failed phase and found the buffer still
    /// exactly 307 characters, the extension field still "txt", and AX reporting focus on the
    /// hosting view rather than the text area. (`PanelView` also disables the editor under this
    /// overlay — belt and braces on a path that sends data off the machine, kept deliberately.)
    /// The siblings take focus into their search field (`CommandPaletteView:36`,
    /// `HistoryOverlayView:94`); this one has no search field, so the card itself is the target.
    @FocusState private var focus: Field?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanProgressTask: Task<Void, Never>?
    @State private var uploadTask: Task<Void, Never>?

    /// Focus targets. The card is focused on appear in every phase; the extension field takes
    /// over when the user clicks or tabs into it.
    private enum Field: Hashable {
        case card
        case fileExtension
    }

    /// Whitespace above the card, and the **first thing given up under height pressure**: it is
    /// the only term in the whole budget with nothing inside it. See
    /// `cardTopPadding(forPanelHeight:)`, which walks it down to `minCardTopPadding` before
    /// anything with content in it is squeezed.
    private static let cardTopPadding: CGFloat = 40
    /// How close to the panel's top edge the card is allowed to get. Not zero: a card flush
    /// against the edge reads as a sheet that failed to lay out rather than a floating card.
    private static let minCardTopPadding: CGFloat = 12
    /// Kept clear below the card so it never sits flush against the panel's bottom edge — and,
    /// more to the point, so the height budget below stops short of it. Given up second, after
    /// the top padding: also whitespace, but whitespace at the edge the buttons are nearest.
    private static let cardBottomMargin: CGFloat = 24
    /// Header block (46 for the title row, plus 18 for the source line under it — a `.caption` is
    /// 10pt on macOS, so ~13pt of line box plus the 2pt `VStack` spacing, reserved at 18 so this
    /// errs towards over-reserving like every other term here), three dividers (3), footer (30).
    private static let cardChromeHeight: CGFloat = 97
    /// The action row and its padding (12 above, 12 below, a ~22pt button between: ~46pt
    /// measured, budgeted at 60). Pinned below the scroll region, never inside it: an Upload or
    /// Cancel button that can be scrolled out of reach is the one thing a height budget must not
    /// produce. The failure banner shares this block and is budgeted separately below — it used
    /// to be exempt from the budget entirely, which was a bug; see `scrollHeight(forPanelHeight:)`.
    private static let actionBlockHeight: CGFloat = 60
    /// What the failure banner adds to the action block when there is one. `errorBanner` is
    /// `.callout` at `lineLimit(3)` — ~16pt a line, so 48 at worst — plus the 8pt `VStack`
    /// spacing between it and the action row.
    ///
    /// Budgeted at the worst case rather than measured per message, so the estimate can only
    /// over-reserve. Over-reserving on a one-line banner leaves ~32pt of panel unused below the
    /// card, which nobody can see; under-reserving pushes Retry and Cancel past the window's
    /// bottom edge, which is exactly what this constant exists to stop.
    private static let bannerBlockHeight: CGFloat = 56
    /// The three option rows, their spacings, and the scroll region's own 12pt padding top and
    /// bottom. No divider term any more: the one that used to sit between the options and the
    /// secret block moved above the per-kind lines, and is only present when there are any
    /// (`findingKindsGap`). These rows are what the region gives up first, because they are the
    /// only thing in the card that can be changed again at any time.
    private static let optionsHeight: CGFloat = 122
    /// One "Checking for secrets…" / "No secrets found" line, plus the 8pt spacing below it — the
    /// pinned verdict's whole height in those two states.
    private static let scanRowHeight: CGFloat = 28
    /// The pinned verdict when findings exist: the "N possible secrets" label, the disposition
    /// radio group, its caption, their spacings, and the 8pt gap to the banner/action row below.
    /// Independent of how many kinds were found — that part lives in the scroll region — which is
    /// the property that makes this safe to pin at all.
    private static let findingsChromeHeight: CGFloat = 112
    /// The over-cap refusal: a two-line `.callout` label (~16pt a line) over a two-line
    /// `.caption` (~13pt), plus the 4pt spacing between them and the 8pt gap to the action row
    /// below. Budgeted at both lines of each, like `bannerBlockHeight`, so the estimate can only
    /// over-reserve — this row is pinned, and the one thing it must never do is push the action
    /// row off a short panel.
    private static let refusalRowHeight: CGFloat = 70
    /// One per-kind line in the scroll region, and the "Found:" caption above them.
    private static let findingLineHeight: CGFloat = 16
    /// The divider and spacings between the per-kind lines and the option rows under them.
    private static let findingKindsGap: CGFloat = 11
    /// The floor on the scroll region: about one option row plus enough height to be scrollable.
    ///
    /// Reaching it means the card is taller than the budget wanted, and at the panel's 380pt
    /// minimum with findings *and* a failure banner it is reached (19pt available against this 44).
    /// That is the deliberate outcome: the option rows become something to scroll to rather than
    /// something to read at a glance, and the verdict, the choice and the buttons are untouched.
    /// It must stay big enough to scroll — a region of zero height cannot be scrolled, and the
    /// expiry control is precisely what a `1001 bad options[deletes-at]` failure needs the user to
    /// reach. It exists at all so the arithmetic cannot produce a negative height.
    private static let minScrollHeight: CGFloat = 44

    /// The overlay's whole state, in the order it can be entered.
    ///
    /// `configure` is first for a reason: asking someone to pick an expiry and a filename and
    /// *then* telling them there is no server to send it to is the failure mode this ordering
    /// exists to prevent.
    private enum Phase: Equatable {
        /// Carries the sentence to show; the two ways to be unconfigured need different words.
        case configure(String)
        case composing
        case uploading
        case done(URL)
        /// The controls stay live underneath this, so a refused option can be changed and retried
        /// without closing and re-scanning.
        case failed(ZiplineUploadError)
    }

    private enum ScanState: Equatable {
        case scanning
        case clean
        case found([SecretMatch])
        /// Over `UploadLimits.maxPayloadBytes`: nothing was scanned and nothing can be sent.
        /// Carries the actual size so the verdict can name it against the limit.
        ///
        /// A distinct state, emphatically not `.clean`: a cap on a safety feature that produced a
        /// clean verdict on bytes nobody looked at is the exact false all-clear this whole feature
        /// exists to prevent (PR #42, and Critical Invariant 13).
        case refusedTooLarge(bytes: Int)
    }

    init(model: AppModel,
         onClose: @escaping () -> Void,
         uploader: any ZiplineUploading = URLSessionZiplineClient(),
         tokenStore: any ZiplineTokenStore = KeychainTokenStore()) {
        _model = ObservedObject(wrappedValue: model)
        self.onClose = onClose
        self.uploader = uploader
        self.tokenStore = tokenStore

        let text = model.document?.working ?? ""
        let settings = model.settings
        _source = State(initialValue: text)
        // `changeCount` is a counter, not a read of the pasteboard's contents, so this costs
        // nothing and prompts for nothing. ⌘⇧U has already re-snapshotted a stale, unedited
        // document by the time this runs (`AppDelegate.summonUpload`), so "not the clipboard"
        // here means the buffer really is the panel's own — edited, or loaded from history.
        let sourceIsClipboard = model.document?.matchesPasteboard(changeCount: NSPasteboard.general.changeCount) ?? false
        _sourceIsClipboard = State(initialValue: sourceIsClipboard)
        // Cheap on purpose: `NSPasteboard.general.types` is a type-list read, the same cost
        // `PasteboardMonitor`'s own gate pays before touching content, and nothing here decodes
        // or even fetches the image data the upload path deliberately never reads.
        _clipboardHasUnsupportedImage = State(initialValue:
            text.isEmpty && sourceIsClipboard
                && ZiplinePasteboardImage.typesIndicateImage(NSPasteboard.general.types ?? []))
        // Seeded here rather than in `onAppear` so the very first frame is already the right
        // state — in particular, a user with no server configured never sees a flash of controls
        // they cannot use, which is the whole point of checking "configured?" before anything
        // else. `@State` initial values are only consumed on first construction, so the user's
        // later edits to these controls are never clobbered by a re-render.
        //
        // Be clear about the cost, though: this is an argument expression, so the keychain read
        // *runs* on every `init` and only its result is discarded. `init` runs whenever
        // `PanelView` re-renders, which while this overlay is open means an `AppModel` or
        // `SettingsStore` publish — rare, and a same-process `SecItemCopyMatching` is cheap. If
        // that ever stops being true, the check moves into a `task` that gates the scan.
        _phase = State(initialValue: Self.initialPhase(settings: settings, tokenStore: tokenStore))
        // The user's setting wins whenever they have set one; detection fills in only while the
        // setting is still its "txt" default — i.e. when the user has expressed no preference at
        // all. Letting a guess override an extension someone deliberately typed was the wrong way
        // round. `ZiplineUpload.defaultExtension(for:)` is the only place that maps kinds to an
        // extension; this view used to keep its own copy of that mapping, and the two drifted.
        //
        // The kinds themselves can be stale, and it is worth being exact about how: `PasteDocument`
        // detects on discrete events — init, push, undo, redo, refresh — and `setWorking`
        // deliberately does *not* redetect, so typing into the panel does not update them. Summon
        // plain text, type JSON, press ⌘⇧U and this seeds `txt`, not `json`. Fine here: it is the
        // seed for an editable control, consulted only when the user has no preference.
        // `detectedKinds` is empty here in the common case and that is not a bug to work around
        // here: detection runs off the main actor (`DetectionScheduler`) and ⌘⇧U re-snapshots the
        // clipboard immediately before this view is built, so the scan for these very bytes is
        // still `.pending`. This seeds what is knowable now — the user's setting, or `txt` — and
        // `seedExtensionFromDetection` asks the same question again when the result lands. Before
        // detection moved off the main actor this call alone was enough, and after the move it
        // silently made every JSON upload a `.txt` one.
        _fileExtension = State(initialValue: ZiplineUpload.extensionSeed(
            setting: settings.ziplineDefaultExtension,
            detectedKinds: model.document?.detectedKinds,
            userHasEditedField: false) ?? "txt")
        // Round-tripped through `expiry(fromRaw:)` so a corrupted setting lands on the same
        // fallback the request builder would have used, instead of showing a picker with nothing
        // selected.
        _expiryTag = State(initialValue: Self.tag(for: SettingsStore.expiry(fromRaw: settings.ziplineDefaultExpiry)))
        _burnOnRead = State(initialValue: settings.ziplineDefaultBurnOnRead)
    }

    var body: some View {
        // The panel is resizable and starts at 460pt of content (380 at its minimum), so the
        // option rows and the secret block are budgeted against the height actually available
        // rather than left to grow — three distinct secret kinds are enough to push the footer,
        // and the Upload button with it, off the bottom of the panel (the Plan 6 lesson, again).
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }
                    .accessibilityLabel("Close upload")
                    .accessibilityAddTraits(.isButton)
                card(scrollHeight: scrollHeight(forPanelHeight: geometry.size.height))
                    .frame(maxWidth: PanelMetrics.paletteCardWidth)
                    // maxWidth + horizontal padding rather than a fixed width: on a panel narrower
                    // than the card, the card shrinks instead of overflowing off both edges.
                    .padding(.horizontal, 24)
                    .padding(.top, cardTopPadding(forPanelHeight: geometry.size.height))
            }
        }
        .onAppear {
            // Takes first responder onto the card, off whatever had it when the overlay opened.
            // Measured to work (see `focus`), and it is what makes Return and Esc reach this
            // overlay's own handlers. The card rather than the extension field, so a stray
            // keypress does not silently rewrite the filename.
            focus = .card
            // Nothing is scanned in the configure state: there is nowhere to send the result, and
            // a scan started there would be work done for a question nobody asked.
            guard !scanStarted, phase == .composing else { return }
            scanStarted = true
            startScan()
        }
        // Detection lands asynchronously, usually a moment after this overlay is already on
        // screen, so the extension is seeded here as well as in `init`. `detectedKinds` is `[]`
        // while `PasteDocument.detection` is `.pending` and carries the real answer once it is
        // `.complete`, which makes this the completion signal: the only transition it can report
        // is pending-or-empty → detected. A `.complete` result with no kinds leaves it `[]`, so
        // this never fires for it — correct, because `txt` is already in the field.
        //
        // Deliberately not `model.isDetecting`: that Bool reads `false` both for "the scan landed"
        // and for "there is no document", and the value this needs is the kinds themselves.
        .onChange(of: model.document?.detectedKinds) { _, kinds in
            seedExtensionFromDetection(kinds)
        }
        .onDisappear {
            // Cancelling the wrapper stops the *result* from landing. It does not stop the scan:
            // `SecretDetector` is a straight-line run over its rules with no suspension point, so
            // the detached task runs to completion on its own thread whatever happens here. This
            // is a dropped result, not a bound on the work — the same distinction #46 drew about
            // the uninterruptible image decode, where serialising the decodes bounded how many
            // ran at once and bounded nothing about how long one took.
            scanTask?.cancel()
            scanProgressTask?.cancel()
            // The upload is cancelled, which cancels the URLSession request if it is still in
            // flight — but it recalls nothing the server has already accepted, so a dismissal at
            // exactly the wrong moment can leave a paste on the server whose URL nobody ever saw.
            // Cancelling is still the better of the two: the alternative is a clipboard write
            // landing seconds after the panel is gone, silently replacing whatever the user
            // copied in the meantime.
            uploadTask?.cancel()
        }
    }

    private func card(scrollHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            content(scrollHeight: scrollHeight)
            Divider()
            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        // The card is the focus target, so it has to be able to hold focus; the ring is
        // suppressed because a focus ring around the whole card would read as a control.
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .card)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.doc").foregroundStyle(.secondary)
                Text("Upload to Zipline").font(.title3)
                Spacer(minLength: 8)
                if let host = destinationHost {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // The card's statement of its own input, in the chrome rather than the scroll region
            // so it cannot be scrolled out of sight. A secret verdict is a claim about a specific
            // buffer, and until this line existed the buffer was never named: a stale one scanned
            // clean looked exactly like the text the user had just copied. Source *and* size,
            // because either alone can look right while the other is wrong.
            Text(sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("Uploading \(sourceDescription)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// "the clipboard · 12 KB" / "the panel buffer · 12 KB". The source half reads `source`, which
    /// never changes after `init`; the size half is `payloadByteCount`, which is the redacted
    /// length when redaction is the choice. The line claims to describe what Upload will send, so
    /// the number has to be the number that goes on the wire — a source size shown against a
    /// redacted upload is a small lie in the one place whose entire job is being checkable.
    ///
    /// "the panel buffer" rather than "the editor" because it covers every non-clipboard case:
    /// text typed or transformed here, a history item re-opened, and a buffer deliberately kept
    /// when the clipboard holds something Pastefix itself wrote (the last upload's short URL).
    private var sourceDescription: String {
        let origin = sourceIsClipboard ? "the clipboard" : "the panel buffer"
        guard !source.isEmpty else {
            // "empty" is the wrong word for a clipboard that holds an image — there is something
            // there, just nothing this overlay can send yet. See `clipboardHasUnsupportedImage`.
            return clipboardHasUnsupportedImage ? "\(origin) — image, not supported yet" : "\(origin) — empty"
        }
        return "\(origin) · \(HistoryFormatting.byteLabel(payloadByteCount))"
    }

    /// The size of the bytes `upload()` will actually send.
    ///
    /// Redaction changes the length in either direction ("[REDACTED aws-access-key]" is longer
    /// than some keys and shorter than others), so this is the redacted length whenever redaction
    /// is the live choice. It is never recomputed here: the scan task measured it once, off the
    /// main actor, at the same time and on the same string as the matches — re-redacting per
    /// render would put a 400 KB string rewrite behind every keystroke in the extension field.
    private var payloadByteCount: Int {
        if case .found = scanState, disposition == .redact, let redactedByteCount {
            return redactedByteCount
        }
        return source.utf8.count
    }

    @ViewBuilder private func content(scrollHeight: CGFloat) -> some View {
        switch phase {
        case .configure(let message):
            configureState(message).padding(12)
        case .done(let url):
            doneState(url).padding(12)
        // Composing, uploading and failed are one layout: a failure has to leave the controls
        // where they were, because the fix for the commonest failure (an expiry past the
        // server's `maxExpiration`) is to change one of them and press Upload again.
        case .composing, .uploading, .failed:
            composingState(scrollHeight: scrollHeight)
        }
    }

    // MARK: Configure

    private func configureState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            // `OpenSettingsButton`, not `SettingsLink` (#54): from inside the non-activating
            // panel a plain `SettingsLink` opens Settings without making Pastefix active, so the
            // window appears unfocused and — before `PanelController` learned to yield its level
            // — behind the panel, unraisable. This is the *first-run* path (no server URL or no
            // token) with exactly one button on it, so a Settings window the user cannot reach is
            // the whole feature failing at its first step. The history overlay's
            // "Enable in Settings…" is the same door; keep the two spelled the same way.
            //
            // Closing the overlay on the way out takes the panel's dim off from behind the
            // Settings window. It also sidesteps a staleness problem — the token lives in the
            // keychain, which publishes nothing, so this view cannot observe it becoming set.
            // Re-pressing ⌘⇧U after configuring opens a fresh overlay that reads both values
            // again, which is the only honest refresh available here.
            OpenSettingsButton { Text("Open Settings…") }
                .simultaneousGesture(TapGesture().onEnded { onClose() })
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    // MARK: Composing

    private func composingState(scrollHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // A *definite* height, not a `maxHeight`: a `ScrollView` is greedy in its scroll axis
            // and would otherwise take the whole budget in every phase, ballooning the card
            // around three short rows. `scrollHeight` is the smaller of what this content needs
            // and what the panel has left, so the region scrolls only when it actually has to.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // The per-kind detail goes *first*, so that what scrolls out of the bottom of
                    // a squeezed region is the expiry, the burn toggle and the extension — three
                    // cosmetic defaults, changeable at any time — rather than anything about the
                    // secrets. See `composingState`'s note on what is pinned and why.
                    if case .found(let matches) = scanState {
                        findingKinds(matches)
                        Divider()
                    }
                    expirationRow
                    burnRow
                    extensionRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                // The *option* controls are inert while the request is on the wire: changing the
                // expiry of an upload that has already been sent would only mislead about what
                // was sent. They stay on screen, greyed, rather than being swapped out — seeing
                // what you sent is the point of showing them at all.
                //
                // On the content, not on the `ScrollView`: `.disabled` takes out the scroll
                // *gesture* too, and on a short panel during a long upload that leaves the user
                // unable to scroll back to the findings list to re-read what they just sent.
                // Inert is the goal; unreadable is not.
                //
                // Scoped to the scroll region and not the action row below either: Cancel has to
                // stay pressable for the whole upload, which is bounded by the client's *resource*
                // timeout (`UploadLimits.resourceTimeout`, 600 s) and not by its 60 s idle one —
                // a slow uplink moving bytes steadily never trips the idle bound, so this can be a
                // long time to be stuck.
                .disabled(phase == .uploading)
            }
            .frame(height: scrollHeight)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // **The invariant this block exists to hold: whatever else height pressure takes
                // away, the secret verdict and the redact-or-send choice stay on screen.** They
                // are the reason this overlay exists, and Upload and Cancel below are a decision
                // *about* them — so they get the same guarantee those two already had, by living
                // outside the budgeted scroll region rather than at the end of it.
                //
                // Measured failure this replaces: at the panel's 380pt minimum in a *failed*
                // phase, the error banner shrinks the region enough to push the entire findings
                // list below the fold, leaving Expires, Burn and File type visible. The surface
                // whose whole job is letting someone check what is about to leave their machine
                // hid exactly that, and kept three re-configurable defaults instead.
                //
                // Only the per-kind lines still scroll (they are unbounded — one line per kind —
                // so pinning them could push the buttons off a short panel, which is the thing
                // no budget may ever do).
                verdict
                    // Inert while the bytes are on the wire, for the same reason the option rows
                    // are: changing the disposition of an upload already sent would only mislead
                    // about what was sent. Scoped to this, never to `actionRow` — Cancel has to
                    // stay pressable for however long the transfer runs (see the action row's
                    // note: up to `UploadLimits.resourceTimeout`, not 60 s).
                    .disabled(phase == .uploading)
                if let message = bannerMessage {
                    errorBanner(message)
                }
                actionRow
            }
            .padding(12)
        }
        // A message attached to a control is about the value that control had. The moment it
        // changes, the message describes something that is no longer there — so it is cleared by
        // the same gesture that fixes it, rather than sitting there contradicting the screen.
        // Matched by header, so an unrelated failure (a rejected token, say) survives a toggle.
        .onChange(of: expiryTag) { _, _ in clearInlineFailure(forHeaderContaining: "deletes-at") }
        .onChange(of: burnOnRead) { _, _ in clearInlineFailure(forHeaderContaining: "max-views") }
        .onChange(of: fileExtension) { _, _ in clearInlineFailure(forHeaderContaining: "file-extension") }
    }

    private var expirationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Expires")
                Spacer()
                Picker("Expires", selection: $expiryTag) {
                    Text("Never").tag("never")
                    Text("1 hour").tag("1h")
                    Text("1 day").tag("1d")
                    Text("7 days").tag("7d")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            // A server that refuses the expiry says so about `x-zipline-deletes-at` by name, and
            // the control that fixes it is right here — so the message goes here rather than in
            // the banner, where it would be a paragraph away from the thing to change.
            if let message = inlineMessage(forHeaderContaining: "deletes-at") {
                inlineError(message)
            }
        }
    }

    private var burnRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Separate from the expiry, and not one of its options: burn-on-read is
            // `x-zipline-max-views: 1`, a different header with different semantics. A paste can
            // be both "one view" and "deleted in an hour", and collapsing them into one picker
            // would make those mutually exclusive for no reason but the UI's convenience.
            Toggle("Burn after reading", isOn: $burnOnRead)
                .help("The paste is deleted after it has been viewed once.")
            if let message = inlineMessage(forHeaderContaining: "max-views") {
                inlineError(message)
            }
        }
    }

    private var extensionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("File type")
                Spacer()
                // Zipline v4 picks syntax highlighting from the extension, so this is the
                // "language" control even though it is spelled as a filename suffix.
                TextField("txt", text: extensionField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .focused($focus, equals: .fileExtension)
                    .accessibilityLabel("File extension")
            }
            // Our own refusal first, and it wins the slot: while it is showing, Upload is
            // disabled, so there cannot be a *newer* server refusal to read — and a stale one
            // from a previous attempt must not be what the user sees next to the value that is
            // blocking them now.
            if let message = extensionRejection {
                inlineError(message)
            } else if let message = inlineMessage(forHeaderContaining: "file-extension") {
                inlineError(message)
            }
        }
    }

    /// The pinned verdict: the scan's answer, and the choice that answer demands. Never inside
    /// the scroll region — see `composingState`.
    @ViewBuilder private var verdict: some View {
        switch scanState {
        case .scanning:
            if showScanProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking for secrets…").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            // Under the delay: nothing at all. A row that appears and is replaced within a frame
            // or two is a flicker, and an empty row is not a claim about the text either way.
        case .clean:
            if clipboardHasUnsupportedImage {
                // Correct that there is nothing to send; the generic empty-buffer line below is
                // wrong about *why* here — the clipboard is not empty, it holds an image, and
                // image upload is simply not built yet (#48, out of scope for this feature). See
                // `ZiplinePasteboardImage`.
                Label("The clipboard holds an image. Image upload isn't supported yet — that's #48.",
                      systemImage: "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if source.isEmpty {
                // True but useless: an empty buffer has no secrets in the same way it has nothing
                // else, and a clean bill of health on nothing implies something was examined.
                Label("Nothing to scan — the buffer is empty.", systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("No secrets found", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // The whole buffer was examined, not the first 256 KB of it — see `startScan`.
                    .help("The whole buffer was scanned, whatever its size.")
            }
        case .found(let matches):
            findings(matches)
        case .refusedTooLarge(let bytes):
            // Both numbers, always: "too large" without the actual size and the limit is a
            // refusal the user cannot act on. The second line says what was *not* done, because
            // the absence of a findings list here must not read as an all-clear.
            VStack(alignment: .leading, spacing: 4) {
                Label("Too large to upload — \(HistoryFormatting.byteLabel(bytes)), and the limit is \(ByteLimit.describe(UploadLimits.maxPayloadBytes)).",
                      systemImage: "exclamationmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Text("It was not scanned for secrets and nothing was sent. Upload a smaller selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// The verdict and the choice, and nothing that can grow without bound: one count line, the
    /// radio group, one caption. Height is independent of how many kinds were found, which is what
    /// makes it safe to pin — `findingKinds` carries the part that is not.
    private func findings(_ matches: [SecretMatch]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(matches.count) possible secret\(matches.count == 1 ? "" : "s") in this text",
                  systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.orange)
            // Redact is preselected and Return uploads, so the safe outcome is the one that
            // happens if the user reads none of this. Sending as-is has to be chosen.
            Picker("Before uploading", selection: $disposition) {
                Text("Redact them").tag(SecretDisposition.redact)
                Text("Send as is").tag(SecretDisposition.sendAsIs)
            }
            .pickerStyle(.radioGroup)
            // "The secrets found", not "the secrets above": the per-kind list is in the scroll
            // region now and may be scrolled out of sight, so a caption pointing at it would be
            // pointing at nothing.
            Text(disposition == .redact
                 ? "Only the uploaded copy is changed; the text in the panel is untouched."
                 : "The secrets found will be uploaded exactly as they appear.")
                .font(.caption)
                .foregroundStyle(disposition == .redact ? Color.secondary : Color.orange)
        }
    }

    /// The per-kind breakdown, which lives in the scroll region because it has one line per kind
    /// and so no bounded height. The pinned verdict above gives the total, so this can be scrolled
    /// away without leaving the user unable to see *that* something was found.
    private func findingKinds(_ matches: [SecretMatch]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Found:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: Self.findingLineHeight, alignment: .leading)
            ForEach(Self.summaries(of: matches), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.findingLineHeight, alignment: .leading)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if phase == .uploading {
                ProgressView().controlSize(.small)
                Text("Uploading…").font(.callout).foregroundStyle(.secondary)
            } else if source.isEmpty {
                Text("Nothing to upload.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onClose() }
            // Reads `@State` at call time through `upload()`; nothing about the press is decided
            // while `body` runs (the ⌘K Return lesson, `7f67d41`).
            Button(isRetry ? "Retry" : "Upload", action: upload)
                .keyboardShortcut(.defaultAction)
                .disabled(!isReadyToUpload)
        }
    }

    // MARK: Done

    private func doneState(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Uploaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(url.absoluteString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(burnOnRead
                 ? "Copied to the clipboard. This paste is deleted after one view — opening it here is that view."
                 : "Copied to the clipboard.")
                .font(.caption)
                .foregroundStyle(burnOnRead ? Color.orange : Color.secondary)
            HStack(spacing: 10) {
                Button("Copy Again") { ClipboardBridge.writePlain(url.absoluteString) }
                Button("Open") { NSWorkspace.shared.open(url) }
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Chrome

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.orange)
    }

    private func inlineError(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(keyHint)
                .lineLimit(1)
            Spacer(minLength: 8)
            // The byte count used to live here on its own. It now sits in the header next to the
            // source it describes, because a size with no source named is half an answer — and
            // two copies of the same number in one small card read as two different facts.
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Derived state

    /// What Return does right now. Return is always bound to the default button, but which
    /// button that is changes with the phase, and a footer that kept promising "↵ Upload" on the
    /// done screen would be describing a button that is no longer there.
    private var keyHint: String {
        switch phase {
        case .configure: return "esc Close"
        case .done: return "↵ Done   esc Close"
        case .uploading: return "esc Close"
        case .failed: return "↵ Retry   esc Close"
        case .composing: return "↵ Upload   esc Close"
        }
    }

    private var destinationHost: String? {
        ZiplineServerURL.parse(model.settings.ziplineServerURL)?.host
    }

    private var isRetry: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Upload is disabled until the scan resolves — offering it during the scan would let the
    /// user send a buffer whose findings arrive a moment later, which is the same false all-clear
    /// as not scanning at all, just harder to notice.
    private var isReadyToUpload: Bool {
        // `scanState`, and never `model.document.secretMatches`. They are not the same verdict:
        // the document's scan is `SecretDetector.scan`, which refuses anything over 256 KB and
        // returns `[]`, so on the largest pastes — the ones most likely to be a dumped config or
        // a log — an empty `secretMatches` means "nobody looked", not "nothing there". `scanState`
        // comes from this overlay's own `scanIgnoringSizeCap` run (see `startScan`), which is the
        // whole reason that entry point exists. `AppModel.isDetecting`'s doc comment tells a gate
        // to wait for the document's scan before trusting an empty `secretMatches`; that is
        // correct advice for a gate that reads `secretMatches`, and this one deliberately does
        // not. Swapping it for the document's scan would reintroduce the false all-clear this
        // feature exists to prevent — it would not be a simplification.
        // `.refusedTooLarge` is as final as `.scanning` is provisional: the buffer was never
        // examined, so there is no version of Upload that is safe to offer for it.
        switch scanState {
        case .scanning, .refusedTooLarge: return false
        case .clean, .found: break
        }
        guard !source.isEmpty else { return false }
        // A "File type" this client refuses to frame disables Upload rather than being quietly
        // replaced with `txt` — see `canonicalExtension`.
        guard canonicalExtension != nil else { return false }
        switch phase {
        case .composing, .failed: return true
        case .configure, .uploading, .done: return false
        }
    }

    /// The failure message, unless it is one already shown against a specific control: two copies
    /// of one sentence read as two separate problems.
    private var bannerMessage: String? {
        guard case .failed(let error) = phase else { return nil }
        if case .badOption(let header, _) = error,
           Self.inlineHeaders.contains(where: { header.localizedCaseInsensitiveContains($0) }) {
            return nil
        }
        return Self.message(for: error)
    }

    /// The v4 headers that map onto a control in this overlay. A refusal about one of these is
    /// fixable here; anything else belongs in the banner.
    private static let inlineHeaders = ["deletes-at", "max-views", "file-extension"]

    /// Drops a failure that was attached to one control, leaving any other failure alone.
    private func clearInlineFailure(forHeaderContaining needle: String) {
        guard case .failed(.badOption(let header, _)) = phase,
              header.localizedCaseInsensitiveContains(needle) else { return }
        phase = .composing
    }

    private func inlineMessage(forHeaderContaining needle: String) -> String? {
        guard case .failed(.badOption(let header, let message)) = phase,
              header.localizedCaseInsensitiveContains(needle) else { return nil }
        return message.isEmpty ? "The server refused this value." : message
    }

    /// Kinds with counts, sorted by name so the list is stable between renders. Counts, not one
    /// line per match: three AWS keys is a useful thing to know, three identical lines is not.
    private static func summaries(of matches: [SecretMatch]) -> [String] {
        Dictionary(grouping: matches, by: \.kind)
            .map { kind, group in group.count == 1 ? kind.displayName : "\(kind.displayName) × \(group.count)" }
            .sorted()
    }

    private static func message(for error: ZiplineUploadError) -> String {
        switch error {
        case .invalidFileExtension:
            // Normally unreachable: Upload is disabled and the same sentence is already showing
            // against the field (`extensionRejection`). Worded to point at the control anyway,
            // because the banner is where this would surface if the two ever disagreed.
            return "Can't use that file type. \(ZiplineFileExtension.requirement)"
        case .unauthorized:
            // Named precisely. "Upload failed" would send the user to look at their server, when
            // the thing to change is the token in Settings.
            return "Token rejected. Check the Zipline API token in Settings."
        case .badOption(let header, let message):
            return "The server refused \(header): \(message)"
        case .server(let status, let message):
            return message.map { "Server error \(status): \($0)" } ?? "Server error \(status)."
        case .malformedResponse:
            // Explicit about the clipboard: a 2xx with an unreadable body is the one failure that
            // might plausibly have stored something, and the user needs to know they have no link.
            return "The server replied with something that was not an upload result. Nothing was copied."
        case .oversizedResponse:
            // Named apart from `.malformedResponse` because the cause is specific and the fix is:
            // a reply this long is a web page, which means the server URL is pointing at a file
            // host, a login page or a proxy rather than at Zipline.
            return "The server replied with more than "
                 + "\(UploadLimits.maxResponseBytes / 1024) KB instead of an upload result — "
                 + "check the Zipline server URL in Settings. Nothing was copied."
        case .transport(let detail):
            return "Couldn't reach the server: \(detail)"
        }
    }

    private static func tag(for expiry: ZiplineExpiry) -> String {
        switch expiry {
        case .never: return "never"
        case .relative(let value): return value
        // Unreachable from a setting — `expiry(fromRaw:)` never produces one — and this overlay
        // offers no date picker, so there is no tag to show it under.
        case .absolute: return "1d"
        }
    }

    private static let noServerMessage =
        "Pastefix doesn't know where to upload yet. Set your Zipline server URL in Settings."
    private static let noTokenMessage =
        "No Zipline API token is stored. Add one in Settings to upload."

    private static func initialPhase(settings: SettingsStore, tokenStore: any ZiplineTokenStore) -> Phase {
        guard ZiplineServerURL.parse(settings.ziplineServerURL) != nil else {
            return .configure(noServerMessage)
        }
        // A keychain read can fail for reasons that are not "no token" — a locked keychain, a
        // denied ACL. There is no token to upload with either way and the door out is the same
        // one, so the two collapse into a single message rather than an error state the user
        // could not act on differently. Nothing about the token is logged, here or anywhere.
        guard let token = (try? tokenStore.token()) ?? nil, !token.isEmpty else {
            return .configure(noTokenMessage)
        }
        return .composing
    }

    /// The height the scrolling region gets: the smaller of what its content needs and what the
    /// panel has left after everything that is not the scroll region.
    ///
    /// **Priority, not just arithmetic.** Everything except this region is pinned, and the order
    /// in which the card gives things up is deliberate: top whitespace first
    /// (`cardTopPadding(forPanelHeight:)`), the bottom margin second, then the option rows — which
    /// scroll rather than vanish. The verdict, the redact-or-send choice and the action row are
    /// never squeezed. A banner-shrunken region used to push the whole findings list below the
    /// fold while keeping three cosmetic defaults pinned, which is exactly backwards for a surface
    /// whose job is letting someone check what is about to leave their machine.
    ///
    /// The arithmetic, re-derived from the constants — do not trust a remembered figure over this:
    ///
    ///     card     = cardChromeHeight(97) + scrollHeight + verdictHeight(0|28|70|112)
    ///                  + actionBlockHeight(60) + banner(0|56)
    ///     on panel = topPadding(12…40) + card + cardBottomMargin(24)
    ///     fits when scrollHeight <= panelHeight - 181 - topPadding - verdict - banner
    ///
    /// At `PanelMetrics.minContentHeight` (380), with the top padding walked down where needed:
    ///
    ///     clean, no banner    → padding 40, 131 available, 122 wanted → no scroll
    ///     findings, no banner → padding 40, 47 available, 181 wanted (2 kinds) → options scroll;
    ///                           card bottom at 356, the 24pt margin exactly honoured
    ///     findings + banner   → padding 12, 19 available → floored at `minScrollHeight` (44), so
    ///                           the card ends at 381: 1pt past the budget, having spent the margin
    ///
    /// Only that last case is over budget, and by 1pt — the adaptive top padding is what pays for
    /// it, which is the whole reason it is adaptive.
    ///
    /// **What was measured, and what has not been.** The Accessibility-automation pass this file
    /// used to cite — action row's bottom at 298 of 384 of content, card's lowest text at 332,
    /// i.e. ~40pt more compact than the budget claims — was taken against the *previous* layout,
    /// before `411a4c7` moved the verdict and the radio group out of the scroll region and added
    /// `findingsChromeHeight` (112) to the pinned budget. The pinned height changed in precisely
    /// the case that gets floored (findings + banner at the 380pt minimum), so that case has not
    /// been measured since, and neither has the over-cap refusal row (`refusalRowHeight`, 70)
    /// added after it. Everything above is re-derived arithmetic, not a measurement of what ships.
    ///
    /// The budget stays pessimistic on purpose — it is the number that cannot be optimistic — but
    /// pessimism is not evidence, and the claim that used to stand here ("the measurement is why
    /// the floored case is safe rather than hoped-for") no longer has a measurement behind it. The
    /// AX pass this owes: at `PanelMetrics.minContentHeight` (380), in a `.failed` phase with
    /// findings, and again with `scanState == .refusedTooLarge`, confirm the verdict block and
    /// both action-row buttons are fully on screen. Until that lands, this case is unverified —
    /// do not re-derive the arithmetic and call it measured.
    ///
    /// The `ScrollView` takes a *definite* height from this, so it will not compress to take up
    /// the slack on its own; if this number is too big, the card simply grows past the panel.
    private func scrollHeight(forPanelHeight panelHeight: CGFloat) -> CGFloat {
        let available = max(Self.minScrollHeight,
                            panelHeight - cardTopPadding(forPanelHeight: panelHeight)
                                - Self.cardBottomMargin - Self.cardChromeHeight
                                - verdictHeight - Self.actionBlockHeight - bannerHeight)
        return min(Self.optionsHeight + findingKindsHeight, available)
    }

    /// Whitespace above the card, surrendered before anything with content in it. Full
    /// `cardTopPadding` whenever the pinned blocks plus a floor-height region fit under it,
    /// otherwise as little as `minCardTopPadding`.
    ///
    /// Written as its own function so `body` and `scrollHeight(forPanelHeight:)` cannot disagree
    /// about it: they are the two readers, and a card positioned by one number and measured by
    /// another is how a budget starts lying.
    private func cardTopPadding(forPanelHeight panelHeight: CGFloat) -> CGFloat {
        let pinned = Self.cardChromeHeight + Self.minScrollHeight + verdictHeight
            + Self.actionBlockHeight + bannerHeight + Self.cardBottomMargin
        return min(Self.cardTopPadding, max(Self.minCardTopPadding, panelHeight - pinned))
    }

    /// What the pinned verdict block takes out of the budget: nothing while the scan is still
    /// quiet, one row for a progress or all-clear line, and the bounded findings block when there
    /// is something to decide about. Tracks exactly what `verdict` renders, so the budget and the
    /// screen cannot disagree.
    private var verdictHeight: CGFloat {
        switch scanState {
        // Nothing is drawn under the 150ms delay, so nothing is budgeted for it — the card grows
        // by a row when the progress line appears, which is the same movement the row itself is.
        case .scanning: return showScanProgress ? Self.scanRowHeight : 0
        case .clean: return Self.scanRowHeight
        case .found: return Self.findingsChromeHeight
        case .refusedTooLarge: return Self.refusalRowHeight
        }
    }

    /// The banner is drawn only in a `.failed` phase, and `bannerMessage` is also nil when the
    /// failure is one already shown inline against a control — so this asks the same question the
    /// view does rather than a looser "are we failed?", and the budget matches what is rendered.
    private var bannerHeight: CGFloat {
        bannerMessage == nil ? 0 : Self.bannerBlockHeight
    }

    /// What the per-kind lines add to the scroll region's content. An estimate, and only has to be
    /// roughly right in the safe direction: too large leaves a few points of slack at the bottom of
    /// the region, too small makes it scroll slightly sooner than it needed to. Neither hides
    /// anything, because everything that must not be hidden is pinned outside the region.
    private var findingKindsHeight: CGFloat {
        guard case .found(let matches) = scanState else { return 0 }
        // +1 line for the "Found:" caption above them.
        return CGFloat(Self.summaries(of: matches).count + 1) * Self.findingLineHeight
            + Self.findingKindsGap
    }

    // MARK: Actions (every one reads live state)

    private func startScan() {
        let text = source
        // The ceiling, checked before any of the work rather than inside it. Everything below
        // this line is unbounded in the input's size and uncancellable once started: the scan is
        // a straight-line run on a detached thread, `SecretRedactor` builds a second full copy,
        // and the client builds a third as the multipart body. `UploadLimits` carries the
        // arithmetic; the important part here is that an over-cap buffer is *refused* — not
        // scanned, not sent, and never rendered as "No secrets found".
        let byteCount = text.utf8.count
        guard byteCount <= UploadLimits.maxPayloadBytes else {
            scanState = .refusedTooLarge(bytes: byteCount)
            return
        }
        scanProgressTask = Task { @MainActor in
            // A delay rather than a size threshold: the threshold would have to be guessed, and
            // the thing actually worth reacting to is "this is taking long enough that the user
            // is waiting". A small paste resolves first and never draws the row at all.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            showScanProgress = true
        }
        scanTask = Task { @MainActor in
            // Detached because the scan is synchronous and, on this path, uncapped: 0.854 s for
            // 4 MB in the Task 1 measurement, which is a visible main-actor freeze if run inline.
            // Only a `String` crosses.
            //
            // `scanIgnoringSizeCap`, never `scan`. `scan` refuses anything over 256 KB and
            // returns an empty array; this overlay would draw that as "No secrets found" on a
            // buffer nobody looked at, immediately before sending it off the machine. That false
            // all-clear is the worst outcome this feature has, and the uncapped entry point
            // exists for this one call site.
            //
            // There is no cancellation point inside it, so the indeterminate spinner above is the
            // whole progress story: nothing here can report a fraction or stop early.
            let (matches, redactedBytes) = await Task.detached(priority: .userInitiated) {
                let matches = SecretDetector.scanIgnoringSizeCap(text)
                // Redacted here rather than in the header: the ranges index `text` and nothing
                // else, this thread already holds both, and the result is one `Int` — so the
                // header can state the true upload size without either re-scanning or keeping a
                // second copy of a large buffer alive.
                let redactedBytes = matches.isEmpty
                    ? nil
                    : SecretRedactor.redact(text, matches: matches).utf8.count
                return (matches, redactedBytes)
            }.value
            guard !Task.isCancelled else { return }
            scanProgressTask?.cancel()
            showScanProgress = false
            redactedByteCount = redactedBytes
            scanState = matches.isEmpty ? .clean : .found(matches)
        }
    }

    private func upload() {
        // Return can reach this twice in one turn — the default button owns it, and a focused
        // text field can forward a submit to the default button as well — so the first thing this
        // does is make the second call a no-op. `isReadyToUpload` is false for `.uploading`.
        guard isReadyToUpload else { return }
        // Re-read, rather than trusting what `init` saw: Settings is reachable while the panel is
        // up, and a token cleared in the meantime should return the overlay to the configure
        // state instead of producing a 401 the user has to interpret.
        guard let server = ZiplineServerURL.parse(model.settings.ziplineServerURL) else {
            phase = .configure(Self.noServerMessage)
            return
        }
        guard let token = (try? tokenStore.token()) ?? nil, !token.isEmpty else {
            phase = .configure(Self.noTokenMessage)
            return
        }
        // `.found` is the only state that carries matches; `.clean` uploads the source untouched,
        // and `.scanning` cannot get here at all (`isReadyToUpload`).
        let matches: [SecretMatch]
        if case .found(let found) = scanState { matches = found } else { matches = [] }
        // The single place that decides which bytes leave: it returns a new string and cannot
        // reach the user's document or clipboard.
        let payload = UploadPayload.text(source, matches: matches, disposition: disposition)
        // `canonicalExtension` is what goes in, not the raw field: it is the one place that turns
        // a blank field into `txt`, and `ZiplineUpload.init` deliberately does not (an empty
        // extension is refused there, so that no *other* rejected value can become `paste.txt`
        // by way of a default). `isReadyToUpload` has already checked the same rule, so neither
        // the `guard` nor the `catch` below is reachable from the UI — they are the belt to that
        // braces, so that if the two ever disagree the result is a visible refusal rather than a
        // request built from a value the type was supposed to reject.
        let request: ZiplineUpload
        do {
            guard let ext = canonicalExtension else { throw ZiplineUploadError.invalidFileExtension }
            request = try ZiplineUpload(text: payload,
                                        fileExtension: ext,
                                        expiry: SettingsStore.expiry(fromRaw: expiryTag),
                                        burnOnRead: burnOnRead)
        } catch {
            phase = .failed(.invalidFileExtension)
            return
        }
        phase = .uploading
        uploadTask = Task { @MainActor in
            do {
                let url = try await uploader.upload(request, to: server, token: token)
                guard !Task.isCancelled else { return }
                // The link on the clipboard is the point of the feature; the URL shown below is
                // the confirmation of it, not the only copy.
                ClipboardBridge.writePlain(url.absoluteString)
                phase = .done(url)
            } catch let error as ZiplineUploadError {
                guard !Task.isCancelled else { return }
                phase = .failed(error)
            } catch {
                // `URLSessionZiplineClient` maps everything it can reach into a
                // `ZiplineUploadError`, so anything arriving here is a bug in that mapping rather
                // than a condition worth modelling — reported verbatim instead of swallowed.
                guard !Task.isCancelled else { return }
                phase = .failed(.transport(error.localizedDescription))
            }
        }
    }

    /// The "File type" field's binding, and the only place a *user* edit arrives.
    ///
    /// A plain `$fileExtension` would make a hand-typed value indistinguishable from a seeded one,
    /// which is exactly the distinction `extensionEdited` has to carry. The equality guard is
    /// there because a `TextField` may write its current value back on commit or on a focus change
    /// without the text having changed; a write that changes nothing is not a choice.
    private var extensionField: Binding<String> {
        Binding(get: { fileExtension },
                set: { newValue in
                    guard newValue != fileExtension else { return }
                    fileExtension = newValue
                    extensionEdited = true
                })
    }

    /// Fills the extension in from a detection result that landed after the overlay opened.
    ///
    /// Same rule as `init`, same function, and the precedence is `ZiplineUpload.extensionSeed`'s
    /// to state: a hand-typed value wins over everything, then the user's setting, then this. Only
    /// *when* the detector's answer is available changed when detection moved off the main actor.
    private func seedExtensionFromDetection(_ kinds: Set<ContentKind>?) {
        guard let seed = ZiplineUpload.extensionSeed(setting: model.settings.ziplineDefaultExtension,
                                                     detectedKinds: kinds,
                                                     userHasEditedField: extensionEdited),
              seed != fileExtension else { return }
        fileExtension = seed
    }

    /// The extension as the request will carry it, or nil when the field holds something that
    /// cannot be framed (`ZiplineFileExtension` says which, and why it is refused rather than
    /// sanitised). Upload is disabled while this is nil and `extensionRejection` is shown against
    /// the field, so a bad value is never silently turned into `paste.txt`.
    ///
    /// A *blank* field is not a rejection: it means "no preference", and `txt` is what an
    /// unrecognised buffer would have been given anyway (`paste.` is not a filename the server
    /// can highlight). A field holding only dots is a typed value and is refused — the user gets
    /// told rather than getting a file named after something they did not type.
    private var canonicalExtension: String? {
        let typed = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZiplineFileExtension.canonical(typed.isEmpty ? "txt" : typed)
    }

    /// The inline message for a "File type" value this client will not send, or nil when the
    /// field is fine. Local and immediate — it needs no round trip, unlike the server's own
    /// `bad options[file-extension]` refusal, which lands in the same slot.
    private var extensionRejection: String? {
        canonicalExtension == nil ? ZiplineFileExtension.requirement : nil
    }
}
