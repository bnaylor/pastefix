---
type: plan
status: implemented
id: 2026-09-28-pastefix-v2-image-transforms-part2
title: Pastefix v2 — Image Transforms, part 2 (Plan 21, #19)
description: "Extract Text (OCR)": Vision .accurate recognition, lines rebuilt by bounding box, size-dependent tiling with an empty-result fallback, and ⌘Z undoing OCR until the user types.
tags: [pastefix, macos, swift, images, transforms, ocr, vision]
timestamp: 2026-09-28T23:00:00Z
---

# Image Transforms, part 2 (Plan 21) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘K "Extract Text (OCR)" turns an image session into a text session holding the recognised text, with ⌘Z bringing the image back until the user types.

**Architecture:** A pure `OCRLayout` (line reassembly, tile geometry, overlap de-duplication, the size-dependent strategy) is tested on constructed observations. A thin `TextRecognizer` wraps Vision. `ExtractText`, an `ImageTransformer` from Plan 20, joins them, and runs on the shared image-transform lane. `PasteDocument` gains an "edited since pushed" flag per entry, which decides when ⌘Z restores the image.

**Tech Stack:** Swift 6, SwiftPM, Vision (`VNRecognizeTextRequest`), ImageIO, SwiftUI, Swift Testing.

**Spec:** `docs/specs/2026-09-28-pastefix-v2-image-transforms.md`, Part 2. Plan 20 (`…-part1.md`) built the foundation this uses: `ImageTransformer`, `TransformOutput`, `PasteDocument.Entry`, the transform note, and ⌘Z/⌘⇧Z on image entries.

## Global Constraints

- Branch `feat/19-ocr`. One commit per task; commit messages end with the repo's `Co-Authored-By` / `Claude-Session` lines.
- Package tests: `swift test`. App tests: `scripts/test-app.sh`. Both green at every commit. 1 known issue is pre-existing (Vision text-region detection).
- Recognition: `VNRecognizeTextRequest`, `recognitionLevel = .accurate`, `usesLanguageCorrection = false`, `automaticallyDetectsLanguage = true`. No language or mode picker.
- Tiling: 2048 px tiles, 64 px overlap. The dual-pass threshold is a longest side **over 4096 px**.
- No confusable folding in the output (#102 covers the scan input).
- User-facing strings, verbatim:
  - Name: `Extract Text (OCR)`
  - Nothing found: `No text was recognised in this image.`
  - Unreadable input: `Couldn't read this image.`
- Category: a new built-in category `Images`, after `Privacy` and before `Presets`.
- AGENTS.md and README are updated in the same PR.

## Review Focus

1. **The owner's 4095×1200 silent-empty case.** Below the dual-pass threshold, an empty whole-image result must trigger the tiled pass. (Task 1)
2. **Two columns side by side.** Observations whose vertical extents overlap join into one line, left to right. That's right for a terminal and a known limitation for true columns, and a test pins it so a change is deliberate. (Task 1)
3. **A TextEditor write-back of the *same* text** (focus, end of editing) must not count as typing, or ⌘Z would stop restoring the image the moment the editor appeared. (Task 3)
4. **OCR output containing a secret** gets the secret badge like any other text: detection runs on the pushed text. (Task 3)
5. **Typing, then deleting back to the recognised text**, still counts as edited, so ⌘Z stays the editor's. The toolbar Undo still restores the image. (Task 3)

---

### Task 1: `OCRLayout` — lines, tiles, de-duplication, strategy (pure)

**Files:**
- Create: `Sources/PastefixCore/Native/OCRLayout.swift`
- Test: `Tests/PastefixCoreTests/OCRLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public struct OCRObservation: Sendable, Equatable { public let text: String; public let box: CGRect; public init(text: String, box: CGRect) }`. `box` is in image pixels, **origin top-left**.
  - `public enum OCRLayout`, with:
    - `static let tileSize = 2048`, `static let tileOverlap = 64`, `static let dualPassThreshold = 4096`
    - `static func lines(_ observations: [OCRObservation]) -> [String]`
    - `static func tiles(width: Int, height: Int) -> [CGRect]`
    - `static func deduplicated(_ observations: [OCRObservation]) -> [OCRObservation]`
    - `static func characterCount(_ observations: [OCRObservation]) -> Int`
    - `static func recognize(width: Int, height: Int, whole: () throws -> [OCRObservation], tiled: () throws -> [OCRObservation]) rethrows -> [OCRObservation]`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PastefixCoreTests/OCRLayoutTests.swift
import Testing
import Foundation
import CoreGraphics
@testable import PastefixCore

@Suite("OCRLayout (#19)")
struct OCRLayoutTests {
    private func o(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 100, h: CGFloat = 20) -> OCRObservation {
        OCRObservation(text: text, box: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test("observations on one line join left to right; lines run top to bottom")
    func lines() {
        let obs = [o("world", x: 120, y: 12), o("second line", x: 10, y: 60), o("hello", x: 10, y: 10)]
        #expect(OCRLayout.lines(obs) == ["hello world", "second line"])
    }

    // Review Focus 2: row-based reassembly joins side-by-side columns into one line. Right for a
    // terminal; a known limitation for true columns. Pinned so a change is deliberate.
    @Test("two columns at the same height join into one line")
    func columns() {
        #expect(OCRLayout.lines([o("right", x: 600, y: 10), o("left", x: 10, y: 11)]) == ["left right"])
    }

    @Test("a token Vision split across observations comes out whole on one line")
    func splitToken() {
        #expect(OCRLayout.lines([o("export TOKEN=xoxb-", x: 10, y: 10), o("1234abcd", x: 220, y: 9)])
                == ["export TOKEN=xoxb- 1234abcd"])
    }

    @Test("tiles cover the image, overlap by 64 px, and clip at the edges")
    func tiles() {
        #expect(OCRLayout.tiles(width: 1000, height: 800) == [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        let t = OCRLayout.tiles(width: 5000, height: 2100)
        #expect(t.count == 3 * 2)
        #expect(t.contains(CGRect(x: 0, y: 0, width: 2048, height: 2048)))
        #expect(t.contains(CGRect(x: 1984, y: 0, width: 2048, height: 2048)))       // 2048 - 64
        #expect(t.contains(CGRect(x: 3968, y: 1984, width: 1032, height: 116)))     // clipped
        #expect(t.allSatisfy { $0.maxX <= 5000 && $0.maxY <= 2100 })
    }

    @Test("an observation seen twice in an overlap is kept once; a fragment inside a whole is dropped")
    func dedupe() {
        let a = o("same", x: 2000, y: 10, w: 60), b = o("same", x: 2002, y: 11, w: 60)
        let whole = o("abcdef", x: 1990, y: 50, w: 120), fragment = o("abc", x: 1990, y: 50, w: 55)
        let kept = OCRLayout.deduplicated([a, b, whole, fragment, o("other", x: 10, y: 10)])
        #expect(kept.map(\.text).sorted() == ["abcdef", "other", "same"])
    }

    @Test("under 4096 px: whole only, and tiles only when the whole pass is empty")
    func strategySmall() throws {
        var tiledRan = false
        let found = try OCRLayout.recognize(width: 3000, height: 2000,
                                            whole: { [o("hi", x: 0, y: 0)] },
                                            tiled: { tiledRan = true; return [] })
        #expect(found.map(\.text) == ["hi"] && !tiledRan)
    }

    // Review Focus 1: the owner measured .accurate returning zero lines at 4095×1200, just under
    // the dual-pass threshold. The empty-result fallback is what catches it.
    @Test("the measured 4095×1200 silent-empty case falls back to tiles")
    func strategyFallback() throws {
        let found = try OCRLayout.recognize(width: 4095, height: 1200, whole: { [] },
                                            tiled: { [o("found", x: 0, y: 0)] })
        #expect(found.map(\.text) == ["found"])
    }

    @Test("over 4096 px: both passes, keeping whichever recovers more characters")
    func strategyLarge() throws {
        let partialWhole = [o("127 lines, few tokens", x: 0, y: 0)]
        let fuller = [o("127 lines, few tokens", x: 0, y: 0), o("and the tokens too", x: 0, y: 40)]
        #expect(try OCRLayout.recognize(width: 5120, height: 2880, whole: { partialWhole }, tiled: { fuller }) == fuller)
        #expect(try OCRLayout.recognize(width: 5120, height: 2880, whole: { fuller }, tiled: { partialWhole }) == fuller)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter OCRLayoutTests 2>&1 | grep -E "error:" | head -2`
Expected: compile error (`OCRObservation` unknown).

- [ ] **Step 3: Implement**

```swift
// Sources/PastefixCore/Native/OCRLayout.swift
import Foundation
import CoreGraphics

/// One piece of recognised text and where it sits, in image pixels with the origin at the top left.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public init(text: String, box: CGRect) { self.text = text; self.box = box }
}

/// The pure half of OCR (#19): how observations become lines, how an image is tiled, and when to
/// tile. Kept apart from Vision so every rule is tested on constructed observations.
public enum OCRLayout {
    public static let tileSize = 2048
    public static let tileOverlap = 64
    /// Over this longest side both passes run (spec, part 2): on the owner's measurements,
    /// always-tiling lost recall on a real capture while a synthetic 5K render needed tiles.
    public static let dualPassThreshold = 4096

    /// Observations rebuilt into lines: grouped by overlapping vertical extent, top to bottom,
    /// each group joined left to right. A token Vision split across two observations comes out whole.
    public static func lines(_ observations: [OCRObservation]) -> [String] {
        var groups: [(minY: CGFloat, maxY: CGFloat, members: [OCRObservation])] = []
        for obs in observations.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let i = groups.indices.last,
               verticalOverlap(groups[i].minY, groups[i].maxY, obs.box.minY, obs.box.maxY)
                >= 0.5 * min(groups[i].maxY - groups[i].minY, obs.box.height) {
                groups[i].minY = min(groups[i].minY, obs.box.minY)
                groups[i].maxY = max(groups[i].maxY, obs.box.maxY)
                groups[i].members.append(obs)
            } else {
                groups.append((obs.box.minY, obs.box.maxY, [obs]))
            }
        }
        return groups.map { $0.members.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
    }

    private static func verticalOverlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// Tiles of `tileSize` stepping by `tileSize - tileOverlap`, clipped to the image.
    public static func tiles(width: Int, height: Int) -> [CGRect] {
        func starts(_ length: Int) -> [Int] {
            guard length > tileSize else { return [0] }
            return Array(stride(from: 0, to: length - tileOverlap, by: tileSize - tileOverlap))
        }
        return starts(height).flatMap { y in
            starts(width).map { x in
                CGRect(x: x, y: y, width: min(tileSize, width - x), height: min(tileSize, height - y))
            }
        }
    }

    /// Drops what the overlaps recognised twice: the same text in boxes that mostly coincide, and a
    /// fragment whose box lies mostly inside a longer observation that contains its text.
    public static func deduplicated(_ observations: [OCRObservation]) -> [OCRObservation] {
        var kept: [OCRObservation] = []
        for obs in observations.sorted(by: { $0.text.count > $1.text.count }) {
            let duplicate = kept.contains { k in
                let shared = k.box.intersection(obs.box)
                guard !shared.isNull else { return false }
                let area = shared.width * shared.height
                let sameText = k.text == obs.text && area >= 0.5 * min(k.box.width * k.box.height, obs.box.width * obs.box.height)
                let fragment = k.text.contains(obs.text) && area >= 0.8 * obs.box.width * obs.box.height
                return sameText || fragment
            }
            if !duplicate { kept.append(obs) }
        }
        return kept
    }

    public static func characterCount(_ observations: [OCRObservation]) -> Int {
        observations.reduce(0) { $0 + $1.text.count }
    }

    /// The size-dependent strategy. Over `dualPassThreshold` both passes run and the one recovering
    /// more characters wins (a tie keeps the whole pass). Otherwise the whole pass, with tiles only
    /// when it returned nothing — `.accurate` can return zero lines, silently, on an image full of
    /// text (the owner measured 4095×1200, just under the threshold).
    public static func recognize(width: Int, height: Int,
                                 whole: () throws -> [OCRObservation],
                                 tiled: () throws -> [OCRObservation]) rethrows -> [OCRObservation] {
        if max(width, height) > dualPassThreshold {
            let a = try whole(), b = try tiled()
            return characterCount(b) > characterCount(a) ? b : a
        }
        let a = try whole()
        return a.isEmpty ? try tiled() : a
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter OCRLayoutTests 2>&1 | grep -E "✘|Test run with"`
Expected: 8 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: OCRLayout — lines, tiles, de-duplication and the tiling strategy (#19)"
```

---

### Task 2: `TextRecognizer` and the "Extract Text (OCR)" transform

**Files:**
- Create: `Sources/PastefixCore/Native/TextRecognizer.swift`, `Sources/PastefixCore/Native/ExtractText.swift`
- Modify: `Sources/PastefixCore/Transformer.swift` (category), `Sources/PastefixCore/Discovery/TransformerRegistry.swift`
- Test: `Tests/PastefixCoreTests/ExtractTextTests.swift`; update `TransformerRegistryTests.swift` (ids, count 28→29, `builtinOrder`) and `TransformerLimitsTests.swift` (the limits table)

**Interfaces:**
- Consumes: `OCRLayout`, `OCRObservation` (Task 1); `ImageTransformer`, `TransformOutput` (Plan 20).
- Produces: `public struct ExtractText: ImageTransformer`, with id `builtin.extracttext` and `static let noTextMessage = "No text was recognised in this image."`; `TransformCategory.images = "Images"`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PastefixCoreTests/ExtractTextTests.swift
import Testing
import Foundation
import AppKit
@testable import PastefixCore

/// A synthetic-render recall suite (#19, requirement 5): text rendered in-process, no committed
/// fixtures, recognised by the real Vision request.
@Suite("Extract Text (OCR) (#19)")
struct ExtractTextTests {
    static func render(_ lines: [String], width: Int = 900, height: Int = 240, fontSize: CGFloat = 28) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 20, y: CGFloat(height) - 60 - CGFloat(i) * fontSize * 1.8),
                                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                                     .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @Test("recognises rendered lines, top to bottom")
    func recall() throws {
        let png = try #require(Self.render(["export API_TOKEN=abc123", "second line here"]))
        guard case .text(let text) = try ExtractText().transformImage(png) else {
            Issue.record("expected text"); return
        }
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.contains("API_TOKEN") == true)
        #expect(lines.last?.contains("second") == true)
    }

    @Test("an image with no text is nothing to do")
    func noText() throws {
        let png = try #require(Self.render([]))
        #expect(try ExtractText().transformImage(png) == .nothingToDo(ExtractText.noTextMessage))
    }

    @Test("bytes that aren't an image are refused")
    func notAnImage() {
        #expect(throws: TransformError.self) { try ExtractText().transformImage(Data("nope".utf8)) }
    }

    @Test("it is registered, in Images, for images only")
    func registered() {
        let t = TransformerRegistry(config: RegistryConfig(scriptsDirectory: URL(fileURLWithPath: "/nonexistent")))
            .load().first { $0.id == "builtin.extracttext" }
        #expect(t?.name == "Extract Text (OCR)" && t?.category == TransformCategory.images)
        #expect(t?.acceptedForms == [.image])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter ExtractTextTests 2>&1 | grep -E "error:" | head -2`
Expected: compile error (`ExtractText` unknown).

- [ ] **Step 3: Implement the recogniser**

```swift
// Sources/PastefixCore/Native/TextRecognizer.swift
import Foundation
import CoreGraphics
import Vision

/// Vision's text recognition, as `OCRObservation`s in image pixels (origin top-left). The settings
/// are the owner's measurements on #19: `.accurate` recalled more than twice what `.fast` did on
/// a real capture, and language correction rewrites tokens, which is the wrong thing for text
/// that may be a key.
enum TextRecognizer {
    static func recognize(_ image: CGImage) throws -> [OCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            // Vision's boxes are normalised with the origin at the bottom left.
            let b = observation.boundingBox
            return OCRObservation(text: text, box: CGRect(x: b.minX * width, y: (1 - b.maxY) * height,
                                                          width: b.width * width, height: b.height * height))
        }
    }

    /// Recognises each tile and maps its observations back into the whole image, dropping what the
    /// overlaps saw twice.
    static func recognizeTiled(_ image: CGImage) throws -> [OCRObservation] {
        var all: [OCRObservation] = []
        for tile in OCRLayout.tiles(width: image.width, height: image.height) {
            guard let cropped = image.cropping(to: tile) else { continue }
            all += try recognize(cropped).map {
                OCRObservation(text: $0.text, box: $0.box.offsetBy(dx: tile.minX, dy: tile.minY))
            }
        }
        return OCRLayout.deduplicated(all)
    }
}
```

- [ ] **Step 4: Implement the transform and register it**

```swift
// Sources/PastefixCore/Native/ExtractText.swift
import Foundation
import ImageIO

/// ⌘K "Extract Text (OCR)" (#19): the image's text, as the session's next entry — the session
/// becomes a text session, and ⌘Z (until the user types) or the Undo button brings the image back.
/// Runs on the image-transform lane (`ImageTransformer`), under the coordinator's pixel ceiling.
///
/// No confusable folding: the output is the user's text, and folding Cyrillic or other lookalikes
/// to ASCII would corrupt genuine non-Latin text. The secret scan's input is #102's question.
public struct ExtractText: ImageTransformer {
    public let id = "builtin.extracttext"
    public let name = "Extract Text (OCR)"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images
    /// Deliberately not "this image has no text": Vision can return nothing on an image full of it.
    public static let noTextMessage = "No text was recognised in this image."
    public init() {}

    public func transformImage(_ png: Data) throws -> TransformOutput {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TransformError.invalidInput("Couldn't read this image.")
        }
        let observations = try OCRLayout.recognize(width: image.width, height: image.height,
                                                   whole: { try TextRecognizer.recognize(image) },
                                                   tiled: { try TextRecognizer.recognizeTiled(image) })
        let text = OCRLayout.lines(observations).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothingToDo(Self.noTextMessage)
        }
        return .text(text)
    }
}
```

In `Transformer.swift`'s `TransformCategory`, add `public static let images = "Images"` after `privacy`, and change `builtinOrder` to `[layout, richText, characters, urls, `case`, data, colors, privacy, images, presets]`.

In `TransformerRegistry.load()`, after the Strip Image Metadata line, add:

```swift
            (112, "Extract Text (OCR)", ExtractText()),
```

- [ ] **Step 5: Update the pinned suites**
  - `TransformerRegistryTests`: add `"builtin.extracttext"` after `"builtin.stripimagemetadata"` in the ids list; change the count from 28 to 29; make the `builtinOrder` expectation `["Layout", "Rich Text", "Characters", "URLs", "Case", "Data", "Colors", "Privacy", "Images", "Presets"]`.
  - `TransformerLimitsTests`: add `"builtin.extracttext": (TransformLimits.defaultMaxInputBytes, 10),` under the Strip entry.
  - `SidebarGroupingTests`: if it pins the built-in order, add `Images` in the same place.

- [ ] **Step 6: Run everything**

Run: `swift test 2>&1 | grep -E "✘ Test.*recorded|Test run with"`; `scripts/test-app.sh 2>&1 | grep -E "Test run with|error:"`
Expected: green; the recall test passes against real Vision. If `recall` fails on recognition itself (not assembly), do not loosen it to `contains("TOKEN")`; raise the font to 36 and record the measurement in the ledger.

- [ ] **Step 7: Mutation check**

Set `request.recognitionLevel = .fast` and run `swift test --filter ExtractTextTests`. Record whether `recall` notices: it may not on friendly synthetic text, which is exactly the owner's finding. Restore. Then replace `OCRLayout.lines(observations)` with `observations.map(\.text)` and confirm `recall` still passes (its lines are one observation each), which shows the order assertion comes from Vision's order. Record both results in the ledger.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: Extract Text (OCR), a ⌘K transform for image sessions (#19)"
```

---

### Task 3: ⌘Z undoes OCR until you type

**Files:**
- Modify: `Sources/PastefixAppCore/PasteDocument.swift`, `Pastefix/Pastefix/PanelView.swift`
- Test: `Tests/PastefixAppCoreTests/PasteDocumentEntryTests.swift`, `Pastefix/PastefixTests/ImageUndoShortcutTests.swift`, `Pastefix/PastefixTests/TransformNoteTests.swift`

**Interfaces:**
- Consumes: `PasteDocument.Entry`, `push`, `setWorking` (Plan 20).
- Produces: `PasteDocument.undoRestoresImage: Bool`, true when the current entry is untouched text pushed over an image entry.

- [ ] **Step 1: Write the failing tests**

In `PasteDocumentEntryTests`, add:

```swift
    // Plan 21: ⌘Z is the editor's typing undo in a text session (#103). While text a transform
    // produced from an image is untouched, ⌘Z restores the image instead.
    @Test("undoRestoresImage: untouched text over an image, until the user types")
    func undoRestoresImage() {
        var d = imageDoc()
        #expect(!d.undoRestoresImage, "on the image itself")
        d.pushState("recognised")
        #expect(d.undoRestoresImage)
        // Review Focus 3: a write-back of the same text (focus, end of editing) is not typing.
        d.setWorking("recognised")
        #expect(d.undoRestoresImage)
        d.setWorking("recognised!")
        #expect(!d.undoRestoresImage)
        // Review Focus 5: typing back to the recognised text still counts as edited.
        d.setWorking("recognised")
        #expect(!d.undoRestoresImage)
        let text = PasteDocument(origin: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        #expect(!text.undoRestoresImage, "a text session never restores an image")
    }
```

In `ImageUndoShortcutTests`, add:

```swift
    @Test("after OCR, ⌘Z restores the image until the user types")
    func ocrUndo() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        let window = host(f); defer { window.orderOut(nil) }
        f.model.apply(Reading(text: "recognised"))
        #expect(await f.eventually { f.model.document?.working == "recognised" })
        #expect(await press(window) { f.model.document?.imagePNG == png }, "⌘Z restores the image")

        f.model.redo()
        #expect(await f.eventually { f.model.document?.working == "recognised" })
        f.model.setWorking("recognised, edited")
        let undid = await press(window) { f.model.document?.displaysAsImage == true }
        #expect(!undid, "once the user types, ⌘Z is the editor's")
    }
```

with, at the top of the file:

```swift
private struct Reading: ImageTransformer {
    let id = "test.reading"; let name = "Reading"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.reading")
    let text: String
    func transformImage(_ png: Data) throws -> TransformOutput { .text(text) }
}
```

In `TransformNoteTests`, add (Review Focus 4):

```swift
    @Test("OCR output containing a secret gets the badge, like any other text")
    func ocrSecretBadge() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        f.model.apply(Noting(result: .text("token: ABCD1234EFGH5678ijkl")))
        #expect(await f.eventually { f.model.document?.secretMatches.isEmpty == false })
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter PasteDocumentEntryTests 2>&1 | grep -E "error:" | head -2`; `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test" | head -4`
Expected: compile error (`undoRestoresImage` unknown). The secret-badge test may already pass: it pins behaviour Plan 20 gave for free. Record which.

- [ ] **Step 3: Implement in `PasteDocument`**

Beside `entryNotes`, add:

```swift
    /// Whether each entry has been typed into since it was pushed. Only `setWorking` with
    /// *different* text sets it — the TextEditor writes the same text back on focus and at the end
    /// of editing, and that is not typing. Decides `undoRestoresImage` (Plan 21).
    private var entryEdited: [Bool]
```

In `init`, `self.entryEdited = [false]`. In `push`, after the notes lines:

```swift
        entryEdited = Array(entryEdited.prefix(cursor + 1))
        entryEdited.append(false)
```

In `setWorking`, before assigning the entry:

```swift
        if case .text(let current) = currentEntry, current != text { entryEdited[cursor] = true }
```

and add:

```swift
    /// True when ⌘Z should restore an image rather than undo typing: the current entry is text a
    /// transform pushed over an image entry (OCR), and the user hasn't typed into it. In a text
    /// session ⌘Z is the editor's typing undo (#103); until there is typing to undo, the image is
    /// what the user expects back. Typing back to the original text still counts as edited.
    public var undoRestoresImage: Bool {
        guard cursor > 0, case .text = currentEntry, case .image = entries[cursor - 1] else { return false }
        return !entryEdited[cursor]
    }
```

- [ ] **Step 4: Implement in `PanelView`**

Replace `imageUndoKeys`:

```swift
    /// ⌘Z/⌘⇧Z belong to the toolbar's Undo/Redo while an image is showing, or while untouched OCR
    /// text sits over one (Plan 21: until the user types, ⌘Z brings the image back), and no overlay
    /// is up. Otherwise ⌘Z is the editor's typing undo (#103).
    private var imageUndoKeys: Bool {
        guard let document = model.document, !isPaletteOpen, !isHistoryOpen, !isUploadOpen else { return false }
        return document.displaysAsImage || document.undoRestoresImage
    }
```

Update the Undo button's comment to match.

- [ ] **Step 5: Run everything, mutation-check, commit**

Run both suites; expected green. Mutation: make `undoRestoresImage` ignore `entryEdited` (`return true` after the guard). `undoRestoresImage` and `ocrUndo` must fail. Restore.

```bash
git add -A && git commit -m "feat: ⌘Z undoes OCR until you type (#19)"
```

---

### Task 4: Documentation and the owner's GUI pass

- [ ] **Step 1: AGENTS.md.**
  - Rows for `OCRLayout.swift`, `TextRecognizer.swift` and `ExtractText.swift` (Core `Native/`), in the style of the Strip row.
  - The `PasteDocument.swift` row gains "`entryEdited` + `undoRestoresImage` (⌘Z undoes OCR until you type; a same-text write-back is not typing)".
  - The `PanelView.swift` row's ⌘Z note gains the OCR case.
  - The `Transformer.swift` row's category list gains `Images`.
- [ ] **Step 2: README.** After the Strip sentence in the image-sessions paragraph, add: "It also offers **Extract Text (OCR)**, which reads the text in the picture and puts it in the editor in place of the picture. Until you type into it, ⌘Z brings the picture back; after that, ⌘Z undoes your typing and the Undo button brings the picture back. If nothing is found it says so rather than emptying the editor."
- [ ] **Step 3: Status.** This plan's status becomes `implemented`; the spec's becomes `implemented (Plans 20 and 21)`.
- [ ] **Step 4: Run both suites; commit.**

```bash
git add -A && git commit -m "docs: OCR in AGENTS and README (Plan 21)"
```

- [ ] **Step 5: Owner GUI pass** (Developer-ID-signed Debug build, `pb begin`/`pb end`, per `docs/gui-automation.md`):
  1. ⌃⇧⌘4 a region of a terminal window to the clipboard. Summon, ⌘K → Extract Text (OCR). The editor shows the text, in reading order.
  2. ⌘Z: the picture is back. ⌘⇧Z: the text again.
  3. Type a character, then ⌘Z: it undoes the character, not the OCR. The Undo button then brings the picture back.
  4. ⌘S after OCR: the clipboard holds the text only.
  5. OCR a screenshot with no text (a solid area): "No text was recognised in this image."
