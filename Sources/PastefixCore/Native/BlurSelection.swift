import Foundation
import CoreGraphics
import CoreImage
import Vision

/// Blurs the selected region: cosmetic, not redaction (redact/blur spec). Blurred screenshot text
/// can often be reconstructed, which the result note says. Only the region goes through Core
/// Image: cropped out, edges clamped so nothing outside is sampled and the edges don't fade to
/// transparent, blurred, rendered in the image's colour space and depth, then drawn over the original
/// in a 1:1 bitmap, so opaque pixels outside the region are unchanged (see `OrientedSource.bitmap`).
public struct BlurSelection: RegionImageTransformer {
    public let id = "builtin.blurselection"
    public let name = "Blur Selection"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.images

    /// How long the secret check may read before it's abandoned (see `secretKinds`). Tests pass a
    /// long one: in the full parallel suite Vision queues behind other OCR tests and a 3 s read
    /// overran, so the warning tests failed on load, not on the warning (#132's lesson).
    public let secretCheckBudget: Duration

    public init(secretCheckBudget: Duration = .seconds(3)) { self.secretCheckBudget = secretCheckBudget }

    public static let noRegionMessage = "Drag on the image to choose what to blur, then choose Blur Selection."
    public static func resultNote(_ w: Int, _ h: Int) -> String {
        "Blurred \(w)×\(h). Blur can be reversed; use Redact Selection to hide something for good."
    }
    /// The note when the selection looked like it held a secret (#129): blur can be reversed, so it
    /// points at Redact Selection. "Holds", not "hides": the blur hid nothing for sure (review).
    static func secretNote(_ w: Int, _ h: Int, _ kinds: [SecretKind]) -> String {
        "Blurred \(w)×\(h). This selection looks like it holds \(secretPhrase(kinds)). Blur can be reversed: ⌘Z, then use Redact Selection to hide \(kinds.count > 1 ? "them" : "it") for good."
    }

    /// "an AWS access key", "a GitHub token and an AWS access key", "a, b and c" — in words for a
    /// note, with the article spelled out per kind rather than guessed from a letter.
    static func secretPhrase(_ kinds: [SecretKind]) -> String {
        let named = kinds.map { kind -> String in
            switch kind {
            case .awsAccessKey: "an AWS access key"
            case .awsSecretKey: "an AWS secret key"
            case .githubToken: "a GitHub token"
            case .anthropicKey: "an Anthropic key"
            case .openAIKey: "an OpenAI key"
            case .slackToken: "a Slack token"
            case .stripeKey: "a Stripe key"
            case .googleAPIKey: "a Google API key"
            case .privateKey: "a private key"
            case .jwt: "a JWT"
            case .passwordInURL: "a password in a URL"
            case .genericAssignment: "a password or token"
            }
        }
        guard named.count > 1 else { return named.first ?? "" }
        return named.dropLast().joined(separator: ", ") + " and " + named.last!
    }

    /// The largest region whose text is read for the secret warning.
    static let secretCheckMaxPixels = 4_000_000

    /// The kinds of secret in the region's text, read by OCR with Extract Text's request settings, in
    /// the order found and without repeats. A hint, so it must never cost the blur, which shares the
    /// transform's 10 s limit: regions over 4 MP aren't read (a dense 5K region took 11.4 s), the read
    /// is ONE pass (Extract Text's dual and tiled passes are for completeness, not a hint), and it has
    /// its own `budget` — past it the request is cancelled and there's no warning (review: a dense
    /// 4 MP region measured 2.6–5 s, once 17.8 s cold). A failed, empty or abandoned read is no kinds,
    /// and the ordinary note never claims the region is safe.
    static func secretKinds(in image: CGImage, region: ImageRegion, budget: Duration = .seconds(3)) -> [SecretKind] {
        guard region.width * region.height <= secretCheckMaxPixels,
              let crop = image.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)) else { return [] }
        let request = TextRecognizer.makeRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
            done.signal()
        }
        let seconds = Double(budget.components.seconds) + Double(budget.components.attoseconds) / 1e18
        guard done.wait(timeout: .now() + seconds) == .success else {
            request.cancel()
            return []
        }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard SecretDetector.isScannable(text) else { return [] }
        var kinds: [SecretKind] = []
        for match in SecretDetector.scan(text) where !kinds.contains(match.kind) { kinds.append(match.kind) }
        return kinds
    }

    /// 5% of the region's shorter side, at least 6 px: text is unreadable at a glance.
    public static func radius(for region: ImageRegion) -> Double {
        max(6, 0.05 * Double(min(region.width, region.height)))
    }

    public func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        guard let region, !region.isEmpty else { return .nothingToDo(Self.noRegionMessage) }
        guard let source = OrientedSource(png) else { throw TransformError.invalidInput("This image can't be read.") }
        guard region.fits((source.width, source.height)) else { throw TransformError.invalidInput("The selection is outside the image.") }
        guard let image = source.image(), let ctx = OrientedSource.bitmap(for: image), let space = ctx.colorSpace else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        let rect = OrientedSource.bitmapRect(region, height: source.height)   // Core Image is bottom-left too
        let patch = CIImage(cgImage: image)
            .cropped(to: rect)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Self.radius(for: region))
            .cropped(to: rect)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let format: CIFormat = ctx.bitsPerComponent > 8 ? .RGBA16 : .RGBA8   // the bitmap's own depth
        guard let blurred = context.createCGImage(patch, from: rect, format: format, colorSpace: space) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        ctx.setBlendMode(.copy)
        ctx.draw(blurred, in: rect)
        guard let result = ctx.makeImage(), let out = PNGEncoder.encode(result) else {
            throw TransformError.invalidInput("\(name) couldn't blur this image.")
        }
        let kinds = Self.secretKinds(in: image, region: region, budget: secretCheckBudget)
        return .image(out, note: kinds.isEmpty ? Self.resultNote(region.width, region.height)
                                               : Self.secretNote(region.width, region.height, kinds))
    }
}
