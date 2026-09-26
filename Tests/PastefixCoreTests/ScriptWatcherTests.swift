import Testing
import Foundation
@testable import PastefixCore

/// Polls until `condition` holds, or the ceiling expires. Sibling of
/// `DetectionSchedulerTests.waitUntil`, which is private to the other test target and takes a
/// `@MainActor` condition; `Counter` here is nonisolated, so this one is too.
///
/// The ceiling is deliberately far larger than any delay under test: it is there so a hung
/// debouncer fails in seconds instead of hanging the suite, not to express a timing expectation.
/// Nothing asserts on how long the wait took.
private func waitUntil(_ condition: () -> Bool, ceiling: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + ceiling
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// These tests used to sleep a fixed interval and then assert, which is why they flaked roughly
/// one run in ten under the default parallel runner (#51): the debouncer's timer fires late
/// relative to a wall-clock sleep when the machine is loaded, so `debouncerFiresAgainAfterQuietPeriod`
/// read `1` where it wanted `2`. Reproduced on `main` at 1-in-10 before this change.
///
/// The distinction the fix turns on: **wait for a thing to happen by polling; wait for a thing
/// *not* to happen by holding a window.** A deadline sleep ("it should have fired by now") is what
/// contention breaks, and polling removes it. But `debouncerFiresOnceAfterBurst` asserts an
/// absence — that a burst coalesced into exactly one call — and an absence cannot be polled for.
/// Polling until the count reaches 1 and asserting it equals 1 would pass the instant the first
/// call landed, and would no longer fail for a debouncer that fired five times. So that test keeps
/// a quiet window, and the window is the assertion rather than an artefact of it.
@Suite struct ScriptWatcherTests {
    /// The debounce delay these tests drive the `Debouncer` with.
    private static let delay: TimeInterval = 0.1

    @Test func debouncerFiresOnceAfterBurst() async throws {
        let counter = Counter()
        let debouncer = Debouncer(delay: Self.delay, queue: .global())
        for _ in 0..<5 { debouncer.schedule { counter.increment() } }

        // Poll for the firing — this half used to be the fixed sleep that flaked.
        await waitUntil { counter.value >= 1 }
        #expect(counter.value >= 1, "the burst never fired within the ceiling")

        // Then hold a window longer than the delay and require the count not to move. This sleep
        // stays on purpose: it is the coalescing assertion, not a guess about scheduling latency.
        // A debouncer that failed to coalesce would have counted 5 well before here.
        let afterFirstFiring = counter.value
        try await Task.sleep(for: .seconds(Self.delay * 3))
        #expect(counter.value == afterFirstFiring, "a second call arrived after the burst settled")
        #expect(counter.value == 1, "the burst of 5 should have coalesced into exactly 1 call")
    }

    @Test func debouncerFiresAgainAfterQuietPeriod() async throws {
        let counter = Counter()
        let debouncer = Debouncer(delay: Self.delay, queue: .global())

        // No fixed sleeps at all: both waits are for something to happen, and the first firing
        // landing *is* the quiet period this test is named for — waiting a wall-clock 250 ms only
        // ever approximated it.
        debouncer.schedule { counter.increment() }
        await waitUntil { counter.value == 1 }
        #expect(counter.value == 1, "the first schedule never fired within the ceiling")

        debouncer.schedule { counter.increment() }
        await waitUntil { counter.value == 2 }
        #expect(counter.value == 2, "a schedule after the debouncer had settled did not fire")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
