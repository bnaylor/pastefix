import Foundation
import PastefixCore

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
    private let deliver: @MainActor (Request, DetectionResult) -> Void
    private var ticket = 0
    private var running: (ticket: Int, task: Task<Void, Never>)?
    private var waiting: Request?

    public init(compute: @escaping @Sendable (String) -> DetectionResult = DetectionResult.compute,
                deliver: @escaping @MainActor (Request, DetectionResult) -> Void) {
        self.compute = compute
        self.deliver = deliver
    }

    public func request(_ req: Request) {
        if running == nil { start(req) } else { waiting = req; running?.task.cancel() }
    }

    public func cancelAll() {
        // Cancel the running scan but keep holding the slot for it: it finishes in the
        // background, undelivered (see the type doc), and `finished` releases the slot then. A
        // request arriving in the meantime goes through `waiting`, same as any displacement.
        waiting = nil
        running?.task.cancel()
    }

    private func start(_ req: Request) {
        ticket += 1
        let mine = ticket
        let compute = self.compute
        let work = Task.detached(priority: .userInitiated) { compute(req.text) }
        let task = Task { [weak self] in
            // Cancelling the detached task is what lets `URLFinder` stop early; the await still
            // returns only when the scan returns, which is why the slot exists.
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            self?.finished(mine, req, result, cancelled: Task.isCancelled)
        }
        running = (mine, task)
    }

    private func finished(_ mine: Int, _ req: Request, _ result: DetectionResult, cancelled: Bool) {
        guard running?.ticket == mine else { return }   // defensive: `start` runs only when `running` is nil, so this cannot fail today
        running = nil
        if let next = waiting { waiting = nil; start(next); return }
        if !cancelled { deliver(req, result) }
    }
}
