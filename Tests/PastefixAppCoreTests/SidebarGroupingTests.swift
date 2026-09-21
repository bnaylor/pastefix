import Testing
import PastefixCore
@testable import PastefixAppCore

private struct CatTransformer: Transformer {
    let id: String
    let category: String?
    var name: String { id }
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite struct SidebarGroupingTests {
    private func titles(_ list: [any Transformer]) -> [String] { SidebarGrouping.sections(list).map(\.title) }

    @Test func builtinOrderThenCustomAlphabeticalThenScripts() {
        let list: [any Transformer] = [
            CatTransformer(id: "s1", category: nil),
            CatTransformer(id: "z", category: "Zeta"),
            CatTransformer(id: "c1", category: TransformCategory.case),
            CatTransformer(id: "a", category: "Alpha"),
            CatTransformer(id: "l1", category: TransformCategory.layout),
            CatTransformer(id: "u1", category: TransformCategory.urls),
        ]
        #expect(titles(list) == ["Layout", "URLs", "Case", "Alpha", "Zeta", "Scripts"])
    }
    @Test func emptySectionsOmittedAndOrderWithinSectionPreserved() {
        let list: [any Transformer] = [
            CatTransformer(id: "l2", category: TransformCategory.layout),
            CatTransformer(id: "l1", category: TransformCategory.layout),
        ]
        let s = SidebarGrouping.sections(list)
        #expect(s.count == 1)
        #expect(s[0].transformers.map(\.id) == ["l2", "l1"])
    }
    @Test func scriptsExplicitCategoryEqualToScriptsLandsLast() {
        let list: [any Transformer] = [CatTransformer(id: "x", category: "Scripts"), CatTransformer(id: "b", category: "Beta")]
        #expect(titles(list) == ["Beta", "Scripts"])
    }
    @Test func customCategoriesUseCaseInsensitiveHumanOrder() {
        let list: [any Transformer] = [
            CatTransformer(id: "b", category: "beta"),
            CatTransformer(id: "a", category: "Alpha"),
        ]
        #expect(titles(list) == ["Alpha", "beta"])
    }
    @Test func emptyInput() { #expect(SidebarGrouping.sections([]).isEmpty) }
}
