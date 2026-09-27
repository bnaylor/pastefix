import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PastefixCore
@testable import PastefixAppCore

/// #48: what the image upload card shows is decided here, off the main actor, as a value.
@Suite("ImageUploadPreparation")
struct ImageUploadPreparationTests {
    static func png(width: Int, height: Int, text: String? = nil, fontSize: CGFloat = 22) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (text as NSString).draw(at: NSPoint(x: 20, y: height / 2),
                                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                                     .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @Test("an image with legible text is ready and flagged as containing text")
    func textFlagged() throws {
        let input = try #require(Self.png(width: 900, height: 200, text: "password=Tr0ub4dor3xKcd9zQ"))
        guard case .ready(let image, let hasText) = ImageUploadPreparation.prepare(input) else {
            Issue.record("expected ready"); return
        }
        #expect(hasText)
        #expect(!image.toSend.data.isEmpty)
    }

    @Test("a blank image is ready and not flagged — which is not a claim that it is safe")
    func blankNotFlagged() throws {
        let input = try #require(Self.png(width: 900, height: 200))
        guard case .ready(_, let hasText) = ImageUploadPreparation.prepare(input) else {
            Issue.record("expected ready"); return
        }
        #expect(!hasText)
    }

    @Test("small text is missed — pinned, because it is why the verdict never reassures")
    func smallTextMissed() throws {
        // Measured: one line at 11 px produces zero text regions (detected from ~16 px up). The
        // card must therefore never say "no text found" — `hasText == false` means "not detected",
        // and the not-checked verdict is shown regardless. If Vision improves and this starts
        // detecting, the limitation note can be revisited; it must never be read as permission to
        // show a clean verdict.
        let input = try #require(Self.png(width: 900, height: 200, text: "password=Tr0ub4dor3xKcd9zQ", fontSize: 11))
        guard case .ready(_, let hasText) = ImageUploadPreparation.prepare(input) else {
            Issue.record("expected ready"); return
        }
        withKnownIssue("Vision text-region detection misses ~11 px text; the verdict never reassures because of this") {
            #expect(hasText)
        }
    }

    @Test("over the pixel ceiling: refused with the figure")
    func overCeiling() throws {
        let input = try #require(Self.png(width: 400, height: 300))
        #expect(ImageUploadPreparation.prepare(input, maxPixels: 400 * 300 - 1) == .refused(.tooManyPixels(400 * 300)))
    }

    @Test("over the byte cap after stripping, even as JPEG: refused with the JPEG's size")
    func overByteCap() throws {
        let input = try #require(Self.png(width: 400, height: 300))
        let jpeg = try #require(ImageSanitizer.encodings(input)?.jpeg)
        #expect(ImageUploadPreparation.prepare(input, maxBytes: 10) == .refused(.tooManyBytes(jpeg.data.count, format: .jpeg)))
    }

    @Test("an image with transparency over the cap: refused with the PNG's size, never flattened")
    func transparentOverByteCap() throws {
        let input = try #require(PhotoFixture.png(PhotoFixture.photo(alpha: 254)))
        let png = try #require(ImageSanitizer.stripped(input))
        #expect(ImageUploadPreparation.prepare(input, maxBytes: 10) == .refused(.tooManyBytes(png.data.count, format: .png)))
    }

    @Test("undecodable bytes: refused, never an upload of the original")
    func unusable() {
        #expect(ImageUploadPreparation.prepare(Data("not an image".utf8)) == .refused(.unusable))
        #expect(ImageUploadPreparation.prepare(Data()) == .refused(.unusable))
    }
}

/// #21: which format a prepared image goes as, end to end — through the real strip, both real
/// encodes and the real rule. The fixtures stand in for what was measured: **smoothed noise with
/// grain** for photo texture (measured ~0.19 of its PNG, like real photos' 0.15–0.23 — *uniform*
/// noise measures 0.38, near the threshold, and would pass only by luck), rendered monospaced text
/// for a terminal screenshot (~1.37), and a text window over a photographic wallpaper (~0.33).
@Suite("ImageUploadPreparation format")
struct ImageUploadPreparationFormatTests {
    static func prepared(_ input: Data, maxBytes: Int = UploadLimits.maxPayloadBytes) -> PreparedImage? {
        guard case .ready(let prepared, _) = ImageUploadPreparation.prepare(input, maxBytes: maxBytes) else { return nil }
        return prepared
    }

    static func sizes(_ input: Data) -> (png: Int, jpeg: Int)? {
        guard let encodings = ImageSanitizer.encodings(input), let jpeg = encodings.jpeg else { return nil }
        return (encodings.png.data.count, jpeg.data.count)
    }

