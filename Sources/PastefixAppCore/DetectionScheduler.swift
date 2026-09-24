import Foundation
import os
import PastefixCore

private let detectionLog = Logger(subsystem: "net.scromp.Pastefix", category: "detection")

/// Runs `DetectionResult.compute` off the main actor, one scan at a time, and delivers results
/// back on it.
///
/// Single slot, not a queue: a request that arrives while a scan runs replaces whatever was
/// waiting and cancels the running scan. Queueing would let rapid undo/redo stack 1 MB scans —
/// the `TIFFConversionSlot` lesson. A cancelled scan's result is discarded; so is a finished
/// scan's when something newer is waiting, because the document it describes is already gone.
///
/// The slot is hard, process-wide, including across `cancelAll()`: at most one scan ever runs.
/// `cancelAll()` clears `waiting` and cancels the running scan's task, but does not let go of the
/// slot — the cancelled scan keeps it until it actually finishes in the background, cancelled and
/// undelivered. A `request` that arrives while that cancelled scan is still winding down becomes
/// `waiting` (the same path an ordinary displacement takes) and starts only once the slot is free.
/// This matters because almost nothing here observes cancellation: of `SecretDetector` and the
/// `ContentDetector` rules, only `URLFinder` checks `Task.isCancelled` (and it's skipped above
/// 256 KB), so a "cancelled" scan usually just runs to completion anyway. If the slot were
/// released early, a cancelled-but-still-running scan could overlap a fresh one, and repeated
/// summon/dismiss could accumulate overlapping scans without bound. The slot, not cancellation,
/// is what keeps this to one scan at a time.
///
/// The slot is also bounded by `scanDeadline`: a scan that never returns (a stuck `compute`, not
/// merely a slow one) would otherwise hold the slot for the process lifetime and disable
/// detection entirely. `start` runs the actual scan on its own detached task (`work`) and only
/// *waits* for it through `Deadline.run`; at the deadline the wait is abandoned and the slot freed
/// regardless of whether `work` itself ever finishes, and the abandoned scan's eventual result, if
/// it ever arrives, is discarded like any other undelivered one. This is logged once, since it
/// means a `compute` implementation is not merely slow but stuck.
@MainActor
public final class DetectionScheduler {
    public struct Request: Sendable {
        public let text: String
        public let revision: Int
        public let generation: Int
        public init(text: String, revision: Int, generation: Int) {
            self.text = text
            self.revision = revision
            self.generation = generation
        }
    }

    private let compute: @Sendable (String) -> DetectionResult
    /// Measured worst case for a 1 MB buffer is under 2 s; ten seconds abandoned means the scan is
    /// stuck, not merely loaded.
    private let scanDeadline: TimeInterval
    private let deliver: @MainActor (Request, DetectionResult) -> Void
    private var ticket = 0
    private var running: (ticket: Int, work: Task<DetectionResult, Never>)?
    private var waiting: Request?

    public init(compute: @escaping @Sendable (String) -> DetectionResult = DetectionResult.compute,
                deadline: TimeInterval = 10,
                deliver: @escaping @MainActor (Request, DetectionResult) -> Void) {
        self.compute = compute
        self.scanDeadline = deadline
        self.deliver = deliver
    }

    public func request(_ req: Request) {
        if running == nil { start(req) } else { waiting = req; running?.work.cancel() }
    }

    public func cancelAll() {
        // Cancel the running scan but keep holding the slot for it: it finishes in the
        // background, undelivered (see the type doc), and `finished` releases the slot then. A
        // request arriving in the meantime goes through `waiting`, same as any displacement.
        waiting = nil
        running?.work.cancel()
    }

    private func start(_ req: Request) {
        ticket += 1
        let mine = ticket
        let compute = self.compute
        let deadline = scanDeadline
        // `work` is detached and created *before* `Deadline.run` ever runs, so it starts
        // unconditionally: an ordinary displacement (`request`/`cancelAll`, above) cancels `work`
        // directly, not the wrapper task below, which is what lets `URLFinder` observe cancellation
        // promptly while still guaranteeing `compute` actually ran at least once. `Deadline.run`
        // checks the *calling* task's cancellation before it starts (Amendment 3 in the spec) —
        // routing that check through the wrapper instead would let a fast displacement burst skip
        // `compute` entirely, which broke the existing burst/cancelAll tests when tried.
        let work = Task.detached(priority: .userInitiated) { compute(req.text) }
        Task { [weak self] in
            // `Deadline.run` bounds how long we *wait* for `work`, not whether it runs: on success
            // it simply returns `work`'s value; on the `scanDeadline` elapsing it hands the slot
            // back immediately and leaves `work` running in the background, undelivered — that is
            // what stops a stuck `compute` from disabling detection for the process lifetime.
            let result = try? await Deadline.run(seconds: deadline) { await work.value }
            self?.finished(mine, req, result, cancelled: work.isCancelled)
        }
        running = (mine, work)
    }

    private func finished(_ mine: Int, _ req: Request, _ result: DetectionResult?, cancelled: Bool) {
        guard running?.ticket == mine else { return }   // defensive: `start` runs only when `running` is nil, so this cannot fail today
        running = nil
        guard let result else {
            // `work` never throws and the wrapper task above is never itself cancelled, so the only
            // way `Deadline.run` returns nil here is `scanDeadline` actually elapsing — log it once;
            // `work` keeps running in the background with its eventual result discarded.
            detectionLog.error("Detection scan exceeded \(self.scanDeadline, privacy: .public)s for a \(req.text.utf8.count, privacy: .public)-byte buffer; abandoned")
            if let next = waiting { waiting = nil; start(next) }
            return
        }
        if let next = waiting { waiting = nil; start(next); return }
        if !cancelled { deliver(req, result) }
    }
}
