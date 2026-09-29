import Foundation
import CoreGraphics
import Vision

/// Vision's text recognition, as `OCRObservation`s in image pixels (origin top-left). The settings
/// are the owner's measurements on #19: `.accurate` recalled more than twice what `.fast` did on
/// a real capture, and language correction rewrites tokens, which is the wrong thing for text
/// that may be a key.
enum TextRecognizer {
    /// The request, configured once. Its settings are pinned by a test because synthetic renders
    /// cannot tell `.accurate` from `.fast` (measured in Plan 21's mutation step): only the owner's
    /// real capture showed the difference, so a test on friendly text would not notice a regression.
    static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        return request
    }

    static func recognize(_ image: CGImage) throws -> [OCRObservation] {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Vision's boxes are normalised with the origin at the bottom left.
        func pixels(_ b: CGRect) -> CGRect {
            CGRect(x: b.minX * width, y: (1 - b.maxY) * height, width: b.width * width, height: b.height * height)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let text = candidate.string
            // One box per character, for tile ownership (`OCRLayout.owned`). Kept only if Vision
            // answers for every character; otherwise ownership falls back to the whole box.
            let boxes = text.indices.compactMap { i in
                (try? candidate.boundingBox(for: i..<text.index(after: i))).flatMap { $0 }.map { pixels($0.boundingBox) }
            }
            return OCRObservation(text: text, box: pixels(observation.boundingBox),
                                  characterBoxes: boxes.count == text.count ? boxes : [])
        }
    }

    /// Recognises each tile, maps its observations back into the whole image, and keeps only what
    /// each tile owns (`OCRLayout.owned`), so an overlap contributes every character exactly once.
    static func recognizeTiled(_ image: CGImage) throws -> [OCRObservation] {
        var all: [OCRObservation] = []
        for tile in OCRLayout.tiles(width: image.width, height: image.height) {
            guard let cropped = image.cropping(to: tile) else { continue }
            let mapped = try recognize(cropped).map {
                OCRObservation(text: $0.text, box: $0.box.offsetBy(dx: tile.minX, dy: tile.minY),
                               characterBoxes: $0.characterBoxes.map { $0.offsetBy(dx: tile.minX, dy: tile.minY) })
            }
            all += OCRLayout.owned(mapped, tile: tile, imageWidth: image.width, imageHeight: image.height)
        }
        return all
    }
}
