import SwiftUI
import PastefixCore
import PastefixAppCore

/// Vertical, category-grouped list of enabled transforms. Click to apply.
///
/// Reads `browsableTransformers()`, not the palette's detection-promoted list: a browse
/// surface that reshuffles itself whenever the clipboard changes is unusable as a map.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sections = SidebarGrouping.sections(model.browsableTransformers())
        List {
            // An empty grey column reads as a broken panel, which is the exact argument
            // `CommandPaletteView.emptyMessage` rests on — and this surface is worse for it,
            // because the sidebar is a persisted setting that is simply *there* in an image
            // session, with nothing the user opened to explain it. Two causes, two sentences: a
            // session that can't have transforms, and a Settings list with none left enabled.
            if sections.isEmpty {
                Text(model.document?.displaysAsImage == true
                     ? "No transforms apply to an image"
                     : "No transforms enabled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.transformers, id: \.id) { transformer in
                        // Sizing lives inside the label so the whole row is the hit target,
                        // not just the glyphs of the name.
                        Button {
                            model.apply(transformer)
                        } label: {
                            // Preset names are user-typed and uncapped; keep a row one row high.
                            Text(transformer.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: PanelMetrics.sidebarWidth)
        .disabled(model.isApplying)
    }
}