    @Test("a photo goes as JPEG, with the PNG offered as the escape")
    func photoIsJPEGWithEscape() throws {
        let input = try #require(PhotoFixture.png(PhotoFixture.photo()))
        let (png, jpeg) = try #require(Self.sizes(input))
        #expect(Double(jpeg) / Double(png) < 0.3)   // fixture sanity: photo-like, not near 0.5
        let prepared = try #require(Self.prepared(input))
        #expect(prepared.choice == .jpegWithPNGEscape)
        #expect(prepared.chosen.format == .jpeg)
        #expect(prepared.pngAlternative?.format == .png)
        #expect(prepared.pngByteCount == png)
        #expect(prepared.toSend == prepared.chosen)
    }

    @Test("a text screenshot goes as PNG, with nothing else kept")
    func screenshotIsPNG() throws {
        let input = try #require(PhotoFixture.png(PhotoFixture.screenshot()))
        let (png, jpeg) = try #require(Self.sizes(input))
        #expect(Double(jpeg) / Double(png) > 1)     // fixture sanity: screenshot-like
        let prepared = try #require(Self.prepared(input))
        #expect(prepared.choice == .png)
        #expect(prepared.chosen.format == .png)
        #expect(prepared.pngAlternative == nil)
    }

    @Test("a screenshot over a photographic wallpaper goes as JPEG with the escape — the owner's call")
    func wallpaperScreenshotIsJPEGWithEscape() throws {
        // The case no ratio can separate from a photo (a real full-screen capture measured 0.28).
        // Pinned so the escape stays the answer, not a threshold tweak.
        let input = try #require(PhotoFixture.png(PhotoFixture.windowOverWallpaper(inset: CGSize(width: 150, height: 100))))
        let (png, jpeg) = try #require(Self.sizes(input))
        #expect(Double(jpeg) / Double(png) < 0.5)
        let prepared = try #require(Self.prepared(input))
        #expect(prepared.choice == .jpegWithPNGEscape)
        #expect(prepared.pngAlternative != nil)
    }

    @Test("an RGBA photo with every alpha at 255 goes as JPEG; one pixel at 254 sends it as PNG")
    func opaqueAlphaIsPixelTest() throws {
        let opaque = try #require(PhotoFixture.png(PhotoFixture.photo(alpha: nil)))
        let translucent = try #require(PhotoFixture.png(PhotoFixture.photo(alpha: 254)))
        #expect(PhotoFixture.hasAlphaChannel(opaque))       // fixture sanity: a channel, all opaque
        #expect(PhotoFixture.hasAlphaChannel(translucent))
        #expect(Self.prepared(opaque)?.choice == .jpegWithPNGEscape)
        let prepared = try #require(Self.prepared(translucent))
        #expect(prepared.choice == .png)
        #expect(prepared.chosen.format == .png)
    }

    @Test("PNG over the cap, JPEG under it: JPEG with no escape, for a photo")
    func overCapPhotoForcedJPEG() throws {
        let input = try #require(PhotoFixture.png(PhotoFixture.photo()))
        let (png, jpeg) = try #require(Self.sizes(input))
        let prepared = try #require(Self.prepared(input, maxBytes: (png + jpeg) / 2))
        #expect(prepared.choice == .jpegForcedByCap)
        #expect(prepared.chosen.format == .jpeg)
        #expect(prepared.pngAlternative == nil)
        #expect(prepared.pngByteCount == png)
    }

    @Test("PNG over the cap, JPEG under it: JPEG even when the ratio alone would say PNG")
    func overCapForcesJPEGWhateverTheRatio() throws {
        // A window with a thin border of wallpaper: opaque, JPEG smaller than PNG, but well over
        // the 0.5 threshold — so under the cap it goes as PNG, and over it, as JPEG.
        let input = try #require(PhotoFixture.png(PhotoFixture.windowOverWallpaper(inset: CGSize(width: 25, height: 25))))
        let (png, jpeg) = try #require(Self.sizes(input))
        let ratio = Double(jpeg) / Double(png)
        #expect(ratio > 0.55 && ratio < 0.95, "fixture ratio \(ratio)")
        #expect(Self.prepared(input)?.choice == .png)
        let prepared = try #require(Self.prepared(input, maxBytes: (png + jpeg) / 2))
        #expect(prepared.choice == .jpegForcedByCap)
        #expect(prepared.chosen.format == .jpeg)
    }

