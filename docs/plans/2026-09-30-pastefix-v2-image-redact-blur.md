# Redact and blur a region Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two region transforms: Redact Selection (opaque black) and Blur Selection (cosmetic Gaussian blur). Also, small regions become movable, and the overlay no longer replays stale drag state.

**Architecture:**
- **Core:** crop's oriented decode moves into one internal helper, `OrientedSource`. Crop, Redact and Blur all use it, so the ImageIO orientation quirk is handled in one place.
- **Redact** draws the oriented image into a bitmap context in its own colour space and fills the region.
- **Blur** renders only the region through Core Image, then draws that patch over the original in the same kind of context. Pixels outside the region are never reprocessed.
- **App:** `RegionGeometry.hit` gains the small-region rule, and `ImageRegionOverlay` moves its drag state to `@GestureState`.

**Tech Stack:** Swift 6, ImageIO, CoreGraphics, Core Image, SwiftUI (macOS 15), Swift Testing, SwiftPM (`PastefixCore`, `PastefixAppCore`), and the hosted app tests (`scripts/test-app.sh`, run under the GUI lease: `python3 ~/.claude/skills/gui-test-lease/lease.py acquire|release`).

**Spec:** `docs/specs/2026-09-30-pastefix-v2-image-redact-blur.md`

## Global Constraints

- **Ids, names, orders:**
  - `builtin.redactselection`, "Redact Selection", order **114**;
  - `builtin.blurselection`, "Blur Selection", order **115**;
  - both `category: TransformCategory.images`, `acceptedForms == [.image]`, conforming to `RegionImageTransformer`.
- **Messages, verbatim:**
  - Redact, no region: `"Drag on the image to choose what to hide, then choose Redact Selection."`
  - Blur, no region: `"Drag on the image to choose what to blur, then choose Blur Selection."`
  - Redact result: `"Redacted W×H."`
  - Blur result: `"Blurred W×H. Blur can be reversed; use Redact Selection to hide something for good."`
  - The ×, U+00D7, is the multiplication sign crop uses.
- **Fill** is opaque black. Where the image has alpha, the region becomes opaque black.
- **Blur radius:** `max(6, 0.05 × min(region.width, region.height))` px. The blur samples only the region, with its edges clamped.
- **Pixels outside the region are byte-identical** to the input, for both transforms.
- **A whole-image region is allowed**, and is not `.nothingToDo`.
- **Same contract as crop:**
  - orientation baked in;
  - the colour profile kept;
  - metadata dropped via `PNGEncoder`;
  - a region that doesn't fit throws `TransformError.invalidInput("The selection is outside the image.")`;
  - an unreadable image throws `TransformError.invalidInput("This image can't be read.")`.
- **Small-region rule:** a press inside the region goes to a handle only when the region is at least **24 pt** on both sides; otherwise it moves the region. A press outside the region but within 8 pt of a handle resizes, at any size.
- **Tests** never run a real image transform on `ImageTransformLane.shared`. Hosted tests use the own-lane wrappers in `Pastefix/PastefixTests/LanedImageTransforms.swift`.
- **Package tests that render with Core Image** or decode images go through `offThePool` (`Tests/PastefixCoreTests/OffThePool.swift`). That avoids blocking the cooperative pool (the CI deadlock lesson).
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv`.

## Review Focus

1. **Images with alpha:** redacting a transparent area must give opaque black, not a transparent hole or grey (Task 1 `redactOverTransparencyIsOpaqueBlack`).
2. **Greyscale PNGs:** a bitmap context can't be made in a grey space with alpha. Redact and blur must still work, not throw (Task 1 `greyscaleInputWorks`).
3. **A blur region touching the image edge:** without clamping, the edges would darken towards transparent. A uniform image blurred edge to edge must stay uniform (Task 1 `blurAtTheEdgesDoesNotDarken`).
4. **A 1×1 px region:** both transforms must work, and only that pixel changes (Task 1 `onePixelRegion`).
5. **A cancelled drag, then a tap outside:** the tap must clear the region, not replay the old move (Task 2 `aCancelledDragDoesNotReplay`).

---

### Task 1: Core: `OrientedSource`, `RedactSelection`, `BlurSelection`

**Files:**
- Create: `Sources/PastefixCore/OrientedSource.swift`
- Create: `Sources/PastefixCore/Native/RedactSelection.swift`
- Create: `Sources/PastefixCore/Native/BlurSelection.swift`
- Modify: `Sources/PastefixCore/Native/CropToSelection.swift` (use `OrientedSource`)
- Modify: `Sources/PastefixCore/Discovery/TransformerRegistry.swift` (orders 114 and 115)
- Test: `Tests/PastefixCoreTests/RedactBlurTests.swift`
- Modify tests:
  - `Tests/PastefixCoreTests/TransformerRegistryTests.swift`: add the ids after `"builtin.crop"`; count 31 → 33.
  - `Tests/PastefixCoreTests/TransformerLimitsTests.swift`: two table rows.

**Interfaces (produces):**
- `struct OrientedSource` (internal):
  - `init?(_ png: Data)` reads the properties on the source;
  - `let width: Int`, `let height: Int` are the oriented size;
  - `func image() -> CGImage?` is the oriented full-size decode, nil on a size mismatch;
  - `static func bitmap(for image: CGImage) -> CGContext?` returns an RGBA8 context in the image's colour space, or sRGB when that isn't RGB, with the image drawn in.
- `public struct RedactSelection: RegionImageTransformer`, with `static let noRegionMessage` and `static func resultNote(_ w: Int, _ h: Int) -> String`.
- `public struct BlurSelection: RegionImageTransformer`, with `static let noRegionMessage`, `static func resultNote(_ w: Int, _ h: Int) -> String` and `static func radius(for region: ImageRegion) -> Double`.

- [ ] **Step 1: Write the failing tests**

`Tests/PastefixCoreTests/RedactBlurTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

