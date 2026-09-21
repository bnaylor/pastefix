import AppKit
import ImageIO
import PastefixAppCore

/// Polls the general pasteboard's change count (macOS offers no notification) and hands
/// each new item, once, to `onCapture` after the filter chain approves it.
///
/// Attribution comes from the `FrontmostAppTracker`, not from a `frontmostApplication` sample
/// taken during the read: by the time a poll notices a change, up to half a second after the
/// copy, the user may already have switched apps. The tracker's `CaptureContext` names the app
/// that was frontmost when the change was noticed plus everyone frontmost within the poll
/// window, so an exclusion can be applied at stage 1 — before any content is read — even when
/// the true source is no longer frontmost (Critical Invariant 12). The context is sampled twice,
/// once for each stage, so stage 2 also sees any app that came forward during the read; the
/// second, refreshed sample is what lands on the candidate.
@MainActor
final class PasteboardMonitor {
    private let pasteboard: NSPasteboard
    private let filters: [any CaptureFilter]
    private let maxImageBytes: Int
    private let tracker: FrontmostAppTracker
    private let windowSeconds: TimeInterval
    private let onCapture: (CaptureCandidate) -> Void
    private var timer: Timer?
    private var lastChangeCount: Int

    init(pasteboard: NSPasteboard = .general, filters: [any CaptureFilter], maxImageBytes: Int,
         tracker: FrontmostAppTracker, windowSeconds: TimeInterval = 1.0,
         onCapture: @escaping (CaptureCandidate) -> Void) {
        self.pasteboard = pasteboard; self.filters = filters; self.maxImageBytes = maxImageBytes
        self.tracker = tracker; self.windowSeconds = windowSeconds; self.onCapture = onCapture
        self.lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount   // never back-fill what was already there
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)      // keeps firing while menus are open
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        let types = pasteboard.types ?? []
        // `clearContents()` bumps changeCount immediately but the writer's subsequent
        // `setData`/`setString` calls do not; landing here mid-write would otherwise see an
        // empty pasteboard and permanently skip the item once `lastChangeCount` advances past
        // it. Leave `lastChangeCount` alone so the next tick retries the same change.
        guard !types.isEmpty else { return }
        lastChangeCount = count
        let context = tracker.context(window: windowSeconds)
        // Stage 1: cheap gate on the types sampled before any content is touched and on who was
        // frontmost just now, so neither a concealed item's bytes nor an excluded app's bytes are
        // ever read under the guise of deciding whether they may be captured.
        guard filters.allSatisfy({ $0.shouldRead(types: types, context: context) }) else { return }
        guard var candidate = Self.read(pasteboard, maxImageBytes: maxImageBytes) else { return }
        // The pasteboard can change again while `read` was busy (RTFD conversion, image
        // decode/re-encode can take real time) — if it did, `candidate` may be a mix of this
        // change's marker types and a later change's content, which must never be recorded.
        // Roll back one so the next tick sees the newer count as unseen and reprocesses it
        // cleanly, rather than treating today's mixed read as final.
        guard pasteboard.changeCount == count else {
            lastChangeCount = count - 1
            return
        }
        // Stage 2: gate again on the full candidate and on a freshly sampled context — the read
        // can take real time, and an app that came forward during it is a possible source too —
        // over the union of the types sampled before and after the read. The union is
        // load-bearing, not belt-and-braces: because
        // `setData`/`setString` do not bump `changeCount` (see above), an unchanged count
        // proves only that nobody called `clearContents`/`declareTypes` again — types can
        // still have been ADDED to this same change since the pre-read sample. A writer that
        // does clearContents -> setString(secret) -> setData(ConcealedType) would otherwise
        // pass both stages on the stale sample and record the secret.
        let finalTypes = Array(Set(types).union(pasteboard.types ?? []))
        let refreshed = tracker.context(window: windowSeconds)
        guard filters.allSatisfy({ $0.shouldCapture(candidate, types: finalTypes, context: refreshed) }) else { return }
        // Attribution is the refreshed context's source, not anything `read` saw.
        candidate.sourceBundleID = refreshed.sourceBundleID
        candidate.sourceAppName = refreshed.sourceAppName
        onCapture(candidate)
    }

    /// One read per change. Rich content only when a rich type is actually declared (Plan 2a lesson).
    /// Content only: source attribution is the caller's job, from the tracker's context.
    ///
    /// `maxImageBytes` is an exact gate for the `.png` branch only: the pasteboard already holds
    /// the PNG, so an over-budget one is skipped without any decoding. The `.tiff` branch cannot
    /// know its PNG size until it has produced the PNG, so a TIFF inside the pixel ceiling below
    /// is still decoded and re-encoded on the main actor, and only then can the byte cap — here
    /// or in `HistoryStore.record` — reject the result. Moving that conversion off the main actor
    /// is tracked as #32; the pixel ceiling is the cheap bound in the meantime.
    static func read(_ pb: NSPasteboard, maxImageBytes: Int) -> CaptureCandidate? {
        var c = CaptureCandidate()
        c.plainText = pb.string(forType: .string)
        if pb.availableType(from: [.rtf, .rtfd, .html]) != nil,
           let attributed = pb.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first as? NSAttributedString {
            c.richRTFD = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        }
        if let png = pb.data(forType: .png) {
            // Size before decode: a header-only read gives pixel dimensions without decoding an
            // image the store is about to reject anyway.
            if png.count <= maxImageBytes, let size = pixelSize(of: png) {
                c.imagePNG = png; c.imagePixelWidth = size.width; c.imagePixelHeight = size.height
            }
        } else if let tiff = pb.data(forType: .tiff), let size = pixelSize(of: tiff),
                  // Header-only pixel gate, not a byte-size heuristic: a full-screen Retina grab
                  // is ~81 MB as raw TIFF but only 2-6 MB once PNG-compressed, so gating on TIFF
                  // byte size rejects exactly the images it should keep. 25M px still covers any
                  // real display (a 6K Pro Display XDR grab is ~20M px) while bounding the
                  // main-actor decode + re-encode this branch has to pay; the store's byte cap on
                  // the PNG result still applies below.
                  size.width * size.height <= 25_000_000,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]),
                  png.count <= maxImageBytes {
            c.imagePNG = png; c.imagePixelWidth = size.width; c.imagePixelHeight = size.height
        }
        guard c.plainText != nil || c.imagePNG != nil else { return nil }
        return c
    }

    /// Pixel dimensions from the image header alone (no decode) — used both to size-gate a TIFF
    /// before paying for a full decode + PNG re-encode, and to fill `imagePixelWidth/Height`
    /// without constructing an `NSBitmapImageRep` just to read them.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
