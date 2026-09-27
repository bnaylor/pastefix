import Testing
import AppKit
import PastefixAppCore
@testable import Pastefix

/// The session (`ClipboardBridge.snapshot`) and history capture (`PasteboardMonitor.read`) read the
/// same pasteboard, and must agree on whether it holds an image at all (#81). They used to disagree
/// on one shape: a `public.png` that is declared but never materialised, beside a real TIFF. The
/// session refused it (a provider that breaks one promise isn't trusted for its other one), and
/// history fell through to the TIFF and captured an image the session would not open.
///
/// Every shape either reader has to decide is here, not only #81's, so that the next divergence on
/// *whether an image exists* fails too. What they may still legitimately differ on — the byte
/// budget, and decode versus header-only validation — is kept out of these shapes.
@MainActor
@Suite("the session and history capture agree on whether there is an image (#81)")
struct ImageReadersAgreeTests {
    private func agree(_ f: ModelFixture, _ label: String, expectImage: Bool) {
        let session = ClipboardBridge.snapshot(from: f.pasteboard).imagePNG != nil
        let read = PasteboardMonitor.read(f.pasteboard, maxImageBytes: .max)
        let history = read?.candidate.imagePNG != nil || read?.pendingTIFF != nil
        #expect(session == expectImage, "\(label): session")
        #expect(history == expectImage, "\(label): history")
    }

    @Test("a declared-but-nil PNG beside a real TIFF is no image to either reader")
    func declaredButNilPNG() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let tiff = try #require(Pixels.encoded(width: 20, height: 10, type: "public.tiff"))
        f.pasteboard.clearContents()
        f.pasteboard.declareTypes([.png, .tiff], owner: nil)
        f.pasteboard.setData(tiff, forType: .tiff)
        #expect(f.pasteboard.data(forType: .png) == nil, "fixture: the PNG must be declared and never materialised")
        agree(f, "declared-but-nil PNG + TIFF", expectImage: false)
    }

    @Test("every other shape: both readers give the same answer")
    func everyShape() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        let tiff = try #require(Pixels.encoded(width: 20, height: 10, type: "public.tiff"))
        let jpeg = try #require(Pixels.encoded(width: 20, height: 10, type: "public.jpeg"))
        let url = Data("file:///.file/id=1.2".utf8)
        let icns = NSPasteboard.PasteboardType("com.apple.icns")
        let shapes: [(String, [NSPasteboard.PasteboardType: Data], Bool)] = [
            ("PNG", [.png: png], true),
            ("TIFF", [.tiff: tiff], true),
            ("PNG + TIFF", [.png: png, .tiff: tiff], true),
            ("empty PNG + TIFF", [.png: Data(), .tiff: tiff], false),
            ("Finder file copy", [.tiff: tiff, .fileURL: url, icns: Data([0])], false),
            ("Photos copy", [.tiff: tiff, .fileURL: url, NSPasteboard.PasteboardType("public.jpeg"): jpeg], true),
            ("text only", [.string: Data("hello".utf8)], false),
        ]
        for (label, representations, expectImage) in shapes {
            f.copy(representations)
            agree(f, label, expectImage: expectImage)
        }
    }
}