/// Redact and Blur Selection (redact/blur spec). Pixels are compared by drawing the decoded
/// image into one sRGB RGBA8 buffer, top-left origin, so "outside the region is untouched" is a
/// byte comparison.
@Suite struct RedactBlurTests {
    /// RGBA8 in sRGB, row 0 at the top.
    static func pixels(_ png: Data) throws -> (w: Int, h: Int, px: [UInt8]) {
        let image = try #require(Fixture.decoded(png))
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, px)
    }
    static func at(_ p: (w: Int, h: Int, px: [UInt8]), _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * p.w + x) * 4
        return Array(p.px[i..<i + 4])
    }
    static func inside(_ r: ImageRegion, _ x: Int, _ y: Int) -> Bool {
        x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
    }
    /// Every pixel outside `r` is identical in `a` and `b`.
    static func outsideUnchanged(_ a: (w: Int, h: Int, px: [UInt8]), _ b: (w: Int, h: Int, px: [UInt8]), _ r: ImageRegion) -> Bool {
        guard a.w == b.w, a.h == b.h else { return false }
        for y in 0..<a.h { for x in 0..<a.w where !inside(r, x, y) { if at(a, x, y) != at(b, x, y) { return false } } }
        return true
    }
    /// `w`×`h`, alternating 2 px black and white rows.
    static func stripes(_ w: Int, _ h: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for y in stride(from: 0, to: h, by: 4) { ctx.fill(CGRect(x: 0, y: y, width: w, height: 2)) }
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    static func solid(_ w: Int, _ h: Int, space: CFString = CGColorSpace.sRGB, grey: Bool = false) throws -> Data {
        let cs = CGColorSpace(name: grey ? CGColorSpace.genericGrayGamma2_2 : space)!
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                         bitmapInfo: grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue))
        if grey { ctx.setFillColor(gray: 0.8, alpha: 1) } else { ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) }
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func image(_ out: TransformOutput) throws -> (Data, String?) {
        guard case .image(let data, let note) = out else { Issue.record("expected an image, got \(out)"); throw CancellationError() }
        return (data, note)
    }

    // MARK: Redact

    @Test func redactFillsTheRegionAndNothingElse() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        let r = ImageRegion(x: 25, y: 5, width: 10, height: 20)
        let (out, note) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(note == "Redacted 10×20.")
        let a = try Self.pixels(png), b = try Self.pixels(out)
        #expect(Self.outsideUnchanged(a, b, r))
        for y in r.y..<r.y + r.height { for x in r.x..<r.x + r.width { #expect(Self.at(b, x, y) == [0, 0, 0, 255]) } }
        #expect(Fixture.properties(out)?[kCGImagePropertyGPSDictionary as String] == nil, "metadata is dropped")
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3, "profile kept")
    }

    @Test func redactWholeImageIsAllBlack() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        let (out, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 60, height: 40)) })
        let b = try Self.pixels(out)
        #expect(stride(from: 0, to: b.px.count, by: 4).allSatisfy { Array(b.px[$0..<$0 + 4]) == [0, 0, 0, 255] })
    }

    /// Orientation 6: displayed 40×60 with the stored left (red) half on top.
    @Test func redactUsesTheDisplayedOrientation() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        let (out, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 40, height: 30)) })
        let b = try Self.pixels(out)
        #expect(b.w == 40 && b.h == 60, "orientation baked in")
        #expect(Self.at(b, 20, 10) == [0, 0, 0, 255], "top (red) half redacted")
        let bottom = Self.at(b, 20, 45)
        #expect(bottom[2] > 150 && bottom[0] < 100, "bottom half still blue: \(bottom)")
    }

    /// Review Focus 1.
    @Test func redactOverTransparencyIsOpaqueBlack() async throws {
        let png = try #require(Fixture.image(as: "public.png", transparentRightHalf: true))
        let r = ImageRegion(x: 40, y: 10, width: 10, height: 10)   // inside the transparent half
        let (out, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(Self.at(try Self.pixels(out), 45, 15) == [0, 0, 0, 255])
    }

    /// Review Focus 2.
    @Test func greyscaleInputWorks() async throws {
        let png = try Self.solid(30, 20, grey: true)
        let r = ImageRegion(x: 5, y: 5, width: 10, height: 10)
        let (redacted, _) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(Self.at(try Self.pixels(redacted), 8, 8) == [0, 0, 0, 255])
        let (blurred, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: r) })
        #expect(Self.outsideUnchanged(try Self.pixels(png), try Self.pixels(blurred), r))
    }

    /// Review Focus 4.
    @Test func onePixelRegion() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        let r = ImageRegion(x: 3, y: 4, width: 1, height: 1)
        let (redacted, note) = try image(try await offThePool { try RedactSelection().transformImage(png, region: r) })
        #expect(note == "Redacted 1×1.")
        let a = try Self.pixels(png), b = try Self.pixels(redacted)
        #expect(Self.outsideUnchanged(a, b, r) && Self.at(b, 3, 4) == [0, 0, 0, 255])
        let (blurred, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: r) })
        #expect(Self.outsideUnchanged(a, try Self.pixels(blurred), r))
    }

    @Test func noRegionAndOutsideTheImage() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        #expect(try RedactSelection().transformImage(png, region: nil) == .nothingToDo(RedactSelection.noRegionMessage))
        #expect(try BlurSelection().transformImage(png, region: nil) == .nothingToDo(BlurSelection.noRegionMessage))
        #expect(RedactSelection.noRegionMessage == "Drag on the image to choose what to hide, then choose Redact Selection.")
        #expect(BlurSelection.noRegionMessage == "Drag on the image to choose what to blur, then choose Blur Selection.")
        #expect(throws: TransformError.self) { try RedactSelection().transformImage(png, region: ImageRegion(x: 55, y: 0, width: 10, height: 10)) }
        #expect(throws: TransformError.self) { try BlurSelection().transformImage(png, region: ImageRegion(x: 55, y: 0, width: 10, height: 10)) }
    }

    // MARK: Blur

    @Test func blurSoftensTheRegionAndNothingElse() async throws {
        let png = try Self.stripes(80, 60)
        let r = ImageRegion(x: 20, y: 10, width: 40, height: 40)
        let (out, note) = try image(try await offThePool { try BlurSelection().transformImage(png, region: r) })
        #expect(note == "Blurred 40×40. Blur can be reversed; use Redact Selection to hide something for good.")
        let a = try Self.pixels(png), b = try Self.pixels(out)
        #expect(Self.outsideUnchanged(a, b, r))
        // Down the middle column, well inside the region: the stripes' contrast at least halves.
        let column = (20..<40).map { Int(Self.at(b, 40, $0)[0]) }
        #expect(column.max()! - column.min()! < 128, "contrast \(column.max()! - column.min()!)")
        #expect(Set(column).count > 1, "blurred, not filled")
    }

    @Test func blurRadius() {
        #expect(BlurSelection.radius(for: ImageRegion(x: 0, y: 0, width: 40, height: 40)) == 6)
        #expect(BlurSelection.radius(for: ImageRegion(x: 0, y: 0, width: 400, height: 1000)) == 20)
    }

    /// Review Focus 3.
    @Test func blurAtTheEdgesDoesNotDarken() async throws {
        let png = try Self.solid(50, 30)
        let (out, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 50, height: 30)) })
        let a = try Self.pixels(png), b = try Self.pixels(out)
        for (x, y) in [(0, 0), (49, 0), (0, 29), (49, 29), (25, 15)] {
            let d = zip(Self.at(a, x, y), Self.at(b, x, y)).map { abs(Int($0) - Int($1)) }.max()!
            #expect(d <= 3, "(\(x), \(y)) differs by \(d)")
        }
    }

    @Test func blurKeepsOrientationAndProfileAndDropsMetadata() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        let (out, _) = try image(try await offThePool { try BlurSelection().transformImage(png, region: ImageRegion(x: 0, y: 0, width: 40, height: 30)) })
        let b = try Self.pixels(out)
        #expect(b.w == 40 && b.h == 60)
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Fixture.properties(out)?[kCGImagePropertyGPSDictionary as String] == nil)
    }

    @Test func registered() {
        let r = RedactSelection(), b = BlurSelection()
        #expect(r.id == "builtin.redactselection" && r.name == "Redact Selection" && r.category == TransformCategory.images)
        #expect(b.id == "builtin.blurselection" && b.name == "Blur Selection" && b.category == TransformCategory.images)
        #expect(r.acceptedForms == [.image] && b.acceptedForms == [.image])
    }
}
```

In `TransformerRegistryTests.swift`, after `"builtin.crop",` add `"builtin.redactselection", "builtin.blurselection",` and change `reg.load().count == 31` to `== 33`. In `TransformerLimitsTests.swift`, after the `"builtin.crop"` row, add:

```swift
            "builtin.redactselection": (TransformLimits.defaultMaxInputBytes, 10),
            "builtin.blurselection": (TransformLimits.defaultMaxInputBytes, 10),
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "RedactBlurTests" 2>&1 | grep -E "error:|Test run" | head -3`
Expected: `cannot find 'RedactSelection' in scope`. Then add stubs with the Interfaces' signatures: `transformImage` returns `.nothingToDo("")`, `radius` returns 0, and the messages are "". Re-run. Expected: behavioural failures in every test.

- [ ] **Step 3: Implement**

`Sources/PastefixCore/OrientedSource.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO

