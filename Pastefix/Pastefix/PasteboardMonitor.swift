import AppKit
import ImageIO
import os
import PastefixAppCore

/// File-scope, alongside `HistoryStore`'s: the capture path can lose an item for reasons no test
/// covers (the pasteboard moved on, a newer change superseded this one), and a silent loss is
/// the one kind this file must not have.
private let historyLog = Logger(subsystem: "net.scromp.Pastefix", category: "history")

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
/// the user switched to after copying. At most one conversion runs at a time
/// (`TIFFConversionSlot`) and at most one result is ever accepted: a conversion superseded before
/// it starts is skipped, and one that has already started finishes anyway, because ImageIO offers
/// nothing to interrupt.
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
    /// The wrapper around the pending conversion's completion — what `stop()` cancels. It is not
    /// what keeps two conversions from running at once; `conversionSlot` is.
    private var conversionTask: Task<Void, Never>?
    /// Bumped whenever a conversion is started or abandoned. A result that comes back under a
    /// stale generation belongs to a change the monitor has already moved past, and is dropped.
    private var conversionGeneration = 0
    /// The single lane every TIFF decode goes down.
    private let conversionSlot = TIFFConversionSlot()

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
        // result when it lands. Bumping the generation is what actually drops it: cancelling the
        // wrapper cannot interrupt an encode already running inside ImageIO. Telling the slot
        // about the new generation is what keeps a conversion that has not started yet from
        // running at all.
        conversionTask?.cancel(); conversionTask = nil
        conversionGeneration &+= 1
        conversionSlot.supersede(with: conversionGeneration)
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
        // On the TIFF path this pass is provisional: the candidate has no image yet, and
        // `finishPendingTIFF` runs the same filters again on the whole thing. Neither shipped
        // filter inspects the candidate's content, but a future one that does will see this call
        // as well as the later one, and must be written for both.
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
    /// Only `Data` and `Int` cross into the conversion slot: no pasteboard, no tracker, no `self`.
    /// Everything that needs app state to decide — is this still the same change, do the filters
    /// still say yes — is decided back on the main actor, because both answers can change while
    /// the conversion runs.
    private func convertPendingTIFF(_ tiff: Data, candidate: CaptureCandidate,
                                    pixelWidth: Int?, pixelHeight: Int?,
                                    types: [NSPasteboard.PasteboardType],
                                    attribution: CaptureContext, changeCount: Int) {
        conversionGeneration &+= 1
        let generation = conversionGeneration
        // Tell the slot before queueing, so a conversion still waiting for the lane learns it has
        // been superseded and never starts. Cancelling the wrapper is separate and weaker: it
        // cannot reach a decode already inside ImageIO.
        conversionSlot.supersede(with: generation)
        conversionTask?.cancel()
        let slot = conversionSlot
        conversionTask = Task { @MainActor [weak self] in
            let png = await slot.convert(tiff, generation: generation)
            guard let self else { return }
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
        // Don't touch `conversionTask` here — whoever superseded us already owns that slot.
        guard generation == conversionGeneration else {
            historyLog.debug("dropped a converted TIFF: superseded by a newer pasteboard change")
            return
        }
        conversionTask = nil
        // Kin to the post-read re-check in `tick`, but not the same loss: there the candidate is
        // a mix of two changes and is worthless, here the bytes are clean and what we have lost
        // is the ability to re-verify them. `pasteboard.types` now describes a different change,
        // so the late-marker check below cannot be performed at all — and recording anyway would
        // put an older image above the thing the user copied after it in a most-recent-first
        // list. `lastChangeCount` has already advanced past this change and the newer one gets
        // its own tick, so dropping is all there is to do.
        guard pasteboard.changeCount == changeCount else {
            historyLog.debug("dropped a converted TIFF: the pasteboard turned over during the conversion")
            return
        }
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
        // match, never narrow what the pre-conversion pass already judged. The cost of that is
        // accepted and deliberate: switching to an excluded app while the conversion runs drops
        // a capture the pre-conversion pass had approved. Fail-closed is the only safe direction
        // when the window is a second wide.
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

/// The one lane TIFF→PNG conversions run down: at most one decode at a time, and a conversion
/// superseded before it reaches the front of the lane never starts.
///
/// A bare `Task.detached` does not give that. Cancelling the wrapper task cannot reach a decode
/// already inside ImageIO, and awaiting a non-throwing `.value` does not resume early — so at a
/// 0.5 s poll and ~1.3 s per 20 M-pixel conversion, a user pasting several large images in a row
/// could have three decodes running at once, each holding its source TIFF (up to ~81 MB) plus a
/// decoded bitmap (25 M px x 4 B). Serialising costs nothing: the work was never parallelisable
/// in any useful sense, since each conversion serves a change that has already superseded the
/// last one.
///
/// A decode that has started is never abandoned — ImageIO offers no cancellation point — so
/// "superseded" only ever means "skipped before it started".
///
/// `nonisolated` is load-bearing: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`, so without it this class would be main-actor isolated and its queue work would be
/// touching main-actor state from a background thread — the opposite of the point.
///
/// `@unchecked Sendable` with real synchronization, as the house rule requires: `newest` is
/// guarded by `lock`, and the only other stored property is the queue itself.
nonisolated private final class TIFFConversionSlot: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.scromp.Pastefix.history.tiff", qos: .utility)
    private let lock = NSLock()
    private var newest = 0

    /// Called on the main actor as each conversion is queued (and by `stop()`), so anything still
    /// waiting for the lane can tell that nobody wants its result any more.
    func supersede(with generation: Int) {
        lock.lock(); newest = generation; lock.unlock()
    }

    /// nil when the conversion was superseded before it started, or when it failed.
    func convert(_ tiff: Data, generation: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.lock.lock()
                let current = self.newest
                self.lock.unlock()
                guard generation == current else { return continuation.resume(returning: nil) }
                guard let rep = NSBitmapImageRep(data: tiff) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: rep.representation(using: .png, properties: [:]))
            }
        }
    }
}
