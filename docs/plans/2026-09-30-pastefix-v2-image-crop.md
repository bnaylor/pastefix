# Image crop and the image region selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag a rectangle on an image in the panel, choose **Crop to Selection**, and the image becomes that rectangle, as one undo step. ⌘Z restores the image and the region.

**Architecture:**
- **Core:** a pixel `ImageRegion` (oriented coordinates) reaches transforms through `TransformInput.region`. The new `RegionImageTransformer` protocol's first conformer is `CropToSelection`.
- **AppCore:** #25's text scope is renamed `TextScope`, and `TransformScope` becomes an enum, `.text` or `.image(region, revision)`, so both kinds of selection reach the coordinator through one channel.
- **App:** the region lives in `PanelView` state and is drawn and edited by an overlay on the fitted image. Esc clears it in `escape()`. The undo step records it, and `pendingImageRegion` restores it on ⌘Z.

**Tech Stack:** Swift 6, SwiftUI and AppKit (macOS 15), ImageIO and CoreGraphics, Swift Testing, SwiftPM (`PastefixCore`, `PastefixAppCore`), and the hosted app tests (`scripts/test-app.sh`, run under the GUI lease: `python3 ~/.claude/skills/gui-test-lease/lease.py acquire|release`).

**Spec:** `docs/specs/2026-09-30-pastefix-v2-image-crop.md`

## Global Constraints

- A region is in **oriented image pixels**, origin top-left, `Int` fields, with EXIF orientation applied (widths and heights swap for orientations 5–8). Map using the header's pixel size, **never** the displayed `NSImage`'s.
- The image scope carries the `detectionRevision` it was drawn on. If it's stale, or out of bounds, it's refused with exactly `"The image changed after you selected a region. Select it again."`.
- The no-region note is exactly `"Drag on the image to choose what to keep, then choose Crop to Selection."`. The whole-image note is `"The selection is the whole image."`. The result note is `"Cropped to W×H."`, with the multiplication sign ×.
- `builtin.crop`, name `"Crop to Selection"`, category `TransformCategory.images`, registry order **113**.
- Crop keeps the colour profile (no profile conversion) and drops metadata (re-encoded through `PNGEncoder`).
- The region is never stored on `AppModel` as live state. Only the one-shot `pendingImageRegion` is.
- Esc order in `PanelView.escape()`: palette, then history, then upload, then preview, then **region**, then cancel.
- ⌘Z after **any** apply made with a region up restores the region.
- Gesture: a single `DragGesture(minimumDistance: 0)`. Travel under **3 pt** is a tap. Handle hit targets are **8 pt**. The region is at least 1 px. The gesture is disabled while applying or uploading.
- Drawing: a two-tone outline (1 pt white over a 1 pt black hairline); handles with a white fill, a dark 1 pt border and a small shadow; dimming at 50% black outside the region.
- With an image scope, transforms that can't use it are marked **"whole image"**; with a text scope, "whole buffer", as before.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv`.

## Review Focus

1. **A 90°-rotated PNG** (eXIf orientation 6): the region the user draws, the footer's size and the crop all agree (Task 1 `orientation6CropsWhatWasDrawn`, Task 4 footer).
2. **A huge screenshot shown downsampled:** the crop uses header pixels, not the displayed bitmap's (Task 1 `viewToPixelsUsesThePixelSizeNotTheDisplay`).
3. **Undo after a non-crop transform with a region up** (Strip Metadata, then ⌘Z) restores the region (Task 4 `undoAfterAnyImageTransformRestoresTheRegion`).
4. **A stale region after undo, redo or refresh** is refused, never cropped against the wrong image (Task 2 `staleImageScopeIsRefused`).
5. **Esc with a region up** clears the region and keeps the panel open; a second Esc cancels (Task 4 `escClearsTheRegionFirst`).

---

### Task 1: Core: `ImageRegion`, region input, `RegionImageTransformer`, `CropToSelection`

**Files:**
- Create: `Sources/PastefixCore/ImageRegion.swift`
- Create: `Sources/PastefixCore/Native/CropToSelection.swift`
- Modify: `Sources/PastefixCore/Transformer.swift`: add `region` to `TransformInput`.
- Modify: `Sources/PastefixCore/ImageTransformer.swift`: add `RegionImageTransformer`.
- Modify: `Sources/PastefixCore/Discovery/TransformerRegistry.swift`: register it at 113.
- Test: `Tests/PastefixCoreTests/ImageRegionTests.swift`, `Tests/PastefixCoreTests/CropToSelectionTests.swift`
- Modify tests: `TransformerRegistryTests.swift` (ids, count 30 → 31, category), `TransformerLimitsTests.swift` (add `"builtin.crop": (TransformLimits.defaultMaxInputBytes, 10)` to its table).

**Interfaces (produces):**
- `public struct ImageRegion: Sendable, Equatable, Codable { public let x, y, width, height: Int; public init(x:y:width:height:); public var isEmpty: Bool }`
- `public static func ImageRegion.orientedPixelSize(of png: Data) -> (width: Int, height: Int)?`
- `public static func ImageRegion.from(viewRect: CGRect, imageFrame: CGRect, pixelSize: (width: Int, height: Int)) -> ImageRegion?` (nil for a zero-area rect)
- `public func ImageRegion.viewRect(imageFrame: CGRect, pixelSize: (width: Int, height: Int)) -> CGRect`
- `public func ImageRegion.fits(_ pixelSize: (width: Int, height: Int)) -> Bool`
- `TransformInput.region: ImageRegion?` (init parameter `region: ImageRegion? = nil`)
- `public protocol RegionImageTransformer: ImageTransformer { func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput }`
- `public struct CropToSelection: RegionImageTransformer`, with `static let noRegionMessage`, `wholeImageMessage`, and `static func resultNote(_ w: Int, _ h: Int) -> String`

- [ ] **Step 1: Write the failing tests**