/// An image's oriented size, and its oriented full-size decode, from one `CGImageSource`, for the
/// region transforms (crop, redact, blur).
///
/// One source for both on purpose: ImageIO's PNG reader applies an eXIf orientation in a
/// `WithTransform` thumbnail only once the properties have been read on *that* source
/// (measured: thumbnail-first gives the unrotated image). `init` reads them; `image()` decodes.
struct OrientedSource {
    let width: Int
    let height: Int
    private let source: CGImageSource

    init?(_ png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = ImageRegion.orientedPixelSize(of: source) else { return nil }
        self.source = source
        self.width = size.width
        self.height = size.height
    }

    /// The oriented image at full size, with no colour-profile conversion. Nil if the decode's size
    /// isn't the oriented size: never act on a differently shaped image than the region was drawn on.
    func image() -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              image.width == width, image.height == height else { return nil }
        return image
    }

    /// An RGBA8 bitmap with `image` drawn in at 1:1, in the image's own colour space so pixels and
    /// profile are unchanged; sRGB when that space isn't RGB (greyscale), which can't back an
    /// RGBA context.
    static func bitmap(for image: CGImage) -> CGContext? {
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let space = own ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    /// `region` (top-left origin) as a rect in a bitmap of this height (bottom-left origin).
    static func bitmapRect(_ region: ImageRegion, height: Int) -> CGRect {
        CGRect(x: region.x, y: height - region.y - region.height, width: region.width, height: region.height)
    }
}
```

`CropToSelection.transformImage` becomes:

```swift
    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits((source.width, source.height)) else { throw TransformError.invalidInput("The selection is outside the image.") }
        if region.width == source.width, region.height == source.height { return .nothingToDo(Self.wholeImageMessage) }
        guard let oriented = source.image(),
              let cropped = oriented.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)),
              let out = PNGEncoder.encode(cropped) else {
            throw TransformError.invalidInput("\(name) couldn't crop this image.")
        }
        return .image(out, note: Self.resultNote(region.width, region.height))
    }
