import Testing
import Foundation
@testable import PastefixCore

/// Lock-guarded flag a detached body can set and the test can poll.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

private func waitFor(_ flag: Flag, upTo seconds: Double = 2) async {
    let end = ContinuousClock.now + .seconds(seconds)
    while !flag.value, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
}

/// `Thread.sleep(forTimeInterval:)` is `@available(*, noasync)`: calling it directly inside an
/// async context is an error in Swift 6 language mode. Indirecting through a synchronous
/// function sidesteps that check without changing what the call does — it still blocks its
/// thread and ignores cancellation, which is exactly the "stubborn body" these tests need.
private func blockingSleep(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

@Suite struct DeadlineTests {
    @Test func fastBodyReturnsItsValue() async throws {
        let v = try await Deadline.run(seconds: 5) { 42 }
        #expect(v == 42)
    }

    @Test func bodyErrorPropagates() async {
        await #expect(throws: TransformError.invalidInput("bad")) {
            try await Deadline.run(seconds: 5) { () -> Int in throw TransformError.invalidInput("bad") }
        }
    }

    /// Thread.sleep is not a cancellation point: this body cannot be stopped, only abandoned. The
    /// property under test is "the caller got its answer while the body was still running" — a
    /// flag the body raises as its last statement, checked the instant the call returns — not a
    /// wall-clock margin. A `< 0.6 s` bound flakes under parallel test load for a reason that has
    /// nothing to do with correctness (a busy CI runner, not a broken abandon); the flag is exact
    /// regardless of how fast or slow the machine is.
    @Test func stubbornBodyDoesNotBlockTheCaller() async {
        let finished = Flag()
        await #expect(throws: TransformError.timeout) {
            try await Deadline.run(seconds: 0.2) { () -> Int in
                blockingSleep(0.75)
                finished.raise()
                return 1
            }
        }
        #expect(!finished.value, "the caller returned while the body was still running")
        await waitFor(finished)   // don't leave the abandoned body running past the test's return
    }

    @Test func deadlineCancelsACooperativeBody() async {
        let stopped = Flag()
        await #expect(throws: TransformError.timeout) {
            try await Deadline.run(seconds: 0.1) { () -> Int in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                stopped.raise()
                return 0
            }
        }
        await waitFor(stopped)
        #expect(stopped.value)
    }

    @Test func callerCancellationCancelsTheBody() async {
        let stopped = Flag()
        let outer = Task {
            try await Deadline.run(seconds: 10) { () -> Int in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                stopped.raise()
                return 0
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        outer.cancel()
        await #expect(throws: CancellationError.self) { try await outer.value }
        await waitFor(stopped)
        #expect(stopped.value)
    }

    /// `Deadline.run` checks cancellation before it ever starts the body (Amendment 3): the
    /// property under test is "the body never ran", via a flag it raises as its *first*
    /// statement — not "the call returned quickly", which a `< 0.6 s` wall-clock bound only
    /// approximates and which flakes under load for reasons unrelated to whether the body ran.
    @Test func alreadyCancelledCallerThrowsWithoutRunningLong() async {
        let started = Flag()
        let outer = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Deadline.run(seconds: 10) { () -> Int in
                started.raise()
                blockingSleep(0.75)
                return 1
            }
        }
        await #expect(throws: CancellationError.self) { try await outer.value }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!started.value, "the body never began")
    }
}