`Tests/PastefixCoreTests/ImageRegionTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import PastefixCore

@Suite struct ImageRegionTests {
    @Test func viewToPixelsUsesThePixelSizeNotTheDisplay() {
        // A 6000×3000 image drawn in a 600×300 frame (it's downsampled on screen): 10 px per point.
        let frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        let r = ImageRegion.from(viewRect: CGRect(x: 10, y: 20, width: 30, height: 40), imageFrame: frame, pixelSize: (6000, 3000))
        #expect(r == ImageRegion(x: 100, y: 200, width: 300, height: 400))
    }

    @Test func roundsOutwardAndClamps() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        // 100×100 image in 300×200: 1/3 px per point horizontally, 1/2 vertically.
        let r = ImageRegion.from(viewRect: CGRect(x: 1, y: 1, width: 1, height: 1), imageFrame: frame, pixelSize: (100, 100))
        #expect(r == ImageRegion(x: 0, y: 0, width: 1, height: 1), "at least 1 px, rounded outward")
        let over = ImageRegion.from(viewRect: CGRect(x: -50, y: -50, width: 500, height: 500), imageFrame: frame, pixelSize: (100, 100))
        #expect(over == ImageRegion(x: 0, y: 0, width: 100, height: 100))
        #expect(ImageRegion.from(viewRect: CGRect(x: 5, y: 5, width: 0, height: 10), imageFrame: frame, pixelSize: (100, 100)) == nil)
    }

    @Test func viewRectIsTheInverse() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        let r = ImageRegion(x: 100, y: 200, width: 300, height: 400)
        #expect(r.viewRect(imageFrame: frame, pixelSize: (6000, 3000)) == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @Test func fits() {
        #expect(ImageRegion(x: 0, y: 0, width: 10, height: 10).fits((10, 10)))
        #expect(!ImageRegion(x: 5, y: 0, width: 10, height: 10).fits((10, 10)))
        #expect(ImageRegion(x: 0, y: 0, width: 0, height: 5).isEmpty)
    }

    @Test func orientedPixelSizeSwapsFor5Through8() throws {
        let up = try #require(Fixture.image(as: "public.png", orientation: 1))
        let rotated = try #require(Fixture.image(as: "public.png", orientation: 6))
        #expect(ImageRegion.orientedPixelSize(of: up).map { [$0.width, $0.height] } == [60, 40])
        #expect(ImageRegion.orientedPixelSize(of: rotated).map { [$0.width, $0.height] } == [40, 60])
        #expect(ImageRegion.orientedPixelSize(of: Data("no".utf8)) == nil)
    }
}
```

`Tests/PastefixCoreTests/CropToSelectionTests.swift` (the `Fixture` is 60×40, left half red, right half blue, with GPS; see `ImageSanitizerTests.swift`):

```swift
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

@Suite struct CropToSelectionTests {
    private let crop = CropToSelection()

    /// The RGB at (x, y), top-left origin, read by drawing the image into an sRGB bitmap.
    private func rgb(_ png: Data, _ x: Int, _ y: Int) throws -> [UInt8] {
        let image = try #require(Fixture.decoded(png))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(px.prefix(3))
    }
    private func isRed(_ c: [UInt8]) -> Bool { c[0] > 150 && c[2] < 100 }
    private func isBlue(_ c: [UInt8]) -> Bool { c[2] > 150 && c[0] < 100 }

    @Test func cropsToTheRegion() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        guard case .image(let out, let note) = try crop.transformImage(png, region: ImageRegion(x: 25, y: 5, width: 10, height: 20))
        else { Issue.record("expected an image"); return }
        let props = try #require(Fixture.properties(out))
        #expect(props[kCGImagePropertyPixelWidth as String] as? Int == 10 && props[kCGImagePropertyPixelHeight as String] as? Int == 20)
        #expect(note == "Cropped to 10×20.")
        #expect(isRed(try rgb(out, 0, 10)) && isBlue(try rgb(out, 9, 10)), "red on the left, blue on the right")
        #expect(props[kCGImagePropertyGPSDictionary as String] == nil, "metadata is dropped")
    }

    @Test func noRegionSaysHow() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        #expect(try crop.transformImage(png, region: nil) == .nothingToDo(CropToSelection.noRegionMessage))
        #expect(try crop.transformImage(png) == .nothingToDo(CropToSelection.noRegionMessage))
    }

    @Test func wholeImageIsNothingToDo() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        #expect(try crop.transformImage(png, region: ImageRegion(x: 0, y: 0, width: 60, height: 40))
                == .nothingToDo(CropToSelection.wholeImageMessage))
    }

    /// Review Focus 1: orientation 6 displays 40×60, with the left (red) half on TOP.
    @Test func orientation6CropsWhatWasDrawn() throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        guard case .image(let top, _) = try crop.transformImage(png, region: ImageRegion(x: 0, y: 0, width: 40, height: 30))
        else { Issue.record("expected an image"); return }
        #expect(isRed(try rgb(top, 20, 15)))
        guard case .image(let bottom, _) = try crop.transformImage(png, region: ImageRegion(x: 0, y: 30, width: 40, height: 30))
        else { Issue.record("expected an image"); return }
        #expect(isBlue(try rgb(bottom, 20, 15)))
    }

    @Test func keepsTheColourProfile() throws {
        let png = try #require(Fixture.image(as: "public.png"))   // Display P3
        guard case .image(let out, _) = try crop.transformImage(png, region: ImageRegion(x: 0, y: 0, width: 10, height: 10))
        else { Issue.record("expected an image"); return }
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test func registeredInImages() {
        let t = CropToSelection()
        #expect(t.id == "builtin.crop" && t.name == "Crop to Selection" && t.category == TransformCategory.images)
        #expect(t.acceptedForms == [.image])
    }
}
```

In `TransformerRegistryTests.swift`: add `"builtin.crop"` after `"builtin.extracttext"` in the ordered id list, change `count == 30` to `count == 31`, and add `#expect(byID["builtin.crop"] == TransformCategory.images)` beside the extract-text category assertion. In `TransformerLimitsTests.swift`, add `"builtin.crop": (TransformLimits.defaultMaxInputBytes, 10),` to the table.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "ImageRegionTests|CropToSelectionTests" 2>&1 | grep -E "error:|Test run" | head -3`
Expected: `cannot find 'ImageRegion' in scope`. Then add stubs with Step 3's signatures (returning nil, `.zero`, `false`, or `.nothingToDo("")`) and re-run. Expected: behavioural failures.

- [ ] **Step 3: Implement**

`Sources/PastefixCore/ImageRegion.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO

