import Testing
import Foundation
import AppKit
import Vision
@testable import PastefixCore

/// A synthetic-render recall suite (#19, requirement 5): text rendered in-process, no committed
/// fixtures, recognised by the real Vision request.
@Suite("Extract Text (OCR) (#19)")
struct ExtractTextTests {
    static func render(_ lines: [String], width: Int = 900, height: Int = 240, fontSize: CGFloat = 28) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 20, y: CGFloat(height) - 60 - CGFloat(i) * fontSize * 1.8),
                                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                                     .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @Test("recognises rendered lines, top to bottom")
    func recall() async throws {
        let png = try #require(Self.render(["export API_TOKEN=abc123", "second line here"]))
        guard case .text(let text) = try await offThePool({ try ExtractText().transformImage(png) }) else {
            Issue.record("expected text"); return
        }
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.contains("API_TOKEN") == true)
        #expect(lines.last?.contains("second") == true)
    }

    // Synthetic text can't tell .accurate from .fast (a .fast mutation passed `recall`); the
    // owner's real capture found .fast recalls under half as much. So the settings are pinned here.
    @Test("the request is .accurate, without language correction, detecting language")
    func requestSettings() {
        let request = TextRecognizer.makeRequest()
        #expect(request.recognitionLevel == .accurate)
        #expect(!request.usesLanguageCorrection)
        #expect(request.automaticallyDetectsLanguage)
    }

    /// A wide render with text laid across the first tile boundary (x 1984–2048), as the #105 review
    /// measured it: 5120 wide so the dual pass runs, Menlo 28.
    static func straddling(_ lines: [(String, CGFloat)]) -> CGImage? {
        let width = 5120, height = 1400
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, (line, x)) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: x, y: CGFloat(height) - 200 - CGFloat(i) * 90),
                                    withAttributes: [.font: NSFont(name: "Menlo", size: 28)!, .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // #105 review: tiled output split a token that crossed a tile boundary, duplicated the overlap's
    // characters, and put a space inside the token. The token avoids glyphs Vision confuses wherever
    // they sit — 0/O, 1/l, and letters whose cases look alike (c k o s u v w x y z; measured: "k" read
    // as "K" mid-token) — so a failure here is the seam's, not an ordinary misread.
    @Test("a token across a tile boundary comes out whole from the tiled pass")
    func straddlingToken() async throws {
        let token = "ghp_aB3dE5fG7hJ9mNqR2tA4bD6eF8gHn"
        let image = try #require(Self.straddling([("export GITHUB_TOKEN=\(token) # trailing", 1500)]))
        let lines = OCRLayout.lines(try await offThePool({ try TextRecognizer.recognizeTiled(image) }))
        let line = try #require(lines.first { $0.contains("ghp_") })
        #expect(line.contains(token), "tiled line was: \(line)")
    }

    @Test("an image with no text is nothing to do")
    func noText() async throws {
        let png = try #require(Self.render([]))
        #expect(try await offThePool({ try ExtractText().transformImage(png) }) == .nothingToDo(ExtractText.noTextMessage))
    }

    @Test("bytes that aren't an image are refused")
    func notAnImage() {
        #expect(throws: TransformError.self) { try ExtractText().transformImage(Data("nope".utf8)) }
    }

    @Test("it is registered, in Images, for images only")
    func registered() {
        let t = TransformerRegistry(config: RegistryConfig(scriptsDirectory: URL(fileURLWithPath: "/nonexistent")))
            .load().first { $0.id == "builtin.extracttext" }
        #expect(t?.name == "Extract Text (OCR)" && t?.category == TransformCategory.images)
        #expect(t?.acceptedForms == [.image])
    }
}
