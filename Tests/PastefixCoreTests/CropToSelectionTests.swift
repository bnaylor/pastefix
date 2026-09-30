import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

@Suite struct CropToSelectionTests {
    private let crop = CropToSelection()

    /// The RGB at (x, y), top-left origin, read by drawing the image into an sRGB bitmap.
    private func rgb(_ png: Data, _ x: Int, _ y: Int) throws -> [UInt8] {
        let image = try #require(Fixture.decoded(png))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(px.prefix(3))
    }
    private func isRed(_ c: [UInt8]) -> Bool { c[0] > 150 && c[2] < 100 }
    private func isBlue(_ c: [UInt8]) -> Bool { c[2] > 150 && c[0] < 100 }

    @Test func cropsToTheRegion() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        guard case .image(let out, let note) = try crop.transformImage(png, region: ImageRegion(x: 25, y: 5, width: 10, height: 20))
        else { Issue.record("expected an image"); return }
        let props = try #require(Fixture.properties(out))
        #expect(props[kCGImagePropertyPixelWidth as String] as? Int == 10 && props[kCGImagePropertyPixelHeight as String] as? Int == 20)
        #expect(note == "Cropped to 10×20.")
        let left = try rgb(out, 0, 10), right = try rgb(out, 9, 10)
        #expect(isRed(left) && isBlue(right), "red on the left, blue on the right")
        #expect(props[kCGImagePropertyGPSDictionary as String] == nil, "metadata is dropped")
    }

    @Test func noRegionSaysHow() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        #expect(try crop.transformImage(png, region: nil) == .nothingToDo(CropToSelection.noRegionMessage))
        #expect(try crop.transformImage(png) == .nothingToDo(CropToSelection.noRegionMessage))
    }

    @Test func wholeImageIsNothingToDo() throws {
        let png = try #require(Fixture.image(as: "public.png"))
        #expect(try crop.transformImage(png, region: ImageRegion(x: 0, y: 0, width: 60, height: 40))
                == .nothingToDo(CropToSelection.wholeImageMessage))
    }

    /// Review Focus 1: orientation 6 displays 40×60, with the left (red) half on TOP.
    @Test func orientation6CropsWhatWasDrawn() throws {
        let png = try #require(Fixture.image(as: "public.png", orientation: 6))
        guard case .image(let top, _) = try crop.transformImage(png, region: ImageRegion(x: 0, y: 0, width: 40, height: 30))
        else { Issue.record("expected an image"); return }
        let topColour = try rgb(top, 20, 15)
        #expect(isRed(topColour))
        guard case .image(let bottom, _) = try crop.transformImage(png, region: ImageRegion(x: 0, y: 30, width: 40, height: 30))
        else { Issue.record("expected an image"); return }
        let bottomColour = try rgb(bottom, 20, 15)
        #expect(isBlue(bottomColour))
    }

    @Test func keepsTheColourProfile() throws {
        let png = try #require(Fixture.image(as: "public.png"))   // Display P3
        guard case .image(let out, _) = try crop.transformImage(png, region: ImageRegion(x: 0, y: 0, width: 10, height: 10))
        else { Issue.record("expected an image"); return }
        #expect(Fixture.decoded(out)?.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test func registeredInImages() {
        let t = CropToSelection()
        #expect(t.id == "builtin.crop" && t.name == "Crop to Selection" && t.category == TransformCategory.images)
        #expect(t.acceptedForms == [.image])
    }
}
