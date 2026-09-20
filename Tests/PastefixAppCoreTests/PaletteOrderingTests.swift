import Testing
import PastefixCore
@testable import PastefixAppCore

private struct FakeTransformer: Transformer {
    let id: String
    let applicableKinds: Set<ContentKind>?
    var name: String { id }
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite struct PaletteOrderingTests {
    let list: [any Transformer] = [
        FakeTransformer(id: "plain1", applicableKinds: nil),
        FakeTransformer(id: "urlA", applicableKinds: [.url]),
        FakeTransformer(id: "plain2", applicableKinds: nil),
        FakeTransformer(id: "json1", applicableKinds: [.json]),
        FakeTransformer(id: "urlB", applicableKinds: [.url]),
    ]
    private func ids(_ kinds: Set<ContentKind>) -> [String] { PaletteOrdering.order(list, for: kinds).map(\.id) }

    @Test func emptyKindsIsIdentity() { #expect(ids([]) == ["plain1", "urlA", "plain2", "json1", "urlB"]) }
    @Test func urlPromotesURLTransformsInRelativeOrder() { #expect(ids([.url]) == ["urlA", "urlB", "plain1", "plain2", "json1"]) }
    @Test func jsonPromotesOnlyJSON() { #expect(ids([.json]) == ["json1", "plain1", "urlA", "plain2", "urlB"]) }
    @Test func bothKindsKeepInputOrderWithinFront() { #expect(ids([.url, .json]) == ["urlA", "json1", "urlB", "plain1", "plain2"]) }
    @Test func nilKindTransformsNeverMoveRelativeToEachOther() {
        let out = ids([.url])
        #expect(out.firstIndex(of: "plain1")! < out.firstIndex(of: "plain2")!)
    }
}
