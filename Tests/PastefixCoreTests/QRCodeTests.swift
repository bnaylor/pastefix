import Testing
import Foundation
import CoreGraphics
@testable import PastefixCore

/// #21: Make QR Code (text → image) and Read QR Code (image → text).
@Suite struct QRCodeTests {
    private func make(_ text: String) async throws -> (Data, String?) {
        guard case .image(let png, let note) = try await MakeQRCode().transform(TransformInput(text: text)) else {
            Issue.record("expected an image"); throw CancellationError()
        }
        return (png, note)
    }
    private func read(_ png: Data) async throws -> TransformOutput {
        try await offThePool { try ReadQRCode().transformImage(png) }
    }

    @Test(arguments: ["https://example.com/path?query=1&utm_source=x", "héllo wörld — 日本語 🎉", "line one\nline two\n\twith a tab"])
    func makeThenReadRoundTrips(_ text: String) async throws {
        let (png, _) = try await make(text)
        #expect(try await read(png) == .text(text))
    }

    @Test func theCodeIsCrisp() async throws {
        let (png, note) = try await make("https://example.com")
        #expect(note == "Made a QR code.")
        let p = try RedactBlurTests.pixels(png)
        #expect(p.w >= 500 && p.w == p.h, "\(p.w)×\(p.h)")
        var grey = 0
        for i in stride(from: 0, to: p.px.count, by: 4) where !(p.px[i] == 0 || p.px[i] == 255) { grey += 1 }
        #expect(grey == 0, "only black and white modules: \(grey) grey pixels")
        #expect(RedactBlurTests.at(p, 2, 2) == [255, 255, 255, 255], "a white quiet zone around it")
    }

    @Test func tooLongAndEmpty() async throws {
        await #expect(throws: TransformError.invalidInput("This is too long for a QR code: 2,400 bytes, and a QR code holds up to 2,331.")) {
            _ = try await MakeQRCode().transform(TransformInput(text: String(repeating: "x", count: 2400)))
        }
        #expect(try await MakeQRCode().transform(TransformInput(text: "  \n")) == .nothingToDo(MakeQRCode.emptyMessage))
        let (png, _) = try await make(String(repeating: "y", count: 2331))   // exactly at the limit
        #expect(try await read(png) == .text(String(repeating: "y", count: 2331)))
    }

    @Test func readsAQRCodeInsideAScreenshot() async throws {
        let (qr, _) = try await make("https://pastefix.example/settings")
        let code = try #require(Fixture.decoded(qr))
        let ctx = try #require(CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        ctx.draw(code, in: CGRect(x: 1000, y: 300, width: 300, height: 300))
        let composed = try #require(ctx.makeImage())
        let shot = try #require(PNGEncoder.encode(composed))
        #expect(try await read(shot) == .text("https://pastefix.example/settings"))
    }

    @Test func noneFound() async throws {
        let png = try #require(Fixture.image(as: "public.png"))
        #expect(try await read(png) == .nothingToDo(ReadQRCode.noneMessage))
        #expect(ReadQRCode.noneMessage == "No QR code was found in this image.")
    }

    @Test func registered() {
        let make = MakeQRCode(), read = ReadQRCode()
        #expect(make.id == "builtin.qrmake" && make.name == "Make QR Code" && make.category == TransformCategory.data && make.acceptedForms == [.text])
        #expect(read.id == "builtin.qrread" && read.name == "Read QR Code" && read.category == TransformCategory.images && read.acceptedForms == [.image])
    }
}
