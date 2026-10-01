# Annotate (markup mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Markup mode for image sessions: Box, Arrow, Text, Highlighter and Freehand marks, each burned into the image as one undo step.

**Architecture:**
- **Core:**
  - `ImageMark` is the mark's data, in oriented image pixels.
  - `MarkGeometry` holds the pure size and shape maths.
  - `MarkRenderer` draws a mark into a CG bitmap.
  - `AnnotateImage` is an unregistered `ImageTransformer` that holds one mark. It goes through the existing coordinator, lane and undo.
- **App model:** `AppModel` keeps a mark queue (`pendingMarks`). It applies one mark at a time, so fast strokes are never dropped, clears the queue at session boundaries, and doesn't count marks as transform uses.
- **View:**
  - `MarkupOverlay` turns drags into marks, mapped through the pure `MarkupGeometry` in AppCore, and previews them.
  - `MarkupStrip` is the tool and colour strip.
  - `PanelView` owns the mode, the ⌘⇧A toggle, and an Esc order made testable as `PanelEscape`.

**Tech Stack:** Swift 6, CoreGraphics, Core Text, SwiftUI (macOS 15), Swift Testing, SwiftPM (`PastefixCore`, `PastefixAppCore`), and the hosted app tests (`scripts/test-app.sh`, run under the GUI lease: `python3 ~/.claude/skills/gui-test-lease/lease.py acquire|release`).

**Spec:** `docs/specs/2026-09-30-pastefix-v2-image-annotate.md`

## Global Constraints

- **Tools:**
  - `ImageMark.Tool`: `box`, `arrow`, `text`, `highlight`, `freehand`.
  - Names, which are also the undo names: "Box", "Arrow", "Text", "Highlight", "Freehand".
  - Notes: "Box added.", "Arrow added.", "Text added.", "Highlight added.", "Drawing added."
- **Colours:** `ImageMark.Color` is `red` (default), `yellow`, `blue`, `black`, `white`, with these sRGB values:
  - red (0.92, 0.20, 0.18);
  - yellow (1.00, 0.80, 0.00);
  - blue (0.16, 0.45, 0.96);
  - black (0, 0, 0);
  - white (1, 1, 1).
- **Highlighter:** always sRGB (1.00, 0.90, 0.00) at alpha 0.45 with the multiply blend, ignoring the swatch.
- **Sizes**, with `L` = the image's longer side in pixels:
  - stroke = `max(2, round(L / 250))`;
  - arrowhead length = `4 × stroke`, and its width = `3 × stroke`;
  - font = bold system at `max(12, round(L / 40))` px;
  - halo = `max(1, round(stroke / 2))`;
  - `round` is Swift `.rounded()`, which rounds half away from zero.
- **The text halo** is white for red, blue and black text, and black for yellow and white text.
- **Discard:**
  - travel under 3 pt (`RegionGeometry.tapTravel`) draws nothing for box, arrow, highlight and freehand;
  - a box or highlight with zero pixel width or height is discarded;
  - freehand drops points closer than 1 px to the previous kept point, and keeps the endpoints.
- **Coordinates:** marks are in **oriented image pixels**, top-left origin, mapped with the header's pixel size, never the displayed bitmap's. Rendering uses `OrientedSource` and `OrientedSource.bitmap(for:)`, so the colour space and depth are kept. `PNGEncoder` drops metadata.
- **`AnnotateImage` is not registered:** it's not in `TransformerRegistry`, ⌘K or the sidebar, and `AppModel` doesn't record its use.
- **Markup mode:**
  - **⌘⇧A** and a toolbar button, enabled only while the current entry displays as an image.
  - Entering clears the region.
  - It turns off at a `sessionGeneration` change, when the entry stops displaying as an image, and when the upload overlay opens.
- **Esc order:**
  1. palette, history, upload;
  2. preview;
  3. text field: discard;
  4. markup mode: leave;
  5. region: clear;
  6. cancel.
- **The queue:**
  - `AppModel.enqueueMark(_:)` appends to `pendingMarks`. One mark applies at a time; the next applies when the previous apply finishes, whether it succeeded or not.
  - A failed apply drops its mark.
  - `resetUndo()`, which runs at every session boundary, empties the queue.
  - The markup overlay is **not** disabled while applying.
- **Tests:** tests never run a real image transform on `ImageTransformLane.shared`. `AnnotateImage(mark, lane:)` takes a lane, and `AppModel.annotateLane` defaults to the shared lane; tests set a private one.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv`.

## Review Focus

1. **Fast strokes:** two marks enqueued back to back must both land as two undo steps, in order (Task 2 `twoQuickMarksBothLand`).
2. **A session ending with marks queued:** the queue must not apply them to the next session's image (Task 2 `boundaryEmptiesTheQueue`).
3. **Rotated images:** a mark drawn on an orientation-6 PNG lands where it was drawn on the displayed image (Task 1 `marksTheDisplayedOrientation`).
4. **The highlighter over text:** dark text stays dark, the background turns yellow, and no text is lost (Task 1 `highlightKeepsTextDark`).
5. **Esc with the text field open:** it discards the text and stays in markup mode; it doesn't cancel the panel (Task 3 `escapeOrder`).

---

### Task 1: Core: `ImageMark`, `MarkGeometry`, `MarkRenderer`, `AnnotateImage`

**Files:**
- Create: `Sources/PastefixCore/Annotate/ImageMark.swift`
- Create: `Sources/PastefixCore/Annotate/MarkGeometry.swift`
- Create: `Sources/PastefixCore/Annotate/MarkRenderer.swift`
- Create: `Sources/PastefixCore/Native/AnnotateImage.swift`
- Test: `Tests/PastefixCoreTests/AnnotateImageTests.swift`

**Interfaces (produces):**
- `public struct ImagePoint: Sendable, Equatable, Codable { public let x: Int; public let y: Int; public init(x: Int, y: Int) }`
- `public struct ImageMark: Sendable, Equatable, Codable`:
  - `public enum Tool: String, Sendable, Codable, CaseIterable { case box, arrow, text, highlight, freehand }`;
  - `public enum Color: String, Sendable, Codable, CaseIterable { case red, yellow, blue, black, white }`;
  - `public let tool: Tool`, `public let color: Color`, `public let points: [ImagePoint]`, `public let text: String?`;
  - `public init(tool:color:points:text: String? = nil)`.
- `public enum MarkGeometry`:
  - `static func strokeWidth(longerSide: Int) -> Int`;
  - `static func fontSize(longerSide: Int) -> Int`;
  - `static func haloWidth(stroke: Int) -> Int`;
  - `static func arrowHead(tail: CGPoint, tip: CGPoint, stroke: CGFloat) -> (tip: CGPoint, left: CGPoint, right: CGPoint, base: CGPoint)`;
  - `static func thinned(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint]`;
  - `static func smoothPath(_ points: [CGPoint]) -> CGPath`.
- `enum MarkRenderer`, internal: `static func draw(_ mark: ImageMark, in ctx: CGContext, imageWidth: Int, imageHeight: Int)`.
- `public struct AnnotateImage: ImageTransformer`:
  - `public init(_ mark: ImageMark, lane: ImageTransformLane.Lane = ImageTransformLane.shared)`;
  - `public let mark: ImageMark`;
  - `public static let nothingToDrawMessage = "Nothing to draw."`.

- [ ] **Step 1: Write the failing tests**

`Tests/PastefixCoreTests/AnnotateImageTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

/// Annotate (markup mode): mark geometry and each mark burned into the image.
@Suite struct AnnotateImageTests {
    private let lane = ImageTransformLane.makeLane(label: "test.annotate.core")

