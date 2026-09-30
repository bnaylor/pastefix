import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

private struct T: Transformer {
    let id: String
    let name: String
    var category: String? = nil
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

/// #26: a Favorites section at the top of the sidebar, in the order they were added. Favorites
/// also stay in their own category, so the category map doesn't change.
@Suite struct FavoritesTests {
    private let ws = T(id: "ws", name: "Whitespace Cleanup", category: TransformCategory.layout)
    private let json = T(id: "json", name: "JSON Prettify", category: TransformCategory.data)
    private let url = T(id: "url", name: "Clean URL Tracking", category: TransformCategory.urls)

    @Test func favoritesComeFirstInTheOrderAdded() {
        let sections = SidebarGrouping.sections([ws, json, url], favorites: ["url", "ws"])
        #expect(sections.first?.title == SidebarGrouping.favoritesTitle)
        #expect(sections.first?.transformers.map(\.id) == ["url", "ws"])
        // Still in their own categories too.
        #expect(sections.dropFirst().flatMap(\.transformers).map(\.id).sorted() == ["json", "url", "ws"])
    }

    @Test func noFavoritesNoSection() {
        #expect(SidebarGrouping.sections([ws, json], favorites: []).first?.title == TransformCategory.layout)
    }

    @Test func aFavoriteThatIsntListedIsHidden() {
        // Disabled, deleted or not applicable here: absent from `transformers`, so absent from Favorites.
        let sections = SidebarGrouping.sections([ws], favorites: ["gone", "ws"])
        #expect(sections.first?.transformers.map(\.id) == ["ws"])
        #expect(SidebarGrouping.sections([ws], favorites: ["gone"]).first?.title == TransformCategory.layout)
    }

    @Test func aCategoryNamedFavoritesDoesNotCollide() {
        let script = T(id: "s", name: "Mine", category: "Favorites")
        let sections = SidebarGrouping.sections([ws, script], favorites: ["ws"])
        #expect(Set(sections.map(\.id)).count == sections.count, "section ids are unique")
    }
}

@MainActor
@Suite(.serialized) struct FavoritesSettingsTests {
    private func withFreshDefaults(_ body: @MainActor (UserDefaults) -> Void) {
        let iso = IsolatedDefaults()
        defer { iso.remove() }
        body(iso.defaults)
    }

    @Test func toggleAddsAtTheEndRemovesAndPersists() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            s.toggleFavorite("a"); s.toggleFavorite("b"); s.toggleFavorite("c")
            #expect(s.favoriteTransformIDs == ["a", "b", "c"])
            s.toggleFavorite("b")
            #expect(s.favoriteTransformIDs == ["a", "c"])
            #expect(SettingsStore(defaults: d).favoriteTransformIDs == ["a", "c"])
        }
    }

    @Test func removingAPresetUnfavoritesIt() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            let preset = RegexPreset(name: "P", pattern: "a", replacement: "b")
            s.regexPresets = [preset]
            let id = RegexPresetTransformer.transformerID(for: preset.id)
            s.toggleFavorite(id)
            s.removePreset(id: preset.id)
            #expect(s.favoriteTransformIDs.isEmpty)
        }
    }
}
