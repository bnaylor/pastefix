import Foundation

/// A process-wide lane for uncancellable heavy work: at most one job running, at most one
/// waiting, and a job superseded before it reaches the front never starts.
///
/// The shape `TIFFConversionSlot` (history capture) established, generalised so it can be tested
/// here and reused — first by image upload preparation (#48), where a repeated ⌘⇧U rebuilds the
/// overlay and a CG decode cannot be cancelled: unguarded, hammering ⌘⇧U on a 24 MP session runs
/// N concurrent ~330 MB decodes.
///
/// Why a single waiting *slot* rather than a queue: a queue bounds the running work but not the
/// memory — every queued job holds its input until dequeued and skipped. A second arrival
/// **replaces** the waiting one, which is resumed with nil (superseded). Peak is one running and
/// one waiting input, whatever the burst. And a lane must be one per *process*, not per view or
/// model instance: a rebuilt owner with its own lane would run its decode alongside the old
/// one's — "a per-instance lane is not a lane" (#46).
///
/// A job that has started is never abandoned; "superseded" only ever means "skipped before it
/// started". `@unchecked Sendable` with real synchronisation: every mutable property is guarded
/// by `lock`.
public final class SingleSlotLane<Input: Sendable, Output: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let work: @Sendable (Input) -> Output
    private let lock = NSLock()
    private var newest = 0
    private var waiting: (input: Input, generation: Int, continuation: CheckedContinuation<Output?, Never>)?
    private var draining = false

    public init(label: String, qos: DispatchQoS = .userInitiated, work: @escaping @Sendable (Input) -> Output) {
        self.queue = DispatchQueue(label: label, qos: qos)
        self.work = work
    }

    /// Mints the generation the next job will carry, superseding anything waiting or not yet
    /// started. Minting alone (without running anything) abandons pending work.
    public func nextGeneration() -> Int {
        lock.lock(); newest &+= 1; let generation = newest; lock.unlock()
        return generation
    }

    /// The job's output, or nil if it was superseded before it started.
    public func run(_ input: Input, generation: Int) async -> Output? {
        await withCheckedContinuation { continuation in
            lock.lock()
            let displaced = waiting
            waiting = (input, generation, continuation)
            let needsDrain = !draining
            draining = true
            lock.unlock()
            displaced?.continuation.resume(returning: nil)
            if needsDrain { queue.async { [self] in drain() } }
        }
    }

    /// For tests: the generation of the job currently waiting, if any.
    var waitingGeneration: Int? { lock.lock(); defer { lock.unlock() }; return waiting?.generation }

    private func drain() {
        while true {
            lock.lock()
            guard let next = waiting else {
                draining = false
                lock.unlock()
                return
            }
            waiting = nil
            let current = newest
            lock.unlock()
            guard next.generation == current else {
                next.continuation.resume(returning: nil)
                continue
            }
            next.continuation.resume(returning: work(next.input))
        }
    }
}
