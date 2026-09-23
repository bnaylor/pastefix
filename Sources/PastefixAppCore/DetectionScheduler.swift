import Foundation
import PastefixCore

/// Runs `DetectionResult.compute` off the main actor, one scan at a time, and delivers results
/// back on it.
///
/// Single slot, not a queue: a request that arrives while a scan runs replaces whatever was
/// waiting and cancels the running scan (`URLFinder` observes cancellation; the other rules are
/// fast). Queueing would let rapid undo/redo stack 1 MB scans — the `TIFFConversionSlot` lesson.
/// A cancelled scan's result is discarded; so is a finished scan's when something newer is
/// waiting, because the document it describes is already gone.
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
        waiting = nil
        running?.task.cancel()
        running = nil
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
        guard running?.ticket == mine else { return }   // cancelAll() already let go of this one
        running = nil
        if let next = waiting { waiting = nil; start(next); return }
        if !cancelled { deliver(req, result) }
    }
}