```

In the same edit, CropToSelection's doc comment says the decode is `OrientedSource`'s.

`Sources/PastefixCore/Native/RedactSelection.swift`:

```swift
import Foundation
import CoreGraphics

/// Covers the selected region with opaque black: the redaction tool (redact/blur spec). Black
/// reads as a redaction on any image and carries nothing from what was there; over transparency
/// the region becomes opaque. Pixels outside the region are drawn 1:1 in the image's own colour
/// space, so they come out unchanged; the re-encode drops metadata.
public struct RedactSelection: RegionImageTransformer {
    public let id = "builtin.redactselection"
    public let name = "Redact Selection"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init() {}

    public static let noRegionMessage = "Drag on the image to choose what to hide, then choose Redact Selection."
    public static func resultNote(_ w: Int, _ h: Int) -> String { "Redacted \(w)×\(h)." }

    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits((source.width, source.height)) else { throw TransformError.invalidInput("The selection is outside the image.") }
        guard let image = source.image(), let ctx = OrientedSource.bitmap(for: image) else {
            throw TransformError.invalidInput("\(name) couldn't redact this image.")
        }
        ctx.setBlendMode(.copy)   // replace, so transparency under the box can't show through
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(OrientedSource.bitmapRect(region, height: source.height))
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't redact this image.")
        }
        return .image(out, note: Self.resultNote(region.width, region.height))
    }
}
```

`Sources/PastefixCore/Native/BlurSelection.swift`:

```swift
import Foundation
import CoreGraphics
import CoreImage

