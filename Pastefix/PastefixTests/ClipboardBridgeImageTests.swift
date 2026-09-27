import Testing
import AppKit
import PastefixAppCore
@testable import Pastefix

/// `ClipboardBridge.snapshot`'s image rules against a real (private) pasteboard. Until #68 they
/// rested on a one-off runtime probe; the pure seam `ClipboardImageRead` is tested at package
/// level, but not that the bridge wires it to `NSPasteboard` the way its comments say.
@MainActor
@Suite("ClipboardBridge image rules")
struct ClipboardBridgeImageTests {
    @Test("a PNG is kept byte-for-byte, never re-encoded — Save writes what was copied")
    func pngVerbatim() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.copy([.png: png])
        #expect(ClipboardBridge.snapshot(from: f.pasteboard).imagePNG == png)
    }

    @Test("a TIFF is converted to PNG")
    func tiffConverted() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let tiff = try #require(Pixels.encoded(width: 20, height: 10, type: "public.tiff"))
        f.copy([.tiff: tiff])
        let out = try #require(ClipboardBridge.snapshot(from: f.pasteboard).imagePNG)
        #expect(out.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("with both offered, the PNG is read — no TIFF decode on the common screenshot path")
    func pngPreferred() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        let tiff = try #require(Pixels.encoded(width: 30, height: 30, type: "public.tiff"))
        f.copy([.png: png, .tiff: tiff])
        #expect(ClipboardBridge.snapshot(from: f.pasteboard).imagePNG == png)
    }

    @Test("a TIFF over the pixel ceiling is refused, and the refusal remembers its size")
    func overCeilingRefused() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let tiff = try #require(Pixels.encoded(width: 5200, height: 5000, type: "public.tiff", compressedTIFF: true))
        f.copy([.tiff: tiff])
        let snap = ClipboardBridge.snapshot(from: f.pasteboard)
        #expect(snap.imagePNG == nil)
        #expect(snap.refusedImagePixels == 5200 * 5000)
    }

    @Test("a Finder-shaped file copy is not an image; a Photos-shaped one is (#78)")
    func fileCopies() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let tiff = try #require(Pixels.encoded(width: 20, height: 10, type: "public.tiff"))
        let url = Data("file:///.file/id=1.2".utf8)
        f.copy([.tiff: tiff, .fileURL: url, NSPasteboard.PasteboardType("com.apple.icns"): Data([0])])
        #expect(ClipboardBridge.snapshot(from: f.pasteboard).imagePNG == nil)
        let jpeg = try #require(Pixels.encoded(width: 20, height: 10, type: "public.jpeg"))
        f.copy([.tiff: tiff, .fileURL: url, NSPasteboard.PasteboardType("public.jpeg"): jpeg])
        #expect(ClipboardBridge.snapshot(from: f.pasteboard).imagePNG != nil)
    }
}
