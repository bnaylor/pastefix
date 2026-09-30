# Selection-scoped transforms (#25) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a single span of the buffer is selected, a transform changes only that span, and the result stays selected. ⌘Z and ⌘⇧Z restore both text and selection.

**Architecture:**
- The selection stays `PanelView` state. At apply time the view turns it into a `TransformScope`: a UTF-16 range plus the text it covers.
- `TransformCoordinator` validates the scope by content, runs the transform on the selected text only, splices the result, and returns the span after.
- `AppModel` publishes that span as `pendingSelection`, tagged with the buffer revision it indexes. The view's buffer-change handler consumes it: focus first, then select one turn later.
- Undo steps record the spans before and after for re-selection.

**Tech Stack:** Swift 6, SwiftUI (macOS 15 `TextEditor(text:selection:)`), Swift Testing, SwiftPM (`PastefixCore`, `PastefixAppCore`), the Xcode app target plus hosted app tests (`scripts/test-app.sh`).

**Spec:** `docs/specs/2026-09-29-pastefix-v2-selection-scoped-transforms.md`

## Global Constraints

- Scopes only for a **single, non-empty range that is not the whole buffer**. A caret, multi-range (⌘-drag), select-all, an image entry or no editor → whole buffer, as today.
- Whole-only transforms (`requiresRichInput`, `OutputModeTransformer`, not `acceptedForms.contains(.text)`) ignore the scope and run on the whole buffer.
- Scope ranges are **UTF-16 `NSRange`**, never `String.Index` carried across strings.
- Stale scope (the text at the range ≠ `expected`, or out of bounds) is **refused**: `"The selection changed before <name> could run. Select the text again."` The document is untouched.
- Cap refusal keeps the existing shape: `"<name> is limited to <ByteLimit.describe(n)> of text."`, measured on the selection.
- Hint text: `"Applies to selection"`. Whole-only marker: `"whole buffer"`.
- Palette ranking by selection only when the selection is ≤ **8 KB** (`8 * 1024` UTF-8 bytes). Otherwise the document's kinds.
- `pendingSelection` is the **only** owner of post-apply, undo and redo re-selection. `requestedSelection` and `resetSecretSelection()` don't touch it.
- One undo step per scoped transform. A scoped no-op pushes nothing and registers nothing (existing #111 rule).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv`.

## Review Focus

1. **Emoji or multi-byte text at a selection edge:** the splice must not corrupt surrogate pairs, and the span after must cover exactly the new text (Task 1 `emojiEdges`).
2. **A transform returning empty text for the selection:** the span after is a caret at the splice point, not a crash or a wrong range (Task 1 `emptyResultIsACaret`).
3. **Chaining:** a second scoped apply on the span the first one selected must transform exactly that span (Task 2 `chainOnTheNewSpan`).
4. **Typing into the transformed span, then ⌘Z ⌘Z ⌘⇧Z:** re-selection must never select out of bounds or trap. A span that no longer fits is dropped (Task 3 `redoAfterTypingDoesNotTrap`).
5. **A session boundary between apply and consumption:** a pending span from the old session must never select in the new one (Task 2 `boundaryClearsPending`).

---

### Task 1: `TransformScope` and the scoped coordinator

**Files:**
- Create: `Sources/PastefixAppCore/TransformScope.swift`
- Modify: `Sources/PastefixAppCore/TransformCoordinator.swift` (add `canScope`, the scoped `apply` overload, and a shared error-message helper)
- Test: `Tests/PastefixAppCoreTests/TransformScopeTests.swift`

**Interfaces:**
- Produces:
  - `public struct TransformScope: Sendable, Equatable { public let range: NSRange; public let expected: String; public init(range:expected:) }`
  - `public static func TransformScope.make(selected: Range<String.Index>, in text: String) -> TransformScope?`
  - `func TransformScope.selected(in text: String) -> Range<String.Index>?` (internal)
  - `public static let TransformScope.rankingLimitBytes = 8 * 1024`
  - `public static func TransformScope.rankingKinds(scope: TransformScope?, documentKinds: Set<ContentKind>) -> Set<ContentKind>`
  - `public static func TransformCoordinator.canScope(_ transformer: any Transformer) -> Bool`
  - `public static func TransformCoordinator.apply(_ transformer: any Transformer, to document: PasteDocument, scope: TransformScope?) async -> (PasteDocument, TransformOutcome, NSRange?)`: the third element is the span after, non-nil only when a scoped apply pushed an entry.
  - `public static func TransformCoordinator.staleSelectionMessage(_ name: String) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TransformScopeTests 2>&1 | grep -E "error:|Test run" | head -5`
Expected: compile errors, `cannot find 'TransformScope' in scope`. Then stub the type and the overload (Step 3's signatures, with bodies that return `nil`, or `(document, .unchanged, nil)`), and re-run. Expected: behavioural failures across the suite.

- [ ] **Step 3: Implement `TransformScope`**

```swift
import Foundation
import PastefixCore

/// The span a transform is scoped to (#25): a UTF-16 range, and the text it covered when the user
/// chose the transform. UTF-16, never `String.Index`: an index is only meaningful in the string it
/// was taken from, and applying one to another string traps (the #111 caret crash). The text is
/// how a stale range is caught: ending an IME composition can change the buffer between the click
/// and the apply, and a range can still convert in bounds while covering different characters.
public struct TransformScope: Sendable, Equatable {
    public let range: NSRange
    public let expected: String

    public init(range: NSRange, expected: String) {
        self.range = range
        self.expected = expected
    }

    /// The scope for `selected` in `text`, or nil when it doesn't scope: a caret (empty), the whole
    /// buffer (select-all is the unscoped case), or a range that isn't expressible in `text`.
    public static func make(selected: Range<String.Index>, in text: String) -> TransformScope? {
        guard !selected.isEmpty, TextRangeClamp.remap(selected, from: text, to: text) != nil else { return nil }
        let ns = NSRange(selected, in: text)
        guard ns.length > 0, ns.length < (text as NSString).length else { return nil }
        return TransformScope(range: ns, expected: String(text[selected]))
    }

    /// The range this scope covers in `text` now, or nil when it's stale: out of bounds, off a
    /// character boundary, or covering something other than `expected`.
    func selected(in text: String) -> Range<String.Index>? {
        guard let r = Range(range, in: text), text[r] == expected else { return nil }
        return r
    }

    /// Selections up to this size rank the palette by their own content. Detection is ~40 ms at
    /// 64 KB (measured, debug and release) — a visible hitch as ⌘K opens — and linear, so ~5 ms here.
    public static let rankingLimitBytes = 8 * 1024

    /// The kinds the ⌘K palette ranks by: the selection's, when there is one within the limit, else
    /// the document's. Runs on the main actor, bounded by `rankingLimitBytes` (AGENTS.md exception).
    public static func rankingKinds(scope: TransformScope?, documentKinds: Set<ContentKind>) -> Set<ContentKind> {
        guard let scope, scope.expected.utf8.count <= rankingLimitBytes else { return documentKinds }
        return ContentDetector.detect(scope.expected)
    }
}
```

- [ ] **Step 4: Implement the coordinator overload**

In `TransformCoordinator.swift`, add these inside `public enum TransformCoordinator`, above the existing `apply(_:to:)`:

```swift
    /// Whether `transformer` can run on a selection. Rich transforms convert the origin's rich copy,
    /// output-mode transforms arm Save for the whole buffer, and image transforms don't take text:
    /// they run on the whole buffer even with a selection (#25).
    public static func canScope(_ transformer: any Transformer) -> Bool {
        !transformer.requiresRichInput
            && !(transformer is any OutputModeTransformer)
            && transformer.acceptedForms.contains(.text)
    }

    public static func staleSelectionMessage(_ name: String) -> String {
        "The selection changed before \(name) could run. Select the text again."
    }

    /// `apply(_:to:)` scoped to `scope` when there is one and the transformer can scope (#25): the
    /// transform sees only the selected text, its result is spliced back as one undo entry, and the
    /// third element is the span the result occupies (UTF-16), non-nil only when an entry was pushed.
    /// Without a usable scope it is exactly `apply(_:to:)`.
    public static func apply(
        _ transformer: any Transformer,
        to document: PasteDocument,
        scope: TransformScope?
    ) async -> (PasteDocument, TransformOutcome, NSRange?) {
        guard let scope, canScope(transformer), document.currentImage == nil else {
            let (doc, outcome) = await apply(transformer, to: document)
            return (doc, outcome, nil)
        }
        var doc = document
        let whole = doc.working
        guard let range = scope.selected(in: whole) else {
            return (doc, .failed(staleSelectionMessage(transformer.name)), nil)
        }
        let selected = String(whole[range])
        guard selected.utf8.count <= transformer.maxInputBytes else {
            return (doc, .failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of text."), nil)
        }
        let input = TransformInput(text: selected, richRTFD: doc.origin.richRTFD)
        do {
            let output = try await Deadline.run(seconds: transformer.timeout) { try await transformer.transform(input) }
            switch output {
            case .nothingToDo(let sentence):
                return (doc, .nothingToDo(sentence), nil)
            case .image:
                return (doc, .failed("\(transformer.name) produced an image, which can't replace selected text."), nil)
            case .text(let result):
                let spliced = String(whole[..<range.lowerBound]) + result + String(whole[range.upperBound...])
                guard spliced != whole else { doc.pushState(spliced); return (doc, .unchanged, nil) }
                doc.pushState(spliced)
                return (doc, .applied, NSRange(location: scope.range.location, length: (result as NSString).length))
            }
        } catch {
            return (doc, .failed(failureMessage(error)), nil)
        }
    }

    /// The `.failed` sentence for an error a transform threw — shared by both `apply` paths.
    static func failureMessage(_ error: Error) -> String {
        switch error {
        case let error as TransformError: return message(for: error)
        case is CancellationError: return "The transform was cancelled."
        default: return error.localizedDescription
        }
    }
```

Then, in the existing `apply(_:to:)`, replace its three `catch` clauses with one:

```swift
        } catch {
            return (doc, .failed(failureMessage(error)))
        }
```

(`pushState` on equal text adds no entry but re-requests detection, the existing rule its comment in `apply(_:to:)` explains. The `.unchanged` branch keeps that.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "TransformScopeTests|TransformCoordinatorTests" 2>&1 | grep -E "✘|Test run with"`
Expected: `✔ … passed`, no `✘`.

- [ ] **Step 6: Run the package suite and commit**

Run: `swift test 2>&1 | grep -E "✘|Test run with" | tail -1`
Expected: passed, with 1 known issue (the Vision small-text pin).

```bash
git add Sources/PastefixAppCore/TransformScope.swift Sources/PastefixAppCore/TransformCoordinator.swift Tests/PastefixAppCoreTests/TransformScopeTests.swift
git commit -m "feat: TransformCoordinator can scope a transform to a selection (#25)" -m "TransformScope carries a UTF-16 range and the text it covered; the scoped apply validates it by content, runs the transform on the selection, splices the result as one entry and returns the span after. Whole-only transforms ignore the scope; a stale scope is refused." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 2: `AppModel` scoped apply, `pendingSelection`, and undo spans

**Files:**
- Modify: `Pastefix/Pastefix/AppModel.swift`: `apply`, `TransformStep`, `stepBack`, `stepForward`, `resetUndo`, and a new `PendingSelection`.
- Test: `Pastefix/PastefixTests/SelectionScopeModelTests.swift`

**Interfaces:**
- Consumes: `TransformScope`, `TransformCoordinator.apply(_:to:scope:)`, and `staleSelectionMessage` from Task 1.
- Produces:
  - `struct PendingSelection: Equatable { let range: NSRange; let revision: Int }` (internal, in `AppModel.swift`)
  - `@Published var pendingSelection: PendingSelection?` on `AppModel`
  - `func apply(_ transformer: any Transformer, scope: TransformScope? = nil)`, with existing callers unchanged

- [ ] **Step 1: Write the failing tests** (unhosted: no window, so nothing consumes `pendingSelection`)

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test \"|Test run with" | head -5`
Expected: compile errors (`extra argument 'scope'`, `cannot find 'PendingSelection'`). After stubbing `PendingSelection`, `pendingSelection` and the `scope:` parameter (ignored), expected: behavioural failures in `scopedApplyPublishesTheSpan`, `staleScopeIsRefused`, `chainOnTheNewSpan`, `boundaryClearsPending`.

- [ ] **Step 3: Implement**

In `AppModel.swift`, add the type above `@MainActor final class AppModel`:

```swift
/// A span to select once the buffer it indexes is on screen (#25): after a scoped apply, and on the
/// undo and redo of one. UTF-16, with the `detectionRevision` of the buffer it belongs to, so the
/// view selects it only in that buffer. The single owner of post-apply selection: carried by
/// `PanelView.carrySelection`, never `requestedSelection` (which the landing path clears).
struct PendingSelection: Equatable {
    let range: NSRange
    let revision: Int
}
```

Add the property beside `requestedSelection`:

```swift
    /// See `PendingSelection`. Consumed (and cleared) by `PanelView`; cleared at session boundaries.
    @Published var pendingSelection: PendingSelection?
```

Change `apply`'s signature and landing. Replace `func apply(_ transformer: any Transformer) {` with:

```swift
    /// `scope`: the selected span to transform instead of the whole buffer (#25), taken by the view
    /// before this call. Checked by content after `settleComposition()`, which can change the text.
    func apply(_ transformer: any Transformer, scope: TransformScope? = nil) {
```

Replace `let (updated, outcome) = await TransformCoordinator.apply(transformer, to: current)` with:

```swift
            let (updated, outcome, span) = await TransformCoordinator.apply(transformer, to: current, scope: scope)
```

Replace the registration line `self.registerUndo(TransformStep(name: transformer.name, generation: generation))` with:

```swift
                self.registerUndo(TransformStep(name: transformer.name, generation: generation,
                                                before: span == nil ? nil : scope?.range, after: span))
```

And immediately after `self.resetSecretSelection()`, add:

```swift
            // After the reset, not before: `resetSecretSelection()` clears `requestedSelection`, and
            // the span is its own channel anyway (see `PendingSelection`).
            if let span { self.pendingSelection = PendingSelection(range: span, revision: updated.detectionRevision) }
```

Extend `TransformStep`:

```swift
    private struct TransformStep {
        let name: String
        let generation: Int
        /// The scoped span before and after (#25), for re-selection on ⌘Z and ⌘⇧Z. Nil when unscoped.
        var before: NSRange? = nil
        var after: NSRange? = nil
    }
```

In `stepBack`, after `undo()`:

```swift
        if let before = step.before, let doc = document {
            pendingSelection = PendingSelection(range: before, revision: doc.detectionRevision)
        }
```

In `stepForward`, after `redo()`:

```swift
        if let after = step.after, let doc = document {
            pendingSelection = PendingSelection(range: after, revision: doc.detectionRevision)
        }
```

In `resetUndo()`, add as its first line:

```swift
        pendingSelection = nil
```

- [ ] **Step 4: Run to verify they pass**

Run: `scripts/test-app.sh 2>&1 | grep -E "✘ Test \"|Test run with" | head -5`
Expected: `✔ Test run with … passed`.

- [ ] **Step 5: Commit**

```bash
git add Pastefix/Pastefix/AppModel.swift Pastefix/PastefixTests/SelectionScopeModelTests.swift
git commit -m "feat: AppModel applies a scope and publishes the span to select (#25)" -m "pendingSelection (span + revision) is the single owner of post-apply, undo and redo re-selection; set after resetSecretSelection, recorded on the undo step, cleared at session boundaries." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 3: The view: scope, hint, ranking, consuming the span, docs

**Files:**
- Create: `Pastefix/Pastefix/SelectionScope.swift` (the pure `TextSelection` → scope predicate)
- Modify: `Pastefix/Pastefix/PanelView.swift` (`currentScope`, `carrySelection`, passing `scope` down)
- Modify: `Pastefix/Pastefix/CommandPaletteView.swift` (the `scope` input, hint, whole-buffer subtitle, ranking, apply)
- Modify: `Pastefix/Pastefix/SidebarView.swift` (the `scope` input, hint, whole-buffer suffix, apply)
- Modify: `AGENTS.md` (entries, and the detection-rule exception); `README.md` (a "Transforming a selection" subsection)
- Test: `Pastefix/PastefixTests/SelectionScopeTests.swift`

**Interfaces:**
- Consumes: Task 1's `TransformScope` and `canScope`. Task 2's `pendingSelection`, `PendingSelection` and `apply(_:scope:)`.
- Produces:
  - `enum SelectionScope { static func scope(for selection: TextSelection?, in text: String) -> TransformScope? }`
  - `SidebarView(model:scope:)`
  - `CommandPaletteView(model:scope:onClose:)`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Bracket: Transformer {
    let id = "test.bracket"; let name = "Bracket"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { "[" + input.text + "]" }
}

/// #25, view half: the scoping predicate, and the span selected after apply, ⌘Z and ⌘⇧Z.
@MainActor
@Suite("selection-scoped transforms, view (#25)")
struct SelectionScopeTests {
    private func host(_ f: ModelFixture) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func textView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView, t.isEditable { return t }
        for sub in view.subviews { if let t = textView(in: sub) { return t } }
        return nil
    }
    private func scope(_ text: String, _ location: Int, _ length: Int) -> TransformScope {
        TransformScope.make(selected: Range(NSRange(location: location, length: length), in: text)!, in: text)!
    }
    private func sendUndo(_ window: NSWindow, redo: Bool = false) -> Bool {
        (window.firstResponder ?? window).tryToPerform(Selector(redo ? "redo:" : "undo:"), with: nil)
    }

    @Test func onlyASingleRealSubrangeScopes() {
        let text = "alpha beta"
        let beta = Range(NSRange(location: 6, length: 4), in: text)!
        #expect(SelectionScope.scope(for: TextSelection(range: beta), in: text)?.expected == "beta")
        #expect(SelectionScope.scope(for: nil, in: text) == nil)
        #expect(SelectionScope.scope(for: TextSelection(range: text.startIndex..<text.endIndex), in: text) == nil)
        #expect(SelectionScope.scope(for: TextSelection(insertionPoint: text.startIndex), in: text) == nil)
        let alpha = Range(NSRange(location: 0, length: 5), in: text)!
        let multi = TextSelection(ranges: RangeSet([alpha, beta]))
        #expect(SelectionScope.scope(for: multi, in: text) == nil, "multi-range runs on the whole buffer")
    }

    @Test func theNewSpanIsSelectedAndUndoRedoReselect() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "alpha beta gamma" && f.model.undoManager != nil })
        let editor = try #require(textView(in: window.contentView!))
        f.model.apply(Bracket(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { editor.string == "alpha [beta] gamma" && editor.selectedRange() == NSRange(location: 6, length: 6) },
                "selected \(editor.selectedRange())")
        #expect(f.model.pendingSelection == nil, "consumed")
        #expect(sendUndo(window))
        #expect(await f.eventually { editor.string == "alpha beta gamma" && editor.selectedRange() == NSRange(location: 6, length: 4) },
                "after ⌘Z \(editor.selectedRange())")
        #expect(sendUndo(window, redo: true))
        #expect(await f.eventually { editor.string == "alpha [beta] gamma" && editor.selectedRange() == NSRange(location: 6, length: 6) },
                "after ⌘⇧Z \(editor.selectedRange())")
    }

    /// The measured failure: without the pending span, `carrySelection` keeps raw offsets after a
    /// length change and selects the wrong characters. Shorter result, span at the end of the text.
    @Test func shorterResultSelectsExactlyTheNewText() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "     aaa bbb ccc", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "     aaa bbb ccc" && f.model.undoManager != nil })
        let editor = try #require(textView(in: window.contentView!))
        let dropFirst = TestTransformer(name: "Drop") { String($0.text.dropFirst()) }
        f.model.apply(dropFirst, scope: scope("     aaa bbb ccc", 13, 3))
        #expect(await f.eventually { editor.string == "     aaa bbb cc" && editor.selectedRange() == NSRange(location: 13, length: 2) },
                "selected \(editor.selectedRange())")
    }

    /// Review Focus 4: typing into the transformed span, then ⌘Z ⌘Z ⌘⇧Z — the re-selection is always
    /// in bounds and never traps. Typing goes in its own undo group, as its key event would give it
    /// (nothing closes an automatic group in a test host, and registering outside one throws).
    @Test func redoAfterTypingDoesNotTrap() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "alpha beta gamma", richRTFD: nil))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.textView(in: window.contentView!)?.string == "alpha beta gamma" && f.model.undoManager != nil })
        let editor = try #require(textView(in: window.contentView!))
        let um = try #require(f.model.undoManager)
        f.model.apply(Bracket(), scope: scope("alpha beta gamma", 6, 4))
        #expect(await f.eventually { editor.string == "alpha [beta] gamma" && !f.model.isApplying })
        if um.groupingLevel > 0 { um.endUndoGrouping() }
        um.beginUndoGrouping()
        editor.insertText(" and more", replacementRange: NSRange(location: 18, length: 0))
        um.endUndoGrouping()
        #expect(await f.eventually { f.model.document?.working == "alpha [beta] gamma and more" })
        #expect(sendUndo(window))                            // the typing
        #expect(sendUndo(window))                            // the transform: re-selects (6,4)
        #expect(await f.eventually { editor.string == "alpha beta gamma" })
        #expect(sendUndo(window, redo: true))                // the transform again: re-selects (6,6)
        #expect(await f.eventually {
            NSMaxRange(editor.selectedRange()) <= (editor.string as NSString).length
                && editor.selectedRange() == NSRange(location: 6, length: 6)
        }, "selected \(editor.selectedRange()) in \(editor.string.debugDescription)")
    }
}