/// Blurs the selected region: cosmetic, not redaction (redact/blur spec). Blurred screenshot text
/// can often be reconstructed, which the result note says. Only the region goes through Core
/// Image: cropped out, edges clamped so nothing outside is sampled and the edges don't fade to
/// transparent, blurred, rendered in the image's colour space, then drawn over the original in a
/// 1:1 bitmap, so every pixel outside the region is untouched.
public struct BlurSelection: RegionImageTransformer {
    public let id = "builtin.blurselection"
    public let name = "Blur Selection"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init() {}

    public static let noRegionMessage = "Drag on the image to choose what to blur, then choose Blur Selection."
    public static func resultNote(_ w: Int, _ h: Int) -> String {
        "Blurred \(w)×\(h). Blur can be reversed; use Redact Selection to hide something for good."
    }
    /// 5% of the region's shorter side, at least 6 px: text is unreadable at a glance.
    public static func radius(for region: ImageRegion) -> Double {
        max(6, 0.05 * Double(min(region.width, region.height)))
    }

    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits((source.width, source.height)) else { throw TransformError.invalidInput("The selection is outside the image.") }
        guard let image = source.image(), let ctx = OrientedSource.bitmap(for: image), let space = ctx.colorSpace else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        let rect = OrientedSource.bitmapRect(region, height: source.height)   // Core Image is bottom-left too
        let patch = CIImage(cgImage: image)
            .cropped(to: rect)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Self.radius(for: region))
            .cropped(to: rect)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        guard let blurred = context.createCGImage(patch, from: rect, format: .RGBA8, colorSpace: space) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        ctx.setBlendMode(.copy)
        ctx.draw(blurred, in: rect)
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        return .image(out, note: Self.resultNote(region.width, region.height))
    }
}
```

In `TransformerRegistry.swift`, after `(113, "Crop to Selection", CropToSelection()),` add:

```swift
            (114, "Redact Selection", RedactSelection()),
            (115, "Blur Selection", BlurSelection()),
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "RedactBlurTests|CropToSelectionTests|ImageRegionTests|TransformerRegistryTests|TransformerLimitsTests" 2>&1 | grep -E "✘|Test run with" | tail -3`
Expected: passed. `CropToSelectionTests` still pass unchanged, which is the refactor's check.

**If `blurAtTheEdgesDoesNotDarken` fails** with the corners darker: the clamp isn't taking effect. Check that `clampedToExtent()` comes after the first `cropped(to:)`. **If `greyscaleInputWorks` fails** in `bitmap(for:)`: log `image.colorSpace?.model` and record a ruling.

- [ ] **Step 5: Run the package suite and commit**

Run: `swift test 2>&1 | grep -E "✘ Test|Test run with" | tail -1`
Expected: passed, 1 known issue.

```bash
git add Sources/PastefixCore Tests/PastefixCoreTests
git commit -m "feat: Redact Selection and Blur Selection" -m "Redact fills the region with opaque black; Blur blurs only the region, edges clamped, and says blur can be reversed. Both keep pixels outside the region byte-identical, bake orientation, keep the profile and drop metadata. Crop's oriented decode moves into OrientedSource, shared by all three." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 2: Region selection fixes, panel tests, docs