    /// `w`×`h` opaque white, with an optional black block (a stand-in for text).
    static func page(_ w: Int, _ h: Int, black: CGRect? = nil) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let black {   // given top-left; CG is bottom-left
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: black.minX, y: CGFloat(h) - black.maxY, width: black.width, height: black.height))
        }
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func mark(_ m: ImageMark, on png: Data) async throws -> (Data, String?) {
        let t = AnnotateImage(m, lane: lane)
        guard case .image(let out, let note) = try await offThePool({ try t.transformImage(png) }) else {
            Issue.record("\(m.tool): expected an image"); throw CancellationError()
        }
        return (out, note)
    }
    private func changed(_ a: (w: Int, h: Int, px: [UInt8]), _ b: (w: Int, h: Int, px: [UInt8]), outside box: CGRect) -> Int {
        var n = 0
        for y in 0..<a.h { for x in 0..<a.w where !box.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
            if RedactBlurTests.at(a, x, y) != RedactBlurTests.at(b, x, y) { n += 1 }
        } }
        return n
    }
    private func isWhite(_ c: [UInt8]) -> Bool { c[0] > 245 && c[1] > 245 && c[2] > 245 }
    private func isRed(_ c: [UInt8]) -> Bool { c[0] > 180 && c[1] < 120 && c[2] < 120 }

    // MARK: geometry

    @Test func sizesScaleWithTheImage() {
        #expect(MarkGeometry.strokeWidth(longerSide: 400) == 2 && MarkGeometry.strokeWidth(longerSide: 1200) == 5
                && MarkGeometry.strokeWidth(longerSide: 5120) == 20 && MarkGeometry.strokeWidth(longerSide: 10) == 2)
        #expect(MarkGeometry.fontSize(longerSide: 400) == 12 && MarkGeometry.fontSize(longerSide: 1200) == 30
                && MarkGeometry.fontSize(longerSide: 5120) == 128)
        #expect(MarkGeometry.haloWidth(stroke: 2) == 1 && MarkGeometry.haloWidth(stroke: 5) == 3 && MarkGeometry.haloWidth(stroke: 20) == 10)
    }

    @Test func arrowHeadPoints() {
        let h = MarkGeometry.arrowHead(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 0), stroke: 5)
        #expect(h.tip == CGPoint(x: 100, y: 0) && h.base == CGPoint(x: 80, y: 0))
        #expect(abs(h.left.x - 80) < 1e-9 && abs(abs(h.left.y) - 7.5) < 1e-9 && abs(h.left.y + h.right.y) < 1e-9)
        let v = MarkGeometry.arrowHead(tail: CGPoint(x: 10, y: 10), tip: CGPoint(x: 10, y: 50), stroke: 2)
        #expect(v.base == CGPoint(x: 10, y: 42) && abs(abs(v.left.x - 10) - 3) < 1e-9)
    }

    @Test func thinningKeepsEndpoints() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5.2, y: 0.1), CGPoint(x: 5.3, y: 0)]
        let t = MarkGeometry.thinned(pts, minDistance: 1)
        #expect(t.first == CGPoint(x: 0, y: 0) && t.last == CGPoint(x: 5.3, y: 0) && t.count == 3)
    }

    // MARK: pixels

    @Test func boxOutlinesWithoutFilling() async throws {
        let png = try Self.page(400, 300)
        let m = ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 100, y: 100), ImagePoint(x: 200, y: 180)])
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Box added.")
        let a = try RedactBlurTests.pixels(png), b = try RedactBlurTests.pixels(out)
        #expect(isRed(RedactBlurTests.at(b, 100, 140)) && isRed(RedactBlurTests.at(b, 150, 100)), "edges")
        #expect(isWhite(RedactBlurTests.at(b, 150, 140)), "interior untouched")
        #expect(changed(a, b, outside: CGRect(x: 96, y: 96, width: 108, height: 88)) == 0)
    }

    @Test func arrowLineAndHead() async throws {
        let png = try Self.page(400, 300)
        let m = ImageMark(tool: .arrow, color: .red, points: [ImagePoint(x: 50, y: 150), ImagePoint(x: 350, y: 150)])
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Arrow added.")
        let a = try RedactBlurTests.pixels(png), b = try RedactBlurTests.pixels(out)
        #expect(isRed(RedactBlurTests.at(b, 200, 150)) && isWhite(RedactBlurTests.at(b, 200, 158)))
        #expect(isRed(RedactBlurTests.at(b, 344, 152)), "head is wider than the line")   // base 342, half-width 3
        #expect(changed(a, b, outside: CGRect(x: 46, y: 144, width: 308, height: 12)) == 0)
    }

    /// Review Focus 4.
    @Test func highlightKeepsTextDark() async throws {
        let png = try Self.page(400, 300, black: CGRect(x: 120, y: 140, width: 60, height: 20))
        let m = ImageMark(tool: .highlight, color: .blue, points: [ImagePoint(x: 100, y: 130), ImagePoint(x: 200, y: 170)])
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Highlight added.")
        let b = try RedactBlurTests.pixels(out)
        let text = RedactBlurTests.at(b, 150, 150), paper = RedactBlurTests.at(b, 105, 135)
        #expect(text[0] < 30 && text[1] < 30 && text[2] < 30, "text stays dark: \(text)")
        #expect(paper[0] > 200 && paper[1] > 180 && paper[2] < 170, "paper turns yellow, the swatch ignored: \(paper)")
        #expect(isWhite(RedactBlurTests.at(b, 250, 150)))
    }

    @Test func textDrawsInsideItsBox() async throws {
        let png = try Self.page(400, 300)
        let m = ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 50, y: 50)], text: "Hi there")
        let (out, note) = try await mark(m, on: png)
        #expect(note == "Text added.")
        let a = try RedactBlurTests.pixels(png), b = try RedactBlurTests.pixels(out)
        let box = CGRect(x: 44, y: 44, width: 120, height: 30)    // font 12 px, plus the halo
        #expect(changed(a, b, outside: box) == 0)
        var reds = 0
        for y in 50..<70 { for x in 50..<150 where isRed(RedactBlurTests.at(b, x, y)) { reds += 1 } }
        #expect(reds > 20, "glyphs drawn: \(reds) red pixels")
    }

    @Test func freehandFollowsThePath() async throws {
        let png = try Self.page(400, 300)
        let ring = (0...36).map { i -> ImagePoint in
            let t = Double(i) / 36 * 2 * .pi
            return ImagePoint(x: 200 + Int((60 * cos(t)).rounded()), y: 150 + Int((40 * sin(t)).rounded()))
        }
        let (out, note) = try await mark(ImageMark(tool: .freehand, color: .red, points: ring), on: png)
        #expect(note == "Drawing added.")
        let b = try RedactBlurTests.pixels(out)
        // The curve runs through midpoints between samples, so allow a pixel either way.
        func redNear(_ x: Int, _ y: Int) -> Bool {
            (-2...2).contains { dy in (-2...2).contains { dx in isRed(RedactBlurTests.at(b, x + dx, y + dy)) } }
        }
        #expect(redNear(260, 150) && redNear(200, 110) && redNear(140, 150))
        #expect(isWhite(RedactBlurTests.at(b, 200, 150)), "the inside of the oval is untouched")
    }

    /// Review Focus 3: orientation 6 shows 40×60 with the stored left (red) half on top.
    @Test func marksTheDisplayedOrientation() async throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        let m = ImageMark(tool: .box, color: .white, points: [ImagePoint(x: 5, y: 5), ImagePoint(x: 35, y: 25)])
        let (out, _) = try await mark(m, on: png)
        let b = try RedactBlurTests.pixels(out)
        #expect(b.w == 40 && b.h == 60)
        #expect(isWhite(RedactBlurTests.at(b, 5, 15)), "the box's left edge, on the red top half")
        let lower = RedactBlurTests.at(b, 5, 45)
        #expect(lower[2] > 150 && lower[0] < 100, "the blue bottom half untouched: \(lower)")
    }

    @Test func keepsProfileDepthDropsMetadata() async throws {
        let m = ImageMark(tool: .box, color: .black, points: [ImagePoint(x: 2, y: 2), ImagePoint(x: 20, y: 20)])
        let (p3, _) = try await mark(m, on: try #require(Fixture.image(as: "public.png")))
        #expect(Fixture.decoded(p3)?.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Fixture.properties(p3)?[kCGImagePropertyGPSDictionary as String] == nil)
        let (deep, _) = try await mark(m, on: try RedactBlurDepthTests.png16())
        #expect(Fixture.decoded(deep)?.bitsPerComponent == 16)
    }

    @Test func degenerateMarksDrawNothing() throws {
        let png = try Self.page(40, 30)
        for m in [ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 1, y: 1)]),
                  ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 1, y: 1)], text: "  "),
                  ImageMark(tool: .freehand, color: .red, points: [])] {
            #expect(try AnnotateImage(m, lane: lane).transformImage(png) == .nothingToDo(AnnotateImage.nothingToDrawMessage))
        }
    }

    @Test func namesAndNotRegistered() {
        let names = ImageMark.Tool.allCases.map { AnnotateImage(ImageMark(tool: $0, color: .red, points: [])).name }
        #expect(names == ["Box", "Arrow", "Text", "Highlight", "Freehand"])
        let reg = TransformerRegistry(config: .init(scriptsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("none-\(UUID().uuidString)"), wrapWidth: 80))
        #expect(!reg.load().contains { $0 is AnnotateImage })
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter AnnotateImageTests 2>&1 | grep -E "error:|Test run" | head -3`
Expected: `cannot find 'ImageMark' in scope`. Then add stubs with the Interfaces' signatures: sizes return 0; `arrowHead` returns all `.zero`; `thinned` returns its input; `smoothPath` returns an empty path; `transformImage` returns `.nothingToDo("")`. Expected: behavioural failures.

- [ ] **Step 3: Implement**

`Sources/PastefixCore/Annotate/ImageMark.swift`:

```swift
import Foundation

/// A point on an image in its oriented pixels, origin top-left (the space `ImageRegion` uses).
public struct ImagePoint: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// One markup mark (annotate spec): what markup mode hands `AnnotateImage` to burn in.
/// Box, arrow and highlight use two points (press, release); freehand the stroke's points;
/// text one point (the text box's top-left) and `text`.
public struct ImageMark: Sendable, Equatable, Codable {
    public enum Tool: String, Sendable, Codable, CaseIterable { case box, arrow, text, highlight, freehand }
    public enum Color: String, Sendable, Codable, CaseIterable { case red, yellow, blue, black, white }

    public let tool: Tool
    public let color: Color
    public let points: [ImagePoint]
    public let text: String?

    public init(tool: Tool, color: Color, points: [ImagePoint], text: String? = nil) {
        self.tool = tool; self.color = color; self.points = points; self.text = text
    }
}

public extension ImageMark.Tool {
    /// The transform's name, which is also the undo action's.
    var name: String {
        switch self {
        case .box: "Box"
        case .arrow: "Arrow"
        case .text: "Text"
        case .highlight: "Highlight"
        case .freehand: "Freehand"
        }
    }
    var note: String {
        switch self {
        case .box: "Box added."
        case .arrow: "Arrow added."
        case .text: "Text added."
        case .highlight: "Highlight added."
        case .freehand: "Drawing added."
        }
    }
}

public extension ImageMark.Color {
    /// sRGB components.
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: (0.92, 0.20, 0.18)
        case .yellow: (1.00, 0.80, 0.00)
        case .blue: (0.16, 0.45, 0.96)
        case .black: (0, 0, 0)
        case .white: (1, 1, 1)
        }
    }
    /// The text halo: white under dark colours, black under light ones.
    var halo: ImageMark.Color { self == .yellow || self == .white ? .black : .white }
}
```

`Sources/PastefixCore/Annotate/MarkGeometry.swift`:

```swift
import CoreGraphics

