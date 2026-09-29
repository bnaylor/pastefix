import Testing
@testable import PastefixAppCore

/// Why a transform list is empty. Image sessions have transforms (Strip Image Metadata, Extract
/// Text), so "no transforms apply to an image" is no longer true; the causes are a search that
/// matched nothing and a Settings list with none of the session's transforms left enabled.
@Suite struct TransformListEmptyStateTests {
    @Test func aSearchThatMatchedNothing() {
        #expect(TransformListEmptyState.message(query: "zzz", showsImage: false) == "No matching transforms")
        #expect(TransformListEmptyState.message(query: "zzz", showsImage: true) == "No matching transforms")
    }

    @Test func nothingEnabledForText() {
        #expect(TransformListEmptyState.message(query: "", showsImage: false) == "No transforms enabled")
    }

    @Test func nothingEnabledForAnImage() {
        #expect(TransformListEmptyState.message(query: "", showsImage: true) == "No image transforms enabled")
    }

    /// Whitespace is not a search: `TransformSearch.rank` treats a blank query as "show all".
    @Test func aBlankQueryIsNotASearch() {
        #expect(TransformListEmptyState.message(query: "  ", showsImage: true) == "No image transforms enabled")
    }
}
