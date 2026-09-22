import SwiftUI
import PastefixCore
import PastefixAppCore

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var isPaletteOpen = false
    @State private var isHistoryOpen = false
    @State private var isUploadOpen = false
    @State private var showPinPopover = false
    @State private var pinTitle = ""
    @State private var pinError: String?
    @State private var isPreviewing = false
    @State private var previewText = NSAttributedString()
    @State private var previewTask: Task<Void, Never>?
    /// The editor's selection, owned here rather than on the model — see `selectionBinding`.
    @State private var editorSelection: TextSelection?
    @FocusState private var editorFocused: Bool
    @FocusState private var pinTitleFocused: Bool

    private var workingBinding: Binding<String> {
        Binding(
            get: { model.document?.working ?? "" },
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
                guard !isPaletteOpen, !isHistoryOpen, !isUploadOpen,
                      let selection = editorSelection else { return nil }
                return isExpressible(selection, in: model.document?.working ?? "") ? selection : nil
            },
            set: { editorSelection = $0 }
        )
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
                        } else {
                            TextEditor(text: workingBinding, selection: selectionBinding)
                                .font(.system(.body, design: .monospaced))
                                .padding(8)
                                .disabled(model.isApplying)
                                .focused($editorFocused)
                        }
                        if let error = model.errorMessage {
                            errorBanner(error)
                        }
                    }
                    if settings.showSidebar {
                        Divider()
                        SidebarView(model: model)
                    }
                }
                Divider()
                actionBar
            }
            // The three overlays are mutually exclusive: one backdrop, one focused field, one
            // owner for Esc. Opening any of them closes the others.
            if isPaletteOpen {
                CommandPaletteView(model: model, onClose: closePalette)
                    .transition(.opacity)
                    // A sidebar-started apply must not leave a live palette behind.
                    .disabled(model.isApplying)
            } else if isHistoryOpen {
                HistoryOverlayView(model: model, onClose: closeHistory)
                    .transition(.opacity)
                    .disabled(model.isApplying)
            } else if isUploadOpen {
                UploadOverlayView(model: model, onClose: closeUpload)
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
        .onChange(of: model.sessionGeneration) { _, _ in
            isPaletteOpen = false
            isHistoryOpen = false
            // The upload overlay holds a snapshot of the buffer it opened on and an in-flight
            // scan of it; both belong to the session that just ended.
            isUploadOpen = false
            // A `String.Index` into the buffer that just went away has no meaning in the new one.
            editorSelection = nil
            // A new summon always starts in the editor: the preview is a view of *this*
            // buffer, and leaving it on would show the previous session's render until the
            // debounce lands. The render is dropped too — the next ⌘⇧M turns the preview on
            // before its immediate render lands, and the stale string it would otherwise show
            // for that frame is the previous clipboard's content.
            isPreviewing = false
            previewTask?.cancel()
            previewText = NSAttributedString()
        }
        // Hand focus back to the editor once a transform finishes, unless the user has an
        // overlay open and is picking the next thing — or is reading the preview, where there
        // is no editor to focus.
        .onChange(of: model.isApplying) { _, applying in
            if !applying && !isPaletteOpen && !isHistoryOpen && !isUploadOpen && !isPreviewing {
                editorFocused = true
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
                editorFocused = true
            }
            model.requestedSelection = nil
        }
        // ⌘⇧V summons straight into the history overlay; the flag is a one-shot request,
        // so reset it here or the next summon would reopen the overlay by itself.
        .onChange(of: model.historyOverlayRequested) { _, requested in
            guard requested else { return }
            isPaletteOpen = false
            isUploadOpen = false
            isHistoryOpen = true
            model.historyOverlayRequested = false
        }
        // ⌘⇧U summons straight into the upload overlay; same one-shot handling as the history
        // flag above, and must stay below the `sessionGeneration` reset for the same reason —
        // a ⌘⇧U that starts a new session resets first, then opens.
        .onChange(of: model.uploadOverlayRequested) { _, requested in
            guard requested else { return }
            isPaletteOpen = false
            isHistoryOpen = false
            isUploadOpen = true
            model.uploadOverlayRequested = false
        }
    }

    private var toolbar: some View {
        HStack {
            Button("Undo") { model.undo() }
                .disabled(model.isApplying || model.document?.canUndo != true)
            Button("Redo") { model.redo() }
                .disabled(model.isApplying || model.document?.canRedo != true)
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
            // Tinted, not gated: anything can be previewed, detection only makes it a suggestion.
            .tint(model.document?.detectedKinds.contains(.markdown) == true ? Color.accentColor : nil)
            // Same one-binding rule as ⌘K/⌘Y: nothing owns ⌘⇧M while an overlay is up.
            .keyboardShortcut(isPaletteOpen || isHistoryOpen || isUploadOpen ? nil : KeyboardShortcut("m", modifiers: [.command, .shift]))
            .disabled(model.document == nil || model.isApplying)
            Spacer()
            Button { toggleHistory() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Clipboard History (⌘Y)")
            .accessibilityLabel("Clipboard History")
            // Same one-binding rule as ⌘K below: while the history overlay is open its own
            // hidden button owns ⌘Y (to close), and while the palette is open nothing does.
            .keyboardShortcut(isPaletteOpen || isHistoryOpen || isUploadOpen ? nil : KeyboardShortcut("y", modifiers: .command))
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
        Task { @MainActor in editorFocused = true }
    }

    /// Esc: close whichever overlay is open, then the preview, otherwise end the session.
    private func escape() {
        if isPaletteOpen {
            closePalette()
        } else if isHistoryOpen {
            closeHistory()
        } else if isUploadOpen {
            closeUpload()
        } else if isPreviewing {
            closePreview()
        } else {
            model.cancel()
        }
    }

    private func closePalette() {
        isPaletteOpen = false
        editorFocused = true
    }

    private func closeHistory() {
        isHistoryOpen = false
        editorFocused = true
    }

    private func closeUpload() {
        isUploadOpen = false
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
}
