import SwiftUI
import PastefixCore
import PastefixAppCore

/// Vertical, category-grouped list of enabled transforms. Click to apply.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ForEach(SidebarGrouping.sections(model.enabledTransformers())) { section in
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
        .frame(width: 220)
        .disabled(model.isApplying)
    }
}
