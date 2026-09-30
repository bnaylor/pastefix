import Testing
import Foundation
import ImageIO
@testable import PastefixCore

/// #67: a shell script can declare `accepts = image` and receive the session's image — as a PNG
/// file path in `PASTEFIX_IMAGE` — returning an image or text on stdout.
@Suite struct ShellImageScriptTests {
    /// Recreated per test with the suite, and removed with it (see `TemporaryDirectory`).
    private let tmp = try! TemporaryDirectory("pfx-imgscript")
    private var dir: URL { tmp.url }

    private func script(_ body: String, accepts: String? = "image", name: String = "s.sh") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let header = accepts.map { "# pastefix: accepts = \($0)\n" } ?? ""
        try ("#!/bin/sh\n" + header + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func transformer(_ url: URL, maxPixels: Int = PixelLimits.maxConvertiblePixels) throws -> ShellImageTransformer {
        let md = ScriptMetadata.parse(try String(contentsOf: url, encoding: .utf8))
        return ShellImageTransformer(url: url, metadata: md, timeout: 5, maxPixels: maxPixels)
    }

    private var png: Data { Fixture.image(as: "public.png")! }   // 60×40

    private func size(_ data: Data) -> (Int, Int)? {
        guard let p = Fixture.properties(data),
              let w = p[kCGImagePropertyPixelWidth as String] as? Int,
              let h = p[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (w, h)
    }

    // MARK: metadata

    @Test func acceptsParses() {
        #expect(ScriptMetadata.parse("# pastefix: accepts = image").accepts == .image)
        #expect(ScriptMetadata.parse("# pastefix: accepts = Text").accepts == .text)
        #expect(ScriptMetadata.parse("# pastefix: name = x").accepts == .text, "text is the default")
        #expect(ScriptMetadata.parse("# pastefix: accepts = imag").accepts == .invalid("imag"))
    }

    // MARK: running

    @Test func anImageComesBackAsAnImage() async throws {
        let t = try transformer(try script("sips -z 4 6 \"$PASTEFIX_IMAGE\" --out out.png >/dev/null && cat out.png && rm out.png\n"))
        #expect(t.acceptedForms == [.image])
        let out = try await t.transform(TransformInput(text: "", richRTFD: nil, image: png))
        guard case .image(let result, _) = out else { Issue.record("expected an image, got \(out)"); return }
        #expect(result.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(size(result).map { $0 == (6, 4) } == true)
    }

    @Test func anotherFormatIsReencodedAsPNG() async throws {
        let t = try transformer(try script("sips -s format jpeg \"$PASTEFIX_IMAGE\" --out out.jpg >/dev/null && cat out.jpg && rm out.jpg\n"))
        guard case .image(let result, _) = try await t.transform(TransformInput(text: "", richRTFD: nil, image: png))
        else { Issue.record("expected an image"); return }
        #expect(result.starts(with: [0x89, 0x50, 0x4E, 0x47]), "re-encoded as PNG")
    }

    @Test func textComesBackAsText() async throws {
        let t = try transformer(try script("echo \"$PASTEFIX_IMAGE_WIDTH x $PASTEFIX_IMAGE_HEIGHT\"\n"))
        #expect(try await t.transform(TransformInput(text: "", richRTFD: nil, image: png)) == .text("60 x 40\n"))
    }

    @Test func theFileIsNamedInputPNG() async throws {
        let t = try transformer(try script("basename \"$PASTEFIX_IMAGE\"\n"))
        #expect(try await t.transform(TransformInput(text: "", richRTFD: nil, image: png)) == .text("input.png\n"))
    }

    @Test func noOutputIsAFailure() async throws {
        let t = try transformer(try script("true\n"))
        await #expect(throws: TransformError.scriptFailed("the script produced no output")) {
            try await t.transform(TransformInput(text: "", richRTFD: nil, image: png))
        }
    }

    @Test func outputThatIsNeitherIsAFailure() async throws {
        let t = try transformer(try script("printf '\\377\\376junk'\n"))
        await #expect(throws: TransformError.scriptFailed("the script's output is neither an image nor UTF-8 text")) {
            try await t.transform(TransformInput(text: "", richRTFD: nil, image: png))
        }
    }

