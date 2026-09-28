---
type: plan
status: implemented
id: 2026-09-28-pastefix-v2-image-transforms-part1
title: Pastefix v2 — Image Transforms, part 1 (Plan 20, #82)
description: Transforms that take an image and produce an image or text; PasteDocument history of text-or-image entries; a transient transform note; Strip Image Metadata on ImageSanitizer with ImageMetadata.inspect.
tags: [pastefix, macos, swift, images, transforms, privacy]
timestamp: 2026-09-28T12:00:00Z
---

# Image Transforms, part 1 (Plan 20) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let ⌘K transforms take an image and produce an image or text, and ship "Strip Image Metadata" (#82) on it.

**Architecture:** `PasteDocument`'s undo history becomes `[Entry]` (`.text` | `.image`) with one cursor, and `displaysAsImage` follows the current entry. `Transformer` gains a defaulted `transform(_:) -> TransformOutput` requirement; image transforms conform to a refining `ImageTransformer` whose synchronous body runs on one process-wide `SingleSlotLane`. The coordinator gates, bounds and pushes; `AppModel` shows a transient transform note.

**Tech Stack:** Swift 6, SwiftPM (`PastefixCore`, `PastefixAppCore`), SwiftUI app target, Swift Testing, ImageIO.

**Spec:** `docs/specs/2026-09-28-pastefix-v2-image-transforms.md` (Part 1). Read it before starting; this plan argues from it.

## Global Constraints

- Branch `feat/82-image-transforms`. One commit per task; commit messages end with the repo's `Co-Authored-By` / `Claude-Session` lines.
- **Clean build before the first test run after Task 2** (`rm -rf .build` and the app's DerivedData): adding a protocol requirement shifts witness-table slots, and a stale build crashed in Plan 14 (SIGSEGV).
- Package tests: `swift test`. App tests: `scripts/test-app.sh`. Both must be green at every commit. The package suite has 1 known issue (Vision, pre-existing).
- No existing transform, script, JS transform or preset may change in code or behaviour. Their existing suites pin this.
- Pixel ceiling: `PixelLimits.maxConvertiblePixels` (25 MP) in Core, `ImageBytes.maxConvertiblePixels` in AppCore (the same value). Never downscale.
- Image transform timeout: 10 s.
- User-facing strings, verbatim:
  - `"Removed location and camera details."` (built by `ImageMetadata.removedMessage`, see Task 6)
  - `"This image has no location or camera details to remove."`
  - Over the ceiling: `"<Name> works on images up to <limit>; this one is <size>."` using `ImageBytes.megapixelLabel`.
  - Bad image output: `"<Name> didn't produce a usable image."`
- AGENTS.md is updated in the same PR (Definition of Done). Comments explain *why*; match the surrounding density.

## Review Focus

1. **A PNG with both GPS and a screenshot `UserComment`** must still report location. The `Screenshot` exemption applies to that one key only. (Task 6)
2. **An image over 25 MP**, a verbatim PNG, which a session can hold: Strip is refused with the size and the limit, and nothing is pushed. (Task 4)
3. **A mixed session** (text plus an attached image) does not offer Strip: its current entry is text. (Task 4)
4. **A stale editor write-back after ⌘Z onto an image** changes nothing, and the next push still works. (Task 3)
5. **The transform note after ⌘Z** is gone, so it can't claim "Removed location…" over the original image. (Task 5)

---

### Task 1: Move `SingleSlotLane` to `PastefixCore`

The image-transform lane (Task 2) lives in Core, where `ImageSanitizer` and the transform registry are, and Core cannot import AppCore. The lane depends on Foundation only.

**Files:**
- Move: `Sources/PastefixAppCore/SingleSlotLane.swift` → `Sources/PastefixCore/SingleSlotLane.swift`
- Move: `Tests/PastefixAppCoreTests/SingleSlotLaneTests.swift` → `Tests/PastefixCoreTests/SingleSlotLaneTests.swift`
- Modify: `Sources/PastefixAppCore/SessionPreparationCache.swift` (add `import PastefixCore`)

**Interfaces:**
- Produces: `PastefixCore.SingleSlotLane<Input, Output>` (unchanged API); its test hooks `waitingGeneration` and `isRunningWithNoneWaiting` become `package` so AppCore's tests still reach them.

- [ ] **Step 1: Move the files**

```bash
git mv Sources/PastefixAppCore/SingleSlotLane.swift Sources/PastefixCore/SingleSlotLane.swift
git mv Tests/PastefixAppCoreTests/SingleSlotLaneTests.swift Tests/PastefixCoreTests/SingleSlotLaneTests.swift
```

- [ ] **Step 2: Fix access and imports**

In `Sources/PastefixCore/SingleSlotLane.swift`, change the two test hooks from internal to `package`:

```swift
    /// For tests: the generation of the job currently waiting, if any.
    package var waitingGeneration: Int? { lock.lock(); defer { lock.unlock() }; return waiting?.generation }
    /// For tests: a job has been taken off the slot and is running (or about to), with none
    /// waiting — so the next arrival waits rather than displacing it.
    package var isRunningWithNoneWaiting: Bool { lock.lock(); defer { lock.unlock() }; return draining && waiting == nil }
```

Also update the doc comment's first line of provenance: it now lives in Core "so image transforms (Plan 20) can use it from the registry's module".

In `Tests/PastefixCoreTests/SingleSlotLaneTests.swift`, change `@testable import PastefixAppCore` to `@testable import PastefixCore`.

In `Sources/PastefixAppCore/SessionPreparationCache.swift`, add `import PastefixCore` below `import Foundation`.

- [ ] **Step 3: Build and run both suites**

Run: `swift build && swift test 2>&1 | grep "Test run with"` then `scripts/test-app.sh 2>&1 | grep -E "Test run with|error:"`
Expected: package 804 tests pass (1 known issue); app 26 pass. The SingleSlotLane suite now reports under PastefixCoreTests.

- [ ] **Step 4: Update AGENTS.md's layout**

Move the `SingleSlotLane.swift` row from the `PastefixAppCore` listing to the `PastefixCore` listing, unchanged except for: `(in Core since Plan 20, so image transforms can use it)`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor: move SingleSlotLane to PastefixCore for image transforms (Plan 20)"
```

---

### Task 2: The transform interface — image input, `TransformOutput`, `ImageTransformer`, the lane

**Files:**
- Modify: `Sources/PastefixCore/Transformer.swift`
- Create: `Sources/PastefixCore/ImageTransformer.swift`
- Test: `Tests/PastefixCoreTests/ImageTransformerTests.swift`

**Interfaces:**
- Produces:
  - `TransformInput(text: String, richRTFD: Data? = nil, image: Data? = nil)`, with `public let image: Data?`
  - `public enum TransformOutput: Sendable, Equatable { case text(String); case image(Data, note: String? = nil); case nothingToDo(String) }`
  - `Transformer.transform(_ input: TransformInput) async throws -> TransformOutput` (a protocol **requirement**), defaulting to `.text(try await apply(input))`
  - `public protocol ImageTransformer: Transformer { var lane: ImageTransformLane.Lane { get }; func transformImage(_ png: Data) throws -> TransformOutput }`, whose extension supplies `lane = ImageTransformLane.shared`, `acceptedForms = [.image]`, `timeout = 10`, a throwing `apply`, and a `transform` that runs `transformImage` on `lane`
  - `public enum ImageTransformLane`: `typealias Lane`, `static let shared: Lane`, `static func makeLane(label: String) -> Lane`, `static func run(on lane: Lane, _ body: @escaping @Sendable () throws -> TransformOutput) async throws -> TransformOutput`; a displaced job throws `CancellationError`
  - **Why `lane` is a requirement:** all package tests share one process, so tests using the shared lane in parallel would displace each other's waiting jobs and fail with `CancellationError`. A task-local override would not survive `Deadline.run`, which detaches its body. So production transforms use `shared`, and every test stub supplies its own lane. It is a requirement, not an extension property, for the same dynamic-dispatch reason as `transform`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PastefixCoreTests/ImageTransformerTests.swift
import Testing
import Foundation
@testable import PastefixCore

private struct TextOnly: Transformer {
    let id = "test.text"; let name = "Text"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text.uppercased() }
}

private struct Flipper: ImageTransformer {
    let id = "test.image"; let name = "Flipper"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.flipper")
    func transformImage(_ png: Data) throws -> TransformOutput { .image(Data(png.reversed()), note: "flipped") }
}

private struct StrippedDefault: ImageTransformer {
    let id = "test.default-lane"; let name = "Default"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func transformImage(_ png: Data) throws -> TransformOutput { .nothingToDo("") }
}

@Suite("the image transform interface")
struct ImageTransformerTests {
    @Test("an ordinary transform's `transform` is its `apply`, as text")
    func defaultWrapsApply() async throws {
        let out = try await TextOnly().transform(TransformInput(text: "abc"))
        #expect(out == .text("ABC"))
    }

    // The coordinator calls through `any Transformer`. If `transform` were only an extension
    // method it would dispatch statically to the text default, and an image transform's own
    // body would never run.
    @Test("an image transform runs its own body through `any Transformer`")
    func dynamicDispatch() async throws {
        let t: any Transformer = Flipper()
        let out = try await t.transform(TransformInput(text: "", image: Data([1, 2, 3])))
        #expect(out == .image(Data([3, 2, 1]), note: "flipped"))
        #expect(t.acceptedForms == [.image] && t.timeout == 10)
    }

    @Test("a production image transform uses the shared lane; a stub can bring its own")
    func laneSelection() {
        #expect(StrippedDefault().lane === ImageTransformLane.shared)
        #expect(Flipper().lane !== ImageTransformLane.shared)
    }

    @Test("an image transform given no image refuses rather than guessing")
    func noImage() async {
        await #expect(throws: TransformError.self) {
            try await Flipper().transform(TransformInput(text: "abc"))
        }
    }

    @Test("a job displaced from the lane throws CancellationError and never runs")
    func displacedJob() async throws {
        let lane = ImageTransformLane.makeLane(label: "test.displaced")
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let first = Task { try await ImageTransformLane.run(on: lane) { started.signal(); gate.wait(); return .nothingToDo("first") } }
        #expect(started.wait(timeout: .now() + 5) == .success)
        let displaced = Task { try await ImageTransformLane.run(on: lane) { .nothingToDo("displaced") } }
        #expect(await eventually { lane.waitingGeneration != nil })
        let newest = Task { try await ImageTransformLane.run(on: lane) { .nothingToDo("newest") } }
        await #expect(throws: CancellationError.self) { try await displaced.value }
        gate.signal()
        #expect(try await first.value == .nothingToDo("first"))
        #expect(try await newest.value == .nothingToDo("newest"))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter ImageTransformerTests 2>&1 | grep -E "error:" | head -3`
Expected: compile errors (`TransformOutput`, `ImageTransformer`, `transform` unknown).

- [ ] **Step 3: Implement in `Transformer.swift`**

Replace `TransformInput`:

```swift
/// Content handed to a transform. `text` is the current working buffer — `""` when the session is
/// showing an image. `richRTFD` carries the original clipboard's rich representation as RTFD data
/// (Sendable); only `RichToPlain` and `RichToMarkdown` read it. `image` is the current image entry's
/// PNG, or nil when the session is showing text (Plan 20).
public struct TransformInput: Sendable {
    public let text: String
    public let richRTFD: Data?
    public let image: Data?

    public init(text: String, richRTFD: Data? = nil, image: Data? = nil) {
        self.text = text
        self.richRTFD = richRTFD
        self.image = image
    }
}

/// What a transform produced (Plan 20). Text and image results become the session's next undo
/// entry; `nothingToDo` pushes nothing and carries the sentence the user sees instead — how
/// Strip Image Metadata says there was nothing to remove, rather than silently re-encoding.
/// `note` on an image result is shown after it lands ("Removed location and camera details.").
public enum TransformOutput: Sendable, Equatable {
    case text(String)
    case image(Data, note: String? = nil)
    case nothingToDo(String)
}
```

In `protocol Transformer`, after `func apply(_ input: TransformInput) async throws -> String`, add:

```swift
    /// The transform's result as text or an image (Plan 20). A protocol **requirement**, not only
    /// an extension method: the coordinator calls through `any Transformer`, and an extension-only
    /// method would dispatch statically to the default below, so an image transform's own body
    /// would never run. Every text transform takes the default and is unchanged.
    func transform(_ input: TransformInput) async throws -> TransformOutput
```

In `extension Transformer`, add:

```swift
    func transform(_ input: TransformInput) async throws -> TransformOutput {
        .text(try await apply(input))
    }
```

- [ ] **Step 4: Create `ImageTransformer.swift`**

```swift
import Foundation

/// A transform whose input is the session's image (Plan 20). Its body is synchronous and runs on
/// `ImageTransformLane`: a CG decode cannot be cancelled, so a cancelled apply (Esc, a new
/// summon) keeps decoding, and without one process-wide lane repeated attempts would stack
/// decodes of hundreds of MB — the #46/#48 lesson.
public protocol ImageTransformer: Transformer {
    /// The lane this transform's body runs on: `ImageTransformLane.shared` for every real
    /// transform. A requirement so tests can give each stub its own — all package tests share one
    /// process, and stubs on the shared lane would displace each other's waiting jobs.
    var lane: ImageTransformLane.Lane { get }
    /// The transform itself, given the current image entry's PNG. Runs on the lane, off the
    /// main actor. The coordinator has already refused an image over the pixel ceiling.
    func transformImage(_ png: Data) throws -> TransformOutput
}

public extension ImageTransformer {
    var lane: ImageTransformLane.Lane { ImageTransformLane.shared }
    var acceptedForms: Set<ContentForm> { [.image] }
    /// A 20 MP decode alone is ~1 s; the text default of 3 s is too tight for decode + encode.
    var timeout: TimeInterval { 10 }

    /// Never called: the coordinator calls `transform`, and `acceptedForms` keeps an image
    /// transform out of text sessions. Throws rather than returning text nobody asked for.
    func apply(_ input: TransformInput) async throws -> String {
        throw TransformError.invalidInput("\(name) needs an image.")
    }

    func transform(_ input: TransformInput) async throws -> TransformOutput {
        guard let png = input.image else { throw TransformError.invalidInput("\(name) needs an image.") }
        return try await ImageTransformLane.run(on: lane) { try self.transformImage(png) }
    }
}

/// The one lane image transforms run down, process-wide: one running, one waiting, and a newer
/// job displaces a waiting one. It is the third such lane (history capture's `TIFFConversionSlot`
/// and upload preparation's are the others), so up to three uncancellable 25 MP decodes can run
/// at once — stated in the spec, and deliberately not merged: a transform displacing a waiting
/// upload preparation would strand that card in its `superseded` state.
public enum ImageTransformLane {
    /// One job: its body, run on the lane's queue.
    public struct Job: Sendable {
        let body: @Sendable () -> Result<TransformOutput, any Error>
    }
    public typealias Lane = SingleSlotLane<Job, Result<TransformOutput, any Error>>

    /// The lane every real image transform uses.
    public static let shared = makeLane(label: "net.scromp.Pastefix.image-transform")

    public static func makeLane(label: String) -> Lane { Lane(label: label) { $0.body() } }

    /// Runs `body` on `lane`. Throws `CancellationError` when a newer job displaced this one
    /// before it started — its caller has been superseded, so there is no one to answer.
    public static func run(on lane: Lane,
                           _ body: @escaping @Sendable () throws -> TransformOutput) async throws -> TransformOutput {
        let job = Job { Result { try body() } }
        guard let result = await lane.run(job, generation: lane.nextGeneration()) else {
            throw CancellationError()
        }
        return try result.get()
    }
}
```

- [ ] **Step 5: Clean build, then run the tests**

Run: `rm -rf .build && swift build 2>&1 | tail -1 && swift test --filter ImageTransformerTests 2>&1 | grep -E "✘|Test run with"`
Expected: `Test run with 5 tests ... passed`.

- [ ] **Step 6: Run everything**

Run: `swift test 2>&1 | grep "Test run with"`; `scripts/test-app.sh 2>&1 | grep -E "Test run with|error:"`
Expected: all green (809 package, 26 app). No existing transform's tests change.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: transforms can take an image and return text or an image (Plan 20)"
```

---

### Task 3: `PasteDocument` — a history of text-or-image entries

**Files:**
- Modify: `Sources/PastefixAppCore/PasteDocument.swift`
- Test: `Tests/PastefixAppCoreTests/PasteDocumentEntryTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `public enum PasteDocument.Entry: Sendable, Equatable { case text(String); case image(Data) }`
  - `public private(set) var entries: [Entry]` (replaces `history: [String]`, which nothing outside the type reads)
  - `public var currentEntry: Entry`
  - `public var currentImage: Data?`: the current entry's PNG if it is an image
  - `public let openedAsImage: Bool`: the init rule, fixed for the session
  - `public var displaysAsImage: Bool`: computed, `currentImage != nil`
  - `public var imagePNG: Data?`: `openedAsImage ? currentImage : origin.imagePNG`
  - `public var effectiveOutputMode: OutputMode`: `.plain` on an image entry, else `outputMode`
  - `public mutating func push(_ entry: Entry)`; `pushState(_ text: String)` becomes `push(.text(text))`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PastefixAppCoreTests/PasteDocumentEntryTests.swift
import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

@Suite("PasteDocument entries (Plan 20)")
struct PasteDocumentEntryTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    private let png2 = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9])
    private func imageDoc(text: String? = nil) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, imagePNG: png))
    }

    @Test("the first entry follows the init rule: image and no real text opens as an image")
    func firstEntry() {
        #expect(imageDoc().currentEntry == .image(png) && imageDoc().openedAsImage)
        #expect(imageDoc(text: "  \n").currentEntry == .image(png))
        let mixed = imageDoc(text: "caption")
        #expect(mixed.currentEntry == .text("caption") && !mixed.openedAsImage && !mixed.displaysAsImage)
        #expect(mixed.imagePNG == png, "a mixed session carries its image, as today")
    }

    @Test("an image result, then undo and redo, move the display with the entry")
    func pushImageUndoRedo() {
        var d = imageDoc()
        d.push(.image(png2))
        #expect(d.displaysAsImage && d.imagePNG == png2 && d.working == "")
        d.undo()
        #expect(d.imagePNG == png)
        d.redo()
        #expect(d.imagePNG == png2)
    }

    @Test("a text result replaces the image: Save writes the text only, and undo brings it back")
    func textReplacesImage() {
        var d = imageDoc()
        d.pushState("recognised")
        #expect(!d.displaysAsImage && d.working == "recognised" && d.imagePNG == nil)
        #expect(SavePayload(document: d).imagePNG == nil && SavePayload(document: d).text == "recognised")
        d.undo()
        #expect(d.displaysAsImage && d.imagePNG == png && SavePayload(document: d).imagePNG == png)
    }

    // pushState's guard compared text; on an image entry `working` is "" and pushing "" was
    // silently dropped.
    @Test("pushing empty text onto an image entry is a real push")
    func emptyTextOntoImage() {
        var d = imageDoc()
        d.pushState("")
        #expect(d.currentEntry == .text("") && d.canUndo)
    }

    // The TextEditor's binding calls setWorking; an IME commit or end-of-editing write can land
    // after ⌘Z has moved onto an image entry.
    @Test("a stale editor write-back on an image entry changes nothing")
    func staleWriteBack() {
        var d = imageDoc()
        d.pushState("text")
        d.undo()
        d.setWorking("late keystroke")
        #expect(d.currentEntry == .image(png) && d.working == "" && d.workingByteCount == 0)
        d.redo()
        #expect(d.working == "text")
    }

    @Test("isUnedited compares against the init rule's entry, image-first included")
    func isUnedited() {
        #expect(imageDoc().isUnedited)
        #expect(imageDoc(text: " ").isUnedited)
        var d = imageDoc(); d.push(.image(png2)); d.undo()
        #expect(!d.isUnedited, "a redo is pending")
    }

    // Output mode is document-wide and survives undo; on an image entry Save would take the
    // rendered-Markdown branch with working == "" and write empty HTML/RTF beside the PNG.
    @Test("an armed output mode is ignored on an image entry")
    func outputModeOnImage() {
        var d = imageDoc()
        d.pushState("# md")
        d.outputMode = .renderedMarkdown
        #expect(d.effectiveOutputMode == .renderedMarkdown)
        d.undo()
        #expect(d.effectiveOutputMode == .plain)
        d.redo()
        #expect(d.effectiveOutputMode == .renderedMarkdown)
    }

    @Test("byte counts count text only")
    func byteCounts() {
        var d = imageDoc()
        #expect(d.workingByteCount == 0 && !d.displaysAsLargeText)
        d.pushState("héllo")
        #expect(d.workingByteCount == "héllo".utf8.count)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter PasteDocumentEntryTests 2>&1 | grep -E "error:" | head -3`
Expected: compile errors (`push`, `currentEntry`, `openedAsImage`, `effectiveOutputMode` unknown).

- [ ] **Step 3: Implement**

In `PasteDocument.swift`:

1. Add the entry type at the top of the struct:

```swift
    /// One undo state: text, or an image (PNG bytes, never empty). Plan 20: transforms can turn
    /// one into the other, and one cursor walks both.
    public enum Entry: Sendable, Equatable {
        case text(String)
        case image(Data)
    }
```

2. Replace `public private(set) var history: [String]` with `public private(set) var entries: [Entry]`, and keep `historyByteCounts` (renamed `entryByteCounts`), where an image entry counts `0`.

3. Replace the `displaysAsImage` stored `let` and its init line with:

```swift
    /// The init rule, fixed for the session: the origin carried an image and no real text. Decides
    /// the first entry, which image `imagePNG` means, and whether rich transforms may run.
    public let openedAsImage: Bool
```

and in `init`:

```swift
        self.openedAsImage = origin.imagePNG != nil
            && (origin.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let first = Self.initialEntry(for: origin)
        self.entries = [first]
        self.entryByteCounts = [Self.byteCount(of: first)]
```

(remove the old `history`/`historyByteCounts` initialisation), with:

```swift
    /// What a fresh session over `origin` shows first. One rule, used by `init` and `isUnedited`.
    static func initialEntry(for origin: ClipboardSnapshot) -> Entry {
        let blank = (origin.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let png = origin.imagePNG, blank { return .image(png) }
        return .text(origin.plainText ?? "")
    }

    private static func byteCount(of entry: Entry) -> Int {
        if case .text(let text) = entry { return text.utf8.count }
        return 0
    }
```

4. Replace `working` and add the readers:

```swift
    public var currentEntry: Entry { entries[cursor] }
    /// The current entry's text, or `""` on an image entry — what an image session has always
    /// effectively had, so detection sees nothing there.
    public var working: String {
        if case .text(let text) = currentEntry { return text }
        return ""
    }
    /// The current entry's PNG when it is an image.
    public var currentImage: Data? {
        if case .image(let png) = currentEntry { return png }
        return nil
    }
    public var canRedo: Bool { cursor < entries.count - 1 }
```

5. Replace the doc comment and declaration of `displaysAsImage` with a computed property:

```swift
    /// True when the current entry is an image, so the panel shows `ImageSessionView`.
    ///
    /// **Derived, and safe to derive** — the opposite of what this doc said before Plan 20, so
    /// read why. The trap AGENTS.md records ("a derived display rule is a trap when what it
    /// derives from is editable") was deriving the display from *editable text*: in a mixed
    /// session, ⌘A then Delete blanked `working`, flipped the view to the image on that keystroke,
    /// and `setWorking` pushes no undo, so the editor could not come back. This derives from the
    /// *form of the current entry*, which only a transform, undo or redo changes — each an undo
    /// record — and `setWorking` is ignored on an image entry, so no keystroke can flip it. Clearing
    /// the text of a mixed session still leaves you in the editor: its entry is `.text("")`.
    /// `refresh` changes the form with no undo record, as it replaces the whole document, which it
    /// always has; `PanelView`'s `onChange(of: displaysAsImage)` handles the preview then.
    public var displaysAsImage: Bool { currentImage != nil }
```

6. Replace `imagePNG`:

```swift
    /// The image Save, upload and the view use. A session that **opened as an image** holds its
    /// image in its entries: the current one, and nil on a text entry — that is what makes OCR
    /// *replace* the image (Plan 20). A session that opened as text or mixed carries the origin's
    /// image through every text transform, as it always has.
    public var imagePNG: Data? { openedAsImage ? currentImage : origin.imagePNG }

    /// How Save writes this document right now. An armed mode is document-wide and survives undo,
    /// so on an image entry it is ignored: otherwise OCR → Markdown → Rich → ⌘Z would render
    /// `working` (`""`) and write empty HTML/RTF beside the PNG, which rich-aware targets prefer —
    /// an empty paste. Redo back onto the text entry arms it again.
    public var effectiveOutputMode: OutputMode { displaysAsImage ? .plain : outputMode }
```

7. Replace `isUnedited`'s body:

```swift
        entries.count == 1 && cursor == 0 && entries[0] == Self.initialEntry(for: origin) && outputMode == .plain
```

and change its doc's first bullet's `history` to `entries`.

8. Replace `pushState`, `setWorking`:

```swift
    /// Append a new state. Leaves `entries`/`cursor` untouched if it equals the current entry, but
    /// still invalidates detection (see below). Compares *entries*: on an image entry `working` is
    /// `""`, so comparing text would silently drop a pushed `.text("")`.
    public mutating func push(_ entry: Entry) {
        guard entry != currentEntry else { invalidateDetection(); return }
        entries = Array(entries.prefix(cursor + 1))
        entries.append(entry)
        entryByteCounts = Array(entryByteCounts.prefix(cursor + 1))
        entryByteCounts.append(Self.byteCount(of: entry))
        cursor = entries.count - 1
        invalidateDetection()
    }

    /// A text result (e.g. a transform's). A push is a discrete event even when it lands on text a
    /// prior `setWorking` already coalesced in, so the scheduler resyncs to what's actually working.
    public mutating func pushState(_ text: String) { push(.text(text)) }

    /// Coalesce a manual edit into the current text entry (no new entry). Ignored on an image
    /// entry: there is no editor on screen, and this is how a stale TextEditor write-back landing
    /// after ⌘Z moved onto an image is made harmless. Deliberately does **not** re-detect.
    public mutating func setWorking(_ text: String) {
        guard case .text = currentEntry else { return }
        entries[cursor] = .text(text)
        entryByteCounts[cursor] = text.utf8.count
    }
```

9. `workingByteCount` reads `entryByteCounts[cursor]`; its doc keeps the "stored, not measured" reason.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "PasteDocument|LargeText|SavePayload" 2>&1 | grep -E "✘|Test run with"`
Expected: all pass, including the existing `PasteDocumentImageTests`, whose mixed-session ⌘A+Delete test must stay green unchanged.

- [ ] **Step 5: Run everything**

Run: `swift test 2>&1 | grep "Test run with"`; `scripts/test-app.sh 2>&1 | grep -E "Test run with|error:"`
Expected: green. `AppModel` and `PanelView` compile unchanged, because `displaysAsImage`, `working`, `imagePNG` and `pushState` keep their names.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: PasteDocument's history holds text or image entries (Plan 20)"
```

---

### Task 4: The coordinator — gating, bounds, and pushing either entry

**Files:**
- Modify: `Sources/PastefixAppCore/TransformCoordinator.swift`
- Test: `Tests/PastefixAppCoreTests/ImageTransformCoordinatorTests.swift`

**Interfaces:**
- Consumes: `TransformOutput`, `ImageTransformer` (Task 2); `PasteDocument.Entry`, `currentImage`, `openedAsImage`, `push` (Task 3).
- Produces: `TransformOutcome` gains `case appliedWithNote(String)` and `case nothingToDo(String)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PastefixAppCoreTests/ImageTransformCoordinatorTests.swift
import Testing
import Foundation
import AppKit
import PastefixCore
@testable import PastefixAppCore

private struct ImageStub: ImageTransformer {
    let id = "test.image"; let name = "Stub"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.coordinator")
    let output: @Sendable (Data) -> TransformOutput
    func transformImage(_ png: Data) throws -> TransformOutput { output(png) }
}

private struct RichStub: Transformer {
    let id = "test.rich"; let name = "Rich"; let requiresRichInput = true
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { "from rich" }
}

@Suite("the coordinator with image transforms (Plan 20)")
struct ImageTransformCoordinatorTests {
    /// A real PNG `width`×`height`, so `isPNG` and the pixel ceiling see real headers.
    static func png(_ width: Int = 8, _ height: Int = 8) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
    private func imageDoc(_ png: Data = png(), text: String? = nil, rich: Data? = nil) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: rich, imagePNG: png))
    }

    @Test("an image transform is offered in an image session and not in text or mixed ones")
    func gating() {
        let t = ImageStub { .image($0) }
        #expect(TransformCoordinator.isEnabled(t, for: imageDoc()))
        #expect(!TransformCoordinator.isEnabled(t, for: imageDoc(text: "caption")), "mixed opens as text")
        #expect(!TransformCoordinator.isEnabled(t, for: PasteDocument(origin: ClipboardSnapshot(plainText: "x", richRTFD: nil))))
    }

    @Test("an image result is pushed, with its note")
    func imagePushed() async {
        let other = Self.png(9, 9)
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .image(other, note: "done") }, to: imageDoc())
        #expect(outcome == .appliedWithNote("done") && doc.imagePNG == other && doc.canUndo)
    }

    @Test("the same image back is unchanged, with no push")
    func sameImage() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { .image($0) }, to: imageDoc())
        #expect(outcome == .unchanged && !doc.canUndo)
    }

    @Test("nothing to do pushes nothing and carries its sentence")
    func nothingToDo() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .nothingToDo("nothing") }, to: imageDoc())
        #expect(outcome == .nothingToDo("nothing") && !doc.canUndo)
    }

    @Test("an image result that isn't a PNG is refused")
    func notPNG() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .image(Data("jpeg?".utf8)) }, to: imageDoc())
        #expect(outcome == .failed("Stub didn't produce a usable image.") && !doc.canUndo)
    }

    @Test("a text result from an image replaces it")
    func textFromImage() async {
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { _ in .text("read") }, to: imageDoc())
        #expect(outcome == .applied && doc.working == "read" && doc.imagePNG == nil)
    }

    // Review Focus 2: a session can hold a verbatim PNG over the ceiling.
    @Test("an image over the pixel ceiling is refused with its size and the limit")
    func overCeiling() async {
        let big = Self.png(6_000, 5_000)   // 30 MP
        let (doc, outcome) = await TransformCoordinator.apply(ImageStub { .image($0) }, to: imageDoc(big))
        #expect(outcome == .failed("Stub works on images up to 25 MP; this one is 30 MP.") && !doc.canUndo)
    }

    // Chrome's "Copy Image" writes HTML beside the image; after OCR, rich transforms would
    // replace the recognised text with a rendering of that HTML.
    @Test("rich transforms need a session that opened as text")
    func richAfterOCR() async {
        let rtfd = try? NSAttributedString(string: "html").data(from: NSRange(location: 0, length: 4),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        var doc = imageDoc(rich: rtfd)
        doc.pushState("ocr text")
        #expect(!TransformCoordinator.isEnabled(RichStub(), for: doc))
        let textOrigin = PasteDocument(origin: ClipboardSnapshot(plainText: "t", richRTFD: rtfd))
        #expect(TransformCoordinator.isEnabled(RichStub(), for: textOrigin))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter ImageTransformCoordinatorTests 2>&1 | grep -E "error:" | head -3`
Expected: compile errors (`appliedWithNote`, `nothingToDo` unknown).

- [ ] **Step 3: Implement**

Replace `TransformOutcome`:

```swift
public enum TransformOutcome: Sendable, Equatable {
    case applied
    /// Applied, with a sentence for the user ("Removed location and camera details.").
    case appliedWithNote(String)
    case unchanged
    /// The transform had nothing to do and pushed nothing; the sentence says so.
    case nothingToDo(String)
    case failed(String)
}
```

In `isEnabled`, replace the rich line:

```swift
        // Rich transforms read the *origin's* rich content, which an image origin can carry too
        // (Chrome's "Copy Image" writes HTML beside it). After OCR such a session is showing text,
        // and Rich → Plain would replace the recognised text with a rendering of that HTML.
        if transformer.requiresRichInput { return !document.openedAsImage && document.origin.hasRichContent }
```

In `apply`, replace from `let input = …` through the end of the `do` block:

```swift
        let image = doc.currentImage
        let input = TransformInput(text: doc.working, richRTFD: doc.origin.richRTFD, image: image)
        // Refuse before running. An image is bounded by the pixel ceiling, not the 1 MB text cap,
        // and never downscaled; its branch comes first because its `input.text` is "".
        if let image {
            let pixels = ImageBytes.pixelSize(of: image)
                .flatMap { ImageBytes.pixelCount(width: $0.width, height: $0.height) } ?? ImageBytes.unmeasurablePixels
            guard pixels <= ImageBytes.maxConvertiblePixels else {
                return (doc, .failed("\(transformer.name) works on images up to \(ImageBytes.megapixelLabel(ImageBytes.maxConvertiblePixels)); this one is \(ImageBytes.megapixelLabel(pixels))."))
            }
        } else if transformer.requiresRichInput {
            guard (input.richRTFD?.count ?? 0) <= transformer.maxInputBytes else {
                return (doc, .failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of rich text."))
            }
        } else {
            guard input.text.utf8.count <= transformer.maxInputBytes else {
                return (doc, .failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of text."))
            }
        }
        do {
            let output = try await Deadline.run(seconds: transformer.timeout) { try await transformer.transform(input) }
            switch output {
            case .nothingToDo(let sentence):
                return (doc, .nothingToDo(sentence))
            case .image(let png, let note):
                guard ImageBytes.isPNG(png) else {
                    return (doc, .failed("\(transformer.name) didn't produce a usable image."))
                }
                guard Entry.image(png) != doc.currentEntry else { return (doc, .unchanged) }
                doc.push(.image(png))
                return (doc, note.map(TransformOutcome.appliedWithNote) ?? .applied)
            case .text(let result):
                if let arming = transformer as? OutputModeTransformer { doc.outputMode = arming.outputMode }
                // (keep the existing comment block about why the push happens either way)
                let outcome: TransformOutcome =
                    .text(result) == doc.currentEntry && !(transformer is OutputModeTransformer) ? .unchanged : .applied
                doc.pushState(result)
                return (doc, outcome)
            }
        }
```

(`Entry` here is `PasteDocument.Entry`; add `typealias Entry = PasteDocument.Entry` at the top of the enum or qualify it.) The `catch` clauses are unchanged.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "Coordinator" 2>&1 | grep -E "✘|Test run with"`
Expected: all pass, the existing `TransformCoordinatorTests` included.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: the coordinator gates, bounds and pushes image transforms (Plan 20)"
```

---

### Task 5: `AppModel` and `PanelView` — the transform note, and Save's output mode

**Files:**
- Modify: `Pastefix/Pastefix/AppModel.swift`, `Pastefix/Pastefix/PanelView.swift`
- Test: `Pastefix/PastefixTests/TransformNoteTests.swift`

**Interfaces:**
- Consumes: `TransformOutcome.appliedWithNote/nothingToDo` (Task 4); `effectiveOutputMode` (Task 3).
- Produces: `@Published var transformNote: String?` on `AppModel`.

- [ ] **Step 1: Write the failing test**

```swift
// Pastefix/PastefixTests/TransformNoteTests.swift
import Testing
import AppKit
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Noting: ImageTransformer {
    let id = "test.noting"; let name = "Noting"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.noting")
    let result: TransformOutput
    func transformImage(_ png: Data) throws -> TransformOutput { result }
}

@MainActor
@Suite("the transform note (Plan 20)")
struct TransformNoteTests {
    @Test("a note appears after an apply, and undo, redo and a new session clear it")
    func lifecycle() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        let other = try #require(Pixels.encoded(width: 30, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        f.model.apply(Noting(result: .image(other, note: "Removed location details.")))
        #expect(await f.eventually { f.model.transformNote == "Removed location details." })
        #expect(f.model.document?.imagePNG == other)
        f.model.undo()
        #expect(f.model.transformNote == nil, "undo makes the sentence false")
        #expect(f.model.document?.imagePNG == png)

        f.model.apply(Noting(result: .nothingToDo("Nothing to remove.")))
        #expect(await f.eventually { f.model.transformNote == "Nothing to remove." })
        #expect(f.model.errorMessage == nil && f.model.noticeMessage == nil)
        f.model.beginSession(from: ClipboardSnapshot(plainText: "new", richRTFD: nil))
        #expect(f.model.transformNote == nil)
    }

    @Test("Save on an image entry ignores an armed output mode")
    func saveIgnoresArmedMode() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        f.model.apply(Noting(result: .text("# heading")))
        #expect(await f.eventually { f.model.document?.working == "# heading" })
        f.model.apply(MarkdownToRich())
        #expect(await f.eventually { f.model.isRichOutputArmed })
        f.model.undo()
        #expect(!f.model.isRichOutputArmed, "the badge hides on an image entry")
        f.model.save()
        let types = f.pasteboard.types ?? []
        #expect(types.contains(.png) && !types.contains(.rtf) && !types.contains(.html))
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `scripts/test-app.sh 2>&1 | grep -E "error:" | head -3`
Expected: compile error (`transformNote` unknown).

- [ ] **Step 3: Implement in `AppModel`**

Below `noticeMessage`, add:

```swift
    /// A transform's sentence about what it just did or why it did nothing ("Removed location and
    /// camera details.", "This image has no location or camera details to remove."), Plan 20.
    /// **Not** `noticeMessage`: that is a standing fact about the origin, cleared only at session
    /// boundaries, and a transform's sentence left there would outlive the ⌘Z that makes it false.
    /// Cleared by the next apply, undo, redo, and every session boundary. `PanelView` shows one
    /// banner: error first, then this, then the notice.
    @Published var transformNote: String?
```

In `apply(_:)`, set `transformNote = nil` before `isApplying = true`, and replace the outcome switch:

```swift
            switch outcome {
            case .applied, .unchanged: self.errorMessage = nil
            case .appliedWithNote(let note), .nothingToDo(let note):
                self.errorMessage = nil
                self.transformNote = note
            case .failed(let message): self.errorMessage = message
            }
```

In `undo()` and `redo()`, add `transformNote = nil` after `document = doc`. At every place that sets `noticeMessage = nil` at a session boundary (`beginSession`, `refresh`, `load`, `endSession`), also set `transformNote = nil`.

In `save()`, replace `if doc.outputMode == .renderedMarkdown {` with `if doc.effectiveOutputMode == .renderedMarkdown {`, and change `isRichOutputArmed` to `document?.effectiveOutputMode == .renderedMarkdown`.

- [ ] **Step 4: Implement in `PanelView`**

In the banner chain, between the error and the notice:

```swift
                        if let error = model.errorMessage {
                            errorBanner(error)
                        } else if let note = model.transformNote {
                            // Informational, like a notice, and transient, unlike one (see
                            // `AppModel.transformNote`).
                            noticeBanner(note)
                        } else if let notice = model.noticeMessage {
```

- [ ] **Step 5: Run both suites**

Run: `swift test 2>&1 | grep "Test run with"`; `scripts/test-app.sh 2>&1 | grep -E "Test run with|error:"`
Expected: green; the new app tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: a transient transform note, and Save ignores output mode on an image (Plan 20)"
```

---

### Task 6: `ImageMetadata.inspect` — what an image carries, by category

**Files:**
- Create: `Sources/PastefixCore/Upload/ImageMetadata.swift`
- Test: `Tests/PastefixCoreTests/ImageMetadataTests.swift`

**Interfaces:**
- Produces:
  - `public enum ImageMetadata`, with `public enum Category: Int, Sendable, Comparable, CaseIterable { case location, cameraAndDate, other }`
  - `public static func inspect(_ data: Data) -> Set<Category>`
  - `public static func removedMessage(_ found: Set<Category>) -> String`
  - `public static let nothingToRemoveMessage = "This image has no location or camera details to remove."`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PastefixCoreTests/ImageMetadataTests.swift
import Testing
import Foundation
import ImageIO
@testable import PastefixCore

@Suite("ImageMetadata.inspect (#82)")
struct ImageMetadataTests {
    /// A PNG shaped like a macOS screenshot: resolution, pixel dimensions and a `UserComment` of
    /// "Screenshot" — what the spec review measured on a real ⌃⇧⌘4 capture.
    static func screenshotShaped(extraExif: [CFString: Any] = [:], gps: Bool = false) -> Data? {
        guard let plain = Fixture.image(as: "public.png"), let stripped = ImageSanitizer.stripped(plain),
              let src = CGImageSourceCreateWithData(stripped.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "Screenshot",
                                     kCGImagePropertyExifPixelXDimension: Fixture.width,
                                     kCGImagePropertyExifPixelYDimension: Fixture.height]
        exif.merge(extraExif) { $1 }
        var props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFResolutionUnit: 2,
                                             kCGImagePropertyTIFFXResolution: 144, kCGImagePropertyTIFFYResolution: 144],
            kCGImagePropertyExifDictionary: exif,
        ]
        if gps { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N"] }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    @Test("the GPS fixture reports location, camera/date, and other")
    func fixture() throws {
        let data = try #require(Fixture.image(as: "public.png"))
        #expect(ImageMetadata.inspect(data) == [.location, .cameraAndDate, .other])
    }

    // Without the structural allowlist, ImageIO's own keys make "other" true of every image and
    // "nothing to remove" unreachable (measured in the spec review).
    @Test("a stripped image reports nothing: stripping twice finds nothing the second time")
    func strippedIsClean() throws {
        let data = try #require(Fixture.image(as: "public.png"))
        let clean = try #require(ImageSanitizer.stripped(data))
        #expect(ImageMetadata.inspect(clean.data).isEmpty)
    }

    @Test("a screenshot's structural keys and its 'Screenshot' comment are not metadata")
    func screenshot() throws {
        #expect(ImageMetadata.inspect(try #require(Self.screenshotShaped())).isEmpty)
    }

    @Test("any other UserComment is metadata")
    func otherComment() throws {
        let data = try #require(Self.screenshotShaped(extraExif: [kCGImagePropertyExifUserComment: "meeting notes"]))
        #expect(ImageMetadata.inspect(data) == [.other])
    }

    // Review Focus 1: the exemption is for one key, not for the image.
    @Test("a screenshot comment does not hide GPS")
    func screenshotWithGPS() throws {
        #expect(ImageMetadata.inspect(try #require(Self.screenshotShaped(gps: true))) == [.location])
    }

    @Test("the removal sentence names what went")
    func messages() {
        #expect(ImageMetadata.removedMessage([.location]) == "Removed location details.")
        #expect(ImageMetadata.removedMessage([.location, .cameraAndDate]) == "Removed location and camera details.")
        #expect(ImageMetadata.removedMessage([.location, .cameraAndDate, .other]) == "Removed location, camera details and other metadata.")
        #expect(ImageMetadata.removedMessage([.other]) == "Removed metadata.")
    }

    @Test("bytes that aren't an image report nothing")
    func notAnImage() {
        #expect(ImageMetadata.inspect(Data("hello".utf8)).isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter ImageMetadataTests 2>&1 | grep -E "error:" | head -2`
Expected: compile error (`ImageMetadata` unknown).

- [ ] **Step 3: Implement**

```swift
// Sources/PastefixCore/Upload/ImageMetadata.swift
import Foundation
import ImageIO

/// What an image carries that `ImageSanitizer` would remove, in categories a user can read (#82).
/// Header-only: `CGImageSourceCopyPropertiesAtIndex`, no decode.
///
/// **Structural keys don't count, by an explicit allowlist.** ImageIO fills keys into *every*
/// image — a bare PNG written by `CGImageDestination` reports `{Exif: ColorSpace,
/// PixelXDimension, PixelYDimension}` and `{PNG: Chromaticities, Gamma, InterlaceType, sRGBIntent}`;
/// a ⌃⇧⌘4 screenshot adds `{TIFF: ResolutionUnit, XResolution, YResolution}` and `UserComment`
/// (measured, spec review). Without the allowlist "other metadata" is true of everything and
/// "nothing to remove" is unreachable.
public enum ImageMetadata {
    public enum Category: Int, Sendable, Comparable, CaseIterable {
        case location, cameraAndDate, other
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public static let nothingToRemoveMessage = "This image has no location or camera details to remove."

    /// Keys ImageIO writes on its own, per dictionary. Present in a clean image; never "metadata".
    static let structural: [String: Set<String>] = [
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifColorSpace,
        ].map { $0 as String }.reduce(into: []) { $0.insert($1) },
        kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFXResolution,
            kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFOrientation,
        ].map { $0 as String }.reduce(into: []) { $0.insert($1) },
        kCGImagePropertyPNGDictionary as String: [
            kCGImagePropertyPNGGamma, kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGInterlaceType,
            kCGImagePropertyPNGsRGBIntent, kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter,
        ].map { $0 as String }.reduce(into: ["pHYs"]) { $0.insert($1) },
    ]

    /// Keys that are camera or date details, per dictionary. Everything else non-structural is
    /// "other".
    static let cameraAndDate: [String: Set<String>] = [
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
            kCGImagePropertyExifSubsecTime, kCGImagePropertyExifSubsecTimeOriginal,
            kCGImagePropertyExifSubsecTimeDigitized, kCGImagePropertyExifOffsetTime,
            kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
            kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSerialNumber,
            kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName,
        ].map { $0 as String }.reduce(into: []) { $0.insert($1) },
        kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
        ].map { $0 as String }.reduce(into: []) { $0.insert($1) },
        kCGImagePropertyPNGDictionary as String: [
            kCGImagePropertyPNGCreationTime, kCGImagePropertyPNGModificationTime,
        ].map { $0 as String }.reduce(into: []) { $0.insert($1) },
    ]

    public static func inspect(_ data: Data) -> Set<Category> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var found: Set<Category> = []
        for (key, value) in props {
            // Only the metadata dictionaries; top-level keys (PixelWidth, DPIWidth, ProfileName…)
            // describe the image itself.
            guard key.hasPrefix("{"), let dict = value as? [String: Any], !dict.isEmpty else { continue }
            if key == kCGImagePropertyGPSDictionary as String { found.insert(.location); continue }
            if key == kCGImagePropertyExifAuxDictionary as String || key.hasPrefix("{Maker") {
                found.insert(.cameraAndDate); continue
            }
            let skip = structural[key] ?? []
            let camera = cameraAndDate[key] ?? []
            for (field, fieldValue) in dict where !skip.contains(field) {
                // macOS writes "Screenshot" here on every screen capture; any other comment is text
                // someone wrote, and can say anything.
                if key == kCGImagePropertyExifDictionary as String,
                   field == kCGImagePropertyExifUserComment as String,
                   (fieldValue as? String) == "Screenshot" { continue }
                found.insert(camera.contains(field) ? .cameraAndDate : .other)
            }
        }
        // An XMP packet is not surfaced as a properties dictionary; its wrapper is.
        if data.range(of: Data("<x:xmpmeta".utf8)) != nil { found.insert(.other) }
        return found
    }

    /// "Removed location and camera details." — what a strip took, in plain words.
    public static func removedMessage(_ found: Set<Category>) -> String {
        let hasLocation = found.contains(.location), hasCamera = found.contains(.cameraAndDate)
        let hasOther = found.contains(.other)
        switch (hasLocation, hasCamera, hasOther) {
        case (true, true, true): return "Removed location, camera details and other metadata."
        case (true, true, false): return "Removed location and camera details."
        case (true, false, true): return "Removed location details and other metadata."
        case (true, false, false): return "Removed location details."
        case (false, true, true): return "Removed camera details and other metadata."
        case (false, true, false): return "Removed camera details."
        case (false, false, _): return "Removed metadata."
        }
    }
}
```

If `strippedIsClean` or `screenshot` fails because ImageIO synthesises a key not in `structural`, add that key to `structural` with a one-line comment naming the measurement. Do **not** widen the allowlist to make `fixture`, `otherComment` or `screenshotWithGPS` pass.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ImageMetadataTests 2>&1 | grep -E "✘|Test run with"`
Expected: 7 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: ImageMetadata.inspect reports what an image carries, by category (#82)"
```

---

### Task 7: "Strip Image Metadata"

**Files:**
- Create: `Sources/PastefixCore/Native/StripImageMetadata.swift`
- Modify: `Sources/PastefixCore/Discovery/TransformerRegistry.swift`
- Test: `Tests/PastefixCoreTests/StripImageMetadataTests.swift`, `Pastefix/PastefixTests/StripImageMetadataAppTests.swift`

**Interfaces:**
- Consumes: `ImageTransformer` (Task 2), `ImageMetadata` (Task 6), `ImageSanitizer.stripped`.
- Produces: `public struct StripImageMetadata: ImageTransformer`, with id `builtin.stripimagemetadata`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PastefixCoreTests/StripImageMetadataTests.swift
import Testing
import Foundation
@testable import PastefixCore

@Suite("Strip Image Metadata (#82)")
struct StripImageMetadataTests {
    @Test("strips a GPS-tagged image and says what went")
    func strips() throws {
        let data = try #require(Fixture.image(as: "public.png"))
        guard case .image(let out, let note) = try StripImageMetadata().transformImage(data) else {
            Issue.record("expected an image"); return
        }
        #expect(ImageMetadata.inspect(out).isEmpty)
        #expect(note == "Removed location, camera details and other metadata.")
    }

    @Test("a clean image has nothing to remove, and nothing is re-encoded")
    func clean() throws {
        let clean = try #require(ImageSanitizer.stripped(try #require(Fixture.image(as: "public.png"))))
        #expect(try StripImageMetadata().transformImage(clean.data) == .nothingToDo(ImageMetadata.nothingToRemoveMessage))
    }

    @Test("it is registered, in Privacy, for images only")
    func registered() {
        let t = TransformerRegistry(config: RegistryConfig(scriptsDirectory: URL(fileURLWithPath: "/nonexistent")))
            .load().first { $0.id == "builtin.stripimagemetadata" }
        #expect(t?.name == "Strip Image Metadata" && t?.category == TransformCategory.privacy)
        #expect(t?.acceptedForms == [.image])
    }
}
```

```swift
// Pastefix/PastefixTests/StripImageMetadataAppTests.swift
import Testing
import AppKit
import ImageIO
import PastefixCore
import PastefixAppCore
@testable import Pastefix

@MainActor
@Suite("Strip Image Metadata in a session (#82)")
struct StripImageMetadataAppTests {
    private func gpsPNG() -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let image = rep?.cgImage else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0,
                                                                              kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    @Test("offered in an image session; applying swaps the image, and ⌘Z restores it")
    func applyAndUndo() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(gpsPNG())
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        let strip = try #require(f.model.enabledTransformers().first { $0.id == "builtin.stripimagemetadata" })
        f.model.apply(strip)
        #expect(await f.eventually { f.model.document?.imagePNG != png })
        #expect(f.model.transformNote == "Removed location details.")
        #expect(ImageMetadata.inspect(try #require(f.model.document?.imagePNG)).isEmpty)
        f.model.undo()
        #expect(f.model.document?.imagePNG == png)
    }

    // Review Focus 3.
    @Test("not offered in a text or mixed session")
    func notOffered() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(gpsPNG())
        f.model.beginSession(from: ClipboardSnapshot(plainText: "caption", richRTFD: nil, imagePNG: png))
        #expect(!f.model.enabledTransformers().contains { $0.id == "builtin.stripimagemetadata" })
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter StripImageMetadataTests 2>&1 | grep -E "error:" | head -2`
Expected: compile error (`StripImageMetadata` unknown).

- [ ] **Step 3: Implement**

```swift
// Sources/PastefixCore/Native/StripImageMetadata.swift
import Foundation

/// ⌘K "Strip Image Metadata" (#82): the image with its location, camera, date and other metadata
/// removed, orientation baked in — exactly what image upload does, through the same
/// `ImageSanitizer`, so there is one implementation. Says what it removed, and says so when there
/// was nothing to remove rather than silently re-encoding.
public struct StripImageMetadata: ImageTransformer {
    public let id = "builtin.stripimagemetadata"
    public let name = "Strip Image Metadata"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.privacy
    public init() {}

    public func transformImage(_ png: Data) throws -> TransformOutput {
        let found = ImageMetadata.inspect(png)
        guard !found.isEmpty else { return .nothingToDo(ImageMetadata.nothingToRemoveMessage) }
        // The coordinator has refused anything over the pixel ceiling, so nil here is a decode or
        // encode failure, not a size.
        guard let clean = ImageSanitizer.stripped(png) else {
            throw TransformError.invalidInput("Couldn't strip this image's metadata.")
        }
        return .image(clean.data, note: ImageMetadata.removedMessage(found))
    }
}
```

In `TransformerRegistry.load()`, after `(110, "Redact Secrets", RedactSecrets()),` add:

```swift
            (111, "Strip Image Metadata", StripImageMetadata()),
```

- [ ] **Step 4: Run both suites**

Run: `swift test 2>&1 | grep "Test run with"`; `scripts/test-app.sh 2>&1 | grep -E "Test run with|error:"`
Expected: green. If a registry test pins the built-in count or ids, update it to include the new entry.

- [ ] **Step 5: Mutation check**

Replace `guard !found.isEmpty else { return .nothingToDo(...) }` with `_ = found` and run `swift test --filter StripImageMetadataTests`. Expected: `clean` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: Strip Image Metadata, a ⌘K transform for image sessions (#82)"
```

---

### Task 8: Documentation and the owner's GUI pass

**Files:**
- Modify: `AGENTS.md`, `README.md`, `docs/specs/2026-09-28-pastefix-v2-image-transforms.md` (status), this plan (status)

- [ ] **Step 1: AGENTS.md**
  - The `PasteDocument.swift` row: replace "displaysAsImage (a STORED `let` set at init, never computed …)" with "entries `[.text | .image]` with one cursor (Plan 20); `openedAsImage` is the init rule, fixed; `displaysAsImage` is DERIVED from the current entry's form — safe because only push/undo/redo change it and `setWorking` is ignored on an image entry (see 'Things that have bitten us'); `imagePNG` is the current image entry for an image-first session, the origin's image otherwise; `effectiveOutputMode` ignores an armed mode on an image entry".
  - The "A derived display rule is a trap…" bullet: append "Plan 20 derives it again, from the *current entry's form* rather than from editable text: only a transform, undo or redo changes that, each an undo record, and `setWorking` is ignored on an image entry. `refresh` replaces the whole document, as before. The trap is deriving from something a keystroke can change."
  - Add rows for `ImageTransformer.swift`, `ImageMetadata.swift` and `StripImageMetadata.swift`; the `TransformCoordinator.swift` row gains "image branch: pixel ceiling, `isPNG` on the result, entry comparison; `appliedWithNote`/`nothingToDo`"; the `AppModel.swift` row gains `transformNote` and its clearing rule.
- [ ] **Step 2: README.md.** In the image-sessions paragraph, replace "No transforms apply to a picture yet, and the ⌘K palette says so rather than showing an empty list." with: "⌘K on a picture offers **Strip Image Metadata**, which removes its location, camera and other metadata, says what it removed, and puts the clean image back on the clipboard when you Save. ⌘Z brings the original back. Your history still holds the original you copied until you remove it (⌘⌫ in the history overlay)."
- [ ] **Step 3: Status.** The spec's and this plan's `status:` become `implemented` for part 1 (the spec notes part 2 is pending).
- [ ] **Step 4: Run both suites; commit.**

```bash
git add -A && git commit -m "docs: image transforms and Strip Image Metadata in AGENTS and README (Plan 20)"
```

- [ ] **Step 5: Owner GUI pass** (Developer-ID-signed Debug build, `pb begin`/`pb end`, per `docs/gui-automation.md`):
  1. Copy a GPS-tagged PNG (for example `Fixture.image(as: "public.png")` written to a file and copied from Preview). Summon, ⌘K → Strip Image Metadata. You see the image, and "Removed location, camera details and other metadata."
  2. Save, paste into Preview → Tools → Show Inspector: no GPS, no camera.
  3. Summon over the original again, strip, then ⌘Z: the original is back and the note is gone.
  4. ⌃⇧⌘4 a screenshot to the clipboard, strip: "This image has no location or camera details to remove."
