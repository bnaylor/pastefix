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
/// the true source is no longer frontmost (Critical Invariant 12).
///
/// The context is sampled once per stage. The second sample is NOT a chance to notice an app
/// that came forward during the read: `tick` holds the main thread throughout, so no activation
/// notification can be delivered between the two samples (unless the read itself spins the
/// runloop, which the rich-text importer can). What it buys is that stage 2 judges by the same
/// rule as stage 1 against the tracker's latest state, including the live
/// `NSWorkspace.frontmostApplication` cross-check the tracker folds into `recentBundleIDs`.
/// Attribution on the candidate is the tracker's newest activation, from that second sample.
///
/// The TIFF branch is the one exception to "tick holds the main thread throughout": converting
/// a TIFF to PNG happens off the main actor (#32), so real time — and real activations — can
/// pass before the capture lands. That path therefore re-checks the change count and re-runs the
/// filters afterwards (see `convertPendingTIFF`), and keeps its attribution from the sample taken
/// before the conversion, because by the time the PNG exists the newest activation may be an app
/// the user switched to after copying.
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
    /// At most one TIFF conversion is ever in flight; a new one supersedes it.
    private var conversionTask: Task<Void, Never>?
    /// Bumped whenever a conversion is started or abandoned. A result that comes back under a
    /// stale generation belongs to a change the monitor has already moved past, and is dropped.
    private var conversionGeneration = 0

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

    func stop() {
        timer?.invalidate(); timer = nil
        // Capture is off as of now, so a conversion started while it was on must not record its
        // result when it lands. Bumping the generation is what actually drops it: cancellation
        // cannot interrupt an encode already running inside ImageIO.
        conversionTask?.cancel(); conversionTask = nil
        conversionGeneration &+= 1
    }

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
        guard let result = Self.read(pasteboard, maxImageBytes: maxImageBytes) else { return }
        // The pasteboard can change again while `read` was busy (RTFD conversion can take real
        // time, and can spin the runloop) — if it did, `candidate` may be a mix of this change's
        // marker types and a later change's content, which must never be recorded.
        // Roll back one so the next tick sees the newer count as unseen and reprocesses it
        // cleanly, rather than treating today's mixed read as final.
        guard pasteboard.changeCount == count else {
            lastChangeCount = count - 1
            return
        }
        // Stage 2: gate again on the full candidate and on a re-sampled context — the same rule
        // as stage 1 applied to the tracker's latest state and its live frontmost cross-check
        // (it will usually be identical to `context`; see the type comment) — over the union of
        // the types sampled before and after the read. The union is load-bearing, not
        // belt-and-braces: because
        // `setData`/`setString` do not bump `changeCount` (see above), an unchanged count
        // proves only that nobody called `clearContents`/`declareTypes` again — types can
        // still have been ADDED to this same change since the pre-read sample. A writer that
        // does clearContents -> setString(secret) -> setData(ConcealedType) would otherwise
        // pass both stages on the stale sample and record the secret.
        let finalTypes = Array(Set(types).union(pasteboard.types ?? []))
        let refreshed = tracker.context(window: windowSeconds)
        var candidate = result.candidate
        guard filters.allSatisfy({ $0.shouldCapture(candidate, types: finalTypes, context: refreshed) }) else { return }
        // An image that exists only as TIFF is not a capture yet: it still needs a decode and a
        // PNG re-encode, which is the one image cost too expensive to pay here (#32). Hand it to
        // a detached task and let the completion do the recording, after re-checking everything
        // that can have changed in the meantime.
        if let tiff = result.pendingTIFF {
            convertPendingTIFF(tiff, candidate: candidate, pixelWidth: result.imagePixelWidth,
                               pixelHeight: result.imagePixelHeight, types: finalTypes,
                               attribution: refreshed, changeCount: count)
            return
        }
        // Attribution is the tracker's newest activation, not anything `read` saw.
        candidate.sourceBundleID = refreshed.sourceBundleID
        candidate.sourceAppName = refreshed.sourceAppName
        onCapture(candidate)
    }

    /// Converts a pasteboard TIFF to PNG off the main actor, then records the result on the main
    /// actor if the pasteboard still holds the change it came from and the filters still approve.
    ///
    /// Why off-main: a photographic TIFF inside the 25M-pixel ceiling still costs 0.4 s (6.6 MP)
    /// to 1.3 s (20.4 MP) to decode and re-encode, often for a PNG the image budget then throws
    /// away — and the poll timer runs in `.common` mode, so on the main actor that stall lands
    /// during menu tracking (#32).
    ///
    /// Only `Data` and `Int` cross into the detached task: no pasteboard, no tracker, no `self`.
    /// Everything that needs app state to decide — is this still the same change, do the filters
    /// still say yes — is decided back on the main actor, because both answers can change while
    /// the conversion runs.
    private func convertPendingTIFF(_ tiff: Data, candidate: CaptureCandidate,
                                    pixelWidth: Int?, pixelHeight: Int?,
                                    types: [NSPasteboard.PasteboardType],
                                    attribution: CaptureContext, changeCount: Int) {
        conversionGeneration &+= 1
        let generation = conversionGeneration
        // One in flight at a time: a newer change supersedes an older pending conversion, whose
        // result would fail the change-count re-check below anyway.
        conversionTask?.cancel()
        conversionTask = Task { @MainActor [weak self] in
            let png = await Task.detached(priority: .utility) { () -> Data? in
                guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
                return rep.representation(using: .png, properties: [:])
            }.value
            guard !Task.isCancelled, let self else { return }
            self.finishPendingTIFF(generation: generation, changeCount: changeCount,
                                   candidate: candidate, png: png, pixelWidth: pixelWidth,
                                   pixelHeight: pixelHeight, types: types, attribution: attribution)
        }
    }

    /// The main-actor half of `convertPendingTIFF`: everything here is re-decided against state
    /// as it is now, not as it was when the conversion started.
    private func finishPendingTIFF(generation: Int, changeCount: Int, candidate: CaptureCandidate,
                                   png: Data?, pixelWidth: Int?, pixelHeight: Int?,
                                   types: [NSPasteboard.PasteboardType], attribution: CaptureContext) {
        // Superseded by a newer change (or by `stop()`): the newer one owns the pasteboard now.
        guard generation == conversionGeneration else { return }
        conversionTask = nil
        // The same rule as the post-read re-check in `tick`, for the same reason: if the
        // pasteboard turned over while we were converting, these bytes may belong to one change
        // and the types and markers we approved to another. `lastChangeCount` has already
        // advanced past this change, and the newer one gets its own tick, so dropping is all
        // there is to do — there is nothing left to roll back to.
        guard pasteboard.changeCount == changeCount else { return }
        // A failed conversion, or a PNG over the budget, still leaves the text worth keeping —
        // exactly what `HistoryStore.record` would have kept had the image never existed.
        guard let resolved = PendingImage.resolve(candidate, png: png, pixelWidth: pixelWidth,
                                                  pixelHeight: pixelHeight,
                                                  maxImageBytes: maxImageBytes) else { return }
        // Stage 2 again, now that the candidate is whole. Types are the union approved before
        // the conversion plus whatever is declared now: `setData` does not bump `changeCount`,
        // so a concealed marker can have been added to this same change while we were busy, and
        // the conversion window is far wider than the read's (Critical Invariant 12).
        let finalTypes = Array(Set(types).union(pasteboard.types ?? []))
        // Attribution stays the pre-conversion sample — the source app is determined before the
        // read (Critical Invariant 12), and a second later the newest activation may be an app
        // the user switched to after copying. The exclusion check, by contrast, gets the union
        // of both samples' recent ids: a fresh sample can only widen the set an exclusion can
        // match, never narrow what the pre-conversion pass already judged.
        var context = attribution
        var recent = tracker.context(window: windowSeconds).recentBundleIDs
        for id in attribution.recentBundleIDs where !recent.contains(id) { recent.append(id) }
        context.recentBundleIDs = recent
        guard filters.allSatisfy({ $0.shouldCapture(resolved, types: finalTypes, context: context) }) else { return }
        var out = resolved
        out.sourceBundleID = context.sourceBundleID
        out.sourceAppName = context.sourceAppName
        onCapture(out)
    }

    /// What one pasteboard change offered: the candidate, plus the raw TIFF when the image is
    /// only available in that form and still has to be converted.
    struct PendingRead {
        var candidate: CaptureCandidate
        /// Non-nil only when the pasteboard had no PNG and the TIFF passed the pixel ceiling.
        /// `candidate.imagePNG` is nil in that case: the PNG does not exist yet.
        var pendingTIFF: Data?
        var imagePixelWidth: Int?
        var imagePixelHeight: Int?
    }

    /// One read per change. Rich content only when a rich type is actually declared (Plan 2a lesson).
    /// Content only: source attribution is the caller's job, from the tracker's context.
    ///
    /// Nothing here decodes an image. `maxImageBytes` is an exact gate for the `.png` branch: the
    /// pasteboard already holds the PNG, so an over-budget one is skipped without any decoding.
    /// The `.tiff` branch cannot know its PNG size until the PNG exists, so it hands the raw TIFF
    /// back as `pendingTIFF` — bounded by the header-only pixel ceiling below — for the caller to
    /// convert off the main actor (#32), where the byte cap is applied to the result.
    static func read(_ pb: NSPasteboard, maxImageBytes: Int) -> PendingRead? {
        var c = CaptureCandidate()
        c.plainText = pb.string(forType: .string)
        if pb.availableType(from: [.rtf, .rtfd, .html]) != nil,
           let attributed = pb.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first as? NSAttributedString {
            c.richRTFD = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        }
        var pendingTIFF: Data?
        var pendingWidth: Int?
        var pendingHeight: Int?
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
                  // decode + re-encode this branch has to pay — cheap first line, off the main
                  // actor or not; the store's byte cap on the PNG result still applies.
                  size.width * size.height <= 25_000_000 {
            pendingTIFF = tiff; pendingWidth = size.width; pendingHeight = size.height
        }
        guard c.plainText != nil || c.imagePNG != nil || pendingTIFF != nil else { return nil }
        return PendingRead(candidate: c, pendingTIFF: pendingTIFF,
                           imagePixelWidth: pendingWidth, imagePixelHeight: pendingHeight)
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
