import SwiftUI
import AppKit
import ImageIO
import PastefixAppCore

/// ⌘Y / ⌘⇧V overlay: type to filter the clipboard history, ↑↓ to choose, ↵ to open,
/// ⌘↵ to copy back, ⌘⌫ to remove, Esc to close.
///
/// Deliberately shaped like `CommandPaletteView` — same backdrop, card, list metrics and
/// footer — so the two overlays read as one surface. Its key-handling rule is also the
/// palette's: every handler reads `@State` at call time, never a value captured while `body`
/// ran (the ⌘K Return bug, `7f67d41`).
struct HistoryOverlayView: View {
    @ObservedObject var model: AppModel
    /// The store is a separate `ObservableObject`, so it needs its own observation for
    /// record/remove to re-render the list.
    @ObservedObject var history: HistoryStore
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    /// Ranked once per query/history change, not once per `body`. Ranking is O(items x haystack)
    /// and `body` re-runs for every arrow key and every thumbnail that lands, so recomputing it
    /// there made each of those pay a full re-rank. Actions read this `@State` at call time
    /// (the ⌘K Return lesson, `7f67d41`) — it is the live value, never a render-time local.
    @State private var results: [HistorySearchResult] = []
    /// Downsampled thumbnails, kept per item id so scrolling doesn't re-read the blob every
    /// frame, with `thumbnailOrder` as the FIFO eviction order.
    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var thumbnailOrder: [UUID] = []
    /// Ids whose blob read + decode is in flight, so a re-render (or a second row for the same
    /// item) doesn't start the same off-main load again.
    @State private var thumbnailsLoading: Set<UUID> = []
    @FocusState private var fieldFocused: Bool

    /// Tall enough for the 44pt image thumbnails; the palette's rows are text-only at 44.
    private static let rowHeight: CGFloat = 52
    /// Never more than this many rows, however tall the panel is.
    private static let maxVisibleRows = 8
    private static let thumbnailSide: CGFloat = 44
    /// 2× the 44pt slot, so the cache holds Retina-sharp thumbnails and not whole bitmaps.
    private static let thumbnailPixelSize = 88
    /// Bounded so a long scroll through an image-heavy history can't balloon RSS.
    private static let thumbnailCacheLimit = 64
    private static let cardTopPadding: CGFloat = 40
    /// Kept clear below the card so it never sits flush against the panel's bottom edge.
    private static let cardBottomMargin: CGFloat = 24
    /// Search row (46) + two dividers (2) + footer (32), rounded up. Only has to be an
    /// over-estimate: the list gets an exact height, so anything left over is margin.
    private static let cardChromeHeight: CGFloat = 84
    /// One plain-list section header. An estimate, like `cardChromeHeight`; two of them come to
    /// the single row's worth the sectioned case used to deduct wholesale.
    private static let sectionHeaderHeight: CGFloat = 26

    init(model: AppModel, onClose: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _history = ObservedObject(wrappedValue: model.history)
        // Seeded here rather than left empty until `onAppear`, so the overlay's first frame
        // already shows the history instead of the "No clipboard history yet" empty state.
        _results = State(initialValue: HistorySearch.rank(query: "", in: model.history.items))
        self.onClose = onClose
    }