/// A rectangle on an image, in the image's **oriented** pixels (EXIF orientation applied, as the
/// panel draws it), origin top-left. Region-aware image transforms (crop; redact later) act on it.
public struct ImageRegion: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isEmpty: Bool { width < 1 || height < 1 }

    public func fits(_ pixelSize: (width: Int, height: Int)) -> Bool {
        !isEmpty && x >= 0 && y >= 0 && x + width <= pixelSize.width && y + height <= pixelSize.height
    }

    /// The image's size as displayed: the header's pixel size, with width and height swapped for
    /// orientations 5–8 (the rotated ones). Header only; nothing is decoded.
    public static func orientedPixelSize(of png: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = (p[kCGImagePropertyOrientation] as? Int) ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }

    /// `viewRect` (points, in the same space as `imageFrame`, the fitted image's rect) as image
    /// pixels: rounded outward so a non-empty drag is at least 1 px, and clamped to the image. Nil
    /// for a zero-area rect.
    public static func from(viewRect: CGRect, imageFrame: CGRect, pixelSize: (width: Int, height: Int)) -> ImageRegion? {
        guard viewRect.width > 0, viewRect.height > 0, imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let sx = Double(pixelSize.width) / imageFrame.width
        let sy = Double(pixelSize.height) / imageFrame.height
        func clampX(_ v: Double) -> Int { min(max(Int(v), 0), pixelSize.width) }
        func clampY(_ v: Double) -> Int { min(max(Int(v), 0), pixelSize.height) }
        let x0 = clampX(((viewRect.minX - imageFrame.minX) * sx).rounded(.down))
        let x1 = clampX(((viewRect.maxX - imageFrame.minX) * sx).rounded(.up))
        let y0 = clampY(((viewRect.minY - imageFrame.minY) * sy).rounded(.down))
        let y1 = clampY(((viewRect.maxY - imageFrame.minY) * sy).rounded(.up))
        let region = ImageRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return region.isEmpty ? nil : region
    }

    /// The inverse of `from`: this region in view points, for drawing it over the fitted image.
    public func viewRect(imageFrame: CGRect, pixelSize: (width: Int, height: Int)) -> CGRect {
        let sx = imageFrame.width / Double(max(pixelSize.width, 1))
        let sy = imageFrame.height / Double(max(pixelSize.height, 1))
        return CGRect(x: imageFrame.minX + Double(x) * sx, y: imageFrame.minY + Double(y) * sy,
                      width: Double(width) * sx, height: Double(height) * sy)
    }
}
```

In `Transformer.swift`, `TransformInput` becomes:

```swift
public struct TransformInput: Sendable {
    public let text: String
    public let richRTFD: Data?
    public let image: Data?
    /// The selected region of `image`, for a `RegionImageTransformer` (crop). Nil otherwise.
    public let region: ImageRegion?

    public init(text: String, richRTFD: Data? = nil, image: Data? = nil, region: ImageRegion? = nil) {
        self.text = text
        self.richRTFD = richRTFD
        self.image = image
        self.region = region
    }
}
```

At the end of `ImageTransformer.swift`:

```swift
/// An image transform that acts on a selected region (crop now; redact later). The region comes in
/// on `TransformInput.region`, and is nil when nothing is selected, which the transform explains.
public protocol RegionImageTransformer: ImageTransformer {
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput
}

public extension RegionImageTransformer {
    func transformImage(_ png: Data) throws -> TransformOutput { try transformImage(png, region: nil) }

    func transform(_ input: TransformInput) async throws -> TransformOutput {
        guard let png = input.image else { throw TransformError.invalidInput("\(name) needs an image.") }
        let region = input.region
        return try await ImageTransformLane.run(on: lane) { try self.transformImage(png, region: region) }
    }
}
```

`Sources/PastefixCore/Native/CropToSelection.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO

/// Crops the image to the selected region. The decode applies EXIF orientation (the region is in
/// oriented pixels, as the panel draws the image) and does no colour-profile conversion, so
/// cropping never shifts colours. The re-encode drops metadata, as Strip Image Metadata does.
/// `cropping(to:)` shares the decoded image's storage, so peak memory is one full decode, run on
/// the image lane like every image transform.
public struct CropToSelection: RegionImageTransformer {
    public let id = "builtin.crop"
    public let name = "Crop to Selection"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init() {}

    public static let noRegionMessage = "Drag on the image to choose what to keep, then choose Crop to Selection."
    public static let wholeImageMessage = "The selection is the whole image."
    public static func resultNote(_ w: Int, _ h: Int) -> String { "Cropped to \(w)×\(h)." }

    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let size = ImageRegion.orientedPixelSize(of: png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits(size) else { throw TransformError.invalidInput("The selection is outside the image.") }
        if region.width == size.width, region.height == size.height { return .nothingToDo(Self.wholeImageMessage) }
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw TransformError.invalidInput("This image can't be read.")
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ] as CFDictionary
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let cropped = oriented.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)),
              let out = PNGEncoder.encode(cropped) else {
            throw TransformError.invalidInput("\(name) couldn't crop this image.")
        }
        return .image(out, note: Self.resultNote(region.width, region.height))
    }
}
```

In `TransformerRegistry.swift`, after `(112, "Extract Text (OCR)", ExtractText()),` add `(113, "Crop to Selection", CropToSelection()),`.

**If `keepsTheColourProfile` fails** (the thumbnail API converted the colour space), replace the decode with `CGImageSourceCreateImageAtIndex` plus an explicit orientation transform drawn into a context created with the source image's `colorSpace`. Record a ruling.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "ImageRegionTests|CropToSelectionTests|TransformerRegistryTests|TransformerLimitsTests" 2>&1 | grep -E "✘|Test run with" | tail -2`
Expected: passed.

- [ ] **Step 5: Run the package suite and commit**

Run: `swift test 2>&1 | grep -E "✘ Test|Test run with" | tail -1`
Expected: passed, 1 known issue.

