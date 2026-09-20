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
            card
                .frame(width: 520)
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
                    .onSubmit { apply(items, selected) }
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
                            .id(result.id)
                    }
                    .listStyle(.plain)
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
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
        .onKeyPress(.downArrow) { move(+1, count: items.count); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ result: SearchResult, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName(result))
                if let category = result.transformer.category {
                    Text(category).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected { Image(systemName: "return").foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    private func highlightedName(_ result: SearchResult) -> AttributedString {
        var text = AttributedString(result.transformer.name)
        for range in result.matchedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = .body.bold()
            text[lower..<upper].foregroundColor = .accentColor
        }
        return text
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = ((selection + delta) % count + count) % count
    }

    private func apply(_ items: [SearchResult], _ index: Int) {
        guard items.indices.contains(index) else { return }
        let transformer = items[index].transformer
        onClose()
        model.apply(transformer)
    }
}
