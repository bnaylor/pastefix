# Pastefix v2 Image Sessions (Plan 15) — Implementation Plan

> ## 🟡 STATUS: IN PROGRESS — branch `feat/image-sessions`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; SwiftUI (Tasks 4, 5) → `swiftui-pro`. **TDD is required** for every package task (1–3). **One implementer at a time on the branch.** The GUI pass is the controller's, with the user's permission, using `docs/gui-automation.md`.

**Goal:** A session can hold, display and write back an image, so that EXIF stripping (#20), OCR (#19), format conversion (#21) and image upload (#48) have something to build on.

**Architecture:** `ClipboardSnapshot` gains `imagePNG: Data?` — the missing third content field beside `plainText` and `richRTFD`. `PasteDocument` exposes it and derives one question (does this session display as an image?) while its text state stays untouched, so the transform pipeline, undo/redo, detection and secret scanning never learn about images. `Transformer` declares which `ContentForm`s it accepts, defaulting to `.text`, and `TransformCoordinator.isEnabled(_:for:)` filters on it. The app target renders an image view when the session displays as one, and ↵ on an image history row now opens it.

**Tech Stack:** Swift 6 SwiftPM (packages macOS 14+, app target macOS 15+), AppKit `NSPasteboard`, SwiftUI, Swift Testing.

**Spec:** `docs/specs/2026-09-26-pastefix-v2-image-sessions.md` — read it first. Its Decisions table is the authority; where this plan and the spec disagree, the spec wins.

## Global Constraints

- **Format:** PNG. #32's `TIFFConversionSlot` already normalises TIFF→PNG on the capture path; do not add a second decode path.
- **"No text" means blank once trimmed.** `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` — the identical rule `PendingImage.resolve:33` and `HistoryStore.record` already apply. Do not write a second rule.
- **An RTFD with an embedded image is NOT an image.** `imagePNG` means a standalone pasteboard image type (`.png`/`.tiff`) only.
- **Advertised but unmaterialised is NOT an image.** A pasteboard type present with nil data means no image, never an empty one.
- **Save never writes less than it was given.** Text as edited, image unchanged.
- **No session size cap.** History's 5 MB skip and `UploadLimits`' 16 MB refusal already exist and already explain themselves.
- **Zero image transforms ship in this plan.** `acceptedForms` defaults to `[.text]`; every existing transform is unchanged.
- **Form is not `applicableKinds`.** Form = can this run at all. Kinds = should it sort first. Keep them separate.
- **Undo stays text-only.** `canUndo` is false in an image session; do not give undo a new meaning.
- **Baseline:** `swift test` → **575 tests in 66 suites**. Any parallel-run failure in `ScriptWatcherTests` is #51 and was fixed in #66 — if you see one, it is new and it is yours.
- **Stamp this increment in THIS PR.** Plan banner → ✅, spec `status:` → `implemented`, AGENTS.md table row 15 → merged, identified by **PR number only, no merge SHA**. The follow-up stamping PR was retired in #61; do not open one.
- **Branch:** `feat/image-sessions`. Conventional commits + `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. PR closes #18. `main` is protected.

---

### Task 0: Baseline

- [ ] **Step 1: Confirm branch and baseline**

```bash
git rev-parse --abbrev-ref HEAD    # expect: feat/image-sessions
swift test 2>&1 | tail -1          # expect: 575 tests in 66 suites passed
```

The spec is already committed on this branch (`bba834a`). Nothing to commit here.

---

### Task 1: `ClipboardSnapshot` carries an image (AppCore, TDD)

**Files:**
- Modify: `Sources/PastefixAppCore/ClipboardSnapshot.swift`
- Create: `Tests/PastefixAppCoreTests/ClipboardSnapshotImageTests.swift`

**Interfaces:**
- Produces: `ClipboardSnapshot.imagePNG: Data?` and an `init(plainText:richRTFD:imagePNG:changeCount:)`. Tasks 2–5 all read `imagePNG`.

The existing type has two initialisers — one taking `richRTFD: Data?`, one taking `rich: NSAttributedString?`. Both need the new field, and **both must keep working for existing callers**, which pass no image at all.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import AppKit
@testable import PastefixAppCore

@Suite("ClipboardSnapshot carries an image")
struct ClipboardSnapshotImageTests {
    @Test("an image round-trips through the Data initialiser")
    func dataInit() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let snap = ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png, changeCount: 7)
        #expect(snap.imagePNG == png)
        #expect(snap.changeCount == 7)
    }

    @Test("an image round-trips through the attributed-string initialiser")
    func richInit() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let snap = ClipboardSnapshot(plainText: "hi", rich: nil, imagePNG: png, changeCount: 3)
        #expect(snap.imagePNG == png)
        #expect(snap.plainText == "hi")
    }

    @Test("existing callers that pass no image get nil, not empty")
    func defaultsToNil() {
        // Every current call site omits the image; nil must mean "there wasn't one",
        // and an empty Data would later be written over someone's clipboard as zero bytes.
        #expect(ClipboardSnapshot(plainText: "x", richRTFD: nil).imagePNG == nil)
        #expect(ClipboardSnapshot(plainText: "x", rich: nil).imagePNG == nil)
    }

    @Test("an image inside rich text is not the image field")
    func embeddedImageIsNotAnImage() throws {
        // The spec's rule: `imagePNG` means a standalone pasteboard image type. An attributed
        // string carrying an attachment goes into `richRTFD` and nowhere else — without this,
        // every rich paste from a web page becomes an image session.
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 4, height: 4))
        let rich = NSAttributedString(attachment: attachment)
        let snap = ClipboardSnapshot(plainText: nil, rich: rich, changeCount: 1)
        #expect(snap.imagePNG == nil)
        #expect(snap.richRTFD != nil, "the attachment should have gone into the rich data")
    }

    @Test("hasRichContent still only means rich text")
    func richIsNotImage() {
        // An image is not rich content: `requiresRichInput` transforms gate on hasRichContent,
        // and an image session must not make Rich → Plain Text look applicable.
        let snap = ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: Data([1, 2, 3]))
        #expect(snap.hasRichContent == false)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter ClipboardSnapshotImageTests 2>&1 | tail -5
```
Expected: FAIL — `extra argument 'imagePNG' in call`.

- [ ] **Step 3: Add the field**

Add to `ClipboardSnapshot`, keeping the existing doc-comment voice:

```swift
    /// A standalone pasteboard image, normalised to PNG.
    ///
    /// Nil covers three different "no image" cases deliberately, because none of them should
    /// become an empty `Data`: the pasteboard had no image type; it advertised one whose provider
    /// never materialised the promised data; or the bytes did not decode. An empty `Data` here
    /// would be written back over the user's clipboard as a zero-byte image by `Save`.
    ///
    /// An image embedded inside `richRTFD` is **not** this. This field means a standalone
    /// pasteboard image type; without that rule every rich paste from a web page would become an
    /// image session (spec, Decisions).
    public let imagePNG: Data?
```

Add `imagePNG: Data? = nil` to both initialisers, defaulted so no existing call site changes.

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --filter ClipboardSnapshotImageTests 2>&1 | tail -5
swift test 2>&1 | tail -1     # whole suite: nothing else moved
```
Expected: PASS, 4 tests; suite total 575 + 4.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/ClipboardSnapshot.swift Tests/PastefixAppCoreTests/ClipboardSnapshotImageTests.swift
git commit -m "feat(appcore): ClipboardSnapshot carries a standalone image (#18)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `PasteDocument` derives its display form (AppCore, TDD)

**Files:**
- Modify: `Sources/PastefixAppCore/PasteDocument.swift`
- Create: `Tests/PastefixAppCoreTests/PasteDocumentImageTests.swift`

**Interfaces:**
- Consumes: `ClipboardSnapshot.imagePNG` (Task 1).
- Produces: `PasteDocument.imagePNG: Data?` and `PasteDocument.displaysAsImage: Bool`. Tasks 3–5 read both.

All four combinations of text/image presence need pinning, and the blank-text case is the one that decides whether this matches the rest of the app.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PastefixAppCore

@Suite("PasteDocument display form")
struct PasteDocumentImageTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func doc(text: String?, image: Data?) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, imagePNG: image))
    }

    @Test("image and no text displays as an image")
    func imageOnly() {
        #expect(doc(text: nil, image: png).displaysAsImage)
    }

    @Test("image and real text displays as text")
    func mixed() {
        // The decision that protects every existing text workflow: a clipboard carrying both
        // keeps opening the editor. The image stays on the session for image-aware actions.
        let d = doc(text: "https://example.test/cat.png", image: png)
        #expect(d.displaysAsImage == false)
        #expect(d.imagePNG == png, "the image must still be carried, not dropped")
    }

    @Test("text and no image displays as text")
    func textOnly() {
        #expect(doc(text: "hello", image: nil).displaysAsImage == false)
    }

    @Test("neither displays as text")
    func neither() {
        #expect(doc(text: nil, image: nil).displaysAsImage == false)
    }

    @Test("blank text with an image displays as an image", arguments: ["", " ", "\n", "  \t\n "])
    func blankTextIsNotText(_ blank: String) {
        // Same rule as PendingImage.resolve:33 and HistoryStore.record: blank once trimmed is
        // not text. Without it, an image plus a single space opens the editor on nothing —
        // and a capture path and a session path disagreeing about "has text" is the kind of
        // divergence that produces two answers for one clipboard.
        #expect(doc(text: blank, image: png).displaysAsImage)
    }

    @Test("blank text with no image still displays as text")
    func blankTextNoImage() {
        #expect(doc(text: " ", image: nil).displaysAsImage == false)
    }

    @Test("an image session has nothing to undo")
    func noUndo() {
        #expect(doc(text: nil, image: png).canUndo == false)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter PasteDocumentImageTests 2>&1 | tail -5
```
Expected: FAIL — `value of type 'PasteDocument' has no member 'displaysAsImage'`.

- [ ] **Step 3: Add the two derived properties**

```swift
    /// The session's standalone image, if the clipboard had one. Carried whatever the session
    /// displays as, so an image-aware action reaches it even from a text session.
    public var imagePNG: Data? { origin.imagePNG }

    /// True when this session should render as an image rather than the editor: an image is
    /// present and there is no real text.
    ///
    /// "No real text" is blank-once-trimmed, which is the rule `PendingImage.resolve` and
    /// `HistoryStore.record` already use. Reusing it rather than writing a second one is the
    /// point: a capture path and a session path that disagree about whether a buffer has text
    /// give two different answers for one clipboard, and nobody notices until they do.
    public var displaysAsImage: Bool {
        guard origin.imagePNG != nil else { return false }
        return working.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
```

`canUndo` needs no change: an image-only session's `history` is seeded with the (blank) text exactly as today, so `cursor > 0` is already false.

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --filter PasteDocumentImageTests 2>&1 | tail -5
swift test 2>&1 | tail -1
```
Expected: PASS, 10 tests (the parameterised case counts 4).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/PasteDocument.swift Tests/PastefixAppCoreTests/PasteDocumentImageTests.swift
git commit -m "feat(appcore): PasteDocument derives whether a session displays as an image (#18)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `Transformer` declares what content it accepts (Core, TDD)

**Files:**
- Modify: `Sources/PastefixCore/Transformer.swift`
- Modify: `Sources/PastefixAppCore/TransformCoordinator.swift:11-14`
- Create: `Tests/PastefixAppCoreTests/TransformFormFilterTests.swift`

**Interfaces:**
- Consumes: `PasteDocument.displaysAsImage` (Task 2).
- Produces: `ContentForm` (`.text`, `.image`), `Transformer.acceptedForms: Set<ContentForm>` defaulting to `[.text]`. Task 4 relies on the palette filtering that falls out of this.

The seam is three lines today:

```swift
    public static func isEnabled(_ transformer: any Transformer, for document: PasteDocument) -> Bool {
        if transformer.requiresRichInput { return document.origin.hasRichContent }
        return true
    }
```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PastefixAppCore
@testable import PastefixCore

private struct FormStub: Transformer {
    let id: String
    let name = "Stub"
    let requiresRichInput = false
    let source = TransformerSource.builtin
    var acceptedForms: Set<ContentForm>
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

private struct TextDefaultStub: Transformer {
    let id = "text-default"
    let name = "Text default"
    let requiresRichInput = false
    let source = TransformerSource.builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite("Transform form filtering")
struct TransformFormFilterTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func doc(text: String?, image: Data?) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, imagePNG: image))
    }

    @Test("a transform that declares nothing accepts text only")
    func defaultIsText() {
        // The default must be explicit and text: ~30 existing transforms declare nothing, and a
        // new one must not claim it handles images by omission.
        #expect(TextDefaultStub().acceptedForms == [.text])
    }

    @Test("a text transform is enabled for a text session and not an image one")
    func textTransform() {
        let t = FormStub(id: "t", acceptedForms: [.text])
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: "hi", image: nil)))
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: nil, image: png)) == false)
    }

    @Test("an image transform is enabled for an image session and not a text one")
    func imageTransform() {
        let t = FormStub(id: "i", acceptedForms: [.image])
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: nil, image: png)))
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: "hi", image: nil)) == false)
    }

    @Test("a both-forms transform is enabled either way")
    func eitherTransform() {
        let t = FormStub(id: "e", acceptedForms: [.text, .image])
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: "hi", image: nil)))
        #expect(TransformCoordinator.isEnabled(t, for: doc(text: nil, image: png)))
    }

    @Test("a mixed session is a text session for filtering")
    func mixedSessionFiltersAsText() {
        // Follows displaysAsImage, not "is there an image": a clipboard with both opens the
        // editor, so text transforms must be available there.
        let mixed = doc(text: "https://example.test/cat.png", image: png)
        #expect(TransformCoordinator.isEnabled(FormStub(id: "t", acceptedForms: [.text]), for: mixed))
        #expect(TransformCoordinator.isEnabled(FormStub(id: "i", acceptedForms: [.image]), for: mixed) == false)
    }

    @Test("requiresRichInput still gates independently of form")
    func richStillGates() {
        // Two independent gates; an image is not rich content, so a rich transform stays off in
        // an image session for its own reason.
        struct RichStub: Transformer {
            let id = "r"; let name = "Rich"; let requiresRichInput = true
            let source = TransformerSource.builtin
            func apply(_ input: TransformInput) async throws -> String { input.text }
        }
        #expect(TransformCoordinator.isEnabled(RichStub(), for: doc(text: "hi", image: nil)) == false)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter TransformFormFilterTests 2>&1 | tail -5
```
Expected: FAIL — `cannot find type 'ContentForm' in scope`.

- [ ] **Step 3: Add `ContentForm` and the filter**

In `Sources/PastefixCore/Transformer.swift`:

```swift
/// What a transform can run on.
///
/// Deliberately separate from `ContentKind`: kinds drive detection-based *promotion* (what sorts
/// first in the palette), while a form is *applicability* (what can run at all). Collapsing them
/// would make "promoted" and "possible" one axis, and they are not — a JSON transform is promoted
/// for JSON and still applicable to any text.
public enum ContentForm: Sendable, Hashable {
    case text
    case image
}
```

Add to the protocol, beside `applicableKinds`:

```swift
    /// Which content forms this transform can run on. Defaults to `[.text]`.
    ///
    /// The default is text and it is deliberate: every transform that predates image sessions
    /// declares nothing, and a new one must not claim it handles images by omission.
    var acceptedForms: Set<ContentForm> { get }
```

And to the default-implementation extension:

```swift
    var acceptedForms: Set<ContentForm> { [.text] }
```

In `TransformCoordinator.isEnabled`:

```swift
    public static func isEnabled(_ transformer: any Transformer, for document: PasteDocument) -> Bool {
        // Two independent gates. Form asks whether this transform can run on what the session is
        // showing at all; rich input asks whether the original clipboard carried rich content.
        // An image session fails the first for a text transform and the second for a rich one,
        // for different reasons, and neither subsumes the other.
        let form: ContentForm = document.displaysAsImage ? .image : .text
        guard transformer.acceptedForms.contains(form) else { return false }
        if transformer.requiresRichInput { return document.origin.hasRichContent }
        return true
    }
```

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --filter TransformFormFilterTests 2>&1 | tail -5
swift test 2>&1 | tail -1
```
Expected: PASS, 6 tests. **The whole suite must still pass** — if any existing transform test fails, a transform is being filtered out that should not be, and the default is wrong rather than the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Transformer.swift Sources/PastefixAppCore/TransformCoordinator.swift Tests/PastefixAppCoreTests/TransformFormFilterTests.swift
git commit -m "feat(core): transforms declare which content forms they accept (#18)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Read the image, show it, write it back (app target, GUI)

**Files:**
- Modify: `Pastefix/Pastefix/ClipboardBridge.swift:5-29` (`snapshot`)
- Create: `Pastefix/Pastefix/ImageSessionView.swift`
- Modify: `Pastefix/Pastefix/PanelView.swift:120` (the `TextEditor` branch)
- Modify: `Pastefix/Pastefix/AppModel.swift` (`save`/`copyBack` write the image; `load` accepts an image item)

**Interfaces:**
- Consumes: `ClipboardSnapshot.imagePNG` (Task 1), `PasteDocument.displaysAsImage` / `.imagePNG` (Task 2).
- Produces: `ImageSessionView`.

No unit tests — the app target has none by design. Verification is the build plus the GUI pass in Task 6.

- [ ] **Step 1: Read a standalone image in `snapshot`, through a testable seam**

Extend `ClipboardBridge.snapshot`. **Do not disturb the count-first ordering** — its comment explains why the order is the whole safety argument, and the image read goes after it with the other content reads.

Three rules from the spec, all of which must hold:

- Only `.png` and `.tiff` count. A `.tiff` is converted to PNG; do not add a second decode path — use the same `NSBitmapImageRep` route `PasteboardMonitor` uses.
- **Advertised but unmaterialised is no image.** `availableType(from:)` saying yes and `data(forType:)` returning nil means nil, never `Data()`.
- **Bytes that do not decode are no image.** Validate before keeping them.

**Put the decision behind an injectable lookup so those three rules are testable**, rather than leaving them in an app-target function no test can reach. The spec's Testing section promises coverage for the unmaterialised rule, and this is what makes that possible — the repo already does exactly this for network reads (`TitleFetcher`, `ZiplineUploading`):

```swift
// Sources/PastefixAppCore/ClipboardImageRead.swift
/// Decides whether a pasteboard offers a usable standalone image, given only a type list and a
/// way to fetch bytes for a type. Pure, so the three "no image" rules are testable without a
/// pasteboard: `ClipboardBridge` passes real `NSPasteboard` closures, tests pass dictionaries.
public enum ClipboardImageRead {
    /// nil for: no image type offered; a type offered whose data is nil (advertised but never
    /// materialised by its provider); or bytes that do not decode. Never an empty `Data` — that
    /// would be written back over the user's clipboard as a zero-byte image.
    public static func imagePNG(
        available: (Set<String>) -> String?,
        data: (String) -> Data?,
        decodePNG: (Data) -> Data?
    ) -> Data?
}
```

Tests for it in `Tests/PastefixAppCoreTests/ClipboardImageReadTests.swift`: no type offered → nil; PNG offered with bytes that decode → those bytes; **type offered and `data` returns nil → nil, and assert it is not `Data()`**; bytes that fail to decode → nil; TIFF offered → the converted PNG.

- [ ] **Step 2: Build the image view**

`ImageSessionView.swift` renders the session's image scaled to fit, with the image's pixel dimensions and byte size shown — the same two facts the upload overlay's header shows, for the same reason: a user should be able to see what they are about to act on. Read `HistoryOverlayView`'s thumbnail code first for the house pattern on decoding off the main actor; this view has a whole panel rather than a 44 pt slot, so it can decode at display size, but it must not decode on a render path (the lesson from #59's Keychain read).

- [ ] **Step 3: Branch the panel**

At `PanelView.swift:120` the `TextEditor` is unconditional. Branch on `model.document?.displaysAsImage`: the image view when true, the `TextEditor` otherwise. Keep everything else — the action bar, the footer, the overlays — exactly as it is; an image session is not a different panel.

The ⌘K palette in an image session will now list nothing, because no transform accepts `.image` yet. **It must say so** ("No transforms apply to an image") rather than rendering an empty list — an empty palette reads as a broken panel, and this increment deliberately ships no image transforms.

- [ ] **Step 4: Save and copy-back write the image**

`ClipboardBridge.write(text:richRTFD:imagePNG:)` already takes all three. Pass the session's image through from `save` and `copyBack` so **Save never writes less than it was given**: a mixed session whose text was edited writes the edited text *and* the original image. Silently dropping an image the user never touched is data loss.

- [ ] **Step 5: `load` accepts an image history item**

`AppModel.load` currently redirects an image-only item to `copyBack`, with a comment saying a session "would silently discard the image". That is now false — delete the redirect and load the item into a session, carrying `history.imagePNG(for: item)` into the snapshot. Rewrite the comment to say what is true rather than leaving a stale justification.

- [ ] **Step 6: Build**

```bash
xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug clean build 2>&1 | grep -E "warning:|BUILD"
```
Expected: `** BUILD SUCCEEDED **` with exactly four pre-existing warning classes — three `HotkeyName.swift init(_:default:)` deprecations and one `MenuBarIcon` asset-catalog. A fifth class is yours.

- [ ] **Step 7: Commit**

```bash
git add Pastefix/Pastefix/ClipboardBridge.swift Pastefix/Pastefix/ImageSessionView.swift \
        Pastefix/Pastefix/PanelView.swift Pastefix/Pastefix/AppModel.swift
git commit -m "feat(app): sessions hold, show and write back an image (#18)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: ↵ opens an image history row (app target, GUI)

**Files:**
- Modify: `Pastefix/Pastefix/HistoryOverlayView.swift`
- Modify: `README.md` (the ⌘⇧V paragraph documenting the old rule)

**Interfaces:**
- Consumes: `AppModel.load` accepting an image item (Task 4).

- [ ] **Step 1: Make ↵ open image rows**

The overlay currently sends ↵ on an image row to copy-back because the editor could not show it. Remove that special case so ↵ means "load this into the panel" for every row type. **⌘↵ still copies back** — that is the path that must not change, because it is how a user gets an image onto the clipboard without opening it.

- [ ] **Step 2: Update the README in the same commit**

The ⌘⇧V paragraph says, in as many words, that *"since an image can't be edited yet, ↵ on an image item puts it straight back on the clipboard instead."* That sentence becomes false. Rewrite it, and describe image sessions where the README describes what the panel shows. Definition of Done item 2 requires this in the same commit — never wait to be asked.

- [ ] **Step 3: Build and commit**

```bash
xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug build 2>&1 | tail -3
git add Pastefix/Pastefix/HistoryOverlayView.swift README.md
git commit -m "feat(app): ↵ opens an image history row like any other (#18)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: GUI pass (controller, with the user's permission)

**Files:** none.

Follow `docs/gui-automation.md`. Standing consent may already cover this; if not, ask. `pb begin` before, `pb end` after quitting, record `PASS_START` for the history purge, and **do not point anything at a real server** — no upload is in scope here anyway.

The spec says plainly that this increment's visible half is verified by a GUI pass rather than by the suite, because the last three defects in Plan 13 were all app-target: two found by reading the spec against the code, one by watching the app.

- [ ] **Step 1: The checks**

1. `pb png 800 600`, then ⌘⇧C — the panel shows the image, not an empty editor.
2. ⌘S — the clipboard holds the image again (`pb types` shows an image type). **Save is ⌘S, not ⌘↵** — an earlier draft of this step had it wrong.
3. `pb text 'hello'`, ⌘⇧C — the editor opens as before. **No regression is the point of this one.**
4. A clipboard with an image *and* text — the editor opens, and the image survives Save: edit the text, ⌘S, then confirm `pb types` still shows both.
9. **In that same mixed session, select all and delete.** The editor must stay — it must not be replaced by the image view, because there would be no way back (`canUndo` is false). This is the trap the Task 4 review found; the display form is sticky per session, not derived per keystroke.
5. ⌘K in an image session — says no transforms apply, rather than an empty list.
6. An image row in ⌘⇧V, ↵ — opens into a session. ⌘↵ on the same row — copies back.
7. `pb png 4000 4000` (over history's 5 MB) — viewable, and absent from history.
8. Undo in an image session — unavailable, not broken.

- [ ] **Step 2: Report frames and outcomes, restore the machine**

---

### Task 7: Documentation and the PR

**Files:**
- Modify: `AGENTS.md` (file map, plan table row 15, invariants if touched, lessons)
- Modify: `docs/plans/2026-09-26-pastefix-v2-image-sessions.md` (banner)
- Modify: `docs/specs/2026-09-26-pastefix-v2-image-sessions.md` (frontmatter `status:`)

- [ ] **Step 1: AGENTS.md**

- File map: `ImageSessionView.swift`, and the changed responsibilities of `ClipboardSnapshot`, `PasteDocument`, `TransformCoordinator`, `Transformer`, `ClipboardBridge`, `AppModel`, `HistoryOverlayView`. **Modified files count** — #59's review found two file-map entries stale because only new files had been added.
- Plan table: add row 15, marked merged with **PR number only, no SHA** (#61 retired the SHA).
- Lessons, under a Plan 15 heading: that `displaysAsImage` reuses `PendingImage.resolve`'s blank-text rule rather than defining a second one, and why two paths disagreeing about "has text" is the hazard; and that form and `applicableKinds` are separate axes, since collapsing them is the obvious-looking simplification.
- **Invariant 13's reach:** the spec records that an image session has no text to scan, so #48 must state "not scanned" as loudly as a finding. Add that consequence to invariant 13 rather than leaving it only in a spec — the invariant is where a future upload path will look.

- [ ] **Step 2: Stamp the increment here**

Plan banner → `✅ STATUS: COMPLETE — merged to \`main\` via PR #<this PR's number>`. Spec frontmatter `status: approved` → `implemented`. Table row 15 → merged, PR number only. **All in this branch.** The PR number is the one field you cannot know before opening the PR — open it first (Step 4), then amend this commit with the number. That is the whole trick #61 used to delete a round trip: everything else is knowable in advance, and the number costs one amend rather than a second PR.

- [ ] **Step 3: Full verification**

```bash
swift test 2>&1 | tail -1
xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug clean build 2>&1 | grep -E "warning:|BUILD"
```
Paste the real output into the PR body. No claims without it.

- [ ] **Step 4: Open the PR**

Body: what shipped, the decisions a reviewer would otherwise re-litigate (mixed clipboard, blank-text rule, form vs kinds), the invariant-13 consequence for #48, the GUI-pass results from Task 6, verbatim test and build output, and `Closes #18`. Note explicitly that the increment is stamped in this PR.

---

## Notes for the implementer

- **The default on `acceptedForms` is the whole safety property.** `[.text]` means ~30 existing transforms are unchanged and a new transform cannot claim images by forgetting to say otherwise. If you find yourself defaulting it to both forms to make something work, that is the bug.
- **Do not write a second blank-text rule.** `PendingImage.resolve:33` has it. Two paths disagreeing about whether a buffer has text produces two answers for one clipboard.
- **Save never writes less than it was given.** The mixed-session case is where this gets lost, and losing it is silent data loss.
- **An image is not rich content.** `hasRichContent` must stay false for an image-only snapshot, or Rich → Plain Text will look applicable in an image session.
- **Nothing in this plan ships an image transform.** If the palette has an entry in an image session at the end of Task 4, something declared `.image` that should not have.