/// Mark sizes and shapes (annotate spec), pure. Sizes scale with the image's longer side so a
/// mark looks alike on a small crop and a 5K screenshot.
public enum MarkGeometry {
    public static func strokeWidth(longerSide: Int) -> Int { max(2, Int((Double(longerSide) / 250).rounded())) }
    public static func fontSize(longerSide: Int) -> Int { max(12, Int((Double(longerSide) / 40).rounded())) }
    public static func haloWidth(stroke: Int) -> Int { max(1, Int((Double(stroke) / 2).rounded())) }

    /// The filled head at `tip`: 4 × stroke long, 3 × stroke wide, centred on the line.
    public static func arrowHead(tail: CGPoint, tip: CGPoint, stroke: CGFloat) -> (tip: CGPoint, left: CGPoint, right: CGPoint, base: CGPoint) {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let len = max(hypot(dx, dy), .ulpOfOne)
        let ux = dx / len, uy = dy / len            // along the arrow
        let length = 4 * stroke, half = 1.5 * stroke
        let base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        let left = CGPoint(x: base.x - uy * half, y: base.y + ux * half)
        let right = CGPoint(x: base.x + uy * half, y: base.y - ux * half)
        return (tip, left, right, base)
    }

    /// Drops points closer than `minDistance` to the previous kept one; always keeps both ends.
    public static func thinned(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first, let last = points.last, points.count > 2 else { return points }
        var kept = [first]
        for p in points.dropFirst().dropLast() where hypot(p.x - kept.last!.x, p.y - kept.last!.y) >= minDistance { kept.append(p) }
        if kept.last != last { kept.append(last) }
        return kept
    }

    /// Quadratic curves through the midpoints of successive points: smooth, and through both ends.
    public static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else { points.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points.last!)
        return path
    }
}
```

`Sources/PastefixCore/Annotate/MarkRenderer.swift`:

```swift
import Foundation
import CoreGraphics
import CoreText

/// Draws one mark into a bitmap that already holds the image (annotate spec). Mark points are
/// top-left oriented pixels; the bitmap is bottom-left, so y flips. Antialiased: marks are new
/// pixels, so smooth edges are wanted.
enum MarkRenderer {
    static func draw(_ mark: ImageMark, in ctx: CGContext, imageWidth: Int, imageHeight: Int) {
        let longer = max(imageWidth, imageHeight)
        let stroke = CGFloat(MarkGeometry.strokeWidth(longerSide: longer))
        func flip(_ p: ImagePoint) -> CGPoint { CGPoint(x: Double(p.x), y: Double(imageHeight - p.y)) }
        func cg(_ c: ImageMark.Color, alpha: Double = 1) -> CGColor {
            CGColor(srgbRed: c.rgb.r, green: c.rgb.g, blue: c.rgb.b, alpha: alpha)
        }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setShouldAntialias(true)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(cg(mark.color)); ctx.setFillColor(cg(mark.color))
        switch mark.tool {
        case .box:
            let a = flip(mark.points[0]), b = flip(mark.points[1])
            ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .highlight:
            let a = flip(mark.points[0]), b = flip(mark.points[1])
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.90, blue: 0.0, alpha: 0.45))
            ctx.fill(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .arrow:
            let tail = flip(mark.points[0]), tip = flip(mark.points[1])
            let head = MarkGeometry.arrowHead(tail: tail, tip: tip, stroke: stroke)
            ctx.move(to: tail); ctx.addLine(to: head.base); ctx.strokePath()
            ctx.move(to: head.tip); ctx.addLine(to: head.left); ctx.addLine(to: head.right); ctx.closePath(); ctx.fillPath()
        case .freehand:
            let pts = MarkGeometry.thinned(mark.points.map(flip), minDistance: 1)
            ctx.addPath(MarkGeometry.smoothPath(pts)); ctx.strokePath()
        case .text:
            guard let text = mark.text else { return }
            let size = CGFloat(MarkGeometry.fontSize(longerSide: longer))
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let halo = CGFloat(MarkGeometry.haloWidth(stroke: Int(stroke)))
            let origin = flip(mark.points[0])
            let ascent = CTFontGetAscent(font)
            let baseline = CGPoint(x: origin.x, y: origin.y - ascent)
            // Halo: the text stroked in the contrasting colour at twice the halo width (half falls
            // inside the glyph, under the fill), then the fill on top.
            func line(_ color: ImageMark.Color, strokeWidthPercent: Double?) -> CTLine {
                var attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(color),
                ]
                if let w = strokeWidthPercent {
                    attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = w
                    attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = cg(color)
                }
                return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            }
            // kCTStrokeWidth is a percentage of the font size; positive = stroke only.
            let haloPercent = Double(2 * halo / size * 100)
            ctx.textPosition = baseline
            CTLineDraw(line(mark.color.halo, strokeWidthPercent: haloPercent), ctx)
            ctx.textPosition = baseline
            CTLineDraw(line(mark.color, strokeWidthPercent: nil), ctx)
        }
    }
}
```

`Sources/PastefixCore/Native/AnnotateImage.swift`:

```swift
import Foundation
import CoreGraphics

