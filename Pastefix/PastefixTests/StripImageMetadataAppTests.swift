import Testing
import AppKit
import ImageIO
import PastefixCore
import PastefixAppCore
@testable import Pastefix

@MainActor
@Suite("Strip Image Metadata in a session (#82)")
struct StripImageMetadataAppTests {
    private func gpsPNG() -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let image = rep?.cgImage else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0,
                                                                              kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    @Test("offered in an image session; applying swaps the image, and ⌘Z restores it")
    func applyAndUndo() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(gpsPNG())
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        let strip = try #require(f.model.enabledTransformers().first { $0.id == "builtin.stripimagemetadata" })
        f.model.apply(strip)
        #expect(await f.eventually { f.model.document?.imagePNG != png })
        #expect(f.model.transformNote == "Removed location details.")
        #expect(ImageMetadata.inspect(try #require(f.model.document?.imagePNG)).isEmpty)
        f.model.undo()
        #expect(f.model.document?.imagePNG == png)
    }

    // Review Focus 3.
    @Test("not offered in a text or mixed session")
    func notOffered() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(gpsPNG())
        f.model.beginSession(from: ClipboardSnapshot(plainText: "caption", richRTFD: nil, imagePNG: png))
        #expect(!f.model.enabledTransformers().contains { $0.id == "builtin.stripimagemetadata" })
    }
}