```bash
git add Sources/PastefixCore Tests/PastefixCoreTests
git commit -m "feat: ImageRegion and Crop to Selection, the first region-aware image transform" -m "A region in oriented image pixels reaches RegionImageTransformers through TransformInput.region. Crop decodes with orientation applied, keeps the colour profile, drops metadata; no region or the whole image is nothing to do." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 2: AppCore: `TransformScope` becomes `.text` / `.image`; coordinator image scope; drag geometry

**Files:**
- Rename: `Sources/PastefixAppCore/TransformScope.swift` → `Sources/PastefixAppCore/TextScope.swift`, with the type renamed `TextScope`.
- Create: `Sources/PastefixAppCore/TransformScope.swift` (the enum)
- Create: `Sources/PastefixAppCore/RegionGeometry.swift` (pure drag and hit-test maths)
- Modify: `Sources/PastefixAppCore/TransformCoordinator.swift`
- Modify (mechanical, rename only): `Tests/PastefixAppCoreTests/TransformScopeTests.swift`, `Pastefix/Pastefix/SelectionScope.swift`, `Pastefix/Pastefix/AppModel.swift`, `Pastefix/Pastefix/CommandPaletteView.swift`, `Pastefix/Pastefix/SidebarView.swift`, `Pastefix/PastefixTests/SelectionScopeModelTests.swift`, `Pastefix/PastefixTests/SelectionScopeTests.swift`
- Test: `Tests/PastefixAppCoreTests/ImageScopeTests.swift`, `Tests/PastefixAppCoreTests/RegionGeometryTests.swift`

**Interfaces:**
- Consumes: Task 1's `ImageRegion`, `RegionImageTransformer`, `CropToSelection`, `TransformInput(region:)`.
- Produces:
  - `public struct TextScope`: exactly #25's `TransformScope` API, renamed.
  - `public enum TransformScope: Sendable, Equatable { case text(TextScope); case image(ImageRegion, revision: Int); public var text: TextScope?; public var imageRegion: ImageRegion?; public var wholeLabel: String }`
  - `TransformCoordinator.canScope(_ t: any Transformer, for scope: TransformScope) -> Bool`
  - `TransformCoordinator.staleImageRegionMessage: String` (static let)
  - `TransformCoordinator.apply(_:to:region:)`: the unscoped apply gains `region: ImageRegion? = nil`.
  - `public enum RegionHandle: CaseIterable, Sendable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }`
  - `public enum RegionHit: Equatable, Sendable { case new, move, handle(RegionHandle) }`
  - `public enum RegionGeometry { static let handleHitSize: CGFloat = 8; static let tapTravel: CGFloat = 3; static func handlePoints(_ r: CGRect) -> [(RegionHandle, CGPoint)]; static func hit(_ p: CGPoint, selection: CGRect?) -> RegionHit; static func dragged(_ hit: RegionHit, from: CGPoint, to: CGPoint, original: CGRect?, bounds: CGRect) -> CGRect; static func isTap(from: CGPoint, to: CGPoint) -> Bool }`

- [ ] **Step 1: Do the rename (mechanical), and confirm #25's tests still pass**

```bash
git mv Sources/PastefixAppCore/TransformScope.swift Sources/PastefixAppCore/TextScope.swift
python3 - <<'PY'
import re
p="Sources/PastefixAppCore/TextScope.swift"; s=open(p).read()
s=s.replace("public struct TransformScope:", "public struct TextScope:").replace("-> TransformScope?", "-> TextScope?").replace("TransformScope(range:", "TextScope(range:").replace("scope: TransformScope?", "scope: TextScope?")
open(p,"w").write(s)
PY
```

Then create `Sources/PastefixAppCore/TransformScope.swift`:

```swift
import Foundation
import PastefixCore

/// What a transform is scoped to: a text selection (#25) or a region of the image. One channel from
/// the view to the coordinator for both.
public enum TransformScope: Sendable, Equatable {
    case text(TextScope)
    /// A region drawn on the image entry whose `detectionRevision` was `revision`.
    case image(ImageRegion, revision: Int)

    public var text: TextScope? { if case .text(let t) = self { t } else { nil } }
    public var imageRegion: ImageRegion? { if case .image(let r, _) = self { r } else { nil } }

