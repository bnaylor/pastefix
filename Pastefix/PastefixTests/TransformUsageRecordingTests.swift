import Testing
import Foundation
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Upper: Transformer {
    let id = "test.upper"; let name = "Upper"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text.uppercased() }
}

/// #26: only an apply that changed the buffer counts as a use.
@MainActor
@Suite("usage is recorded on a real change (#26)")
struct TransformUsageRecordingTests {
    @Test func aChangeCountsANoOpDoesNot() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        f.model.apply(Upper())
        #expect(await f.eventually { f.model.document?.working == "HELLO" && !f.model.isApplying })
        #expect(f.settings.transformUsage["test.upper"]?.count == 1)
        f.model.apply(Upper())                                   // already upper: unchanged
        #expect(await f.eventually { !f.model.isApplying })
        #expect(f.settings.transformUsage["test.upper"]?.count == 1, "an unchanged result isn't a use")
    }
}
