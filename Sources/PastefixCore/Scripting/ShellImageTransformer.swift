import Foundation
import ImageIO

/// A shell script that declared `# pastefix: accepts = image` (#67).
///
/// **Input:** the session's image as a PNG file, `input.png` in a private folder, named by
/// `PASTEFIX_IMAGE`, with `PASTEFIX_IMAGE_WIDTH`/`_HEIGHT` beside it; stdin is empty. A path, not
/// the bytes on stdin: `exiftool`, `magick`, `sips`, `tesseract` all take paths, and it spares a
/// multi-MB pipe write the script may never read. argv is untouched, as for every script.
///
/// **Output:** stdout. Bytes that start like an image (a magic-byte allowlist, not ImageIO's
/// guess, which also takes signature-less formats) are the new image, re-encoded as PNG — so
/// metadata a script *adds* is dropped. Anything else must be UTF-8 text, which replaces the image
/// as Extract Text's does. Neither, or nothing at all, is a failure.
public struct ShellImageTransformer: Transformer {
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource
    public let applicableKinds: Set<ContentKind>?
    public let category: String?
    public var acceptedForms: Set<ContentForm> { [.image] }
    private let url: URL
    private let runnerTimeout: TimeInterval
    private let maxPixels: Int
    /// A text script's 3 s default is wrong for `magick` on a 20 MP image. Cancel (⌘Z, Esc) still
    /// stops the script's whole process group at once.
    public var timeout: TimeInterval { runnerTimeout + 1 }

    public init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval,
                maxPixels: Int = PixelLimits.maxConvertiblePixels) {
        self.url = url
        self.runnerTimeout = max(timeout, 30)
        self.maxPixels = maxPixels
        self.id = "shell:" + url.lastPathComponent
        self.name = metadata.name ?? url.deletingPathExtension().lastPathComponent
        self.source = .shell(url)
        self.applicableKinds = metadata.kinds
        self.category = metadata.category
    }

    public func apply(_ input: TransformInput) async throws -> String {
        throw TransformError.invalidInput("\(name) needs an image.")
    }

    public func transform(_ input: TransformInput) async throws -> TransformOutput {
        guard let png = input.image else { throw TransformError.invalidInput("\(name) needs an image.") }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("net.scromp.Pastefix.script-image", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Every exit: success, a failed or timed-out script, a launch failure, cancellation.
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input.png")
        try png.write(to: file)
        var environment = ["PASTEFIX_IMAGE": file.path]
        if let (width, height) = Self.pixelSize(png) {
            environment["PASTEFIX_IMAGE_WIDTH"] = String(width)
            environment["PASTEFIX_IMAGE_HEIGHT"] = String(height)
        }
        let out = try await ShellRunner.runData(scriptURL: url, stdin: nil, environment: environment,
                                                timeout: runnerTimeout, maxOutputBytes: ShellRunner.maxImageOutputBytes)
        guard !out.isEmpty else { throw TransformError.scriptFailed("the script produced no output") }
        if Self.startsLikeAnImage(out) { return .image(try reencoded(out), note: nil) }
        guard let text = String(data: out, encoding: .utf8) else {
            throw TransformError.scriptFailed("the script's output is neither an image nor UTF-8 text")
        }
        return .text(text)
    }

    /// Checks the size from the header before anything decodes it, then decodes and re-encodes.
    private func reencoded(_ data: Data) throws -> Data {
        guard let (width, height) = Self.pixelSize(data) else {
            throw TransformError.scriptFailed("the script's image couldn't be read")
        }
        let pixels = PixelLimits.pixelCount(width: width, height: height) ?? Int.max
        guard pixels <= maxPixels else {
            let f = NumberFormatter(); f.numberStyle = .decimal
            let say = { (n: Int) in f.string(from: NSNumber(value: n)) ?? String(n) }
            throw TransformError.scriptFailed("the script's image is \(say(pixels)) pixels; the limit is \(say(maxPixels))")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = PNGEncoder.encode(image) else {
            throw TransformError.scriptFailed("the script's image couldn't be read")
        }
        return png
    }

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// PNG, JPEG, GIF, TIFF (both byte orders), WebP, and the ISO-BMFF family (HEIC, AVIF).
    /// BMP's "BM" is left out on purpose: text starts with it ("BMW …").
    static func startsLikeAnImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(12))
        func starts(_ sig: [UInt8]) -> Bool { b.starts(with: sig) }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if starts([0xFF, 0xD8, 0xFF]) { return true }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return true }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return true }
        if b.count >= 12, starts(Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return true }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            return ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif"].contains(brand)
        }
        return false
    }
}

/// A script that can't run as written, listed so the user sees it and learns why when they apply
/// it — never silently dropped or silently run the wrong way (#67): a JavaScript transform that
/// declared `accepts = image` (JavaScriptCore strings aren't byte-safe), or an `accepts` value
/// that is neither `text` nor `image`.
public struct UnsupportedScriptTransformer: Transformer {
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource
    public let applicableKinds: Set<ContentKind>?
    public let category: String?
    public let acceptedForms: Set<ContentForm>
    private let reason: String

    public init(id: String, name: String, source: TransformerSource, metadata: ScriptMetadata,
                acceptedForms: Set<ContentForm>, reason: String) {
        self.id = id; self.name = name; self.source = source
        self.applicableKinds = metadata.kinds; self.category = metadata.category
        self.acceptedForms = acceptedForms; self.reason = reason
    }

    public func apply(_ input: TransformInput) async throws -> String { throw TransformError.scriptFailed(reason) }
    public func transform(_ input: TransformInput) async throws -> TransformOutput { throw TransformError.scriptFailed(reason) }
}