/// Burns one markup mark into the image (annotate spec): markup mode applies one of these per
/// finished mark, so each is one undo step through the ordinary transform pipeline. Not in the
/// registry: it carries its mark, and nothing in ⌘K or the sidebar could supply one. The decode
/// is `OrientedSource`'s (orientation applied, so a mark lands where it was drawn), the bitmap
/// keeps the source's colour space and depth, and the re-encode drops metadata.
public struct AnnotateImage: ImageTransformer {
    public let mark: ImageMark
    public let lane: ImageTransformLane.Lane
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init(_ mark: ImageMark, lane: ImageTransformLane.Lane = ImageTransformLane.shared) {
        self.mark = mark
        self.lane = lane
    }

    public var id: String { "builtin.annotate.\(mark.tool.rawValue)" }
    public var name: String { mark.tool.name }

    public static let nothingToDrawMessage = "Nothing to draw."

    /// Whether the mark has enough to draw: two points for the shapes, one or more for freehand,
    /// a point and visible text for text.
    var isDrawable: Bool {
        switch mark.tool {
        case .box, .arrow, .highlight: mark.points.count >= 2
        case .freehand: !mark.points.isEmpty
        case .text: mark.points.count >= 1 && !(mark.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func transformImage(_ png: Data) throws -> TransformOutput {
        guard isDrawable else { return .nothingToDo(Self.nothingToDrawMessage) }
        guard let source = OrientedSource(png), let image = source.image(),
              let ctx = OrientedSource.bitmap(for: image) else {
            throw TransformError.invalidInput("This image can't be read.")
        }
        MarkRenderer.draw(mark, in: ctx, imageWidth: source.width, imageHeight: source.height)
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't be drawn on this image.")
        }
        return .image(out, note: mark.tool.note)
    }
}
```

**If `textDrawsInsideItsBox` fails** because the expected box is too tight (font metrics), print the bounding box of changed pixels and widen the test box to cover it plus the halo, keeping the 0-outside check. Record a ruling. **If `highlightKeepsTextDark` fails** on the paper colour: the multiply of white with (1, 0.9, 0, 0.45) should give about (255, 243, 140). Check that the blend mode was set before the fill.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "AnnotateImageTests|TransformerRegistryTests" 2>&1 | grep -E "✘|Test run with" | tail -3`
Expected: passed. The registry count is unchanged at 39, since `AnnotateImage` isn't registered.

- [ ] **Step 5: Run the package suite and commit**

Run: `swift test 2>&1 | grep -E "✘ Test|Test run with" | tail -1`
Expected: passed, 1 known issue. The #132 timing flake may show; rerun it alone if so.

```bash
git add Sources/PastefixCore Tests/PastefixCoreTests
git commit -m "feat: ImageMark and AnnotateImage burn markup marks into an image" -m "Box, arrow, text (with a contrasting halo), highlighter (multiply yellow) and smoothed freehand, sized from the image's longer side, drawn in oriented pixels on OrientedSource's bitmap so the profile and depth are kept. AnnotateImage is a transform but not registered: markup mode applies it." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 2: App model: the mark queue, and `MarkupGeometry`

**Files:**
- Create: `Sources/PastefixAppCore/MarkupGeometry.swift`
- Modify: `Pastefix/Pastefix/AppModel.swift`
- Test: `Tests/PastefixAppCoreTests/MarkupGeometryTests.swift`, `Pastefix/PastefixTests/MarkupQueueTests.swift`

**Interfaces:**
- Consumes: Task 1's `ImageMark`, `ImagePoint`, `AnnotateImage(_:lane:)`.
- Produces:
  - `public enum MarkupGeometry`:
    - `static func pixel(_ p: CGPoint, frame: CGRect, pixelSize: (width: Int, height: Int)) -> ImagePoint`, clamped to the image;
    - `static func mark(tool: ImageMark.Tool, color: ImageMark.Color, path: [CGPoint], frame: CGRect, pixelSize: (width: Int, height: Int)) -> ImageMark?`. It's nil for the text tool and for discarded marks.
  - `AppModel`:
    - `@Published private(set) var pendingMarks: [ImageMark]`;
    - `func enqueueMark(_ mark: ImageMark)`;
    - `var annotateLane: ImageTransformLane.Lane`;
    - `var markupTool: ImageMark.Tool = .box`;
    - `var markupColor: ImageMark.Color = .red`;
    - `var markupModeOnScreen = false`, a write-only mirror for tests, like `imageRegionOnScreen`.

- [ ] **Step 1: Write the failing tests**

`Tests/PastefixAppCoreTests/MarkupGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
import PastefixCore
@testable import PastefixAppCore

@Suite struct MarkupGeometryTests {
    private let frame = CGRect(x: 0, y: 0, width: 300, height: 200)   // a 600×400 image at 2 px/pt
    private let size = (width: 600, height: 400)

    @Test func twoPointMarksMapToPixels() {
        let m = MarkupGeometry.mark(tool: .box, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20), CGPoint(x: 60, y: 40)],
                                    frame: frame, pixelSize: size)
        #expect(m == ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 20, y: 20), ImagePoint(x: 120, y: 80)]))
        let a = MarkupGeometry.mark(tool: .arrow, color: .blue, path: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: -50)], frame: frame, pixelSize: size)
        #expect(a?.points == [ImagePoint(x: 0, y: 0), ImagePoint(x: 600, y: 0)], "clamped to the image")
    }

    @Test func tapsAndFlatShapesAreDiscarded() {
        #expect(MarkupGeometry.mark(tool: .box, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 11)], frame: frame, pixelSize: size) == nil)
        #expect(MarkupGeometry.mark(tool: .freehand, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 11)], frame: frame, pixelSize: size) == nil)
        #expect(MarkupGeometry.mark(tool: .highlight, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10)], frame: frame, pixelSize: size) == nil, "zero height")
        #expect(MarkupGeometry.mark(tool: .arrow, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10)], frame: frame, pixelSize: size) != nil, "a flat arrow is fine")
        #expect(MarkupGeometry.mark(tool: .text, color: .red, path: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60)], frame: frame, pixelSize: size) == nil, "text is placed by the text field")
    }

    @Test func freehandKeepsThePath() {
        let path = (0...20).map { CGPoint(x: Double($0) * 5, y: 50) }
        let m = MarkupGeometry.mark(tool: .freehand, color: .black, path: path, frame: frame, pixelSize: size)
        #expect(m?.points.first == ImagePoint(x: 0, y: 100) && m?.points.last == ImagePoint(x: 200, y: 100) && (m?.points.count ?? 0) >= 3)
    }
}
```

`Pastefix/PastefixTests/MarkupQueueTests.swift`:

```swift
import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// The mark queue (annotate spec): one mark applies at a time, none are dropped, each is one undo step.
@MainActor
@Suite("markup queue (annotate)")
struct MarkupQueueTests {
    private func png() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func host(_ f: ModelFixture) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func box(_ x: Int) -> ImageMark {
        ImageMark(tool: .box, color: .red, points: [ImagePoint(x: x, y: 20), ImagePoint(x: x + 40, y: 60)])
    }