    /// How a transform that can't use this scope is marked in the palette and sidebar.
    public var wholeLabel: String { text != nil ? "whole buffer" : "whole image" }
}
```

Update the #25 call sites:
- **`TransformCoordinator.swift`:** in `apply(_:to:scope:)`, switch on the enum (Step 3 shows the full body).
- **`AppModel.swift`:** `scope?.range` becomes `scope?.text?.range`. In the `selectAfter` closure, `guard let scope,` becomes `guard let scope = scope?.text,`.
- **`SelectionScope.swift`:** `return TransformScope.make(selected: range, in: text)` becomes `return TextScope.make(selected: range, in: text).map(TransformScope.text)`.
- **`CommandPaletteView.swift`:**
  - `TransformScope.rankingKinds(scope: scope,` becomes `TextScope.rankingKinds(scope: scope?.text,`.
  - The subtitle's `scope != nil && !TransformCoordinator.canScope(result.transformer) ? " · whole buffer" : ""` becomes `scope.map { TransformCoordinator.canScope(result.transformer, for: $0) ? "" : " · \($0.wholeLabel)" } ?? ""`.
- **`SidebarView.swift`:** `scope != nil && !TransformCoordinator.canScope(transformer) ? "\(transformer.name) — whole buffer" : transformer.name` becomes `scope.map { TransformCoordinator.canScope(transformer, for: $0) ? transformer.name : "\(transformer.name) — \($0.wholeLabel)" } ?? transformer.name`.
- **Tests:**
  - `TransformScopeTests.swift`: `TransformScope.make` → `TextScope.make`, `TransformScope(range:` → `TextScope(range:`, `TransformScope.rankingKinds` → `TextScope.rankingKinds`. The `scope(_:_:_:)` helper returns `TransformScope` as `.text(TextScope.make(selected: r, in: text)!)`, and the `makeOnlyScopesARealSubrange` expectation compares against `TextScope(...)`.
  - `SelectionScopeModelTests.swift` and `SelectionScopeTests.swift`: their `scope(...)` helpers return `.text(TextScope.make(...)!)`, and `SelectionScope.scope(for:in:)?.expected` becomes `?.text?.expected`.

Run: `swift test 2>&1 | grep -E "error:|✘ Test|Test run with" | tail -2` (with the Step 3 coordinator switch already in place; a pure rename otherwise won't compile). Expected: passed, with the #25 tests unchanged in number.

- [ ] **Step 2: Write the failing tests for the image scope and geometry**

`Tests/PastefixAppCoreTests/ImageScopeTests.swift`:

```swift
import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// A plain image transform that records whether it saw a region.
private struct Recorder: ImageTransformer {
    let id = "test.recorder"; let name = "Recorder"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.recorder")
    func transformImage(_ png: Data) throws -> TransformOutput { .nothingToDo("saw no region") }
}

@Suite struct ImageScopeTests {
    private func imageDoc() throws -> PasteDocument {
        let png = try #require(Fixture.image(as: "public.png"))   // 60×40 (see PastefixCoreTests' Fixture; copy it here as `Fixture` if not visible)
        return PasteDocument(origin: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
    }

    @Test func anImageScopeReachesARegionTransformer() async throws {
        let doc = try imageDoc()
        let scope = TransformScope.image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: doc.detectionRevision)
        let (d, outcome, _) = await TransformCoordinator.apply(CropToSelection(), to: doc, scope: scope)
        #expect(outcome == .appliedWithNote("Cropped to 30×40."))
        #expect(d.imagePNG.flatMap(ImageRegion.orientedPixelSize).map { [$0.width, $0.height] } == [30, 40])
    }

    @Test func noRegionIsTheHowToNote() async throws {
        let doc = try imageDoc()
        #expect(await TransformCoordinator.apply(CropToSelection(), to: doc, scope: nil).1 == .nothingToDo(CropToSelection.noRegionMessage))
    }

    @Test func plainImageTransformsIgnoreTheRegion() async throws {
        let doc = try imageDoc()
        let scope = TransformScope.image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: doc.detectionRevision)
        #expect(await TransformCoordinator.apply(Recorder(), to: doc, scope: scope).1 == .nothingToDo("saw no region"))
        #expect(!TransformCoordinator.canScope(Recorder(), for: scope) && TransformCoordinator.canScope(CropToSelection(), for: scope))
        #expect(scope.wholeLabel == "whole image")
    }

    /// Review Focus 4.
    @Test func staleImageScopeIsRefused() async throws {
        let doc = try imageDoc()
        let stale = TransformScope.image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: doc.detectionRevision + 1)
        let (d, outcome, _) = await TransformCoordinator.apply(CropToSelection(), to: doc, scope: stale)
        #expect(outcome == .failed(TransformCoordinator.staleImageRegionMessage) && d.cursor == doc.cursor)
        let outside = TransformScope.image(ImageRegion(x: 50, y: 0, width: 30, height: 40), revision: doc.detectionRevision)
        #expect(await TransformCoordinator.apply(CropToSelection(), to: doc, scope: outside).1 == .failed(TransformCoordinator.staleImageRegionMessage))
    }
}
```

If `Fixture` (PastefixCoreTests) isn't visible from PastefixAppCoreTests, add a minimal `ImageFixture.png60x40()` in `Tests/PastefixAppCoreTests/` by copying `Fixture.image(as:)`'s body. Record a ruling.

`Tests/PastefixAppCoreTests/RegionGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import PastefixAppCore

@Suite struct RegionGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let sel = CGRect(x: 100, y: 100, width: 100, height: 50)

    @Test func hitTesting() {
        #expect(RegionGeometry.hit(CGPoint(x: 10, y: 10), selection: nil) == .new)
        #expect(RegionGeometry.hit(CGPoint(x: 10, y: 10), selection: sel) == .new)
        #expect(RegionGeometry.hit(CGPoint(x: 150, y: 125), selection: sel) == .move)
        #expect(RegionGeometry.hit(CGPoint(x: 102, y: 98), selection: sel) == .handle(.topLeft))
        #expect(RegionGeometry.hit(CGPoint(x: 199, y: 151), selection: sel) == .handle(.bottomRight))
        #expect(RegionGeometry.hit(CGPoint(x: 150, y: 150), selection: sel) == .handle(.bottom))
    }

    @Test func newDragIsStandardisedAndClamped() {
        let r = RegionGeometry.dragged(.new, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 500, y: 100), original: nil, bounds: bounds)
        #expect(r == CGRect(x: 300, y: 100, width: 100, height: 150))
    }

    @Test func moveKeepsSizeAndStaysInside() {
        let r = RegionGeometry.dragged(.move, from: CGPoint(x: 150, y: 125), to: CGPoint(x: 500, y: 125), original: sel, bounds: bounds)
        #expect(r == CGRect(x: 300, y: 100, width: 100, height: 50))
    }

    @Test func handleResizesOneCorner() {
        let r = RegionGeometry.dragged(.handle(.bottomRight), from: CGPoint(x: 200, y: 150), to: CGPoint(x: 250, y: 200), original: sel, bounds: bounds)
        #expect(r == CGRect(x: 100, y: 100, width: 150, height: 100))
        let flipped = RegionGeometry.dragged(.handle(.left), from: CGPoint(x: 100, y: 120), to: CGPoint(x: 260, y: 120), original: sel, bounds: bounds)
        #expect(flipped == CGRect(x: 200, y: 100, width: 60, height: 50), "dragging past the opposite edge flips, standardised")
    }

    @Test func tapVersusDrag() {
        #expect(RegionGeometry.isTap(from: .zero, to: CGPoint(x: 2, y: 2)))
        #expect(!RegionGeometry.isTap(from: .zero, to: CGPoint(x: 3, y: 3)))
    }
}
```

Run: `swift test --filter "ImageScopeTests|RegionGeometryTests" 2>&1 | grep -E "error:|Test run" | head -3`
Expected: compile errors for `canScope(_:for:)`, `staleImageRegionMessage` and `RegionGeometry`. Stub them, then expect behavioural failures.

- [ ] **Step 3: Implement the coordinator's image scope and `RegionGeometry`**

In `TransformCoordinator.swift`:

1. Add `canScope(_:for:)` and the message beside `canScope(_:)`:

```swift
    /// Whether `transformer` can use `scope`: a text scope as `canScope(_:)` says; an image region
    /// only for a `RegionImageTransformer`. Everything else runs on the whole buffer or image.
    public static func canScope(_ transformer: any Transformer, for scope: TransformScope) -> Bool {
        switch scope {
        case .text: return canScope(transformer)
        case .image: return transformer is any RegionImageTransformer
        }
    }

    public static let staleImageRegionMessage = "The image changed after you selected a region. Select it again."
```

2. The unscoped `apply(_:to:)` gains `region: ImageRegion? = nil`, and its input line becomes:

```swift
        let input = TransformInput(text: doc.working, richRTFD: doc.origin.richRTFD, image: image, region: region)
```

3. The scoped `apply(_:to:scope:)` starts with a switch (the existing text body moves into the `.text` case, using `text` where it used `scope`):

```swift
    ) async -> (PasteDocument, TransformOutcome, NSRange?) {
        switch scope {
        case .image(let region, let revision)?:
            // A region only means something to a region transform; the rest run on the whole image.
            guard transformer is any RegionImageTransformer, let png = document.currentImage else {
                let (doc, outcome) = await apply(transformer, to: document)
                return (doc, outcome, nil)
            }
            // Drawn on this entry, and still inside it: undo, redo or refresh replaced the image
            // otherwise, and cropping the new one to the old rectangle would be wrong.
            guard revision == document.detectionRevision,
                  let size = ImageRegion.orientedPixelSize(of: png), region.fits(size) else {
                return (document, .failed(staleImageRegionMessage), nil)
            }
            let (doc, outcome) = await apply(transformer, to: document, region: region)
            return (doc, outcome, nil)
        case .text(let text)?:
            guard canScope(transformer), document.currentImage == nil else {
                let (doc, outcome) = await apply(transformer, to: document)
                return (doc, outcome, nil)
            }
            // (the existing #25 body, with `scope.` replaced by `text.`)
        case nil:
            let (doc, outcome) = await apply(transformer, to: document)
            return (doc, outcome, nil)
        }
    }