    @Test("the cap applies to the JPEG that is sent")
    func capAppliesToJPEG() throws {
        let input = try #require(PhotoFixture.png(PhotoFixture.photo()))
        let (_, jpeg) = try #require(Self.sizes(input))
        #expect(Self.prepared(input, maxBytes: jpeg)?.chosen.data.count == jpeg)
        #expect(ImageUploadPreparation.prepare(input, maxBytes: jpeg - 1) == .refused(.tooManyBytes(jpeg, format: .jpeg)))
    }
}

/// Synthetic stand-ins for photos and screenshots (#21). Never a real photograph.
enum PhotoFixture {
    static let width = 640, height = 480

    static func context(width: Int = width, height: Int = height) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Smoothed noise plus grain: random colour cells 8 px apart, interpolated up, then ±3 of
    /// per-channel grain — texture that compresses like a photo (JPEG ~0.19 of PNG). Every alpha
    /// is 255, in a real alpha channel; `alpha` sets one pixel to something else.
    static func photo(width: Int = width, height: Int = height, alpha: UInt8? = nil) -> CGImage? {
        var seed: UInt32 = 0x9E37_79B9
        func next() -> UInt32 { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed }
        let cellsWide = width / 8 + 2, cellsHigh = height / 8 + 2
        guard let small = context(width: cellsWide, height: cellsHigh),
              let cells = small.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
        for i in 0..<(cellsWide * cellsHigh) { cells[i] = next() | 0xFF00_0000 }
        guard let cellImage = small.makeImage(), let big = context(width: width, height: height),
              let pixels = big.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        big.interpolationQuality = .high
        big.draw(cellImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<(width * height * 4) where i % 4 != 3 {
            pixels[i] = UInt8(clamping: Int(pixels[i]) + Int(next() % 7) - 3)
        }
        if let alpha {
            // Premultiplied: colour components may not exceed alpha.
            let p = (height / 2 * width + width / 3) * 4
            for c in 0..<3 { pixels[p + c] = min(pixels[p + c], alpha) }
            pixels[p + 3] = alpha
        }
        return big.makeImage()
    }

    /// A terminal's worth of monospaced text on white: compresses like a screenshot (JPEG > PNG).
    static func screenshot(width: Int = width, height: Int = height) -> CGImage? {
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(in: ctx, rect: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// A white text window over photographic wallpaper, `inset` from each edge.
    static func windowOverWallpaper(inset: CGSize, width: Int = 800, height: Int = 500) -> CGImage? {
        guard let wallpaper = photo(width: width, height: height),
              let ctx = context(width: width, height: height) else { return nil }
        ctx.draw(wallpaper, in: CGRect(x: 0, y: 0, width: width, height: height))
        let window = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: inset.width, dy: inset.height)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(window)
        drawText(in: ctx, rect: window)
        return ctx.makeImage()
    }

    static func drawText(in ctx: CGContext, rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                         .foregroundColor: NSColor.black]
        var y = rect.maxY - 20, n = 0
        while y > rect.minY + 4 {
            ("\(n) $ ls -la /usr/local/bin && echo 'hello world' | grep -v foo # line \(n * 7919 % 1000)" as NSString)
                .draw(at: NSPoint(x: rect.minX + 8, y: y), withAttributes: attributes)
            y -= 17; n += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// PNG bytes, keeping the alpha channel (ImageIO in memory: fixture-only, so its leak is moot).
    static func png(_ image: CGImage?) -> Data? {
        guard let image else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    static func hasAlphaChannel(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
    }
}

/// Chrome's "Copy Image" (measured, 8 types): public.png, public.html (`<img src=…>`),
/// org.chromium.source-url, public.tiff — and **no plain text**. So a Chrome copy is an image
/// session and ⌘⇧U uploads the picture. The trap: the declared `public.html` makes the rich read
/// return a one-character string, U+FFFC (an attachment). `displaysAsImage` looks only at
/// `plainText`, so it is unaffected — anything that ever derived "text session" from rich content
/// would flip every Chrome copy to text, and ⌘⇧U would then upload nothing the user meant.
@Suite("Chrome-shaped snapshot")
struct ChromeShapedSnapshotTests {
    @Test("a Chrome Copy Image snapshot displays as an image despite its rich attachment")
    func chromeIsImage() throws {
        let png = try #require(ImageUploadPreparationTests.png(width: 40, height: 30))
        let attachment = NSAttributedString(string: "\u{FFFC}")
        let snapshot = ClipboardSnapshot(plainText: nil, rich: attachment, imagePNG: png)
        #expect(snapshot.richRTFD != nil)   // fixture sanity: the rich representation is present
        #expect(PasteDocument(origin: snapshot).displaysAsImage)
    }
}
