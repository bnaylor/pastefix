import Testing
import Foundation
import CoreGraphics
import PastefixCore
import PastefixAppCore
@testable import Pastefix

@MainActor
@Suite("image region, model (crop)")
struct ImageRegionModelTests {
    private func png() throws -> Data {
        // 60×40, two colours: the same shape as the Core Fixture.
        let ctx = try #require(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }

    @Test func cropThroughTheModel() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(LanedCrop(), scope: .image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: revision))
        #expect(await f.eventually { !f.model.isApplying && f.model.transformNote == "Cropped to 30×40." })
        #expect(f.model.document?.imagePNG.flatMap(ImageRegion.orientedPixelSize).map { [$0.width, $0.height] } == [30, 40])
    }

    @Test func staleRegionIsRefusedWithTheSentence() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(LanedCrop(), scope: .image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: revision + 7))
        #expect(await f.eventually { !f.model.isApplying })
        #expect(f.model.errorMessage == TransformCoordinator.staleImageRegionMessage)
    }

    @Test func boundaryClearsAPendingRegion() throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        f.model.pendingImageRegion = PendingImageRegion(region: ImageRegion(x: 0, y: 0, width: 5, height: 5), revision: 0)
        f.model.beginSession(from: ClipboardSnapshot(plainText: "text", richRTFD: nil))
        #expect(f.model.pendingImageRegion == nil)
    }
}
