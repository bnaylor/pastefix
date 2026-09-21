import SwiftUI
import AppKit
import PastefixAppCore

/// ⌘Y / ⌘⇧V overlay: type to filter the clipboard history, ↑↓ to choose, ↵ to open,
/// ⌘↵ to copy back, ⌘⌫ to remove, Esc to close.
///
/// Deliberately shaped like `CommandPaletteView` — same backdrop, card, list metrics and
/// footer — so the two overlays read as one surface. Its key-handling rule is also the
/// palette's: every handler recomputes `results` and reads `@State` at call time, never a
/// value captured while `body` ran (the ⌘K Return bug, `7f67d41`).
struct HistoryOverlayView: View {
    @ObservedObject var model: AppModel
    /// The store is a separate `ObservableObject`, so it needs its own observation for
    /// record/remove to re-render the list.
    @ObservedObject var history: HistoryStore
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    /// Decoded PNGs, kept per item id so scrolling doesn't re-read the blob every frame.
    @State private var thumbnails: [UUID: NSImage] = [:]
    @FocusState private var fieldFocused: Bool

    /// Tall enough for the 44pt image thumbnails; the palette's rows are text-only at 44.
    private static let rowHeight: CGFloat = 52
    private static let visibleRows = 8
    private static let thumbnailSide: CGFloat = 44

    init(model: AppModel, onClose: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _history = ObservedObject(wrappedValue: model.history)
        self.onClose = onClose
    }

    private var results: [HistorySearchResult] {
        HistorySearch.rank(query: query, in: history.items)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
                .accessibilityLabel("Close clipboard history")
                .accessibilityAddTraits(.isButton)
            card
                .frame(maxWidth: PanelMetrics.paletteCardWidth)
                // maxWidth + horizontal padding rather than a fixed width: on a panel narrower
                // than the card, the card shrinks instead of overflowing off both edges.
                .padding(.horizontal, 24)
                .padding(.top, 40)
        }
        .onAppear { fieldFocused = true }
    }

    private var card: some View {
        let items = results
        let selected = clampedSelection(in: items)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    // Plain Return only: the ⌘↵ handler below claims the command case first.
                    .onSubmit { openSelection() }
                    .onChange(of: query) { _, _ in selection = 0 }
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
                    List(Array(items.enumerated()), id: \.element.id) { index, result in
                        row(result, isSelected: index == selected)
                            .contentShape(Rectangle())
                            .onTapGesture { open(items, index) }
                            .listRowBackground(index == selected ? Color.accentColor.opacity(0.25) : Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight)
                    .onChange(of: selected) { _, new in
                        guard items.indices.contains(new) else { return }
                        proxy.scrollTo(items[new].id)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Label("Open", systemImage: "return")
                Label("Choose", systemImage: "arrow.up.arrow.down")
                Text("⌘↵ Copy")
                Text("⌘⌫ Remove")
                Text("esc Close")
                Spacer()
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
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
        .onKeyPress(.downArrow) { move(+1, count: results.count); return .handled }
        // Cancel's `.cancelAction` already closes the overlay first; this is a harmless
        // duplicate that keeps Esc working even if that button is ever disabled or removed.
        .onKeyPress(.escape) { onClose(); return .handled }
        // Modified Return/Delete: `.ignored` for the unmodified press so the field editor
        // still gets it (Return reaches `.onSubmit`, ⌫ still edits the query).
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            copyBackSelection()
            return .handled
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            removeSelection()
            return .handled
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !model.settings.historyEnabled {
            VStack(spacing: 8) {
                Text("Clipboard history is off").foregroundStyle(.secondary)
                // Same door the menu bar uses; close first so the panel isn't left dimmed
                // behind the Settings window.
                SettingsLink { Text("Enable in Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { onClose() })
            }
        } else if history.items.isEmpty {
            Text("No clipboard history yet").foregroundStyle(.secondary)
        } else {
            Text("No matches").foregroundStyle(.secondary)
        }
    }

    private func row(_ result: HistorySearchResult, isSelected: Bool) -> some View {
        let item = result.item
        return HStack(spacing: 10) {
            if item.kind == .image {
                thumbnail(for: item)
                    .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedPreview(result)).lineLimit(2)
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
                .task(id: item.id) {
                    guard thumbnails[item.id] == nil,
                          let data = history.imagePNG(for: item),
                          let image = NSImage(data: data) else { return }
                    thumbnails[item.id] = image
                }
        }
    }

    // MARK: Actions (every one reads live state)

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

    private func openSelection() {
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
    /// straight back on the clipboard (which ends the session and closes the panel).
    private func open(_ item: HistoryItem) {
        if item.kind == .image {
            model.copyBack(item)
        } else {
            model.load(item)
            onClose()
        }
    }

    private func copyBackSelection() {
        guard let item = selectedItem() else { return }
        model.copyBack(item)
    }

    private func removeSelection() {
        guard let item = selectedItem() else { return }
        history.remove(item.id)
    }
}
