import SwiftUI
import AppKit
import ImageIO
import PastefixAppCore

/// What an image session shows where a text session shows the editor: the clipboard's image
/// scaled to fit, with its pixel dimensions and byte size underneath.
///
/// Those are the same two facts the upload overlay's header states about its payload, for the
/// same reason — a user about to act on a buffer should be able to see what the buffer is. Here
/// it is also the only way to tell two similar screenshots apart.
///
/// **Nothing decodes on a render path.** The decode happens in `.task`, once per image, off the
/// main actor, and only its result is installed here — the shape of the bug #59 shipped, where a
/// Keychain read sat in a SwiftUI `init` and ran on every re-render. `body` runs for every
/// keystroke elsewhere in the panel, every overlay toggle and every window resize; a multi-
/// megabyte PNG decode on that path would be a stutter per frame.
struct ImageSessionView: View {
    /// The session's image, already normalised to PNG by `ClipboardBridge` and already known to
    /// decode — it would not be in the document otherwise.
    let imagePNG: Data
    /// The document's detection revision, used only as the decode task's identity.
    ///
    /// The session's origin is immutable, but Refresh (⌘R) replaces it in place without starting
    /// a new session, and that is the one way the image can change under a view that stays alive.
    /// `refresh` bumps this, so the task re-runs. Over-eager would cost one redundant off-main
    /// decode; under-eager would leave the panel showing the *previous* clipboard's image, which
    /// is the failure worth spending an Int to avoid. A new summon or a loaded history item is
    /// covered at the call site, which keys the whole view on the session generation.
    let revision: Int

    /// nil until the decode lands. `NSImage` is built here on the main actor from a `CGImage`
    /// carried across, matching `HistoryOverlayView`'s thumbnail path: nothing AppKit-mutable is
    /// constructed off the main actor.
    @State private var image: NSImage?
    /// The image's true pixel dimensions, from its header — not the displayed bitmap's, which is
    /// downsampled. Read in the same pass as the decode, so the footer states the real size.
    @State private var pixels: PixelSize?
    /// Set when the header parsed but the decode did not produce anything to draw. The bytes stay
    /// on the document either way: a picture we cannot draw is still an image Save must write back.
    @State private var failed = false
    /// The revision whose decode has already settled, landed or failed.
    ///
    /// It is what keeps a `.task` restart under an unchanged identity — the view leaving and
    /// re-entering the hierarchy (⌘⇧M and back) with its `@State` intact — from paying for the
    /// decode a second time, *without* also swallowing a real image change: a plain
    /// "already have an image, do nothing" guard would leave Refresh showing the previous
    /// clipboard's picture, which is the one wrong answer this view can give.
    @State private var settledRevision: Int?

    /// Ceiling on the bitmap this view builds. The panel's content is a few hundred points wide
    /// and the image is scaled to fit it, so 2048 px covers a Retina-sharp full-panel view on any
    /// display while bounding the bitmap at ~16 MB — the same trade `HistoryOverlayView` makes for
    /// its 44 pt slot, at this view's size.
    private static let displayMaxPixelSize = 2048

    private struct PixelSize: Equatable { let width: Int; let height: Int }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: revision) { await decode() }
            Divider()
            facts
        }
    }

    @ViewBuilder private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(12)
                .accessibilityLabel(accessibilityDescription)
        } else if failed {
            // Visible rather than logged: the user can see there is an image session and would
            // otherwise be looking at an empty panel with no account of why. Save still works.
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                Text("This image can't be shown").font(.callout)
                Text("Save still puts it back on the clipboard.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(12)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading the clipboard image")
        }
    }

    /// Pixel dimensions and byte size. The size is known without touching the image, so it shows
    /// immediately; the dimensions arrive with the decode.
    private var facts: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text(factsDescription)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var factsDescription: String {
        let size = HistoryFormatting.byteLabel(imagePNG.count)
        guard let pixels else { return "Image · \(size)" }
        return "\(pixels.width)×\(pixels.height) · \(size)"
    }

    private var accessibilityDescription: String {
        let size = HistoryFormatting.byteLabel(imagePNG.count)
        guard let pixels else { return "Clipboard image, \(size)" }
        return "Clipboard image, \(pixels.width) by \(pixels.height) pixels, \(size)"
    }

    /// Reads the header and builds a display-sized bitmap, both off the main actor, then installs
    /// the result. Only `Data` and an `Int` cross the boundary.
    private func decode() async {
        guard settledRevision != revision else { return }
        // The image on screen belongs to the revision that is going away, so it goes with it: a
        // spinner for the length of a decode is honest, the previous clipboard's picture is not.
        image = nil
        pixels = nil
        failed = false
        let data = imagePNG
        let maxPixelSize = Self.displayMaxPixelSize
        let decoded = await Task.detached(priority: .userInitiated) { () -> (CGImage, Int, Int)? in
            ImageSessionView.displayImage(data, maxPixelSize: maxPixelSize)
        }.value
        settledRevision = revision
        guard let (cgImage, width, height) = decoded else {
            failed = true
            return
        }
        pixels = PixelSize(width: width, height: height)
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// `nonisolated` so the work above can actually leave the main actor: the target builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this would be main-actor
    /// isolated and the detached task would just hop back — the same trap `TIFFConversionSlot`
    /// spells out. It touches nothing but its arguments and ImageIO.
    ///
    /// Returns the bitmap to draw plus the image's *true* pixel dimensions, read from the header
    /// before any downsampling, so the footer cannot report the size of the thumbnail instead of
    /// the size of the image.
    nonisolated private static func displayImage(_ data: Data, maxPixelSize: Int) -> (CGImage, Int, Int)? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // `…FromImageAlways` with a max above the image's own size returns it at full size rather
        // than upscaling, so a small image is not blown up into a blurry bitmap here — SwiftUI
        // scales it to the panel instead.
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return (image, width, height)
    }
}
