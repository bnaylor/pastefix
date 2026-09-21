import SwiftUI
import PastefixCore
import PastefixAppCore

/// ⌘K overlay: type to filter, ↑↓ to choose, ↵ to apply, Esc to close.
struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var results: [SearchResult] {
        TransformSearch.rank(
            query: query,
            in: model.enabledTransformers(),
            kinds: model.document?.detectedKinds ?? []
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
                .accessibilityLabel("Close transform palette")
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
        let selected = items.isEmpty ? 0 : min(selection, items.count - 1)
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Transform…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { applyCurrentSelection() }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                Text("No matching transforms").foregroundStyle(.secondary).padding(16)
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, result in
                        row(result, isSelected: index == selected)
                            .contentShape(Rectangle())
                            .onTapGesture { apply(items, index) }
                            .listRowBackground(index == selected ? Color.accentColor.opacity(0.25) : Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(min(items.count, 8)) * 44)
                    .onChange(of: selected) { _, new in
                        guard items.indices.contains(new) else { return }
                        proxy.scrollTo(items[new].id)
                    }
                }
            }
            Divider()
            HStack(spacing: 16) {
                Label("Apply", systemImage: "return")
                Label("Choose", systemImage: "arrow.up.arrow.down")
                Text("esc Close")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            // ⌘K toggles: while the palette is open the action bar's button is under the
            // backdrop, so the shortcut lives here instead (PanelView drops its binding for as
            // long as we exist, so only one ⌘K is ever registered). Zero-sized and transparent
            // rather than `.hidden()`, which would still reserve a button's worth of layout.
            Button("Close transform palette", action: onClose)
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
        .onKeyPress(.downArrow) { move(+1, count: results.count); return .handled }
        // Cancel's `.cancelAction` already closes the palette first; this is a harmless
        // duplicate that keeps Esc working even if that button is ever disabled or removed.
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ result: SearchResult, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName(result))
                // Uncategorised transforms are shown under "Scripts" in the sidebar; the
                // subtitle says the same thing so the two surfaces agree.
                Text(result.transformer.category ?? TransformCategory.scripts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "return")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }

    private func highlightedName(_ result: SearchResult) -> AttributedString {
        var text = AttributedString(result.transformer.name)
        // Set the base font first so the bold runs differ only in weight, not in size.
        text.font = .body
        for range in result.matchedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = .body.weight(.bold)
            text[lower..<upper].foregroundColor = .accentColor
        }
        return text
    }

    /// Index the list is actually highlighting: `selection` clamped to the live result count.
    private func clampedSelection(in items: [SearchResult]) -> Int {
        items.isEmpty ? 0 : min(selection, items.count - 1)
    }

    /// Applies whatever is highlighted *now*. A retained handler must not close over render-time
    /// locals; read `@State` (which resolves through its storage box and is always current) at
    /// call time. Return applied the first result after arrowing until this was fixed.
    private func applyCurrentSelection() {
        let items = results
        apply(items, clampedSelection(in: items))
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        // Step from the index the list is actually showing, which is `selection` clamped
        // to the current result count — otherwise a stale larger `selection` skips rows.
        let current = min(selection, count - 1)
        selection = ((current + delta) % count + count) % count
    }

    private func apply(_ items: [SearchResult], _ index: Int) {
        guard items.indices.contains(index) else { return }
        let transformer = items[index].transformer
        onClose()
        model.apply(transformer)
    }
}