    /// Header-only: an image over the ceiling is refused before anything decodes it.
    @Test func anOversizedImageIsRefused() async throws {
        let t = try transformer(try script("cat \"$PASTEFIX_IMAGE\"\n"), maxPixels: 100)
        await #expect(throws: TransformError.scriptFailed("the script's image is 2,400 pixels; the limit is 100")) {
            try await t.transform(TransformInput(text: "", richRTFD: nil, image: png))
        }
    }

    /// The temp folder goes whatever the outcome, a failed run included.
    @Test(arguments: ["ok", "fails"])
    func theTempFolderIsRemoved(_ outcome: String) async throws {
        let record = dir.appendingPathComponent("path-\(outcome)")
        let t = try transformer(try script("echo \"$PASTEFIX_IMAGE\" > '\(record.path)'\necho hi\n\(outcome == "fails" ? "exit 3\n" : "")"))
        _ = try? await t.transform(TransformInput(text: "", richRTFD: nil, image: png))
        let path = try String(contentsOf: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!path.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    // MARK: the runner's output cap

    @Test func outputOverTheCapIsAFailureNotAHang() async throws {
        let url = try script("yes | head -c 100000\n", accepts: nil)
        let start = ContinuousClock.now
        await #expect(throws: TransformError.scriptFailed("the script's output is over 1 KB")) {
            try await ShellRunner.runData(scriptURL: url, stdin: Data(), timeout: 5, maxOutputBytes: 1_024)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    // MARK: registry

    @Test func theRegistryBuildsEachKind() throws {
        _ = try script("cat\n", accepts: "image", name: "img.sh")
        _ = try script("cat\n", accepts: nil, name: "txt.sh")
        try "/* pastefix: accepts = image */\nfunction transform(t) { return t }\n"
            .write(to: dir.appendingPathComponent("jimg.js"), atomically: true, encoding: .utf8)
        let loaded = TransformerRegistry(config: RegistryConfig(scriptsDirectory: dir, timeout: 3)).load()
        func named(_ n: String) -> (any Transformer)? { loaded.first { $0.name == n } }
        #expect(named("img") is ShellImageTransformer)
        #expect(named("txt") is ShellTransformer)
        #expect(named("img")?.acceptedForms == [.image])
        #expect(named("jimg") is UnsupportedScriptTransformer, "not a JSTransformer that would mangle bytes")
    }

    @Test func aJavaScriptImageTransformSaysWhyItCant() async throws {
        try "// pastefix: name = JSImg\n// pastefix: accepts = image\nfunction transform(t) { return t }\n"
            .write(to: dir.appendingPathComponent("j.js"), atomically: true, encoding: .utf8)
        let t = try #require(TransformerRegistry(config: RegistryConfig(scriptsDirectory: dir, timeout: 3)).load()
            .first { $0.name == "JSImg" })
        #expect(t.acceptedForms == [.image])
        await #expect(throws: TransformError.scriptFailed("JavaScript transforms can't take images (JavaScriptCore strings aren't byte-safe); use a shell script.")) {
            try await t.transform(TransformInput(text: "", richRTFD: nil, image: png))
        }
    }

    @Test func anUnknownAcceptsValueSaysSo() async throws {
        _ = try script("cat\n", accepts: "imag", name: "typo.sh")
        let t = try #require(TransformerRegistry(config: RegistryConfig(scriptsDirectory: dir, timeout: 3)).load()
            .first { $0.name == "typo" })
        #expect(t.acceptedForms == [.text, .image], "listed where the user will look for it")
        await #expect(throws: TransformError.scriptFailed("“accepts = imag” isn't text or image.")) {
            try await t.transform(TransformInput(text: "x", richRTFD: nil))
        }
    }
}
