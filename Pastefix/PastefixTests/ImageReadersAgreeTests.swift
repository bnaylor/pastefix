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
/// Every shape that decides *whether an image exists* is here, not only #81's, so that the next
/// divergence on that question fails too. Out of scope, and not the same question:
/// - the byte budget, which can only make history hold *less* than the session — never an image
///   the session refuses, which was #81's harm;
/// - which *bytes* each keeps. JPEG bytes under `public.png` are converted by the session and
///   stored raw by history (header-only validation). Both say "image", so this suite passes;
///   history now converts them too (#97, `mislabelledPNG` below).
@MainActor
@Suite("the session and history capture agree on whether there is an image (#81)")
struct ImageReadersAgreeTests {
    private func agree(_ f: ModelFixture, _ label: String, expectImage: Bool) {
        let session = ClipboardBridge.snapshot(from: f.pasteboard).imagePNG != nil
        let read = PasteboardMonitor.read(f.pasteboard, maxImageBytes: .max)
        let history = read?.candidate.imagePNG != nil || read?.pendingConversion != nil
        #expect(session == expectImage, "\(label): session")
        #expect(history == expectImage, "\(label): history")
    }

    /// Declares `declared`, but materialises only `materialised` — a provider that promises a type
    /// and never delivers it.
    private func copyDeclaring(_ f: ModelFixture, _ declared: [NSPasteboard.PasteboardType],
                               materialised: [NSPasteboard.PasteboardType: Data]) {
        f.pasteboard.clearContents()
        f.pasteboard.declareTypes(declared, owner: nil)
        for (type, data) in materialised { f.pasteboard.setData(data, forType: type) }
        for type in declared where materialised[type] == nil {
            #expect(f.pasteboard.data(forType: type) == nil, "fixture: \(type.rawValue) must never materialise")
        }
    }

    @Test("a declared-but-nil PNG beside a real TIFF is no image to either reader")
    func declaredButNilPNG() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let tiff = try #require(Pixels.encoded(width: 20, height: 10, type: "public.tiff"))
        copyDeclaring(f, [.png, .tiff], materialised: [.tiff: tiff])
        agree(f, "declared-but-nil PNG + TIFF", expectImage: false)
    }

    @Test("a declared-but-nil TIFF alone is no image to either reader")
    func declaredButNilTIFF() throws {
        let f = try ModelFixture(); defer { f.finish() }
        copyDeclaring(f, [.tiff], materialised: [:])
        agree(f, "declared-but-nil TIFF only", expectImage: false)
        // Not here, because it cannot be built: a PNG beside a declared, never-set TIFF. The
        // pasteboard synthesises the TIFF from the PNG (measured: `data(forType: .tiff)` returned
        // 3,992 bytes), so on a real pasteboard that shape is "PNG + TIFF", already covered below.
    }

    // #97: the readers agree that JPEG bytes under `public.png` are an image; they used to keep
    // different bytes. The session converts them; history stored them raw, EXIF included, and ⌘↵
    // wrote them back under a PNG's name. Now history defers them to the conversion a TIFF gets.
    @Test("history defers a mislabelled PNG to conversion, and takes a real PNG as-is (#97)")
    func mislabelledPNG() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let jpeg = try #require(Pixels.encoded(width: 20, height: 10, type: "public.jpeg"))
        f.copy([.png: jpeg])
        let mislabelled = try #require(PasteboardMonitor.read(f.pasteboard, maxImageBytes: .max))
        #expect(mislabelled.candidate.imagePNG == nil, "stored raw under a PNG's name")
        #expect(mislabelled.pendingConversion == jpeg)
        #expect(mislabelled.imagePixelWidth == 20 && mislabelled.imagePixelHeight == 10)
        // The claim itself: history's conversion lane produces the bytes the session keeps.
        let session = try #require(ClipboardBridge.snapshot(from: f.pasteboard).imagePNG)
        #expect(ImageBytes.convertedToPNG(try #require(mislabelled.pendingConversion)) == session)

        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.copy([.png: png])
        let real = try #require(PasteboardMonitor.read(f.pasteboard, maxImageBytes: .max))
        #expect(real.candidate.imagePNG == png, "a real PNG is kept verbatim, with no conversion")
        #expect(real.pendingConversion == nil)
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
            ("empty TIFF", [.tiff: Data()], false),
            ("garbage under public.png", [.png: Data("not an image at all".utf8)], false),
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