    /// Review Focus 1.
    @Test func twoQuickMarksBothLand() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.queue")
        let original = try png()
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: original))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        f.model.enqueueMark(box(20))
        f.model.enqueueMark(ImageMark(tool: .arrow, color: .blue, points: [ImagePoint(x: 100, y: 100), ImagePoint(x: 200, y: 150)]))
        #expect(f.model.pendingMarks.count == 2)
        #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying })
        #expect(f.model.transformNote == "Arrow added.", "applied in order")
        let um = try #require(f.model.undoManager)
        #expect(um.undoActionName == "Arrow")
        um.undo()
        #expect(await f.eventually { um.undoActionName == "Box" })
        um.undo()
        #expect(await f.eventually { f.model.document?.imagePNG == original }, "two marks, two undo steps")
        #expect(f.settings.transformUsage.keys.allSatisfy { !$0.hasPrefix("builtin.annotate") }, "marks aren't transform uses")
    }

    /// Review Focus 2.
    @Test func boundaryEmptiesTheQueue() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.boundary")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        f.model.enqueueMark(box(10)); f.model.enqueueMark(box(60)); f.model.enqueueMark(box(110))
        let second = try png()
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: second))
        #expect(f.model.pendingMarks.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(f.model.document?.imagePNG == second, "nothing from the old queue reached the new session")
    }

    @Test func aFailedMarkIsDroppedAndTheQueueMovesOn() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.annotateLane = ImageTransformLane.makeLane(label: "test.annotate.fail")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        f.model.enqueueMark(ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 5, y: 5)], text: " "))   // nothing to draw
        f.model.enqueueMark(box(30))
        #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying })
        #expect(f.model.transformNote == "Box added.")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MarkupGeometryTests 2>&1 | grep -E "error:|Test run" | head -2`
Expected: `cannot find 'MarkupGeometry'`.

Run, under the lease: `scripts/test-app.sh "-only-testing:PastefixTests/MarkupQueueTests" 2>&1 | grep -E "error:|✘ Test.*recorded|Test run with" | head -4`
Expected: `value of type 'AppModel' has no member 'enqueueMark'`. Stub the members, re-run, and expect behavioural failures.

- [ ] **Step 3: Implement**

`Sources/PastefixAppCore/MarkupGeometry.swift`:

```swift
import CoreGraphics
import PastefixCore

/// Turns a markup drag (view points over the fitted image) into an `ImageMark` in image pixels
/// (annotate spec), or nil when it draws nothing: a tap (under 3 pt), a flat box or highlight,
/// or the text tool, whose mark comes from its text field.
public enum MarkupGeometry {
    public static func pixel(_ p: CGPoint, frame: CGRect, pixelSize: (width: Int, height: Int)) -> ImagePoint {
        let x = (p.x - frame.minX) / max(frame.width, 1) * Double(pixelSize.width)
        let y = (p.y - frame.minY) / max(frame.height, 1) * Double(pixelSize.height)
        return ImagePoint(x: min(max(Int(x.rounded()), 0), pixelSize.width),
                          y: min(max(Int(y.rounded()), 0), pixelSize.height))
    }

    public static func mark(tool: ImageMark.Tool, color: ImageMark.Color, path: [CGPoint],
                            frame: CGRect, pixelSize: (width: Int, height: Int)) -> ImageMark? {
        guard tool != .text, let first = path.first, let last = path.last,
              !RegionGeometry.isTap(from: first, to: path.max { hypot($0.x - first.x, $0.y - first.y) < hypot($1.x - first.x, $1.y - first.y) } ?? last)
        else { return nil }
        func px(_ p: CGPoint) -> ImagePoint { pixel(p, frame: frame, pixelSize: pixelSize) }
        switch tool {
        case .box, .highlight:
            let a = px(first), b = px(last)
            guard a.x != b.x, a.y != b.y else { return nil }
            return ImageMark(tool: tool, color: color, points: [a, b])
        case .arrow:
            let a = px(first), b = px(last)
            guard a != b else { return nil }
            return ImageMark(tool: tool, color: color, points: [a, b])
        case .freehand:
            return ImageMark(tool: tool, color: color, points: path.map(px))
        case .text:
            return nil
        }
    }
}
```

(The tap test uses the farthest point from the start, not just the last, so a freehand loop that ends where it began still counts as a stroke.)

In `AppModel.swift`, next to `pendingImageRegion`:

```swift
    /// Markup marks waiting to be burned in (annotate spec), in order. The head applies when no apply
    /// is running; each is one undo step. Never dropped by a fast second stroke, emptied at session
    /// boundaries (`resetUndo`).
    @Published private(set) var pendingMarks: [ImageMark] = []
    /// True while the head of `pendingMarks` is the apply in flight.
    private var markInFlight = false
    /// The lane `AnnotateImage` runs on: the shared image lane; tests give it a private one.
    var annotateLane: ImageTransformLane.Lane = ImageTransformLane.shared
    /// The markup tool and colour, for the app's run (not saved, not published: `PanelView` owns
    /// the live copies and writes them back).
    var markupTool: ImageMark.Tool = .box
    var markupColor: ImageMark.Color = .red
    /// A write-only mirror of `PanelView`'s markup mode, for the hosted tests (as `imageRegionOnScreen`).
    var markupModeOnScreen = false

    func enqueueMark(_ mark: ImageMark) {
        pendingMarks.append(mark)
        drainMarks()
    }

    /// Applies the queue's head if nothing is applying. Called on enqueue and whenever an apply ends.
    private func drainMarks() {
        guard !isApplying, !markInFlight, let next = pendingMarks.first, document != nil else { return }
        markInFlight = true
        apply(AnnotateImage(next, lane: annotateLane))
    }
```

Change `isApplying` to finish the in-flight mark and move on when an apply ends. `isApplying` is declared `@Published private(set) var isApplying = false`:

```swift
    @Published private(set) var isApplying = false {
        didSet {
            guard oldValue, !isApplying else { return }
            // An apply just ended: if it was a mark, that mark is done, landed or failed (a failed
            // one is dropped; its error shows as usual). Then the next one.
            if markInFlight {
                markInFlight = false
                if !pendingMarks.isEmpty { pendingMarks.removeFirst() }
            }
            drainMarks()
        }
    }
```

In `resetUndo()`, beside `pendingImageRegion = nil`:

```swift
        pendingMarks = []
        markInFlight = false
```

At the usage-recording line, `case .applied, .appliedWithNote: self.settings.recordTransformUse(transformer.id)`, exclude marks:

```swift
            case .applied, .appliedWithNote:
                // A markup mark isn't a transform the user chose from a list (annotate spec).
                if !(transformer is AnnotateImage) { self.settings.recordTransformUse(transformer.id) }
```

**If `isApplying` is set in more than one place,** the `didSet` covers them all, which is the point. **If a session boundary sets `isApplying = false`** while a mark is in flight, `resetUndo` has already emptied the queue, so the `didSet` finds nothing to remove or drain. Check `resetUndo` runs before `isApplying` is cleared at boundaries. If it doesn't, the `didSet`'s `document != nil` and the empty queue still keep it safe.

- [ ] **Step 4: Run to verify they pass, and commit**

Run: `swift test 2>&1 | grep -E "✘ Test|Test run with" | tail -1`, then, under the lease, `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test|Test run with" | tail -2`
Expected: both pass.

```bash
git add -A Sources/PastefixAppCore Tests/PastefixAppCoreTests Pastefix
git commit -m "feat: a markup mark queue on AppModel, and MarkupGeometry" -m "Marks apply one at a time, in order, each one undo step; a fast second stroke waits rather than being dropped, a failed one is dropped and the queue moves on, and session boundaries empty it. Marks aren't recorded as transform uses. MarkupGeometry maps a drag to an ImageMark in image pixels, discarding taps and flat shapes." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### Task 3: The view: markup mode, strip, overlay, Esc, docs

**Files:**
- Create: `Pastefix/Pastefix/MarkupOverlay.swift`
- Create: `Pastefix/Pastefix/MarkupStrip.swift`
- Create: `Pastefix/Pastefix/PanelEscape.swift`
- Modify: `Pastefix/Pastefix/ImageSessionView.swift`, `Pastefix/Pastefix/PanelView.swift`
- Test: `Pastefix/PastefixTests/MarkupOverlayTests.swift`, `Pastefix/PastefixTests/MarkupModeTests.swift`
- Modify: `README.md`, `AGENTS.md`

**Interfaces:**
- Consumes:
  - Task 1's `ImageMark` and `MarkGeometry`.
  - Task 2's `MarkupGeometry`, `AppModel.enqueueMark`, `pendingMarks`, `markupTool`, `markupColor`, `markupModeOnScreen`.
- Produces:
  - `struct TextDraft: Equatable { var point: ImagePoint; var viewPoint: CGPoint; var text: String }`;
  - `struct MarkupConfig { let tool: ImageMark.Tool; let color: ImageMark.Color; let pending: [ImageMark]; let textDraft: Binding<TextDraft?>; let onMark: (ImageMark) -> Void }`;
  - `MarkupOverlay(pixelSize:config:)`;
  - `ImageSessionView(..., markup: MarkupConfig?)`;
  - `enum PanelEscape` with `action(...)`.

- [ ] **Step 1: Write the failing tests**

`Pastefix/PastefixTests/MarkupOverlayTests.swift`:

```swift
import Testing
import AppKit
import SwiftUI
import Combine
import PastefixCore
@testable import Pastefix

