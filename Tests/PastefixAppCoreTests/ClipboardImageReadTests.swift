import Testing
import Foundation
@testable import PastefixAppCore

@Suite("ClipboardImageRead")
struct ClipboardImageReadTests {
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private let tiffBytes = Data([0x4D, 0x4D, 0x00, 0x2A])
    private let convertedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x99])

    /// Stands in for the pasteboard: a type-to-bytes table plus the adapter's decode behaviour
    /// (PNG through unchanged, TIFF converted, anything else undecodable).
    private func read(_ table: [String: Data?],
                      decode: ((Data) -> Data?)? = nil) -> Data? {
        ClipboardImageRead.imagePNG(
            available: { asked in asked.sorted().first(where: { table.keys.contains($0) }) },
            data: { table[$0] ?? nil },
            decodePNG: decode ?? { bytes in
                if bytes.starts(with: [0x89, 0x50]) { return bytes }
                if bytes == self.tiffBytes { return self.convertedPNG }
                return nil
            }
        )
    }

    @Test("no image type offered is no image")
    func noTypeOffered() {
        #expect(read([:]) == nil)
        #expect(read(["public.utf8-plain-text": Data("hi".utf8)]) == nil)
    }

    @Test("a PNG whose bytes decode is kept as those bytes")
    func pngKeptVerbatim() throws {
        let out = try #require(read([ClipboardImageRead.pngType: pngBytes]))
        // Byte-for-byte: what Save writes back has to be what the user copied, not a re-encode.
        #expect(out == pngBytes)
    }

    @Test("a type advertised whose data is nil is no image, and never an empty Data")
    func advertisedButUnmaterialised() {
        // The rule that matters most. A provider can declare `.png` and then fail to produce it
        // (a promised type whose owner has quit, a Finder promise never fulfilled). An empty
        // `Data` here would be written straight back over the user's clipboard by Save as a
        // zero-byte image, destroying what they copied.
        let out = read([ClipboardImageRead.pngType: nil])
        #expect(out == nil)
        #expect(out != Data())
    }

    @Test("zero bytes for an advertised type is no image")
    func emptyBytes() {
        let out = read([ClipboardImageRead.pngType: Data()])
        #expect(out == nil)
        #expect(out != Data())
    }

    @Test("bytes that do not decode are no image")
    func undecodableBytes() {
        // Advertised as a PNG, and the provider did hand over bytes — they are just not an image.
        #expect(read([ClipboardImageRead.pngType: Data("not an image at all".utf8)]) == nil)
    }

    @Test("a TIFF becomes the converted PNG")
    func tiffConverted() throws {
        let out = try #require(read([ClipboardImageRead.tiffType: tiffBytes]))
        #expect(out == convertedPNG)
        #expect(out != tiffBytes)   // never the raw TIFF under a PNG's name
    }

    @Test("a TIFF that will not convert is no image")
    func tiffConversionFailure() {
        #expect(read([ClipboardImageRead.tiffType: tiffBytes], decode: { _ in nil }) == nil)
    }

    @Test("a type outside the image set is refused")
    func typeOutsideTheSet() {
        // The "only .png and .tiff count" rule lives in the pure function, so a lookup that
        // answers with something else — a JPEG, a PDF, an app's private type — is not an image
        // even if bytes exist for it.
        let out = ClipboardImageRead.imagePNG(
            available: { _ in "public.jpeg" },
            data: { _ in self.pngBytes },
            decodePNG: { $0 }
        )
        #expect(out == nil)
    }

    @Test("the lookup is asked about exactly PNG and TIFF")
    func asksAboutBothTypes() {
        var asked: Set<String>?
        _ = ClipboardImageRead.imagePNG(
            available: { types in asked = types; return nil },
            data: { _ in nil },
            decodePNG: { $0 }
        )
        #expect(asked == [ClipboardImageRead.pngType, ClipboardImageRead.tiffType])
    }

    @Test("bytes are never fetched for a clipboard with no image type")
    func noFetchWithoutAType() {
        // The capture path takes care never to read content it has not been cleared to read;
        // this seam should not become the exception.
        var fetched = false
        _ = ClipboardImageRead.imagePNG(
            available: { _ in nil },
            data: { _ in fetched = true; return nil },
            decodePNG: { $0 }
        )
        #expect(fetched == false)
    }
}