```

`Sources/PastefixAppCore/RegionGeometry.swift`:

```swift
import CoreGraphics

public enum RegionHandle: CaseIterable, Sendable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
public enum RegionHit: Equatable, Sendable { case new, move, handle(RegionHandle) }

/// The drag maths for the image region, in view points. Pure; the overlay maps its result to pixels.
public enum RegionGeometry {
    public static let handleHitSize: CGFloat = 8
    public static let tapTravel: CGFloat = 3

    public static func handlePoints(_ r: CGRect) -> [(RegionHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    /// Handles first (they sit on and just outside the edge), then inside to move, else a new region.
    public static func hit(_ p: CGPoint, selection: CGRect?) -> RegionHit {
        guard let r = selection else { return .new }
        if let handle = handlePoints(r).first(where: { abs($0.1.x - p.x) <= handleHitSize && abs($0.1.y - p.y) <= handleHitSize }) {
            return .handle(handle.0)
        }
        return r.contains(p) ? .move : .new
    }

    public static func isTap(from: CGPoint, to: CGPoint) -> Bool {
        hypot(to.x - from.x, to.y - from.y) < tapTravel
    }

    /// The region after a drag from `from` to `to`, clamped to `bounds`.
    public static func dragged(_ hit: RegionHit, from: CGPoint, to: CGPoint, original: CGRect?, bounds: CGRect) -> CGRect {
        func clampPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        switch hit {
        case .new, .handle where original == nil:
            let a = clampPoint(from), b = clampPoint(to)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .move:
            guard let r = original else { return .zero }
            let dx = min(max(to.x - from.x, bounds.minX - r.minX), bounds.maxX - r.maxX)
            let dy = min(max(to.y - from.y, bounds.minY - r.minY), bounds.maxY - r.maxY)
            return r.offsetBy(dx: dx, dy: dy)
        case .handle(let h):
            guard let r = original else { return .zero }
            let p = clampPoint(to)
            var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
            if [.topLeft, .left, .bottomLeft].contains(h) { x0 = p.x }
            if [.topRight, .right, .bottomRight].contains(h) { x1 = p.x }
            if [.topLeft, .top, .topRight].contains(h) { y0 = p.y }
            if [.bottomLeft, .bottom, .bottomRight].contains(h) { y1 = p.y }
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test 2>&1 | grep -E "error:|✘ Test|Test run with" | tail -2`
Expected: passed, 1 known issue.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/PastefixAppCore Tests/PastefixAppCoreTests Pastefix
git commit -m "feat: TransformScope carries a text selection or an image region" -m "#25's scope is renamed TextScope; TransformScope is .text or .image(region, revision). The coordinator passes an image region to region transforms only, refuses one drawn on a different image or outside it, and marks others 'whole image'. RegionGeometry holds the drag maths." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 3: `AppModel`: `pendingImageRegion` and region-aware undo

**Files:**
- Modify: `Pastefix/Pastefix/AppModel.swift`
- Test: `Pastefix/PastefixTests/ImageRegionModelTests.swift`

**Interfaces:**
- Consumes: Task 2's `TransformScope.image`.
- Produces:
  - `struct PendingImageRegion: Equatable { let region: ImageRegion; let revision: Int }`
  - `@Published var pendingImageRegion: PendingImageRegion?`
  - `TransformStep.regionBefore: ImageRegion?`

- [ ] **Step 1: Write the failing test** (unhosted; the undo half is hosted in Task 4)

```swift
import Testing
import Foundation
import PastefixCore
import PastefixAppCore
@testable import Pastefix

@MainActor
@Suite("image region, model (crop)")
struct ImageRegionModelTests {
    private func png() throws -> Data {
        // 60×40, two colours: the same shape as the Core Fixture.
        let ctx = try #require(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        return try #require(PNGEncoder.encode(try #require(ctx.makeImage())))
    }

    @Test func cropThroughTheModel() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(CropToSelection(), scope: .image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: revision))
        #expect(await f.eventually { !f.model.isApplying && f.model.transformNote == "Cropped to 30×40." })
        #expect(f.model.document?.imagePNG.flatMap(ImageRegion.orientedPixelSize).map { [$0.width, $0.height] } == [30, 40])
    }

    @Test func staleRegionIsRefusedWithTheSentence() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(CropToSelection(), scope: .image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: revision + 7))
        #expect(await f.eventually { !f.model.isApplying })
        #expect(f.model.errorMessage == TransformCoordinator.staleImageRegionMessage)
    }

    @Test func boundaryClearsAPendingRegion() throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        f.model.pendingImageRegion = PendingImageRegion(region: ImageRegion(x: 0, y: 0, width: 5, height: 5), revision: 0)
        f.model.beginSession(from: ClipboardSnapshot(plainText: "text", richRTFD: nil))
        #expect(f.model.pendingImageRegion == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run, under the lease: `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test|Test run with" | head -4`
Expected: `cannot find 'PendingImageRegion'`. After stubbing the type and property, `boundaryClearsAPendingRegion` fails. (The other two already pass through Task 2's coordinator, since model apply just forwards the scope; they stay as model-level pins.)

- [ ] **Step 3: Implement**

In `AppModel.swift`, beside `PendingSelection`:

```swift
/// The image region to restore once the image entry it was drawn on is back on screen (crop spec):
/// set when ⌘Z undoes a transform that was applied with a region up. Consumed by `PanelView`.
struct PendingImageRegion: Equatable {
    let region: ImageRegion
    let revision: Int
}
```

Beside `pendingSelection`: `@Published var pendingImageRegion: PendingImageRegion?`.

Extend `TransformStep` with `var regionBefore: ImageRegion? = nil`, and pass it at the registration site:

```swift
                self.registerUndo(TransformStep(name: transformer.name, generation: generation,
                                                before: selectAfter == nil ? nil : scope?.text?.range, after: selectAfter,
                                                regionBefore: scope?.imageRegion))
```

(Any apply made with a region up records it, whatever the transform: spec decision 6.)

In `stepBack`, after the existing `pendingSelection` block:

```swift
        if let region = step.regionBefore, let doc = document {
            pendingImageRegion = PendingImageRegion(region: region, revision: doc.detectionRevision)
        }
```

In `resetUndo()`, beside `pendingSelection = nil`: `pendingImageRegion = nil`.

- [ ] **Step 4: Run to verify it passes, then commit**

Run, under the lease: `scripts/test-app.sh 2>&1 | grep -E "✘ Test|Test run with" | tail -1`
Expected: passed.

```bash
git add Pastefix/Pastefix/AppModel.swift Pastefix/PastefixTests/ImageRegionModelTests.swift
git commit -m "feat: an image region is recorded on the undo step and restored by ⌘Z" -m "PendingImageRegion mirrors #25's pendingSelection; every apply made with a region up records it, whatever the transform." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 4: The view: region state, overlay, Esc, oriented footer, docs

**Files:**
- Modify: `Pastefix/Pastefix/PanelView.swift`: `imageRegion` state, `currentScope`, `escape()`, the `ImageSessionView` call, consuming and clearing.
- Modify: `Pastefix/Pastefix/ImageSessionView.swift`: region binding, overlay, oriented size, footer readout.
- Create: `Pastefix/Pastefix/ImageRegionOverlay.swift`
- Modify: `AGENTS.md`, `README.md`
- Test: `Pastefix/PastefixTests/ImageRegionViewTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `ImageSessionView(imagePNG:revision:region:interactive:)`; `ImageRegionOverlay(region: Binding<ImageRegion?>, pixelSize: (width: Int, height: Int), enabled: Bool)`.

- [ ] **Step 1: Write the failing tests**

These reach the view's region through the footer's accessibility label, which gains `", selection W by H at X, Y"` (as VoiceOver reads it).

```swift
import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

@MainActor
@Suite("image region, view (crop)")
struct ImageRegionViewTests {
    private func png() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        return try #require(PNGEncoder.encode(try #require(ctx.makeImage())))
    }
    private func host(_ f: ModelFixture) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    /// Every accessibility label under `element`, depth-first.
    private func labels(_ element: Any) -> [String] {
        guard let e = element as? NSAccessibilityProtocol else { return [] }
        let own = e.accessibilityLabel().map { [$0] } ?? []
        return own + (e.accessibilityChildren() ?? []).flatMap(labels)
    }
    private func selectionLabel(_ window: NSWindow) -> String? {
        labels(window.contentView!).first { $0.contains("selection") }
    }
    private func sendUndo(_ window: NSWindow) -> Bool {
        (window.firstResponder ?? window).tryToPerform(Selector("undo:"), with: nil)
    }
    private func pressEsc(_ window: NSWindow) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        _ = window.performKeyEquivalent(with: e)
    }

    /// Review Focus 3.
    @Test func undoAfterAnyImageTransformRestoresTheRegion() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(CropToSelection(), scope: .image(ImageRegion(x: 100, y: 50, width: 200, height: 100), revision: revision))
        #expect(await f.eventually { f.model.transformNote == "Cropped to 200×100." })
        #expect(selectionLabel(window) == nil, "the selection is clear after a crop")
        #expect(sendUndo(window))
        #expect(await f.eventually { self.selectionLabel(window)?.contains("selection 200 by 100 at 100, 50") == true },
                "labels: \(labels(window.contentView!))")
    }

    /// Review Focus 5.
    @Test func escClearsTheRegionFirst() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        // Put a region up the way ⌘Z does: a crop, then undo.
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(CropToSelection(), scope: .image(ImageRegion(x: 10, y: 10, width: 50, height: 50), revision: revision))
        #expect(await f.eventually { f.model.transformNote != nil })
        _ = sendUndo(window)
        #expect(await f.eventually { self.selectionLabel(window) != nil })
        pressEsc(window)
        #expect(await f.eventually { self.selectionLabel(window) == nil })
        #expect(f.model.document != nil, "the first Esc cleared the region; the panel is still up")
    }

    @Test func footerStatesOrientedSize() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let rotated = try #require(Self.orientation6PNG())
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: rotated))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { self.labels(window.contentView!).contains { $0.contains("40 by 60 pixels") } },
                "labels: \(labels(window.contentView!))")
    }

    /// A 60×40 PNG tagged orientation 6: displayed 40×60.
    static func orientation6PNG() -> Data? {
        guard let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = { ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40)); return ctx.makeImage() }() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run, under the lease: `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test|Test run with" | head -6`
Expected: all three fail. There's no selection label yet, Esc cancels the session, and the footer says "60 by 40".

- [ ] **Step 3: `ImageRegionOverlay`**

```swift
import SwiftUI
import PastefixCore
import PastefixAppCore

/// The region selection over the fitted image (crop spec). Placed as an `.overlay` on the image
/// after `.resizable().scaledToFit()`, so its geometry *is* the fitted image rect: no letterbox
/// offset. One `DragGesture(minimumDistance: 0)`, classified on end: under 3 pt is a tap (outside
/// the region clears it); otherwise new, move or resize by `RegionGeometry.hit`. Drawn Preview-style
/// so it reads on dark, light and blue screenshots.
struct ImageRegionOverlay: View {
    @Binding var region: ImageRegion?
    let pixelSize: (width: Int, height: Int)
    let enabled: Bool

    @State private var dragHit: RegionHit?
    @State private var dragOriginal: CGRect?

    var body: some View {
        GeometryReader { geo in
            let frame = CGRect(origin: .zero, size: geo.size)
            let rect = region?.viewRect(imageFrame: frame, pixelSize: pixelSize)
            ZStack(alignment: .topLeading) {
                if let rect {
                    // Dimming outside the region, about 50%.
                    Path { p in p.addRect(frame); p.addRect(rect) }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    // Two-tone outline: white over a black hairline.
                    Rectangle().path(in: rect).stroke(Color.black, lineWidth: 2)
                    Rectangle().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).stroke(Color.white, lineWidth: 1)
                    ForEach(RegionGeometry.handlePoints(rect), id: \.0) { _, point in
                        Rectangle()
                            .fill(Color.white)
                            .overlay(Rectangle().stroke(Color.black.opacity(0.8), lineWidth: 1))
                            .frame(width: 7, height: 7)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .position(point)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragHit == nil {
                        dragHit = RegionGeometry.hit(value.startLocation, selection: rect)
                        dragOriginal = rect
                    }
                    guard let hit = dragHit, !RegionGeometry.isTap(from: value.startLocation, to: value.location) else { return }
                    let next = RegionGeometry.dragged(hit, from: value.startLocation, to: value.location, original: dragOriginal, bounds: frame)
                    if let r = ImageRegion.from(viewRect: next, imageFrame: frame, pixelSize: pixelSize) { region = r }
                }
                .onEnded { value in
                    // A tap outside the region clears it; a tap inside leaves it.
                    if RegionGeometry.isTap(from: value.startLocation, to: value.location), dragHit == .new { region = nil }
                    dragHit = nil
                    dragOriginal = nil
                })
            .disabled(!enabled)
        }
    }
}
```

(`RegionHandle` needs `Hashable` for `ForEach(id: \.0)`. An enum without associated values is `Hashable` automatically; add the conformance explicitly if the compiler asks.)

- [ ] **Step 4: `ImageSessionView`**

Add the inputs:

```swift
    /// The region selection (crop spec), owned by `PanelView`.
    @Binding var region: ImageRegion?
    /// False while a transform runs or the upload overlay is up: the region can't move then.
    let interactive: Bool
```

In `preview`, attach the overlay to the image, before the padding:

```swift
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    if let pixels {
                        ImageRegionOverlay(region: $region, pixelSize: (pixels.width, pixels.height), enabled: interactive)
                    }
                }
                .padding(12)
                .accessibilityLabel(accessibilityDescription)
```

In `displayImage`, return the **oriented** size. After the thumbnail line, replace `return (image, width, height)` with:

```swift
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        // The footer and the region speak oriented pixels, as the image is drawn (crop spec).
        return (5...8).contains(orientation) ? (image, height, width) : (image, width, height)
```

Extend the footer text and its accessibility label:

```swift
    private var selectionSuffix: (text: String, spoken: String)? {
        guard let region else { return nil }
        return (" · Selection \(region.width)×\(region.height) at (\(region.x), \(region.y))",
                ", selection \(region.width) by \(region.height) at \(region.x), \(region.y)")
    }
```

Append `selectionSuffix?.text ?? ""` to both returns of `factsDescription`, and `selectionSuffix?.spoken ?? ""` to both returns of `accessibilityDescription`.

- [ ] **Step 5: `PanelView`**

Add the state beside `editorSelection`:

```swift
    /// The region drawn on the image (crop spec): view state, like `editorSelection`, never on the model.
    @State private var imageRegion: ImageRegion?
```

Replace `currentScope`:

```swift
    private var currentScope: TransformScope? {
        guard let document = model.document else { return nil }
        // The *current* entry: after Extract Text the text scope applies, never a leftover region.
        if document.displaysAsImage {
            guard let imageRegion, !imageRegion.isEmpty else { return nil }
            return .image(imageRegion, revision: document.detectionRevision)
        }
        guard !document.displaysAsLargeText || showLargeTextAnyway, !isPreviewing else { return nil }
        return SelectionScope.scope(for: editorSelection, in: document.working)
    }
```

The `ImageSessionView` call becomes:

```swift
                            ImageSessionView(imagePNG: imagePNG, revision: document.detectionRevision,
                                             region: $imageRegion, interactive: !(model.isApplying || isUploadOpen))
```

In `escape()`, between the `isPreviewing` branch and `model.cancel()`:

```swift
        } else if imageRegion != nil {
            // The region clears before the panel cancels, as a selection does everywhere (crop spec).
            imageRegion = nil
```

Add a handler beside the `sessionGeneration` one:

```swift
        // A new image entry (a transform, undo, redo, refresh) drops the region, unless ⌘Z named the
        // one to restore for exactly this entry.
        .onChange(of: model.document?.detectionRevision) { _, revision in
            if let pending = model.pendingImageRegion {
                model.pendingImageRegion = nil
                if pending.revision == revision, model.document?.displaysAsImage == true {
                    imageRegion = pending.region
                    return
                }
            }
            imageRegion = nil
        }
```

In the existing `.onChange(of: model.sessionGeneration)` body, add `imageRegion = nil`.

- [ ] **Step 6: Run to verify they pass**

Run, under the lease: `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test|Test run with" | tail -2`, then `swift test 2>&1 | grep -E "✘ Test|Test run with" | tail -1`
Expected: both pass.

- [ ] **Step 7: Docs**

`README.md`, under the image section of Using Pastefix (the paragraph on Strip Image Metadata and Extract Text), add:

```markdown
**Cropping.** Drag on the picture to select part of it: drag the handles to adjust, drag inside to move it, and press Esc or click outside it to clear it. The footer shows the selection's size and position in the image's real pixels. Then choose **Crop to Selection** in ⌘K or the sidebar. The crop is one undo step: ⌘Z brings back the whole picture and your selection. Cropping keeps the picture's colours and drops its metadata, the same as Strip Image Metadata.
```

In `AGENTS.md`:
- Add `ImageRegion.swift` and `CropToSelection.swift` to the Core file map. ImageRegion: oriented pixels, top-left; mapping with header pixels, never the displayed NSImage. CropToSelection: a thumbnail decode with transform, no profile conversion, order 113.
- Add `TextScope.swift` (#25's type, renamed), `TransformScope.swift` (the `.text`/`.image` enum) and `RegionGeometry.swift` to AppCore.
- Add `ImageRegionOverlay.swift` to the app file map: an overlay on the fitted image, one `minimumDistance: 0` gesture, Preview-style drawing.
- On the `PanelView` line: the region is `@State`; Esc clears it in `escape()` after the overlays and preview; it's consumed from `pendingImageRegion` on a revision change.

- [ ] **Step 8: Commit**

```bash
git add -A Pastefix AGENTS.md README.md
git commit -m "feat: select a region on the image and crop to it" -m "The region is PanelView state drawn and edited by ImageRegionOverlay on the fitted image; Esc clears it before cancelling; ⌘Z restores it; the footer states oriented size and the selection. Docs: README and AGENTS." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### After the tasks

- A whole-branch review by a fresh reviewer, then the PR.
- `work`'s GUI pass, from the spec's list:
  - the first drag on a non-key panel;
  - tap vs a small drag;
  - Esc order;
  - dark, blue and white fixtures;
  - drag, handles, move and clamp;
  - the footer readout;
  - the hint and the "whole image" marks;
  - a real screenshot and a rotated PNG;
  - undo and redo, including after Strip Metadata.
