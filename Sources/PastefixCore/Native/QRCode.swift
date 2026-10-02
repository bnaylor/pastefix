import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// A text transform whose result is an image that replaces the whole buffer (Make QR Code). With a
/// selection it reads just the selected text, and the image still replaces the buffer — an image
/// can't be spliced into text (#21 review: it used to fail).
public protocol ImageFromTextTransformer: Transformer {}

/// Make QR Code (#21): the text as a QR code image, which replaces it in the panel (⌘Z brings the
/// text back). Core Image's generator at error-correction level M, scaled up by a whole number with
/// nearest-neighbour sampling so every module is a crisp black or white square, on a white quiet
/// zone of four modules (the standard's minimum). The panel's Save writes the image.
public struct MakeQRCode: ImageFromTextTransformer {
    public let id = "builtin.qrmake"
    public let name = "Make QR Code"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.data

    public init() {}

    public static let emptyMessage = "There's no text to put in a QR code."
    /// The most a QR code holds at level M, in bytes (version 40, byte mode).
    public static let maxBytes = 2331
    static let targetSide = 600
    static let quietZone = 4

    public func apply(_ input: TransformInput) async throws -> String { input.text }

    public func transform(_ input: TransformInput) async throws -> TransformOutput {
        let text = input.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingToDo(Self.emptyMessage) }
        let bytes = Data(text.utf8)
        guard bytes.count <= Self.maxBytes else {
            let f = NumberFormatter(); f.numberStyle = .decimal
            let n = f.string(from: NSNumber(value: bytes.count)) ?? "\(bytes.count)"
            let max = f.string(from: NSNumber(value: Self.maxBytes)) ?? "\(Self.maxBytes)"
            throw TransformError.invalidInput("This is too long for a QR code: \(n) bytes, and a QR code holds up to \(max).")
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = bytes
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { throw TransformError.invalidInput("\(name) couldn't encode this text.") }
        // The generator's output is one pixel per module, with a one-module margin of its own.
        let modules = Int(code.extent.width) + 2 * (Self.quietZone - 1)
        let scale = max(1, Self.targetSide / modules)
        let side = modules * scale
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let small = context.createCGImage(code, from: code.extent),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TransformError.invalidInput("\(name) couldn't draw the code.")
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        let inset = CGFloat((Self.quietZone - 1) * scale)
        ctx.draw(small, in: CGRect(x: inset, y: inset, width: code.extent.width * CGFloat(scale), height: code.extent.height * CGFloat(scale)))
        guard let image = ctx.makeImage(), let png = PNGEncoder.encode(image) else {
            throw TransformError.invalidInput("\(name) couldn't draw the code.")
        }
        return .image(png, note: "Made a QR code.")
    }
}

/// Read QR Code (#21): every QR code Vision finds in the image, as text — one per line, top to
/// bottom — replacing the image, as Extract Text does. Nothing found is "nothing to do", never an
/// empty buffer.
public struct ReadQRCode: ImageTransformer {
    public let id = "builtin.qrread"
    public let name = "Read QR Code"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    public init() {}

    public static let noneMessage = "No QR code was found in this image."
    public static let binaryMessage = "Found a QR code, but it holds data rather than text."

    public func transformImage(_ png: Data) throws -> TransformOutput {
        guard let source = OrientedSource(png), let image = source.image() else {
            throw TransformError.invalidInput("This image can't be read.")
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var seen = Set<String>()
        let results = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }   // Vision's origin is bottom-left
        let payloads = results.compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
        // A code whose payload isn't text (binary data) has no string: say so, not "no code" (review).
        guard !payloads.isEmpty else { return .nothingToDo(results.isEmpty ? Self.noneMessage : Self.binaryMessage) }
        return .text(payloads.joined(separator: "\n"))
    }
}
