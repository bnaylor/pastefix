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
                        Button(transformer.name) { model.apply(transformer) }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 220)
        .disabled(model.isApplying)
    }
}
