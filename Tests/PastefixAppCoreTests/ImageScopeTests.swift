import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// A plain image transform that records whether it saw a region.
private struct Recorder: ImageTransformer {
    let id = "test.recorder"; let name = "Recorder"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.recorder")
    func transformImage(_ png: Data) throws -> TransformOutput { .nothingToDo("saw no region") }
}

/// Crop on a lane of its own: tests running in parallel on the shared lane displace each other's
/// waiting jobs (a `CancellationError`, "The transform was cancelled."), as `ImageTransformer.lane` says.
private struct Crop: RegionImageTransformer {
    let id = "builtin.crop"; let name = "Crop to Selection"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.crop")
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput {
        try CropToSelection().transformImage(png, region: region)
    }
}

@Suite struct ImageScopeTests {
    private func imageDoc() throws -> PasteDocument {
        let png = ImageTransformCoordinatorTests.png(60, 40)
        return PasteDocument(origin: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
    }

    @Test func anImageScopeReachesARegionTransformer() async throws {
        let doc = try imageDoc()
        let scope = TransformScope.image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: doc.detectionRevision)
        let (d, outcome, _) = await TransformCoordinator.apply(Crop(), to: doc, scope: scope)
        #expect(outcome == .appliedWithNote("Cropped to 30×40."))
        #expect(d.imagePNG.flatMap(ImageRegion.orientedPixelSize).map { [$0.width, $0.height] } == [30, 40])
    }

    @Test func noRegionIsTheHowToNote() async throws {
        let doc = try imageDoc()
        #expect(await TransformCoordinator.apply(Crop(), to: doc, scope: nil).1 == .nothingToDo(CropToSelection.noRegionMessage))
    }

    @Test func plainImageTransformsIgnoreTheRegion() async throws {
        let doc = try imageDoc()
        let scope = TransformScope.image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: doc.detectionRevision)
        #expect(await TransformCoordinator.apply(Recorder(), to: doc, scope: scope).1 == .nothingToDo("saw no region"))
        #expect(!TransformCoordinator.canScope(Recorder(), for: scope) && TransformCoordinator.canScope(Crop(), for: scope))
        #expect(scope.wholeLabel == "whole image")
    }

    /// Review Focus 4.
    @Test func staleImageScopeIsRefused() async throws {
        let doc = try imageDoc()
        let stale = TransformScope.image(ImageRegion(x: 0, y: 0, width: 30, height: 40), revision: doc.detectionRevision + 1)
        let (d, outcome, _) = await TransformCoordinator.apply(Crop(), to: doc, scope: stale)
        #expect(outcome == .failed(TransformCoordinator.staleImageRegionMessage) && d.cursor == doc.cursor)
        let outside = TransformScope.image(ImageRegion(x: 50, y: 0, width: 30, height: 40), revision: doc.detectionRevision)
        #expect(await TransformCoordinator.apply(Crop(), to: doc, scope: outside).1 == .failed(TransformCoordinator.staleImageRegionMessage))
    }
}