    var body: some View {
        // The panel is resizable and starts at 460pt of content (380 at its minimum), so the
        // row count is derived from the height actually available rather than fixed at 8 —
        // otherwise a full history pushes the footer, with its key hints, off the bottom.
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }
                    .accessibilityLabel("Close clipboard history")
                    .accessibilityAddTraits(.isButton)
                card(visibleRows: Self.visibleRows(forHeight: geometry.size.height, headers: headerCount))
                    .frame(maxWidth: PanelMetrics.paletteCardWidth)
                    // maxWidth + horizontal padding rather than a fixed width: on a panel narrower
                    // than the card, the card shrinks instead of overflowing off both edges.
                    .padding(.horizontal, 24)
                    .padding(.top, Self.cardTopPadding)
            }
        }
        .onAppear { fieldFocused = true; refreshResults() }
        .onChange(of: query) { _, _ in
            selection = 0
            refreshResults()
        }
        // record/remove/clear all land here, including a capture arriving while the overlay is open.
        .onChange(of: history.items) { _, _ in refreshResults() }
        // The view is torn down on close, so this is belt-and-braces — but the cache is the one
        // piece of state here that is worth megabytes.
        .onDisappear { thumbnails.removeAll(); thumbnailOrder.removeAll(); thumbnailsLoading.removeAll() }
    }

    /// How many rows fit above the footer at this panel height, given the number of section
    /// headers the list will actually draw — without that deduction the footer, with its key
    /// hints, is pushed off the bottom of the minimum-height panel (the Plan 6 lesson). Deducting
    /// for two headers when only one is shown (every result pinned, so there is no History
    /// section) costs a row the panel had room for.
    private static func visibleRows(forHeight height: CGFloat, headers: Int) -> Int {
        let available = height - cardTopPadding - cardBottomMargin - cardChromeHeight
            - CGFloat(headers) * sectionHeaderHeight
        return min(maxVisibleRows, max(1, Int(available / rowHeight)))
    }

    /// Headers the list renders: none when flat, one when every result is pinned (no History
    /// section to head), two when both sections show.
    private var headerCount: Int {
        guard isSectioned else { return 0 }
        let pinned = results.prefix { $0.item.pinned }.count
        return pinned == results.count ? 1 : 2
    }

    /// Pins get their own section only on an empty query: with a query the list is one ranked
    /// run (pins merely sort ahead at equal tier), and splitting it would imply a grouping the
    /// ranking doesn't have.
    private var isSectioned: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty && results.contains { $0.item.pinned }
    }

    private func card(visibleRows: Int) -> some View {
        let items = results
        let selected = clampedSelection(in: items)
        // `HistorySearch.rank` puts pins first on an empty query, so the split is the first
        // unpinned result and every row keeps its index in `results` — `selection` stays a
        // single global index across both sections.
        let pinnedCount = isSectioned ? items.prefix { $0.item.pinned }.count : 0
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    // Plain Return only; the handler below handles the command case.
                    .onSubmit { openSelection() }
                if history.lastWriteError != nil {
                    Label("History couldn't be saved", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(history.lastWriteError ?? "")
                }
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    list(items, selected: selected, pinnedCount: pinnedCount)
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        // The headers' height is exactly what `visibleRows` already gave up for
                        // them, so the list still occupies at most the budget the footer was
                        // measured against.
                        .frame(height: CGFloat(min(items.count, visibleRows)) * Self.rowHeight
                               + CGFloat(headerCount) * Self.sectionHeaderHeight)
                    .onChange(of: selected) { _, new in
                        guard items.indices.contains(new) else { return }
                        proxy.scrollTo(items[new].id)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("↵ Open   ⌘↵ Copy   ⇧↵ Paste   ⌘P Pin   ⌘⌫ Remove   esc Close")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(history.items.count) items · \(HistoryFormatting.byteLabel(history.totalBytes))")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            // ⌘Y toggles: while the overlay is open the toolbar button is under the backdrop,
            // so the shortcut lives here instead (PanelView drops its binding for as long as we
            // exist, so only one ⌘Y is ever registered). Zero-sized and transparent rather than
            // `.hidden()`, which would still reserve a button's worth of layout.
            Button("Close clipboard history", action: onClose)
                .keyboardShortcut("y", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            // ⌘⌫ has to be a key *equivalent*, not an `onKeyPress`: the search field is first
            // responder and its field editor implements `deleteToBeginningOfLine:`, so it would
            // consume ⌘⌫ and truncate the query instead of forwarding it. `performKeyEquivalent:`
            // runs before `keyDown:`, so this button sees the key first. Deliberately the only
            // ⌘⌫ handler in the view — two would risk removing two items on one press.
            Button("Remove from clipboard history", action: removeSelection)
                .keyboardShortcut(.delete, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            // ⌘P and ⇧↵ are key equivalents for the same reason ⌘⌫ is (`0966c97`): the search
            // field is first responder, and `performKeyEquivalent:` runs before the field editor
            // sees the key. Both handlers read the live `@State results` through `selectedItem()`.
            Button("Pin or unpin", action: togglePinSelected)
                .keyboardShortcut("p", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            Button("Paste into the previous app", action: pasteSelected)
                .keyboardShortcut(.return, modifiers: .shift)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
        .onKeyPress(.downArrow) { move(+1, count: results.count); return .handled }
        // Cancel's `.cancelAction` already closes the overlay first; this is a harmless
        // duplicate that keeps Esc working even if that button is ever disabled or removed.
        .onKeyPress(.escape) { onClose(); return .handled }
        // ⌘↵ is not a field-editor binding, so it reaches here; `.ignored` for the unmodified
        // press leaves plain Return to `.onSubmit`, which is its only handler.
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            copyBackSelection()
            return .handled
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !model.settings.historyEnabled {
            VStack(spacing: 8) {
                Text("Clipboard history is off").foregroundStyle(.secondary)
                // Same door the menu bar uses; closing the overlay first takes the dim off the
                // panel behind the Settings window.
                SettingsLink { Text("Enable in Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { onClose() })
            }
        } else if history.items.isEmpty {
            Text("No clipboard history yet").foregroundStyle(.secondary)
        } else {
            Text("No matches").foregroundStyle(.secondary)
        }
    }

    /// Sectioned when there are pins and no query, flat otherwise. Both paths render the same
    /// `results` in the same order, so a row's index — and therefore `selection` — means the
    /// same thing either way.
    @ViewBuilder
    private func list(_ items: [HistorySearchResult], selected: Int, pinnedCount: Int) -> some View {
        let indexed = Array(items.enumerated())
        List {
            if pinnedCount > 0 {
                Section("Pinned") { rows(indexed.prefix(pinnedCount), items: items, selected: selected) }
                if pinnedCount < items.count {
                    Section("History") { rows(indexed.dropFirst(pinnedCount), items: items, selected: selected) }
                }
            } else {
                rows(indexed[...], items: items, selected: selected)
            }
        }
    }

    private func rows(
        _ indexed: ArraySlice<(offset: Int, element: HistorySearchResult)>,
        items: [HistorySearchResult],
        selected: Int
    ) -> some View {
        ForEach(indexed, id: \.element.id) { index, result in
            row(result, isSelected: index == selected)
                .contentShape(Rectangle())
                .onTapGesture { open(items, index) }
                .listRowBackground(index == selected ? Color.accentColor.opacity(0.25) : Color.clear)
        }
    }

    private func row(_ result: HistorySearchResult, isSelected: Bool) -> some View {
        let item = result.item
        return HStack(spacing: 10) {
            // `== true` only: nil is "never examined" (a pre-Plan-11 row), and a glyph there
            // would be a claim the store cannot make.
            if item.containsSecret == true {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.orange)
                    .help("Looks like it contains a credential")
                    .accessibilityLabel("Looks like it contains a credential")
            }
            if item.pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            if item.kind == .image {
                thumbnail(for: item)
                    .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                // A titled pin spends one of the row's two text lines on the label, so the
                // preview drops to one line and the row keeps its height. Pinned rows only: an
                // unpinned item keeps its title (unpin is reversible, see `HistoryStore.unpin`)
                // but a label is a property of a snippet, not of a history entry.
                if let title = rowTitle(for: item) {
                    Text(title).fontWeight(.semibold).lineLimit(1)
                }
                Text(highlightedPreview(result)).lineLimit(rowTitle(for: item) == nil ? 2 : 1)
                HStack(spacing: 6) {
                    if item.kind == .richText {
                        Text("rich")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    if item.kind == .image {
                        Text("↵ copies").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(trailingLabel(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSelected {
                Image(systemName: "return")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }

    private func rowTitle(for item: HistoryItem) -> String? {
        item.pinned ? item.title : nil
    }

    private func trailingLabel(for item: HistoryItem) -> String {
        [item.sourceAppName, HistoryFormatting.relativeAge(from: item.capturedAt)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Bolds the matched ranges in the preview. Built as an `AttributedString` (like the
    /// palette's `highlightedName`) so an index that doesn't convert is skipped rather than
    /// trapping on a bad slice.
    private func highlightedPreview(_ result: HistorySearchResult) -> AttributedString {
        let preview = HistoryFormatting.previewText(for: result.item)
        var text = AttributedString(preview)
        let base = Font.system(.body, design: .monospaced)
        // Set the base font first so the bold runs differ only in weight, not in size.
        text.font = base
        for range in result.matchedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = base.weight(.bold)
            text[lower..<upper].foregroundColor = .accentColor
        }
        return text
    }

    @ViewBuilder private func thumbnail(for item: HistoryItem) -> some View {
        if let image = thumbnails[item.id] {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Color.secondary.opacity(0.2)
                .task(id: item.id) { await cacheThumbnail(for: item) }
        }
    }

    /// Reads the blob and decodes it straight down to thumbnail size — a 5MB PNG decoded whole
    /// would cost tens of megabytes of bitmap to fill a 44pt slot — off the main actor (#32),
    /// hopping back only to install the result, and evicts FIFO at the cache cap.
    ///
    /// The result is keyed to the id it was loaded for, never to "the row that asked": the
    /// overlay can be scrolled, filtered or re-ranked while the bytes are in flight, and the row
    /// that started this load may be showing a different item by the time it lands. The
    /// `thumbnailsLoading` set is the other half of that — without it, a re-render while the read
    /// is in flight starts a second read of the same blob.
    private func cacheThumbnail(for item: HistoryItem) async {
        let id = item.id
        guard thumbnails[id] == nil, !thumbnailsLoading.contains(id),
              let url = history.imageURL(for: item) else { return }
        thumbnailsLoading.insert(id)
        let maxPixelSize = Self.thumbnailPixelSize
        // Only Sendable values cross: a file URL and an Int. The `NSImage` wrapper is built back
        // here on the main actor, so nothing AppKit-mutable is constructed off it.
        let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return HistoryOverlayView.downsample(data, maxPixelSize: maxPixelSize)
        }.value
        thumbnailsLoading.remove(id)
        // Cancellation means the row is gone (`.task(id:)` is torn down with it); the next
        // appearance re-requests the thumbnail.
        guard !Task.isCancelled, let decoded, thumbnails[id] == nil else { return }
        while thumbnails.count >= Self.thumbnailCacheLimit, let oldest = thumbnailOrder.first {
            thumbnailOrder.removeFirst()
            thumbnails.removeValue(forKey: oldest)
        }
        thumbnails[id] = NSImage(cgImage: decoded,
                                 size: NSSize(width: decoded.width, height: decoded.height))
        thumbnailOrder.append(id)
    }

    /// `nonisolated` so the read + decode above can run off the main actor: it touches nothing
    /// but its arguments and ImageIO.
    nonisolated private static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    // MARK: Actions (every one reads live state)

    private func refreshResults() {
        results = HistorySearch.rank(query: query, in: history.items)
    }

    /// Index the list is actually highlighting: `selection` clamped to the live result count.
    private func clampedSelection(in items: [HistorySearchResult]) -> Int {
        items.isEmpty ? 0 : min(selection, items.count - 1)
    }

    /// Whatever is highlighted *now*. A retained handler must not close over render-time
    /// locals; read `@State` (which resolves through its storage box and is always current)
    /// at call time.
    private func selectedItem() -> HistoryItem? {
        let items = results
        guard !items.isEmpty else { return nil }
        return items[clampedSelection(in: items)].item
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        // Step from the index the list is actually showing, which is `selection` clamped
        // to the current result count — otherwise a stale larger `selection` skips rows.
        let current = min(selection, count - 1)
        selection = ((current + delta) % count + count) % count
    }

    /// `.onSubmit` is plain Return's handler. The hidden ⇧↵ button is a key *equivalent*, so it
    /// consumes the shifted press before the field editor's `insertNewline:` can turn it into a
    /// submit — but if it ever doesn't, submitting would silently open the item instead of
    /// pasting it, so route a shifted submit to the paste it was meant to be rather than
    /// letting the two keys do the same thing.
    private func openSelection() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { pasteSelected(); return }
        guard let item = selectedItem() else { return }
        open(item)
    }

    /// Click path: the row the user hit is unambiguous, so it acts on that index directly.
    private func open(_ items: [HistorySearchResult], _ index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        open(items[index].item)
    }

    /// Text and rich text load into the editor; an image has nothing to edit, so ↵ puts it
    /// straight back on the clipboard.
    ///
    /// Closes first, like `CommandPaletteView.apply`: `copyBack` ends the session and orders the
    /// panel out synchronously, so the overlay must not be left relying on `PanelView`'s
    /// session-ended `onChange` running while the window is hidden.
    private func open(_ item: HistoryItem) {
        onClose()
        if item.kind == .image { model.copyBack(item) } else { model.load(item) }
    }

    private func copyBackSelection() {
        guard let item = selectedItem() else { return }
        onClose()
        model.copyBack(item)
    }

    private func removeSelection() {
        guard let item = selectedItem() else { return }
        history.remove(item.id)
    }

    /// The overlay stays open: pinning is a curation gesture, and the row re-ranks under the
    /// cursor (the store publishes, `onChange(of: history.items)` re-ranks) so the user can see
    /// it land in the Pinned section.
    /// Pinning re-ranks the list under the highlight, so the selection has to follow the item.
    /// Left where it was, `selection` would designate a *different* row: a second ⌘P — the natural
    /// "undo that" — would then pin an unrelated item, or unpin whichever pin slid into its place.
    /// ⌘P⌘P on one row is a no-op by design (unpin keeps the title, and `SnippetHotkeys` keeps the
    /// recorded shortcut); ⌘P on the *wrong* row still is not, hence following the item.
    /// The store mutates synchronously, so the new order is readable immediately; the later
    /// `onChange(of: history.items)` refresh re-ranks to the same value and is a no-op.
    private func togglePinSelected() {
        guard let item = selectedItem() else { return }
        // An image cannot *become* a pin (spec, README): it would get a hotkey recorder whose
        // shortcut could never paste anything, and pinned bytes are exempt from eviction, so a
        // handful of screenshot pins can starve history. An image pinned before this guard
        // existed must still be un-pinnable from here, hence `|| item.pinned`. The UI is the
        // gate — `HistoryStore.pin` stays policy-free.
        guard item.hasText || item.pinned else { NSSound.beep(); return }
        model.togglePin(item)
        refreshResults()
        selection = results.firstIndex { $0.item.id == item.id } ?? clampedSelection(in: results)
    }

    /// Dismisses the overlay first — `onClose` only collapses the overlay within the panel, it
    /// does not hide the panel or change activation, so the ⇧↵ paste that follows still runs while
    /// Pastefix is the active app (which is what `SnippetPaster` needs to hand over activation).
    private func pasteSelected() {
        guard let item = selectedItem() else { return }
        onClose()
        model.pasteIntoPreviousApp(item)
    }
}