/// The markup overlay driven by real mouse events, alone in a window (as ImageRegionOverlayTests).
@MainActor
@Suite("markup overlay, mouse (annotate)")
struct MarkupOverlayTests {
    final class Box: ObservableObject {
        @Published var tool: ImageMark.Tool = .box
        @Published var draft: TextDraft?
        var marks: [ImageMark] = []
    }
    private struct Host: View {
        @ObservedObject var box: Box
        var body: some View {
            MarkupOverlay(pixelSize: (600, 400),
                          config: MarkupConfig(tool: box.tool, color: .red, pending: [],
                                               textDraft: $box.draft, onMark: { box.marks.append($0) }))
                .frame(width: 300, height: 200)
        }
    }
    private func window(_ box: Box) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Host(box: box))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func drag(_ w: NSWindow, _ pts: [CGPoint]) async {
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: 200 - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        w.sendEvent(event(.leftMouseDown, pts[0])); await Task.yield()
        for p in pts.dropFirst() { w.sendEvent(event(.leftMouseDragged, p)); await Task.yield() }
        w.sendEvent(event(.leftMouseUp, pts.last!))
        try? await Task.sleep(for: .milliseconds(60))
    }

    @Test func aBoxDragMakesOneMarkInPixels() async {
        let box = Box(); let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, [CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 80), CGPoint(x: 150, y: 120)])
        #expect(box.marks == [ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 100, y: 100), ImagePoint(x: 300, y: 240)])])
    }

    @Test func aTapDrawsNothing() async {
        let box = Box(); let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, [CGPoint(x: 50, y: 50), CGPoint(x: 51, y: 51)])
        #expect(box.marks.isEmpty)
    }

    @Test func freehandRecordsThePath() async {
        let box = Box(); box.tool = .freehand
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, (0...10).map { CGPoint(x: 40 + Double($0) * 10, y: 100 + Double($0 % 3) * 5) })
        #expect(box.marks.count == 1 && box.marks[0].tool == .freehand && box.marks[0].points.count >= 3)
        #expect(box.marks.first?.points.first == ImagePoint(x: 80, y: 200))
    }

    @Test func aTextClickOpensADraftAndASecondClickCommitsIt() async {
        let box = Box(); box.tool = .text
        let w = window(box); defer { w.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        await drag(w, [CGPoint(x: 60, y: 40)])
        #expect(box.draft?.point == ImagePoint(x: 120, y: 80))
        box.draft?.text = "Look here"
        await drag(w, [CGPoint(x: 200, y: 150)])   // a click elsewhere finishes it, and opens nothing new
        #expect(box.marks == [ImageMark(tool: .text, color: .red, points: [ImagePoint(x: 120, y: 80)], text: "Look here")])
        #expect(box.draft == nil)
    }
}
```

`Pastefix/PastefixTests/MarkupModeTests.swift`:

```swift
import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

@MainActor
@Suite("markup mode (annotate)")
struct MarkupModeTests {
    /// Review Focus 5, and the whole Esc order, as a pure decision.
    @Test func escapeOrder() {
        func a(palette: Bool = false, history: Bool = false, upload: Bool = false, preview: Bool = false,
               text: Bool = false, markup: Bool = false, region: Bool = false) -> PanelEscape {
            PanelEscape.action(paletteOpen: palette, historyOpen: history, uploadOpen: upload, previewing: preview,
                               textDraftOpen: text, markupMode: markup, regionUp: region)
        }
        #expect(a(palette: true, text: true, markup: true) == .closePalette)
        #expect(a(history: true, markup: true) == .closeHistory)
        #expect(a(upload: true, markup: true) == .closeUpload)
        #expect(a(preview: true, text: true) == .closePreview)
        #expect(a(text: true, markup: true, region: true) == .discardText)
        #expect(a(markup: true, region: true) == .leaveMarkup)
        #expect(a(region: true) == .clearRegion)
        #expect(a() == .cancel)
    }

    private func png() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    private func host(_ f: ModelFixture) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func key(_ w: NSWindow, _ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        _ = w.performKeyEquivalent(with: e)
    }
    private func toggle(_ w: NSWindow) { key(w, "a", 0, [.command, .shift]) }
    private func esc(_ w: NSWindow) { key(w, "\u{1b}", 53, []) }

