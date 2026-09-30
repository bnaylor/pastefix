import SwiftUI
import PastefixCore
import PastefixAppCore

/// Vertical, category-grouped list of enabled transforms. Click to apply.
///
/// Reads `browsableTransformers()`, not the palette's detection-promoted list: a browse
/// surface that reshuffles itself whenever the clipboard changes is unusable as a map.
struct SidebarView: View {
    @ObservedObject var model: AppModel
    /// Observed so adding or removing a favorite (#26) redraws the sidebar; the model alone
    /// doesn't republish settings changes.
    @ObservedObject var settings: SettingsStore
    /// The selection a transform chosen here applies to (#25), or nil for the whole buffer.
    let scope: TransformScope?

    var body: some View {
        let sections = SidebarGrouping.sections(model.browsableTransformers(), favorites: settings.favoriteTransformIDs)
        VStack(spacing: 0) {
        List {
            // An empty grey column reads as a broken panel, and the sidebar is a persisted
            // setting that is simply *there*, with nothing the user opened to explain it.
            if sections.isEmpty {
                Text(TransformListEmptyState.message(query: "", showsImage: model.document?.displaysAsImage == true))
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
                            model.apply(transformer, scope: scope)
                        } label: {
                            // Preset names are user-typed and uncapped; keep a row one row high.
                            Text(scope != nil && !TransformCoordinator.canScope(transformer)
                                 ? "\(transformer.name) — whole buffer" : transformer.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(settings.favoriteTransformIDs.contains(transformer.id)
                                   ? "Remove from Favorites" : "Add to Favorites") {
                                settings.toggleFavorite(transformer.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Below the list, outside it: a row at the top of the list pushed every transform down as
        // a selection came and went (clicks missed), and an inset overprinted the last row and ate
        // clicks on it (GUI passes). Here the list simply ends above the hint.
        if scope != nil {
            Divider()
            Text("Applies to selection")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        }
        .frame(width: PanelMetrics.sidebarWidth)
        .disabled(model.isApplying)
    }
}