**Files:**
- Modify: `Sources/PastefixAppCore/RegionGeometry.swift` (`hit`)
- Modify: `Pastefix/Pastefix/ImageRegionOverlay.swift` (`@GestureState`)
- Modify: `Pastefix/PastefixTests/LanedImageTransforms.swift` (add `LanedRedact`, `LanedBlur`)
- Modify tests:
  - `Tests/PastefixAppCoreTests/RegionGeometryTests.swift`;
  - `Pastefix/PastefixTests/ImageRegionOverlayTests.swift`;
  - `Pastefix/PastefixTests/ImageRegionViewTests.swift`.
- Modify: `README.md`, `AGENTS.md`

**Interfaces:**
- Consumes: Task 1's `RedactSelection`, `BlurSelection` (messages and notes).
- Produces: `RegionGeometry.smallRegionSide: CGFloat = 24`. `hit(_:selection:)` keeps its signature, with the new rule.

- [ ] **Step 1: Write the failing tests**

Add to `RegionGeometryTests` in `Tests/PastefixAppCoreTests/RegionGeometryTests.swift`:

```swift
    /// Small regions move from inside; their handles are grabbed from the outer half (redact/blur spec).
    @Test func smallRegionsMoveFromInside() {
        let small = CGRect(x: 100, y: 100, width: 10, height: 10)
        #expect(RegionGeometry.hit(CGPoint(x: 105, y: 105), selection: small) == .move)
        #expect(RegionGeometry.hit(CGPoint(x: 101, y: 101), selection: small) == .move, "inside, near a corner")
        #expect(RegionGeometry.hit(CGPoint(x: 98, y: 98), selection: small) == .handle(.topLeft), "just outside the corner")
        #expect(RegionGeometry.hit(CGPoint(x: 112, y: 105), selection: small) == .handle(.right))
        let thin = CGRect(x: 100, y: 100, width: 200, height: 12)   // wide but short: still small
        #expect(RegionGeometry.hit(CGPoint(x: 102, y: 104), selection: thin) == .move)
        let big = CGRect(x: 100, y: 100, width: 100, height: 100)
        #expect(RegionGeometry.hit(CGPoint(x: 103, y: 103), selection: big) == .handle(.topLeft), "inside a big region, near a corner")
        #expect(RegionGeometry.smallRegionSide == 24)
    }
```

Add to `ImageRegionOverlayTests` in `Pastefix/PastefixTests/ImageRegionOverlayTests.swift`. `Host` is changed to read `enabled` from the box: add `@Published var enabled = true` to `Box`, and pass `enabled: box.enabled`.

```swift
    @Test func aSmallRegionMovesAndKeepsItsSize() async {
        let box = Box()
        box.region = ImageRegion(x: 100, y: 100, width: 20, height: 20)   // 10×10 pt at 2 px/pt
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, from: CGPoint(x: 55, y: 55), to: CGPoint(x: 85, y: 75))   // inside, near its centre
        #expect(await eventually { box.region == ImageRegion(x: 160, y: 140, width: 20, height: 20) },
                "region: \(String(describing: box.region))")
    }

    /// Review Focus 5: a drag cancelled mid-way (the overlay is disabled when a transform starts)
    /// must not leave its hit behind for the next gesture.
    @Test func aCancelledDragDoesNotReplay() async {
        let box = Box()
        box.region = ImageRegion(x: 100, y: 100, width: 101, height: 77)
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: 200 - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Press inside (a move) and drag, then cancel by disabling before the release.
        w.sendEvent(event(.leftMouseDown, CGPoint(x: 90, y: 80))); await Task.yield()
        w.sendEvent(event(.leftMouseDragged, CGPoint(x: 100, y: 85))); await Task.yield()
        box.enabled = false
        try? await Task.sleep(for: .milliseconds(50))
        w.sendEvent(event(.leftMouseUp, CGPoint(x: 100, y: 85)))
        box.enabled = true
        try? await Task.sleep(for: .milliseconds(50))
        let afterCancel = box.region
        await drag(w, from: CGPoint(x: 280, y: 190), to: CGPoint(x: 280, y: 190))   // a tap outside
        #expect(await eventually { box.region == nil }, "was \(String(describing: afterCancel)), now \(String(describing: box.region))")
    }
```