    @Test func shortcutTogglesOnlyInImageSessions() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: "text", richRTFD: nil))
        let w = host(f); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        toggle(w); try await Task.sleep(for: .milliseconds(150))
        #expect(!f.model.markupModeOnScreen, "no markup mode in a text session")
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        try await Task.sleep(for: .milliseconds(150))
        toggle(w)
        #expect(await f.eventually { f.model.markupModeOnScreen })
        toggle(w)
        #expect(await f.eventually { !f.model.markupModeOnScreen })
    }

    @Test func escLeavesMarkupThenCancels() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let w = host(f); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        toggle(w)
        #expect(await f.eventually { f.model.markupModeOnScreen })
        esc(w)
        #expect(await f.eventually { !f.model.markupModeOnScreen })
        #expect(f.model.document != nil, "the first Esc only left markup mode")
        esc(w)
        #expect(await f.eventually { f.model.document == nil })
    }

    @Test func aSessionBoundaryLeavesMarkup() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let w = host(f); defer { w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        toggle(w)
        #expect(await f.eventually { f.model.markupModeOnScreen })
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        #expect(await f.eventually { !f.model.markupModeOnScreen })
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run, under the lease: `scripts/test-app.sh "-only-testing:PastefixTests/MarkupOverlayTests" "-only-testing:PastefixTests/MarkupModeTests" 2>&1 | grep -E "error:|✘ Test.*recorded|Test run with" | head -6`
Expected: `cannot find 'MarkupOverlay'` and `cannot find 'PanelEscape'`. Add stubs with the Interfaces' signatures: an overlay that does nothing, and `action` returning `.cancel`. Expected: behavioural failures.

- [ ] **Step 3: `PanelEscape`, `MarkupOverlay`, `MarkupStrip`**

`Pastefix/Pastefix/PanelEscape.swift`:

```swift
/// What Esc does next in the panel: the whole order in one pure decision, so it can be tested
/// without a window (annotate spec). Overlays, then the preview, then the markup text field,
/// then markup mode, then the region, then the panel itself.
enum PanelEscape: Equatable {
    case closePalette, closeHistory, closeUpload, closePreview, discardText, leaveMarkup, clearRegion, cancel

    static func action(paletteOpen: Bool, historyOpen: Bool, uploadOpen: Bool, previewing: Bool,
                       textDraftOpen: Bool, markupMode: Bool, regionUp: Bool) -> PanelEscape {
        if paletteOpen { return .closePalette }
        if historyOpen { return .closeHistory }
        if uploadOpen { return .closeUpload }
        if previewing { return .closePreview }
        if textDraftOpen { return .discardText }
        if markupMode { return .leaveMarkup }
        if regionUp { return .clearRegion }
        return .cancel
    }
}
```

`Pastefix/Pastefix/MarkupOverlay.swift`:

```swift
import SwiftUI
import PastefixCore
import PastefixAppCore

/// A text label being typed (annotate spec): where it goes, in image pixels and in view points.
struct TextDraft: Equatable {
    var point: ImagePoint
    var viewPoint: CGPoint
    var text: String
}

/// What `ImageSessionView` needs to show markup mode instead of the region overlay.
struct MarkupConfig {
    let tool: ImageMark.Tool
    let color: ImageMark.Color
    /// Marks queued but not yet burned in, previewed so a fast stroke is visible at once.
    let pending: [ImageMark]
    let textDraft: Binding<TextDraft?>
    let onMark: (ImageMark) -> Void
}

/// Drawing over the fitted image in markup mode (annotate spec). One `DragGesture(minimumDistance: 0)`;
/// the stroke's points are collected while it runs and handed to `MarkupGeometry` at the end, which
/// returns the mark (or nil for a tap). Its start is `@GestureState`, so a cancelled stroke leaves
/// nothing behind. The text tool opens a `TextDraft` on a click; Return, or a click elsewhere,
/// finishes it. Never disabled while a mark applies: the model's queue keeps the order.
struct MarkupOverlay: View {
    let pixelSize: (width: Int, height: Int)
    let config: MarkupConfig

    @GestureState private var active = false
    @State private var path: [CGPoint] = []
    @FocusState private var textFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let frame = CGRect(origin: .zero, size: geo.size)
            let scale = geo.size.width / Double(max(pixelSize.width, 1))   // points per pixel
            ZStack(alignment: .topLeading) {
                Color.clear
                Canvas { context, _ in
                    for mark in config.pending { draw(mark, in: &context, scale: scale) }
                    if !path.isEmpty,
                       let live = MarkupGeometry.mark(tool: config.tool, color: config.color, path: path,
                                                      frame: frame, pixelSize: pixelSize) {
                        draw(live, in: &context, scale: scale)
                    }
                }
                if let draft = config.textDraft.wrappedValue {
                    TextField("Label", text: Binding(get: { config.textDraft.wrappedValue?.text ?? "" },
                                                     set: { config.textDraft.wrappedValue?.text = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: Double(MarkGeometry.fontSize(longerSide: max(pixelSize.width, pixelSize.height))) * scale,
                                      weight: .bold))
                        .foregroundStyle(swiftUIColor(config.color))
                        .fixedSize()
                        .focused($textFocused)
                        .onSubmit(commitText)
                        .offset(x: draft.viewPoint.x, y: draft.viewPoint.y)
                        .onAppear { textFocused = true }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($active) { value, state, _ in
                    if !state { state = true; path = [value.startLocation] }
                    path.append(value.location)
                }
                .onEnded { value in
                    defer { path = [] }
                    if config.tool == .text || config.textDraft.wrappedValue != nil {
                        // A click with a draft open finishes it and starts nothing; otherwise the
                        // text tool opens a draft where it was clicked.
                        if config.textDraft.wrappedValue != nil { commitText(); return }
                        if RegionGeometry.isTap(from: value.startLocation, to: value.location) {
                            config.textDraft.wrappedValue = TextDraft(
                                point: MarkupGeometry.pixel(value.startLocation, frame: frame, pixelSize: pixelSize),
                                viewPoint: value.startLocation, text: "")
                        }
                        return
                    }
                    if let mark = MarkupGeometry.mark(tool: config.tool, color: config.color, path: path,
                                                      frame: frame, pixelSize: pixelSize) {
                        config.onMark(mark)
                    }
                })
        }
    }

    private func commitText() {
        guard let draft = config.textDraft.wrappedValue else { return }
        config.textDraft.wrappedValue = nil
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        config.onMark(ImageMark(tool: .text, color: config.color, points: [draft.point], text: text))
    }

    private func swiftUIColor(_ c: ImageMark.Color) -> Color { Color(.sRGB, red: c.rgb.r, green: c.rgb.g, blue: c.rgb.b) }

    /// A preview of `mark` in view points: the same shapes `MarkRenderer` burns in, at display scale.
    private func draw(_ mark: ImageMark, in context: inout GraphicsContext, scale: Double) {
        let longer = max(pixelSize.width, pixelSize.height)
        let stroke = Double(MarkGeometry.strokeWidth(longerSide: longer)) * scale
        func v(_ p: ImagePoint) -> CGPoint { CGPoint(x: Double(p.x) * scale, y: Double(p.y) * scale) }
        let color = swiftUIColor(mark.color)
        let style = StrokeStyle(lineWidth: max(stroke, 1), lineCap: .round, lineJoin: .round)
        switch mark.tool {
        case .box where mark.points.count >= 2:
            let a = v(mark.points[0]), b = v(mark.points[1])
            context.stroke(Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))), with: .color(color), style: style)
        case .highlight where mark.points.count >= 2:
            let a = v(mark.points[0]), b = v(mark.points[1])
            context.blendMode = .multiply
            context.fill(Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))),
                         with: .color(Color(.sRGB, red: 1, green: 0.9, blue: 0, opacity: 0.45)))
            context.blendMode = .normal
        case .arrow where mark.points.count >= 2:
            let tail = v(mark.points[0]), tip = v(mark.points[1])
            let head = MarkGeometry.arrowHead(tail: tail, tip: tip, stroke: max(stroke, 1))
            context.stroke(Path { $0.move(to: tail); $0.addLine(to: head.base) }, with: .color(color), style: style)
            context.fill(Path { $0.move(to: head.tip); $0.addLine(to: head.left); $0.addLine(to: head.right); $0.closeSubpath() }, with: .color(color))
        case .freehand:
            let pts = MarkGeometry.thinned(mark.points.map(v), minDistance: 1)
            context.stroke(Path(MarkGeometry.smoothPath(pts)), with: .color(color), style: style)
        case .text:
            if let text = mark.text, let p = mark.points.first {
                let size = Double(MarkGeometry.fontSize(longerSide: longer)) * scale
                context.draw(Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(color), at: v(p), anchor: .topLeading)
            }
        default:
            break
        }
    }
}
```

`Pastefix/Pastefix/MarkupStrip.swift`:

```swift
import SwiftUI
import PastefixCore

/// The markup tool strip (annotate spec): the five tools, five colours, and Done. Shown above the
/// image only in markup mode.
struct MarkupStrip: View {
    @Binding var tool: ImageMark.Tool
    @Binding var color: ImageMark.Color
    let done: () -> Void

    private func symbol(_ t: ImageMark.Tool) -> String {
        switch t {
        case .box: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .freehand: "scribble"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ImageMark.Tool.allCases, id: \.self) { t in
                Button { tool = t } label: { Image(systemName: symbol(t)).frame(width: 22, height: 18) }
                    .buttonStyle(.bordered)
                    .tint(tool == t ? .accentColor : nil)
                    .help(t.name)
                    .accessibilityLabel(t.name)
                    .accessibilityAddTraits(tool == t ? .isSelected : [])
            }
            Divider().frame(height: 16)
            ForEach(ImageMark.Color.allCases, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(Color(.sRGB, red: c.rgb.r, green: c.rgb.g, blue: c.rgb.b))
                        .overlay(Circle().stroke(Color.primary.opacity(color == c ? 0.9 : 0.25), lineWidth: color == c ? 2 : 1))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(c.rawValue.capitalized)
                .accessibilityLabel("\(c.rawValue.capitalized) colour")
                .accessibilityAddTraits(color == c ? .isSelected : [])
            }
            Spacer()
            Button("Done", action: done)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
```

- [ ] **Step 4: Wire `ImageSessionView` and `PanelView`**

In `ImageSessionView`, add after `let interactive: Bool`:

```swift
    /// Markup mode's tools and queue (annotate spec), or nil for the region selection.
    let markup: MarkupConfig?
```

Replace the overlay body inside `preview`:

```swift
                .overlay {
                    // On the fitted image, so the overlay's geometry is exactly the image's rect.
                    if let pixels {
                        if let markup {
                            MarkupOverlay(pixelSize: (pixels.width, pixels.height), config: markup)
                        } else {
                            ImageRegionOverlay(region: $region, pixelSize: (pixels.width, pixels.height), enabled: interactive)
                        }
                    }
                }
```

In `PanelView`:

1. State, beside `imageRegion`:

```swift
    /// Markup mode (annotate spec): view state, like the region. Tool and colour live on the model
    /// for the app's run; these are the live copies.
    @State private var markupMode = false
    @State private var markupTool: ImageMark.Tool = .box
    @State private var markupColor: ImageMark.Color = .red
    @State private var textDraft: TextDraft?
```

2. The image branch becomes:

```swift
                        } else if let document = model.document, document.displaysAsImage,
                                  let imagePNG = document.imagePNG {
                            VStack(spacing: 0) {
                                if markupMode {
                                    MarkupStrip(tool: $markupTool, color: $markupColor, done: leaveMarkup)
                                    Divider()
                                }
                                ImageSessionView(imagePNG: imagePNG, revision: document.detectionRevision,
                                                 region: $imageRegion, interactive: !(model.isApplying || isUploadOpen),
                                                 markup: markupMode ? MarkupConfig(tool: markupTool, color: markupColor,
                                                                                    pending: model.pendingMarks, textDraft: $textDraft,
                                                                                    onMark: { model.enqueueMark($0) }) : nil)
                                    .id(model.sessionGeneration)
                            }
```

3. The toolbar button, before the Preview (eye) button:

```swift
            Button { toggleMarkup() } label: {
                Image(systemName: markupMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
            .help(markupMode ? "Done marking up (⌘⇧A)" : "Mark up the image (⌘⇧A)")
            .accessibilityLabel(markupMode ? "Done marking up" : "Mark up the image")
            .keyboardShortcut(isPaletteOpen || isHistoryOpen || isUploadOpen ? nil : KeyboardShortcut("a", modifiers: [.command, .shift]))
            .disabled(model.document?.displaysAsImage != true || isPaletteOpen || isHistoryOpen || isUploadOpen)
```

4. The helpers:

```swift
    private func toggleMarkup() {
        guard model.document?.displaysAsImage == true else { return }
        if markupMode { leaveMarkup() } else { markupMode = true; imageRegion = nil }
    }

    /// Leaves markup mode. A text label being typed is finished, as clicking away would; queued
    /// marks keep applying, since the queue is the model's.
    private func leaveMarkup() {
        if let draft = textDraft {
            textDraft = nil
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { model.enqueueMark(ImageMark(tool: .text, color: markupColor, points: [draft.point], text: text)) }
        }
        markupMode = false
    }
```

5. `escape()` becomes:

```swift
    /// Esc, in `PanelEscape`'s order: overlays, preview, the markup text field, markup mode, the
    /// image region, then the panel.
    private func escape() {
        switch PanelEscape.action(paletteOpen: isPaletteOpen, historyOpen: isHistoryOpen, uploadOpen: isUploadOpen,
                                  previewing: isPreviewing, textDraftOpen: textDraft != nil, markupMode: markupMode,
                                  regionUp: imageRegion != nil) {
        case .closePalette: closePalette()
        case .closeHistory: closeHistory()
        case .closeUpload: closeUpload()
        case .closePreview: closePreview()
        case .discardText: textDraft = nil
        case .leaveMarkup: markupMode = false
        // The region clears before the panel cancels, as a selection does everywhere (crop spec).
        case .clearRegion: imageRegion = nil
        case .cancel: model.cancel()
        }
    }
```

6. The handlers, next to the region's:

```swift
        .onChange(of: markupMode) { _, on in model.markupModeOnScreen = on }
        .onChange(of: markupTool) { _, t in model.markupTool = t }
        .onChange(of: markupColor) { _, c in model.markupColor = c }
        .onChange(of: model.document?.displaysAsImage) { _, isImage in
            if isImage != true { markupMode = false; textDraft = nil }   // e.g. after Extract Text
        }
        .onAppear { markupTool = model.markupTool; markupColor = model.markupColor }
```

7. In the `.onChange(of: model.sessionGeneration)` body, add `markupMode = false; textDraft = nil`. Where the upload overlay opens (`isUploadOpen = true`), add `markupMode = false; textDraft = nil`.

8. In `onChange(of: model.document?.detectionRevision)`, the region rule is unchanged. Markup mode survives a mark landing, because each mark is a new revision.

- [ ] **Step 5: Run to verify they pass**

Run: `swift test 2>&1 | grep -E "✘ Test|Test run with" | tail -1`, then, under the lease, `scripts/test-app.sh 2>&1 | grep -E "error:|✘ Test|Test run with" | tail -2`
Expected: both pass.

**If `aTextClickOpensADraftAndASecondClickCommitsIt` fails** because the second click lands on the `TextField` rather than the overlay: the field sits at (60, 40). The click at (200, 150) is away from it, but check the field isn't laid out full width (`.fixedSize()`). **If the ⌘⇧A tests fail** because `performKeyEquivalent` doesn't reach the button: the `HistoryShortcutTests` pattern is the reference for how other shortcut tests send keys. Use the same mechanism and record a ruling.

- [ ] **Step 6: Docs**

`README.md`, in the Images section after the Scale bullet:

```markdown
- **Markup** (⌘⇧A, or the pencil button) lets you draw on the picture: a **box** around something, an **arrow** pointing at it, a short **text** label, a yellow **highlighter** over text, or a **freehand** line, such as a rough circle. Pick a tool and a colour in the strip above the picture, then drag (or click, for text: type, then press Return). Each mark becomes part of the picture straight away, and ⌘Z removes the last one. Press Esc or Done when you've finished.
```

`AGENTS.md`:

- **Core file map, a new `Annotate/` group:**

```
  Annotate/
    ImageMark.swift                   # annotate: ImagePoint + ImageMark (tool box/arrow/text/highlight/freehand, colour red/yellow/blue/black/white, points in ORIENTED image pixels top-left, text); tool names = undo names; notes "Box added." etc.; colour halo rule
    MarkGeometry.swift                #   pure: stroke max(2, L/250), font max(12, L/40), halo max(1, stroke/2) (L = longer side, .rounded()); arrowHead (4×/3× stroke); thinned (1 px, keeps ends); smoothPath (quads through midpoints)
    MarkRenderer.swift                #   draws one mark into OrientedSource's bitmap (y flipped); highlighter = sRGB (1, .9, 0, .45) MULTIPLY, ignores the swatch; text via Core Text, halo = stroke-only pass under the fill
```

- After `ScaleImage.swift`:

```
    AnnotateImage.swift               #   NOT REGISTERED (not in ⌘K/sidebar; AppModel doesn't record its use): holds one ImageMark; markup mode applies one per finished mark → one undo step each; takes a lane (tests: never the shared one)
```

- **AppCore:** `MarkupGeometry.swift  # annotate: drag (view points) → ImageMark (pixels) or nil: taps (< 3 pt, by the FARTHEST point from the start), flat box/highlight, and the text tool (its mark comes from the text field)`
- **App:**
  - `MarkupOverlay.swift`: the overlay in markup mode, never disabled while applying; previews `pendingMarks`; text draft.
  - `MarkupStrip.swift`: the tool strip.
  - `PanelEscape.swift`: the Esc order as a pure decision.
- **On the `AppModel.swift` line:** `pendingMarks` queue: one apply at a time via the `isApplying` `didSet`; a failed mark is dropped; `resetUndo` empties it.
- **On the `PanelView.swift` line:** markup mode is `@State`, toggled by ⌘⇧A and only in image sessions; it turns off at a session boundary, when the entry stops being an image, and when upload opens; Esc goes through `PanelEscape`.

- [ ] **Step 7: Commit**

```bash
git add -A Pastefix README.md AGENTS.md
git commit -m "feat: markup mode — draw boxes, arrows, text, highlights and freehand on an image" -m "⌘⇧A or the pencil button opens a tool strip over the image; a drag (or a click, for text) makes a mark that the model's queue burns in as one undo step, in order, without dropping fast strokes. Esc's order is a pure PanelEscape decision: overlays, preview, the text field, markup mode, the region, then the panel." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AmKVj6UbJNzczbuG1p7mqv"
```

---

### After the tasks

- A final whole-branch review by a fresh reviewer, then the PR.
- The GUI pass, with the owner's OK:
  - every tool and colour on dark, blue and white images;
  - text legibility;
  - the highlighter over real text;
  - a freehand oval;
  - fast strokes;
  - undo and redo;
  - ⌘⇧A;
  - how the strip looks.
- Clicks only: never type into fields under automation. The text tool's typing is checked by the owner.
