import Testing
import AppKit
import SwiftUI
import ImageIO
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// The region on the image (crop spec), through the real panel. SwiftUI builds no accessibility
/// tree in-process, so these read the region the panel holds from `model.imageRegionOnScreen`.
@MainActor
@Suite("image region, view (crop)")
struct ImageRegionViewTests {
    private func png() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        let image = try #require(ctx.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
    /// `png()` carrying GPS, so Strip Image Metadata really pushes a step (a clean PNG is nothing to do).
    private func pngWithGPS() throws -> Data {
        let image = try #require(NSBitmapImageRep(data: try png())?.cgImage)
        let out = NSMutableData()
        let dst = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dst, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5,
                                                                                kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dst))
        return out as Data
    }
    private func host(_ f: ModelFixture) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        w.makeKeyAndOrderFront(nil)
        return w
    }
    private func sendUndo(_ window: NSWindow) -> Bool {
        (window.firstResponder ?? window).tryToPerform(Selector(("undo:")), with: nil)
    }
    private func pressEsc(_ window: NSWindow) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        _ = window.performKeyEquivalent(with: e)
    }

    /// Review Focus 3, the crop case.
    @Test func undoAfterAnyImageTransformRestoresTheRegion() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(LanedCrop(), scope: .image(ImageRegion(x: 100, y: 50, width: 200, height: 100), revision: revision))
        #expect(await f.eventually { f.model.transformNote == "Cropped to 200×100." })
        #expect(f.model.imageRegionOnScreen == nil, "the selection is clear after a crop")
        #expect(sendUndo(window))
        #expect(await f.eventually { f.model.imageRegionOnScreen == ImageRegion(x: 100, y: 50, width: 200, height: 100) })
        #expect(f.model.document?.imagePNG.flatMap(ImageRegion.orientedPixelSize).map { [$0.width, $0.height] } == [600, 400])
    }

    /// Review Focus 3, the non-crop case: a whole-image transform applied with a region up.
    @Test func undoAfterStripMetadataRestoresTheRegion() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try pngWithGPS()))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(LanedStripMetadata(), scope: .image(ImageRegion(x: 10, y: 20, width: 30, height: 40), revision: revision))
        #expect(await f.eventually { !f.model.isApplying && f.model.transformNote != nil })
        #expect(f.model.document?.detectionRevision != revision, "Strip pushed a new image entry")
        #expect(sendUndo(window))
        #expect(await f.eventually { f.model.imageRegionOnScreen == ImageRegion(x: 10, y: 20, width: 30, height: 40) })
    }

    /// Review Focus 5.
    @Test func escClearsTheRegionFirst() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: try png()))
        let window = host(f); defer { window.orderOut(nil) }
        #expect(await f.eventually { f.model.undoManager != nil })
        // Put a region up the way ⌘Z does: a crop, then undo.
        let revision = try #require(f.model.document?.detectionRevision)
        f.model.apply(LanedCrop(), scope: .image(ImageRegion(x: 10, y: 10, width: 50, height: 50), revision: revision))
        #expect(await f.eventually { f.model.transformNote != nil })
        _ = sendUndo(window)
        #expect(await f.eventually { f.model.imageRegionOnScreen != nil })
        pressEsc(window)
        #expect(await f.eventually { f.model.imageRegionOnScreen == nil })
        #expect(f.model.document != nil, "the first Esc cleared the region; the panel is still up")
        pressEsc(window)
        #expect(await f.eventually { f.model.document == nil }, "the second Esc cancels")
    }

    /// Review Focus 1: the footer and the region's pixel size are the oriented ones.
    @Test func displaySizeIsOriented() throws {
        let rotated = try #require(Self.orientation6PNG())
        let decoded = try #require(ImageSessionView.displayImage(rotated, maxPixelSize: 2048))
        let (image, width, height): (CGImage, Int, Int) = decoded
        #expect(width == 40 && height == 60)
        #expect(image.width == 40 && image.height == 60, "drawn rotated, the same way round as the size")
    }

    @Test func footerReadout() throws {
        let s = try #require(ImageSessionView.selectionSuffix(ImageRegion(x: 3, y: 4, width: 50, height: 60)))
        let text: String = s.text, spoken: String = s.spoken
        #expect(text == " · Selection 50×60 at (3, 4)")
        #expect(spoken == ", selection 50 by 60 at 3, 4")
        #expect(ImageSessionView.selectionSuffix(nil) == nil)
    }

    /// A 60×40 PNG tagged orientation 6: displayed 40×60.
    static func orientation6PNG() -> Data? {
        guard let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