Add to `ImageRegionViewTests` in `Pastefix/PastefixTests/ImageRegionViewTests.swift`:

```swift
    @Test func redactThroughThePanelAndUndo() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(LanedRedact(), scope: .image(ImageRegion(x: 10, y: 20, width: 30, height: 40), revision: revision))
        #expect(await f.eventually { f.model.transformNote == "Redacted 30×40." })
        #expect(f.model.imageRegionOnScreen == nil)
        #expect(f.model.document?.imagePNG.flatMap(ImageRegion.orientedPixelSize).map { [$0.width, $0.height] } == [600, 400])
        #expect(sendUndo(window))
        #expect(await f.eventually { f.model.imageRegionOnScreen == ImageRegion(x: 10, y: 20, width: 30, height: 40) })
    }
```

In `Pastefix/PastefixTests/LanedImageTransforms.swift`, add:

```swift
struct LanedRedact: RegionImageTransformer {
    let id = "builtin.redactselection"; let name = "Redact Selection"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let category: String? = TransformCategory.images
    let lane = ImageTransformLane.makeLane(label: "test.redact")
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        try RedactSelection().transformImage(png, region: region)
    }
}

struct LanedBlur: RegionImageTransformer {
    let id = "builtin.blurselection"; let name = "Blur Selection"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let category: String? = TransformCategory.images
    let lane = ImageTransformLane.makeLane(label: "test.blur")
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        try BlurSelection().transformImage(png, region: region)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter RegionGeometryTests 2>&1 | grep -E "error:|✘ Test.*failed after|Test run with" | head -4`
Expected: `smallRegionSide` not found. Stub it and expect `smallRegionsMoveFromInside` to fail on the `.move` expectations.

Run, under the lease: `scripts/test-app.sh "-only-testing:PastefixTests/ImageRegionOverlayTests" 2>&1 | grep -E "✘ Test.*recorded|Test run with" | head -6`
Expected:
- `aSmallRegionMovesAndKeepsItsSize` fails (the press resizes instead).
- `aCancelledDragDoesNotReplay` fails: the stale `.move` hit means the tap doesn't clear.
- **If `aCancelledDragDoesNotReplay` passes before the fix,** disabling didn't cancel the gesture in-process. Then record a ruling saying the fix is verified by code reading and the GUI pass only, and keep the test as a regression pin.
- `redactThroughThePanelAndUndo` already passes, because Task 1 made the transform and the panel machinery is crop's. It's a pin, not a red test.

- [ ] **Step 3: Implement**

In `RegionGeometry.swift`, add beside `tapTravel`, and replace `hit`:

```swift
    /// Below this on either side, a press inside the region moves it: a handle's 8 pt hit box
    /// would otherwise cover the whole inside (redact/blur spec).
    public static let smallRegionSide: CGFloat = 24

    /// A handle within 8 pt wins, except that inside a small region a press moves it (so small
    /// regions are resized from their handles' outer half); then inside moves, else a new region.
    public static func hit(_ p: CGPoint, selection: CGRect?) -> RegionHit {
        guard let r = selection else { return .new }
        let small = r.width < smallRegionSide || r.height < smallRegionSide
        if small, r.contains(p) { return .move }
        if let handle = handlePoints(r).first(where: { abs($0.1.x - p.x) <= handleHitSize && abs($0.1.y - p.y) <= handleHitSize }) {
            return .handle(handle.0)
        }
        return r.contains(p) ? .move : .new
    }
```

In `ImageRegionOverlay.swift`, replace the two `@State` drag properties and the gesture:

```swift
    /// The drag's classification and the region it started from. `@GestureState`, so SwiftUI resets
    /// it when the gesture ends *or is cancelled* (the panel losing key, `.disabled` flipping as a
    /// transform starts); as `@State` a cancelled drag's hit replayed on the next one.
    @GestureState private var drag: DragStart?
    private struct DragStart { let hit: RegionHit; let original: ImageRegion? }
```

