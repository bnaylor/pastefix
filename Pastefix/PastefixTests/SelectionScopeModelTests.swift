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
private struct Bracket: Transformer {
    let id = "test.bracket"; let name = "Bracket"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { "[" + input.text + "]" }
}

/// #25, model half: a scoped apply publishes the span after as `pendingSelection`, with the revision
/// of the buffer it indexes; nothing else owns post-apply selection.
@MainActor
@Suite("selection-scoped apply, model (#25)")
struct SelectionScopeModelTests {
    private func scope(_ text: String, _ location: Int, _ length: Int) -> TransformScope {
        TransformScope.make(selected: Range(NSRange(location: location, length: length), in: text)!, in: text)!
    }

    @Test func scopedApplyPublishesTheSpan() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        f.model.apply(Bracket(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { f.model.document?.working == "alpha [beta] gamma" && !f.model.isApplying })
        let revision = try #require(f.model.document?.detectionRevision)
        #expect(f.model.pendingSelection == PendingSelection(range: NSRange(location: 6, length: 6), revision: revision))
        #expect(f.model.requestedSelection == nil, "the one-shot badge request isn't used")
    }

    @Test func unscopedApplyPublishesNothing() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha", richRTFD: nil))
        f.model.apply(Upper())
        #expect(await f.eventually { f.model.document?.working == "ALPHA" && !f.model.isApplying })
        #expect(f.model.pendingSelection == nil)
    }

    @Test func staleScopeIsRefused() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        let s = scope("alpha beta gamma", 6, 4)
        f.model.setWorking("xalpha beta gamma")          // the text moved after the range was taken
        f.model.apply(Upper(), scope: s)
        #expect(await f.eventually { !f.model.isApplying })
        #expect(f.model.errorMessage == TransformCoordinator.staleSelectionMessage("Upper"))
        #expect(f.model.document?.working == "xalpha beta gamma" && f.model.pendingSelection == nil)
    }

    /// Review Focus 3.
    @Test func chainOnTheNewSpan() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        f.model.apply(Bracket(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { !f.model.isApplying && f.model.pendingSelection != nil })
        let text = try #require(f.model.document?.working)
        let span = try #require(f.model.pendingSelection).range
        f.model.apply(Upper(), scope: scope(text, span.location, span.length))
        #expect(await f.eventually { f.model.document?.working == "alpha [BETA] gamma" && !f.model.isApplying })
    }

    /// Review Focus 5.
    @Test func boundaryClearsPending() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        f.model.apply(Bracket(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { f.model.pendingSelection != nil })
        f.model.beginSession(from: ClipboardSnapshot(plainText: "other", richRTFD: nil))
        #expect(f.model.pendingSelection == nil)
    }
}
