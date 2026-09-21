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
        List {
            ForEach(SidebarGrouping.sections(model.browsableTransformers())) { section in
                Section(section.title) {
                    ForEach(section.transformers, id: \.id) { transformer in
                        // Sizing lives inside the label so the whole row is the hit target,
                        // not just the glyphs of the name.
                        Button {
                            model.apply(transformer)
                        } label: {
                            Text(transformer.name)
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
