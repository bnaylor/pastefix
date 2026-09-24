import Foundation

/// The one sanctioned way to put a wall-clock bound on work that may not honour cancellation.
///
/// `run` returns to its caller at the deadline *whatever the body does*: a structured task group
/// cannot do that, because it awaits every child before returning (Plan 12 measured a 3 s
/// sleeper unblocking its caller at 10.9 s). The price is honesty about what a timeout means: the
/// body task is cancelled, and a body that checks `Task.isCancelled` stops, but a body inside an
/// uninterruptible Foundation call runs to completion in the background with its result
/// discarded. Input caps, not this helper, are the bound on that work.
public enum Deadline {
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let gate = Gate<T>()
        let work = Task.detached(priority: priority) {
            let outcome: Result<T, any Error>
            do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
            gate.finish(outcome)
        }
        let sleeper = Task.detached(priority: priority) {
            try? await Task.sleep(for: .seconds(seconds), clock: .continuous)
            guard !Task.isCancelled else { return }
            gate.finish(.failure(TransformError.timeout))
            work.cancel()
        }
        defer { sleeper.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                gate.arm(continuation)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
            work.cancel()
        }
    }

    /// Resumes a continuation exactly once, whichever of body / sleeper / cancellation gets
    /// there first, and remembers an outcome that arrives before the continuation is armed
    /// (a caller cancelled before `withCheckedThrowingContinuation` ran). Once the gate is
    /// closed the body's eventual result is discarded by definition, so both the sleeper and
    /// the cancellation handler finish the gate before cancelling the body: cancelling first
    /// opened a window in which a cooperative body could finish and win the race, handing the
    /// caller a `CancellationError` on a plain timeout or a partial result (e.g. `URLCleaner`
    /// over a `URLFinder` that stopped early) reported as applied.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var pending: Result<T, any Error>?
        private var done = false

        func arm(_ c: CheckedContinuation<T, any Error>) {
            let ready: Result<T, any Error>? = lock.withLock {
                if let p = pending { pending = nil; done = true; return p }
                continuation = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }

        func finish(_ r: Result<T, any Error>) {
            let c: CheckedContinuation<T, any Error>? = lock.withLock {
                if done { return nil }
                if let c = continuation { continuation = nil; done = true; return c }
                if pending == nil { pending = r }
                return nil
            }
            c?.resume(with: r)
        }
    }
}
