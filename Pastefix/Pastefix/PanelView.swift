import SwiftUI
import PastefixCore
import PastefixAppCore

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var isPaletteOpen = false
    @State private var isHistoryOpen = false
    @State private var isUploadOpen = false
    /// Bumped on every ⌘⇧U. It is the upload overlay's `.id`, so pressing the hotkey again while
    /// the overlay is already open rebuilds it from scratch instead of doing nothing: the flag
    /// alone is already consumed by then, and the view would keep the server URL, token and
    /// buffer snapshot it read when it first opened. "Configure it, come back, press ⌘⇧U" is the
    /// documented way out of the configure state, so it has to actually re-read them.
    @State private var uploadGeneration = 0
    @State private var showPinPopover = false
    @State private var pinTitle = ""
    @State private var pinError: String?
    @State private var isPreviewing = false
    /// "Show anyway" on the large-text placeholder (#52): lays the text out after all, for this
    /// session only. Reset at every session boundary.
    @State private var showLargeTextAnyway = false
    @State private var previewText = NSAttributedString()
    @State private var previewTask: Task<Void, Never>?
    /// The editor's selection, owned here rather than on the model — see `selectionBinding`.
    @State private var editorSelection: TextSelection?
    /// The region drawn on the image (crop spec): view state, like `editorSelection`, never on the
    /// model. ⌘Z hands one back through `model.pendingImageRegion`.
    @State private var imageRegion: ImageRegion?
    @FocusState private var editorFocused: Bool
    @FocusState private var pinTitleFocused: Bool

    private var workingBinding: Binding<String> {
        Binding(
            // Mid-composition, the editor's own text: the model never holds marked text, and
            // handing SwiftUI anything else makes it overwrite (and discard) the composition on
            // the next render (see `AppModel.composingEditorText`).
            get: { model.composingEditorText() ?? model.document?.working ?? "" },
            set: { model.setWorking($0) }
        )
    }

    /// The editor's selection, kept in this view's `@State` and never on the model.
    ///
    /// A `TextEditor` writes its selection back through this binding whenever the caret moves or
    /// it gains or loses focus. While that binding went to an `@Published` property, every one of
    /// those writes published on `AppModel`, re-rendered the whole panel — overlays included —
    /// and re-applied the selection to the editor, which took first responder back from the ⌘K
    /// palette's search field the moment it appeared. Local state keeps those writes inside the
    /// editor's own subtree.
    ///
    /// The getter is a guard, not a transform, and it does two things. It hands the editor
    /// nothing while an overlay is open: `nil` is "no preference" (it does not move the caret),
    /// and a re-applied selection is precisely what pulls focus out of the overlay's field. And
    /// it re-validates the stored selection against the buffer the editor actually has, because a
    /// `String.Index` made against a longer buffer is undefined against a shorter one — the
    /// `onChange` clamp below converges the state, but nothing promises it ran before the render
    /// that hands this value down.
    private var selectionBinding: Binding<TextSelection?> {
        Binding(
            get: {
                // Mid-composition, the editor's own selection (see `AppModel.composingEditorSelection`).
                if let composing = model.composingEditorSelection() { return composing }
                guard !isPaletteOpen, !isHistoryOpen, !isUploadOpen,
                      let selection = editorSelection else { return nil }
                return isExpressible(selection, in: model.document?.working ?? "") ? selection : nil
            },
            set: { editorSelection = $0 }
        )
    }

    /// The scope a transform chosen now would get: the region on the image (crop spec), or the
    /// editor's own selection (#25), never the binding getter's (mid-composition that returns the
    /// marked range). Nil when neither is there or the editor isn't on screen.
    private var currentScope: TransformScope? {
        guard let document = model.document else { return nil }
        // The *current* entry decides: after Extract Text the text scope applies, never a leftover region.
        if document.displaysAsImage {
            guard let imageRegion, !imageRegion.isEmpty else { return nil }
            return .image(imageRegion, revision: document.detectionRevision)
        }
        guard !document.displaysAsLargeText || showLargeTextAnyway, !isPreviewing else { return nil }
        return SelectionScope.scope(for: editorSelection, in: document.working)
    }

    /// True when every range of `selection` is a usable range of `text`. `TextRangeClamp.remap`
    /// from a string to itself is exactly that test — bounds *and* grapheme boundaries — and it
    /// compares indices (safe offset arithmetic) before measuring anything.
    private func isExpressible(_ selection: TextSelection, in text: String) -> Bool {
        switch selection.indices {
        case .selection(let range):
            return TextRangeClamp.remap(range, from: text, to: text) != nil
        case .multiSelection(let ranges):
            return ranges.ranges.allSatisfy { TextRangeClamp.remap($0, from: text, to: text) != nil }
        @unknown default:
            return false
        }
    }

    /// Carries the caret across a buffer replacement — a landed transform, undo, redo.
    ///
    /// Clearing the selection instead is safe but throws the caret back to the start of the
    /// buffer on every apply, including the many that barely touch the text (`8e0520c`), so the
    /// selection is re-expressed at the same UTF-16 offsets in the new buffer and dropped only
    /// when they don't exist there. The second attempt covers the other caller of this handler:
    /// an ordinary keystroke, where the editor has *already* reported a selection against the new
    /// text and the caret can legitimately sit past the old buffer's end — validating that
    /// against `current` leaves it exactly where the user put it.
    private func carrySelection(from previous: String, to current: String) {
        // A scoped apply, or the undo/redo of one, names the span to select (#25). It wins over
        // remapping — which keeps raw offsets and, after a length change, lands on the wrong
        // characters (measured) — but only in the buffer it indexes.
        if let pending = model.pendingSelection {
            model.pendingSelection = nil
            if pending.revision == model.document?.detectionRevision,
               !isPaletteOpen, !isHistoryOpen, !isUploadOpen, !isPreviewing,
               let range = Range(pending.range, in: current) {
                let selection = TextSelection(range: range)
                editorSelection = selection
                // Focus, then select a turn later: an NSTextView becoming first responder restores
                // the selection it resigned with (#111 pass 5), which would overwrite this one.
                focusEditorUnlessRefusedImage()
                Task { @MainActor in
                    if model.document?.working == current { editorSelection = selection }
                }
                return
            }
        }
        guard let range = firstRange(of: editorSelection) else { return }
        let carried = TextRangeClamp.remap(range, from: previous, to: current)
            ?? TextRangeClamp.remap(range, from: current, to: current)
        let updated = carried.map { TextSelection(range: $0) }
        // Writing an equal value would invalidate the view for nothing on every keystroke.
        if updated != editorSelection { editorSelection = updated }
    }

    /// The selection's range in the buffer it was made against. A multi-selection (⌥-drag) is
    /// represented by its first range: carrying one range beats dropping the caret entirely, and
    /// the badge — the only other writer — never makes one.
    private func firstRange(of selection: TextSelection?) -> Range<String.Index>? {
        switch selection?.indices {
        case .selection(let range): return range
        case .multiSelection(let ranges): return ranges.ranges.first
        default: return nil
        }
    }

    var body: some View {
        // The palette is a sibling of the whole panel, not of the editor: its backdrop has to
        // dim and swallow clicks for the toolbar, sidebar and action bar too, or a "modal"
        // overlay would leave live controls showing through around its edges.
        ZStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if isPreviewing {
                            // No padding here: the text view carries its own 8 pt
                            // `textContainerInset`, which matches the editor's gutter.
                            MarkdownPreviewView(text: previewText)
                        } else if let document = model.document, document.displaysAsLargeText,
                                  !showLargeTextAnyway {
                            // The editor lays the whole text out, at ~1 s per MB on the main
                            // thread (#52) — what kept a 17 MB ⌘⇧U waiting ~9 s to say "too
                            // large" (#62). After the preview, not before: the preview caps
                            // itself at 16 KB and says so, so ⌘⇧M stays cheap and visible here.
                            largeTextPlaceholder(bytes: document.workingByteCount)
                        } else if let document = model.document, document.displaysAsImage,
                                  let imagePNG = document.imagePNG {
                            // An image session shows the image where the editor would be, and
                            // nothing else about the panel changes: same toolbar, action bar,
                            // footer and overlays. `.id` on the session generation because the
                            // view holds a decoded bitmap in `@State` — a new summon or a loaded
                            // history item must start it over rather than inherit the last
                            // session's image (the view keeps its place in the hierarchy, so
                            // SwiftUI would otherwise keep its state too).
                            ImageSessionView(imagePNG: imagePNG, revision: document.detectionRevision,
                                             region: $imageRegion, interactive: !(model.isApplying || isUploadOpen))
                                .id(model.sessionGeneration)
                        } else {
                            TextEditor(text: workingBinding, selection: selectionBinding)
                                .font(.system(.body, design: .monospaced))
                                .padding(8)
                                // Disabled under the upload overlay, and only that one. The
                                // overlay uploads a snapshot of the buffer taken when it opened,
                                // so an edit landing behind the dim would make the uploaded text
                                // differ from the text on screen. The overlay's own focus call is
                                // the first line of defence and a measured one — an AX pass typed
                                // into both its phases and the buffer did not change — so this is
                                // not a workaround for focus misbehaving. It is kept anyway:
                                // belt and braces on the one path that sends data off the machine.
                                .disabled(model.isApplying || isUploadOpen)
                                .focused($editorFocused)
                                // The editor exists only while text is showing, so a focus request
                                // made while an image (or the placeholder) was up landed on nothing
                                // and it came back without first responder, losing the first
                                // keystroke (#117). A turn later, as `closePreview` does: the view
                                // isn't in the window yet when this runs.
                                .onAppear {
                                    Task { @MainActor in
                                        guard !isPaletteOpen, !isHistoryOpen, !isUploadOpen, !isPreviewing else { return }
                                        focusEditorUnlessRefusedImage()
                                    }
                                }
                                // Tearing the editor down (preview, an image entry, the placeholder)
                                // removes its typing actions from the stack without a notification.
                                .onDisappear { Task { @MainActor in model.refreshUndoState() } }
                        }
                        if let error = model.errorMessage {
                            errorBanner(error)
                        } else if let note = model.transformNote {
                            // Informational, like a notice, and transient, unlike one (see
                            // `AppModel.transformNote`).
                            noticeBanner(note)
                        } else if let notice = model.noticeMessage {
                            // A separate banner from `errorBanner`, not just a recolor of it: a
                            // notice reports a refusal in which nothing the user can act on has
                            // failed, and the red-and-white treatment below said the opposite —
                            // see `AppModel.noticeMessage`. Three messages today, all about an
                            // image that would not open: too large to convert at summon
                            // (`noteRefusedImage`), and too large or file-missing when a history
                            // item is opened (`noteUnopenableImage`).
                            //
                            // This `else if` is a priority for one banner slot, not an assumption
                            // that only one of the two can be set: both can be non-nil at once
                            // (see `AppModel.noticeMessage`), and a transient error outranks a
                            // standing notice here on purpose. The notice reappears on its own
                            // once the error clears — nothing here discards it.
                            noticeBanner(notice)
                        }
                    }
                    if settings.showSidebar {
                        Divider()
                        SidebarView(model: model, settings: settings, scope: currentScope)
                    }
                }
                Divider()
                actionBar
            }
            // The three overlays are mutually exclusive: one backdrop, one focused field, one
            // owner for Esc. Opening any of them closes the others.
            if isPaletteOpen {
                CommandPaletteView(model: model, scope: currentScope, onClose: closePalette)
                    .transition(.opacity)
                    // A sidebar-started apply must not leave a live palette behind.
                    .disabled(model.isApplying)
            } else if isHistoryOpen {
                HistoryOverlayView(model: model, onClose: closeHistory)
                    .transition(.opacity)
                    .disabled(model.isApplying)
            } else if isUploadOpen {
                UploadOverlayView(model: model, onClose: closeUpload, tokenStore: KeychainTokenStore())
                    .id(uploadGeneration)
                    .transition(.opacity)
                    .disabled(model.isApplying)
            }
        }
        .frame(
            minWidth: settings.showSidebar
                ? PanelMetrics.minContentWidthWithSidebar
                : PanelMetrics.minContentWidth,
            minHeight: PanelMetrics.minContentHeight
        )
        .animation(.easeInOut(duration: 0.15), value: settings.showSidebar)
        .animation(.easeInOut(duration: 0.1), value: isPaletteOpen)
        .animation(.easeInOut(duration: 0.1), value: isHistoryOpen)
        .animation(.easeInOut(duration: 0.1), value: isUploadOpen)
        // Every session boundary closes both overlays. Keyed on the generation counter, not on
        // `document == nil`: ⌘S and auto-hide-on-blur end the session from inside the overlay
        // and hide the panel synchronously, and SwiftUI does not promise to update a hosting
        // view in an ordered-out window — a derived Bool reads the same on both sides of a
        // skipped render, so the transition is never observed and the next summon comes up with
        // the overlay still over it. The counter is monotonic, so a skipped render can't hide it.
        // Must stay above the `historyOverlayRequested` handler: a ⌘⇧V summon resets, then opens.
        // The window's undo manager is the one stack for typing and transforms (#103).
        .background(WindowUndoBinding(model: model))
        // A new image entry (a transform, undo, redo, refresh) drops the region, unless ⌘Z named the
        // one to restore for exactly this entry.
        .onChange(of: imageRegion) { _, region in model.imageRegionOnScreen = region }
        .onChange(of: model.document?.detectionRevision) { _, revision in
            if let pending = model.pendingImageRegion {
                model.pendingImageRegion = nil
                if pending.revision == revision, model.document?.displaysAsImage == true {
                    imageRegion = pending.region
                    return
                }
            }
            imageRegion = nil
        }
        .onChange(of: model.sessionGeneration) { _, _ in
            isPaletteOpen = false
            isHistoryOpen = false
            // The upload overlay holds a snapshot of the buffer it opened on and an in-flight
            // scan of it; both belong to the session that just ended.
            isUploadOpen = false
            // A `String.Index` into the buffer that just went away has no meaning in the new one.
            editorSelection = nil
            imageRegion = nil
            showLargeTextAnyway = false
            // A new summon always starts in the editor: the preview is a view of *this*
            // buffer, and leaving it on would show the previous session's render until the
            // debounce lands. The render is dropped too — the next ⌘⇧M turns the preview on
            // before its immediate render lands, and the stale string it would otherwise show
            // for that frame is the previous clipboard's content.
            isPreviewing = false
            previewTask?.cancel()
            previewText = NSAttributedString()
        }
        // Refresh (⌘R) can turn a text session into an image session *without* a new session
        // generation, so the reset above does not cover it. The preview is a view of the buffer
        // that just went away, and leaving it on would draw a blank preview over the image with
        // the ⌘⇧M that turns it off now disabled — a dead end reachable in two keystrokes.
        .onChange(of: model.document?.displaysAsImage) { _, displaysAsImage in
            guard displaysAsImage == true, isPreviewing else { return }
            isPreviewing = false
            previewTask?.cancel()
            previewText = NSAttributedString()
        }
        // Hand focus back to the editor once a transform finishes, unless the user has an
        // overlay open and is picking the next thing — or is reading the preview, where there
        // is no editor to focus.
        .onChange(of: model.isApplying) { _, applying in
            if !applying && !isPaletteOpen && !isHistoryOpen && !isUploadOpen && !isPreviewing {
                focusEditorUnlessRefusedImage()
            }
        }
        // Transforms, undo/redo and typing all land here; the debounce keeps a fast-changing
        // buffer from re-rendering HTML on every keystroke.
        .onChange(of: model.document?.working) { previous, current in
            if isPreviewing { scheduleRender() }
            // The model swaps the whole buffer out from under the editor on a landed transform,
            // undo or redo; the selection it is holding indexes the buffer that just left.
            carrySelection(from: previous ?? "", to: current ?? "")
        }
        // The secrets badge asks for a selection rather than setting one: the live selection is
        // this view's. One-shot, like `historyOverlayRequested` — cleared as it is consumed, so
        // clicking the badge again moves the caret to the next match. Ignored while an overlay is
        // up (the badge is hidden then) because applying a selection there is what takes first
        // responder away from the overlay's search field.
        .onChange(of: model.requestedSelection) { _, requested in
            guard let requested else { return }
            if !isPaletteOpen && !isHistoryOpen && !isUploadOpen && !isPreviewing {
                editorSelection = requested
                focusEditorUnlessRefusedImage()
            }
            model.requestedSelection = nil
        }
        // ⌘⇧V summons straight into the history overlay; the flag is a one-shot request,
        // so reset it here or the next summon would reopen the overlay by itself.
        .onChange(of: model.historyOverlayRequested) { _, requested in
            guard requested else { return }
            closeOthers()
            isHistoryOpen = true
            model.historyOverlayRequested = false
        }
        // ⌘⇧U summons straight into the upload overlay; same one-shot handling as the history
        // flag above, and must stay below the `sessionGeneration` reset for the same reason —
        // a ⌘⇧U that starts a new session resets first, then opens.
        .onChange(of: model.uploadOverlayRequested) { _, requested in
            guard requested else { return }
            closeOthers()
            // Bumped before the flag is set, so an already-open overlay is replaced rather than
            // left standing with the configuration it read a minute ago.
            uploadGeneration &+= 1
            // The overlay snapshots the buffer when it opens; marked text isn't in it yet.
            model.settleComposition()
            isUploadOpen = true
            model.uploadOverlayRequested = false
        }
    }

    private var toolbar: some View {
        HStack {
            // Through the window's undo manager, like ⌘Z (Edit ▸ Undo): one stack, so the button
            // undoes typing as readily as a transform (#103). Enabled while a transform runs, since
            // undoing it then cancels it.
            UndoButtons(model: model, state: model.undoState)
            Button("Refresh") { model.refresh() }
                .disabled(model.isApplying)
            Button { showPinPopover = true } label: {
                Image(systemName: "pin")
            }
            .help("Pin this text as a snippet (⌘⇧P)")
            .accessibilityLabel("Pin this text as a snippet")
            .keyboardShortcut(isPaletteOpen || isHistoryOpen || isUploadOpen ? nil : KeyboardShortcut("p", modifiers: [.command, .shift]))
            .disabled(model.document == nil || isPaletteOpen || isHistoryOpen || isUploadOpen)
            .popover(isPresented: $showPinPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pin as snippet").font(.headline)
                    TextField("Title (optional)", text: $pinTitle)
                        .frame(width: 260)
                        .focused($pinTitleFocused)
                        .onSubmit(commitPin)
                    if pinError != nil {
                        Text(pinError!).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { cancelPin() }
                        Button("Pin", action: commitPin).keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .onAppear { pinTitleFocused = true }
                // Clicking away dismisses the popover without going through Cancel, so the
                // reset has to live here as well or the next ⌘⇧P reopens on a stale title and a
                // stale error.
                .onDisappear { pinTitle = ""; pinError = nil }
            }
            Button { togglePreview() } label: {
                Image(systemName: isPreviewing ? "eye.fill" : "eye")
            }
            .help(isPreviewing ? "Back to the editor (⌘⇧M)" : "Preview as Markdown (⌘⇧M)")
            .accessibilityLabel(isPreviewing ? "Back to the editor" : "Preview as Markdown")
            // Tinted, not gated: any *text* can be previewed, detection only makes it a suggestion.
            .tint(model.document?.detectedKinds.contains(.markdown) == true ? Color.accentColor : nil)
            // Nothing owns ⌘⇧M while an overlay is up (no overlay binds it either, so no swap).
            .keyboardShortcut(isPaletteOpen || isHistoryOpen || isUploadOpen ? nil : KeyboardShortcut("m", modifiers: [.command, .shift]))
            // Gated in an image session, which is the one thing there is no text to preview of:
            // the buffer is blank, so ⌘⇧M would draw an empty preview over the image and the way
            // back would be a shortcut the user has to guess. Disabled rather than reordering the
            // branches below it — a lit button that silently does nothing is the worse failure.
            .disabled(model.document == nil || model.isApplying
                      || model.document?.displaysAsImage == true)
            Spacer()
            Button { toggleHistory() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Clipboard History (⌘Y)")
            .accessibilityLabel("Clipboard History")
            // Bound while the history overlay is open, and toggles it closed: one ⌘Y, never
            // swapped. It used to hand ⌘Y to a hidden button inside the overlay and take it back
            // on close, and SwiftUI lost the re-added binding here — ⌘Y worked twice, then went
            // dead until another overlay cycle (#73). A key equivalent does not care that the
            // button is under the backdrop. Nothing owns ⌘Y while the palette or upload is open.
            .keyboardShortcut(isPaletteOpen || isUploadOpen ? nil : KeyboardShortcut("y", modifiers: .command))
            .disabled(model.isApplying)
            Button { settings.showSidebar.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help(settings.showSidebar ? "Hide Transforms Sidebar (⌘⇧L)" : "Show Transforms Sidebar (⌘⇧L)")
            .accessibilityLabel(settings.showSidebar ? "Hide Transforms Sidebar" : "Show Transforms Sidebar")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            // Cancel stays enabled during a slow transform, and owns Esc outright: one key with
            // two meanings, resolved here rather than by attaching and detaching the binding.
            // Esc with an overlay open closes that overlay; Esc with both closed cancels the
            // panel. Keeping the shortcut permanently attached means there is never a frame in
            // which nothing claims Esc.
            Button("Cancel") { escape() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isApplying)
                .help(model.isRichOutputArmed
                      ? "Save as formatted text + Markdown source (⌘S)"
                      : "Save to clipboard (⌘S)")
        }
        .padding(8)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { togglePalette() } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Transform…")
                    Spacer()
                    Text("⌘K")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Only one ⌘K can exist at a time: while the palette is open this button is still
            // in the hierarchy (just under the backdrop), and the palette's own hidden button
            // takes over the shortcut to close it. Two live bindings would be ambiguous.
            // This swap is the pattern that broke ⌘Y (#73): the re-added binding was lost when
            // the button sat in the toolbar, and survived here in the action bar (measured). If
            // this button moves, bind it permanently and toggle instead, as ⌘Y now does.
            .keyboardShortcut(isPaletteOpen || isHistoryOpen || isUploadOpen ? nil : KeyboardShortcut("k", modifiers: .command))
            .disabled(model.isApplying)
            .accessibilityLabel("Find a transform")
            if let color = model.detectedColor {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Detected color \(color.cssHex)")
            }
            // Hidden while an overlay is up: the backdrop dims the action bar, and the click
            // target underneath it would select text the user cannot see. Hidden during the
            // Markdown preview for the same reason — there is no editor on screen to select in,
            // so the click would silently do nothing. Its count comes from the document's pinned
            // matches, but the click re-scans the live buffer — see `AppModel.selectNextSecret`.
            if !model.secretMatches.isEmpty && !isPaletteOpen && !isHistoryOpen && !isUploadOpen
                && !isPreviewing {
                let n = model.secretMatches.count
                Button { model.selectNextSecret() } label: {
                    Label("\(n) secret\(n == 1 ? "" : "s")", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Looks like credentials: \(Set(model.secretMatches.map(\.kind.displayName)).sorted().joined(separator: ", ")). Click to select the next one; use Redact Secrets (⌘K) to mask them.")
                .accessibilityLabel("\(n) possible secrets; click to select the next one")
            } else if model.secretScanSkipped {
                // The buffer was never examined, so showing nothing here would be indistinguishable
                // from "scanned and found nothing" — the user would act on a clean-looking bar.
                // Grey, not orange: this is an absence of knowledge, not a finding. Nothing to
                // click, so unlike the orange badge it needs no overlay guard.
                Label("Not scanned for secrets", systemImage: "shield.slash")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("This text is over 256 KB, the limit for the secrets scan.")
                    .accessibilityLabel("Not scanned for secrets; this text is over the 256 KB scan limit")
            }
            if let summary = model.detectedSummary {
                Text("Detected: \(summary)")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Detected content: \(summary)")
            }
            // Only while a Markdown render is armed. Clicking it is the disarm affordance —
            // the same capsule tells you what ⌘S will do and how to take it back.
            if model.isRichOutputArmed {
                Button { model.disarmRichOutput() } label: {
                    Label("Rich text on save", systemImage: "textformat")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("⌘S will paste as formatted text (HTML + RTF); plain-text targets get the Markdown source. Click to save plain text only.")
                .accessibilityLabel("Rich text on save; click to disarm")
            }
            if model.isApplying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Applying transform")
            }
        }
        .padding(8)
    }

    private func togglePalette() {
        if isPaletteOpen { closePalette() } else { closeOthers(); isPaletteOpen = true }
    }

    private func toggleHistory() {
        if isHistoryOpen { closeHistory() } else { closeOthers(); isHistoryOpen = true }
    }

    /// Clears all three flags, so an opener only has to set its own. With three overlays,
    /// spelling out "the other two" at each call site is how one of them gets forgotten and two
    /// backdrops end up stacked.
    private func closeOthers() {
        isPaletteOpen = false
        isHistoryOpen = false
        isUploadOpen = false
    }

    private func togglePreview() {
        if isPreviewing {
            closePreview()
        } else {
            isPreviewing = true
            // No debounce on the way in: the toggle has to paint something immediately.
            scheduleRender(immediate: true)
        }
    }

    /// Renders the buffer off the keystroke path. `immediate` skips the 150 ms debounce.
    private func scheduleRender(immediate: Bool = false) {
        previewTask?.cancel()
        let text = model.document?.working ?? ""
        // The session the render belongs to. The `sessionGeneration` handler also cancels this
        // task, but that only wins if it runs first — `onChange` order is a property of the
        // modifier stack, not something this function can rely on. Checking the generation at
        // the end makes the drop independent of who ran when: a render scheduled into a session
        // that has since ended never reaches `previewText`.
        let generation = model.sessionGeneration
        previewTask = Task { @MainActor in
            if !immediate { try? await Task.sleep(for: .milliseconds(150)) }
            // Both paths check: a cancelled immediate render would still import the old buffer
            // on the main actor and write it back over a newer one (or into a dead session).
            guard !Task.isCancelled, model.sessionGeneration == generation else { return }
            previewText = MarkdownPreview.attributedString(markdown: text)
        }
    }

    private func closePreview() {
        isPreviewing = false
        previewTask?.cancel()
        // Unlike the overlays, the editor does not exist yet at this point — it comes back on
        // the next render — so the focus request has to wait a turn or it lands on nothing.
        Task { @MainActor in focusEditorUnlessRefusedImage() }
    }

    /// Esc: close whichever overlay is open, then the preview, then clear the image region,
    /// otherwise end the session.
    private func escape() {
        if isPaletteOpen {
            closePalette()
        } else if isHistoryOpen {
            closeHistory()
        } else if isUploadOpen {
            closeUpload()
        } else if isPreviewing {
            closePreview()
        } else if imageRegion != nil {
            // The region clears before the panel cancels, as a selection does everywhere (crop spec).
            imageRegion = nil
        } else {
            model.cancel()
        }
    }

    private func closePalette() {
        isPaletteOpen = false
        focusEditorUnlessRefusedImage()
    }

    private func closeHistory() {
        isHistoryOpen = false
        focusEditorUnlessRefusedImage()
    }

    private func closeUpload() {
        isUploadOpen = false
        focusEditorUnlessRefusedImage()
    }

    /// Requests focus for the editor, except in an *empty* refused-image session, where it is on
    /// screen only beneath the notice telling the user their picture is still on the clipboard. A
    /// blinking caret there invites the one keystroke `save()` deliberately allows to overwrite
    /// that image (typing is a deliberate act, so `save()` does not block it) — this just stops
    /// inviting it. The editor stays reachable by click for anyone who does mean to type over it.
    ///
    /// Emptiness is the condition, not "this session had a refused image", and the difference is a
    /// whole class of session: a **mixed** one (real text plus an over-ceiling image) is an ordinary
    /// text session with a banner over it, and the weaker condition left it never able to regain
    /// focus — every overlay close, every landed transform, for the session's whole life. The rule
    /// lives in `PasteDocument.isEmptyRefusedImageSession`, where it is one expression of "blank
    /// once trimmed" shared with Save's refusal, and where it can be tested (#68).
    private func focusEditorUnlessRefusedImage() {
        guard model.document?.isEmptyRefusedImageSession != true else { return }
        editorFocused = true
    }

    private func cancelPin() {
        pinTitle = ""
        pinError = nil
        showPinPopover = false
    }

    private func commitPin() {
        switch model.pinCurrentBuffer(title: pinTitle) {
        case .pinned:
            pinTitle = ""
            pinError = nil
            showPinPopover = false
        // Two different refusals, and the wrong one is actively misleading: a user who pressed
        // ⌘⇧P on an empty buffer and reads "Too large to pin" has no idea what to do next.
        case .nothingToPin:
            pinError = "Nothing to pin"
        case .tooLarge:
            pinError = "Too large to pin"
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.red.opacity(0.85))
    }

    /// What stands in for the editor over `PasteDocument.editorDisplayLimitBytes`. It names the
    /// size and says what still works — Save and Upload; most transforms refuse at their own 1 MB
    /// input cap — so nothing about the buffer is hidden but its layout.
    private func largeTextPlaceholder(bytes: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("\(HistoryFormatting.byteLabel(bytes)) of text isn't shown, so the panel stays fast.")
                .font(.headline)
            // Not "transforms still work": most refuse above `TransformLimits.defaultMaxInputBytes`,
            // which is this same 1 MB, and they say so in the error banner when they do.
            Text("Save and Upload (⌘⇧U) still work on all of it. Most transforms stop at 1 MB and will say so.")
                .foregroundStyle(.secondary)
            Button("Show anyway") { showLargeTextAnyway = true }
                .help("Lay the text out in the editor — about a second per MB")
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Amber, not red-and-white: a notice (currently only the refused-image message) reports
    /// that a refusal happened and nothing was lost, not that something failed. `errorBanner`
    /// above stays exactly as it was — real errors still get the solid red strip and the
    /// warning triangle.
    private func noticeBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "info.circle.fill")
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(8)
        .background(Color.orange.opacity(0.18))
    }
}

/// The toolbar's Undo/Redo. A view of its own so an undo-state change re-renders these two buttons
/// and nothing else — in particular not `PanelView`, which owns the TextEditor (see `UndoState`).
private struct UndoButtons: View {
    let model: AppModel
    @ObservedObject var state: UndoState

    var body: some View {
        Button("Undo") { model.undoManager?.undo() }
            .disabled(!state.canUndo)
        Button("Redo") { model.undoManager?.redo() }
            .disabled(!state.canRedo)
    }
}
