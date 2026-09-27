import Testing
import Foundation
import AppKit
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
        #expect(!image.png.isEmpty)
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

    @Test("over the byte cap after stripping: refused with the stripped size")
    func overByteCap() throws {
        let input = try #require(Self.png(width: 400, height: 300))
        guard case .refused(.tooManyBytes(let bytes)) = ImageUploadPreparation.prepare(input, maxBytes: 10) else {
            Issue.record("expected a byte refusal"); return
        }
        #expect(bytes > 10)
    }

    @Test("undecodable bytes: refused, never an upload of the original")
    func unusable() {
        #expect(ImageUploadPreparation.prepare(Data("not an image".utf8)) == .refused(.unusable))
        #expect(ImageUploadPreparation.prepare(Data()) == .refused(.unusable))
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