```swift
            .gesture(DragGesture(minimumDistance: 0)
                .updating($drag) { value, state, _ in
                    if state == nil {
                        state = DragStart(hit: RegionGeometry.hit(value.startLocation, selection: rect), original: region)
                    }
                    guard let start = state, !RegionGeometry.isTap(from: value.startLocation, to: value.location) else { return }
                    // In pixels from the original region, so a move or resize never drifts (I1).
                    if let r = RegionGeometry.draggedRegion(start.hit, from: value.startLocation, to: value.location,
                                                            original: start.original, imageFrame: frame, pixelSize: pixelSize) {
                        region = r
                    }
                }
                .onEnded { value in
                    // A tap outside the region clears it; a tap inside leaves it. Classified from the
                    // gesture's own start: a tap hasn't moved the region, so no stored state is needed.
                    if RegionGeometry.isTap(from: value.startLocation, to: value.location),
                       RegionGeometry.hit(value.startLocation, selection: rect) == .new {
                        region = nil
                    }
                })
```

The file's header comment says the classification is `@GestureState`.

**If the compiler refuses to write the `region` binding from `updating`:** it may treat the closure as non-mutating on the view. The binding is a reference, so it should work. Otherwise keep `.onChanged` for the region write, reading the start from `drag`. `.updating` runs before `.onChanged` for the same value. Record a ruling.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test 2>&1 | grep -E "✘ Test|Test run with" | tail -1`, then, under the lease, `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test|Test run with" | tail -2`
Expected: both pass.

- [ ] **Step 5: Docs**

In `README.md`'s Images section, "Three image transforms appear" becomes "Five image transforms appear". After the Crop to Selection bullet, add:

```markdown
- **Redact Selection** covers the part of the picture you selected with a solid black box. Use it to hide a password, a token, a name or anything else before you share a screenshot. Select the way you do for cropping. ⌘Z brings back what was there and your selection.
- **Blur Selection** blurs the part you selected. It's for tidying a picture, not hiding things: blurred text can often be read back, so use Redact Selection for anything secret.
```

In the transform table, the Images row becomes `| Images | Extract Text (OCR), Crop to Selection, Redact Selection, Blur Selection |`. After `- **Crop to Selection:** see [Images](#images).`, add `- **Redact Selection:** see [Images](#images).` and `- **Blur Selection:** see [Images](#images).`

In `AGENTS.md`'s Core file map, after the `CropToSelection.swift` line, add:

```
    OrientedSource.swift              #   redact/blur: one CGImageSource for the oriented size AND the WithTransform full decode (ImageIO's PNG orientation quirk); image() refuses a size mismatch; bitmap(for:) = RGBA8 in the image's own space (sRGB if not RGB), drawn 1:1 so untouched pixels stay byte-identical — used by Crop, Redact, Blur
    RedactSelection.swift             #   builtin.redactselection (114, Images, [.image]): opaque black fill (.copy blend: opaque over transparency); whole image allowed; no region → how-to note
    BlurSelection.swift               #   builtin.blurselection (115, Images, [.image]): COSMETIC — only the region through Core Image (crop, clampedToExtent, Gaussian sigma max(6, 5% of the shorter side)), drawn back over a 1:1 bitmap so outside pixels are byte-identical; note says blur can be reversed (secret-triggered warning is #129)
```

On the `RegionGeometry.swift` line, append: `; small-region rule: inside a region under 24 pt on either side, a press moves (handles from their outer half)`. On the `ImageRegionOverlay.swift` line, append: `; drag start in @GestureState (reset on cancel), taps classified from the gesture's own start`.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/PastefixAppCore Tests/PastefixAppCoreTests Pastefix README.md AGENTS.md
git commit -m "feat: small regions move, a cancelled drag leaves nothing behind; docs for redact and blur" -m "Inside a region under 24 pt a press moves it (handles from their outer half). The overlay's drag start is @GestureState, reset when a gesture is cancelled, so a stale hit can't replay on the next drag." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### After the tasks

- A final whole-branch review by a fresh reviewer, then the PR.
- The GUI pass, with the owner's OK:
  - redact and blur on dark, blue and white fixtures;
  - blur on a real screenshot with text;
  - moving and resizing a small region;
  - undo and redo;
  - the marks in the palette and sidebar.