private struct TestTransformer: Transformer {
    let id = "test.t"; let name: String; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let body: @Sendable (TransformInput) -> String
    init(name: String, _ body: @escaping @Sendable (TransformInput) -> String) { self.name = name; self.body = body }
    func apply(_ input: TransformInput) async throws -> String { body(input) }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test \"|Test run with" | head -8`
Expected: `cannot find 'SelectionScope'`. After a stub (`static func scope(...) -> TransformScope? { nil }`), expected: `onlyASingleRealSubrangeScopes` fails; `theNewSpanIsSelectedAndUndoRedoReselect` and `shorterResultSelectsExactlyTheNewText` fail on the selected range (nothing consumes the pending span yet).

- [ ] **Step 3: Implement `SelectionScope`**

```swift
import SwiftUI
import PastefixAppCore

/// Whether the editor's selection scopes a transform (#25), and to what: exactly one non-empty range
/// that isn't the whole buffer. A caret, a multi-range selection (⌘-drag) and select-all run on the
/// whole buffer. The one predicate behind both the "Applies to selection" hint and apply, so the two
/// can't disagree.
enum SelectionScope {
    static func scope(for selection: TextSelection?, in text: String) -> TransformScope? {
        guard case .selection(let range) = selection?.indices else { return nil }
        return TransformScope.make(selected: range, in: text)
    }
}
```

- [ ] **Step 4: `PanelView`: the current scope, passing it down, and consuming the span**

Add below `selectionBinding`:

```swift
    /// The scope a transform chosen now would get (#25): the editor's own selection, never the
    /// binding getter's (mid-composition that returns the marked range). Nil while an image is
    /// showing or the editor isn't on screen.
    private var currentScope: TransformScope? {
        guard let document = model.document, !document.displaysAsImage, !document.displaysAsLargeText || showLargeTextAnyway,
              !isPreviewing else { return nil }
        return SelectionScope.scope(for: editorSelection, in: document.working)
    }
```

Change the two construction sites: `SidebarView(model: model)` becomes `SidebarView(model: model, scope: currentScope)`, and `CommandPaletteView(model: model, onClose: closePalette)` becomes `CommandPaletteView(model: model, scope: currentScope, onClose: closePalette)`.

Replace the start of `carrySelection(from:to:)` (before its `guard let range = firstRange…`) with the consume step:

```swift
    private func carrySelection(from previous: String, to current: String) {
        // A scoped apply, or the undo/redo of one, names the span to select (#25). It wins over
        // remapping — which keeps raw offsets and, after a length change, lands on the wrong
        // characters (measured) — but only in the buffer it indexes.
        if let pending = model.pendingSelection {
            model.pendingSelection = nil
            if pending.revision == model.document?.detectionRevision,
               !isPaletteOpen, !isHistoryOpen, !isUploadOpen, !isPreviewing,
               let range = Range(pending.range, in: current) {
                let selection = TextSelection(range: range)
                editorSelection = selection
                // Focus, then select a turn later: an NSTextView becoming first responder restores
                // the selection it resigned with (#111 pass 5), which would overwrite this one.
                focusEditorUnlessRefusedImage()
                Task { @MainActor in
                    if model.document?.working == current { editorSelection = selection }
                }
                return
            }
        }
        guard let range = firstRange(of: editorSelection) else { return }
```

(The remaining body of `carrySelection` is unchanged.)

- [ ] **Step 5: `SidebarView`: scope, hint, suffix, apply**

Add a stored property below `@ObservedObject var model: AppModel`:

```swift
    /// The selection a transform chosen here applies to (#25), or nil for the whole buffer.
    let scope: TransformScope?
```

At the top of the `List { … }`, before the `if sections.isEmpty` block, add:

```swift
            if scope != nil {
                Text("Applies to selection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Change the button action `model.apply(transformer)` to `model.apply(transformer, scope: scope)`, and the label's `Text(transformer.name)` to:

```swift
                            Text(scope != nil && !TransformCoordinator.canScope(transformer)
                                 ? "\(transformer.name) — whole buffer" : transformer.name)
```

- [ ] **Step 6: `CommandPaletteView`: scope, hint, subtitle, ranking, apply**

Add a stored property below `@ObservedObject var model: AppModel`:

```swift
    /// The selection a transform chosen here applies to (#25), or nil for the whole buffer.
    let scope: TransformScope?
```

Change `.onAppear { kindsSnapshot = model.document?.detectedKinds ?? [] }` to:

```swift
        .onAppear {
            kindsSnapshot = TransformScope.rankingKinds(scope: scope, documentKinds: model.document?.detectedKinds ?? [])
        }
```

In the footer `HStack`, after the `if !items.isEmpty { … }` hint labels and before `Text("esc Close")`, add:

```swift
                if scope != nil { Text("Applies to selection") }
```

In `row(_:isSelected:)`, replace the subtitle `Text(result.transformer.category ?? TransformCategory.scripts)` with:

```swift
                Text((result.transformer.category ?? TransformCategory.scripts)
                     + (scope != nil && !TransformCoordinator.canScope(result.transformer) ? " · whole buffer" : ""))
```

In `apply(_:_:)`, change `model.apply(transformer)` to `model.apply(transformer, scope: scope)`.

- [ ] **Step 7: Run to verify they pass**

Run: `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test \"|Test run with" | head -5`
Expected: `✔ Test run with … passed`. Also: `swift test 2>&1 | grep -E "✘|Test run with" | tail -1`, which should pass.

- [ ] **Step 8: Docs**

`AGENTS.md`:
- **Detection rule.** Line 252 is the bullet beginning `- **Session text is scanned off the main actor.**`. Append to the end of that bullet: ` ONE bounded exception (#25): the ⌘K palette ranks by a selection's kinds via TransformScope.rankingKinds on the main actor, only for selections ≤ 8 KB (detection measured ~40 ms at 64 KB, linear → ~5 ms), because kinds landing after the palette opened would reorder rows under the cursor.`
- **AppCore file map.** Add a line after the `TransformCoordinator.swift` entry: `    TransformScope.swift              # #25: a scope = UTF-16 NSRange + the text it covered; make() rejects a caret/select-all/unexpressible range; selected(in:) validates by CONTENT (a range can convert in bounds and cover different text after settleComposition); rankingKinds (≤ 8 KB)`
- **App file map.** Add after the `PanelView.swift` entry: `    SelectionScope.swift              # #25: the one predicate (single, non-empty, not-whole range) behind both the "Applies to selection" hint and apply`
- **`AppModel` entry.** Add to it: `pendingSelection (#25): the single owner of post-apply/undo/redo re-selection — UTF-16 span + the revision it indexes, consumed by PanelView.carrySelection in place of remapping (focus, then select a turn later), never requestedSelection (the landing path clears that); cleared in resetUndo.`

`README.md`: under `### Finding transforms` (the Using Pastefix section), add a paragraph:

```markdown
**Transforming a selection.** Select part of the text first and a transform changes only that part: the palette and sidebar say **Applies to selection**, and the result stays selected so you can run another transform on it. ⌘Z puts the original text back and selects it again. A caret, select-all or a multi-range (⌘-drag) selection transforms the whole buffer, as do the three rich-text transforms (Rich → Plain Text, Rich → Markdown, Markdown → Rich Text), which are marked **whole buffer** while text is selected. If the text changed between selecting and applying (for example, an unfinished accent was discarded), the transform stops and asks you to select again. With a selection of 8 KB or less, the palette lists the transforms that fit the selected text first.
```

- [ ] **Step 9: Commit**

```bash
git add Pastefix/Pastefix/SelectionScope.swift Pastefix/Pastefix/PanelView.swift Pastefix/Pastefix/CommandPaletteView.swift Pastefix/Pastefix/SidebarView.swift Pastefix/PastefixTests/SelectionScopeTests.swift AGENTS.md README.md
git commit -m "feat: transforms apply to the selection, with a hint; the result stays selected (#25)" -m "One predicate (SelectionScope) drives the hint and apply. PanelView consumes pendingSelection in carrySelection instead of remapping, focusing first and selecting a turn later. The palette ranks by a selection of 8 KB or less. Docs: AGENTS (with the bounded detection exception) and README." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### After the tasks

- A full-branch review, then the PR (`Resolves #25`, base `main`).
- The GUI pass by `work`, using its `AXSelectedTextRange` probe to assert exact spans. The list is in the spec's Testing section:
  - the hint and the whole-buffer marks;
  - ⌘K and a sidebar click keeping the selection;
  - chaining;
  - ⌘Z/⌘⇧Z re-selection;
  - a dead-key composition beside the selection;
  - multi-range and select-all.
