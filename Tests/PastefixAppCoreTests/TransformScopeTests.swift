import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

private struct Fake: Transformer {
    let id = "test.fake"
    let name: String
    let requiresRichInput: Bool
    let source: TransformerSource = .builtin
    var maxInputBytes = TransformLimits.defaultMaxInputBytes
    let behavior: @Sendable (TransformInput) async throws -> String
    init(_ name: String = "Fake", rich: Bool = false, cap: Int = TransformLimits.defaultMaxInputBytes,
         _ behavior: @escaping @Sendable (TransformInput) async throws -> String) {
        self.name = name; self.requiresRichInput = rich; self.maxInputBytes = cap; self.behavior = behavior
    }
    func apply(_ input: TransformInput) async throws -> String { try await behavior(input) }
}

private struct Arm: OutputModeTransformer {
    let id = "test.arm"; let name = "Arm"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let outputMode: OutputMode = .renderedMarkdown
    func apply(_ i: TransformInput) async throws -> String { i.text }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock(); private var value = ""
    var text: String { lock.withLock { value } }
    func record(_ s: String) { lock.withLock { value = s } }
}

/// #25: a selection scopes a transform to the selected span.
@Suite struct TransformScopeTests {
    private func doc(_ text: String) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil))
    }
    private func scope(_ text: String, _ location: Int, _ length: Int) -> TransformScope {
        let r = Range(NSRange(location: location, length: length), in: text)!
        return TransformScope.make(selected: r, in: text)!
    }
    private let upper = Fake { $0.text.uppercased() }

    @Test func spliceInTheMiddle() async {
        let text = "alpha beta gamma"
        let (d, outcome, span) = await TransformCoordinator.apply(upper, to: doc(text), scope: scope(text, 6, 4))
        #expect(d.working == "alpha BETA gamma" && outcome == .applied)
        #expect(span == NSRange(location: 6, length: 4))
    }

    @Test func spliceAtStartAndEnd() async {
        let text = "alpha beta gamma"
        #expect(await TransformCoordinator.apply(upper, to: doc(text), scope: scope(text, 0, 5)).0.working == "ALPHA beta gamma")
        #expect(await TransformCoordinator.apply(upper, to: doc(text), scope: scope(text, 11, 5)).0.working == "alpha beta GAMMA")
    }

    @Test func spanAfterFollowsTheResultLength() async {
        let text = "alpha beta gamma"
        let longer = Fake { "[" + $0.text + "]" }
        let shorter = Fake { String($0.text.prefix(1)) }
        let (d1, _, s1) = await TransformCoordinator.apply(longer, to: doc(text), scope: scope(text, 6, 4))
        #expect(d1.working == "alpha [beta] gamma" && s1 == NSRange(location: 6, length: 6))
        let (d2, _, s2) = await TransformCoordinator.apply(shorter, to: doc(text), scope: scope(text, 6, 4))
        #expect(d2.working == "alpha b gamma" && s2 == NSRange(location: 6, length: 1))
    }

    /// Review Focus 2.
    @Test func emptyResultIsACaret() async {
        let text = "alpha beta gamma"
        let (d, outcome, span) = await TransformCoordinator.apply(Fake { _ in "" }, to: doc(text), scope: scope(text, 6, 5))
        #expect(d.working == "alpha gamma" && outcome == .applied && span == NSRange(location: 6, length: 0))
    }

    /// Review Focus 1: UTF-16 offsets around surrogate pairs.
    @Test func emojiEdges() async {
        let text = "😀x😀 and 🇫🇷"
        let (d, _, span) = await TransformCoordinator.apply(upper, to: doc(text), scope: scope(text, 2, 1))
        #expect(d.working == "😀X😀 and 🇫🇷" && span == NSRange(location: 2, length: 1))
        let flagged = Fake { "<" + $0.text + ">" }
        let r = (text as NSString).range(of: "🇫🇷")
        let (d2, _, s2) = await TransformCoordinator.apply(flagged, to: doc(text), scope: scope(text, r.location, r.length))
        #expect(d2.working == "😀x😀 and <🇫🇷>" && s2 == NSRange(location: r.location, length: r.length + 2))
    }

    @Test func staleScopeIsRefused() async {
        let taken = "alpha beta gamma"
        let s = scope(taken, 6, 4)                          // "beta"
        let now = doc("xalpha beta gamma")                  // (6,4) is now " bet"
        let (d, outcome, span) = await TransformCoordinator.apply(upper, to: now, scope: s)
        #expect(outcome == .failed(TransformCoordinator.staleSelectionMessage("Fake")))
        #expect(d.working == "xalpha beta gamma" && d.cursor == now.cursor && span == nil)
        let short = doc("alpha")                            // out of bounds
        #expect(await TransformCoordinator.apply(upper, to: short, scope: s).1 == .failed(TransformCoordinator.staleSelectionMessage("Fake")))
    }

    @Test func capIsMeasuredOnTheSelection() async {
        let text = String(repeating: "a", count: 100)
        let capped = Fake("Capped", cap: 10) { $0.text.uppercased() }
        #expect(await TransformCoordinator.apply(capped, to: doc(text), scope: scope(text, 0, 5)).1 == .applied)
        #expect(await TransformCoordinator.apply(capped, to: doc(text), scope: scope(text, 0, 20)).1
                == .failed("Capped is limited to 10 bytes of text."))
    }

    @Test func wholeOnlyTransformsIgnoreTheScope() async {
        let text = "alpha beta gamma"
        let seen = Seen()
        let rich = Fake(rich: true) { seen.record($0.text); return $0.text }
        let origin = ClipboardSnapshot(plainText: text, richRTFD: Data("x".utf8))
        _ = await TransformCoordinator.apply(rich, to: PasteDocument(origin: origin), scope: scope(text, 6, 4))
        #expect(seen.text == text)
        #expect(!TransformCoordinator.canScope(rich) && !TransformCoordinator.canScope(Arm()) && TransformCoordinator.canScope(upper))
        let (_, _, span) = await TransformCoordinator.apply(Arm(), to: doc(text), scope: scope(text, 6, 4))
        #expect(span == nil)
    }

    @Test func outcomesKeepTheirMeaning() async {
        let text = "alpha BETA gamma"
        let same = await TransformCoordinator.apply(upper, to: doc(text), scope: scope(text, 6, 4))
        #expect(same.1 == .unchanged && same.2 == nil && same.0.cursor == 0)
        let failing = Fake { _ in throw TransformError.invalidInput("nope") }
        let failed = await TransformCoordinator.apply(failing, to: doc(text), scope: scope(text, 6, 4))
        #expect(failed.1 == .failed("nope") && failed.0.working == text && failed.2 == nil)
    }

    @Test func makeOnlyScopesARealSubrange() {
        let text = "alpha beta"
        #expect(TransformScope.make(selected: text.startIndex..<text.startIndex, in: text) == nil)   // caret
        #expect(TransformScope.make(selected: text.startIndex..<text.endIndex, in: text) == nil)     // select-all
        let r = Range(NSRange(location: 6, length: 4), in: text)!
        #expect(TransformScope.make(selected: r, in: text) == TransformScope(range: NSRange(location: 6, length: 4), expected: "beta"))
    }

    @Test func rankingFollowsASmallSelection() {
        let prose = "see https://example.com/x for details"
        let r = Range((prose as NSString).range(of: "https://example.com/x"), in: prose)!
        let s = TransformScope.make(selected: r, in: prose)
        #expect(TransformScope.rankingKinds(scope: s, documentKinds: [.markdown]).contains(.url))
        #expect(TransformScope.rankingKinds(scope: nil, documentKinds: [.markdown]) == [.markdown])
        let big = TransformScope(range: NSRange(location: 0, length: 9000), expected: String(repeating: "a", count: 9000))
        #expect(TransformScope.rankingKinds(scope: big, documentKinds: [.json]) == [.json])
    }
}
