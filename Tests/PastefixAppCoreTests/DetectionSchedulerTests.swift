import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// Records which texts the injected scan ran for, from detached tasks, and the peak number
/// simultaneously in flight — evidence that the slot is a hard bound, not just an assertion about
/// delivery order.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var inFlight = 0
    private var peak = 0
    var value: [String] { lock.withLock { items } }
    var maxConcurrent: Int { lock.withLock { peak } }
    var active: Int { lock.withLock { inFlight } }
    func add(_ s: String) { lock.withLock { items.append(s) } }
    func enter() { lock.withLock { inFlight += 1; peak = max(peak, inFlight) } }
    func exit() { lock.withLock { inFlight -= 1 } }
}

@MainActor
private func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }

/// Polls `condition` every ~10 ms until it holds or `ceiling` passes, instead of a fixed sleep —
/// so a test resolves as soon as its outcome is decided rather than waiting out a worst case.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, ceiling: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + ceiling
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func slowScan(_ log: Log, sleep: TimeInterval = 0.15) -> @Sendable (String) -> DetectionResult {
    { text in
        log.add(text)
        log.enter()
        defer { log.exit() }
        Thread.sleep(forTimeInterval: sleep)
        return DetectionResult.compute(text)
    }
}

/// `Thread.sleep(forTimeInterval:)` is `@available(*, noasync)`: calling it directly inside an
/// async context is an error in Swift 6 language mode. Indirecting through a synchronous function
/// sidesteps that check without changing what the call does — it still blocks its thread and
/// ignores cancellation, which is exactly what a "stuck" compute needs.
private func blockingSleep(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

/// A compute that never returns in time for "STUCK" (a full second, sync and uncancellable) and
/// behaves normally for anything else.
private func stuckOnceScan(_ log: Log) -> @Sendable (String) -> DetectionResult {
    { text in
        log.add(text)
        log.enter()
        defer { log.exit() }
        if text == "STUCK" { blockingSleep(1.0) }
        return DetectionResult.compute(text)
    }
}

/// Records whether an injected scan observed cancellation and how long that took.
private final class CancelObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _elapsed: Duration = .zero
    func recordCancelled(elapsed: Duration) { lock.withLock { _cancelled = true; _elapsed = elapsed } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var elapsed: Duration { lock.withLock { _elapsed } }
}

@Suite(.serialized) @MainActor struct DetectionSchedulerTests {
    @Test func deliversWithTheOriginatingRequest() async {
        var delivered: [(DetectionScheduler.Request, DetectionResult)] = []
        let s = DetectionScheduler(compute: DetectionResult.compute) { delivered.append(($0, $1)) }
        s.request(.init(text: "https://example.com", revision: 3, generation: 7))
        await waitUntil { delivered.count == 1 }
        #expect(delivered.count == 1)
        #expect(delivered.first?.0.revision == 3)
        #expect(delivered.first?.0.generation == 7)
        #expect(delivered.first?.1.kinds == [.url])
    }

    @Test func aBurstRunsFirstAndLastOnlyAndDeliversOnlyTheLast() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.request(.init(text: "B", revision: 1, generation: 1))
        s.request(.init(text: "C", revision: 2, generation: 1))
        await waitUntil { delivered == ["C"] }
        #expect(delivered == ["C"])
        // No extra settle needed: once C is delivered, `running` and `waiting` are both nil, so
        // nothing else can arrive, and B's absence from the log was decided at displacement time.
        #expect(log.value == ["A", "C"], "B was displaced before it started; A was cancelled but could not be stopped")
        #expect(log.maxConcurrent == 1)
    }

    @Test func aFinishedScanIsDeliveredWhenNothingDisplacedIt() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log, sleep: 0.05)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        await waitUntil { delivered == ["A"] }
        s.request(.init(text: "B", revision: 1, generation: 1))
        await waitUntil { delivered == ["A", "B"] }
        #expect(delivered == ["A", "B"])
    }

    @Test func cancelAllDeliversNothing() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.request(.init(text: "B", revision: 1, generation: 1))
        s.cancelAll()
        await settle()
        #expect(delivered.isEmpty)
        #expect(log.value == ["A"], "the waiting request never starts")
    }

    @Test func requestAfterCancelAllWaitsForTheCancelledScan() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log, sleep: 0.15)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.cancelAll()
        s.request(.init(text: "B", revision: 0, generation: 2))
        await waitUntil { delivered == ["B"] }
        #expect(log.value == ["A", "B"])
        #expect(log.maxConcurrent == 1)
    }

    @Test func cancellationReachesTheRunningScan() async {
        let observation = CancelObservation()
        let compute: @Sendable (String) -> DetectionResult = { text in
            guard text == "A" else { return DetectionResult.compute(text) }
            let start = ContinuousClock.now
            let deadline = start + .seconds(1)
            while !Task.isCancelled && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if Task.isCancelled {
                observation.recordCancelled(elapsed: start.duration(to: ContinuousClock.now))
            }
            return DetectionResult.compute(text)
        }
        var delivered: [String] = []
        let s = DetectionScheduler(compute: compute) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.request(.init(text: "B", revision: 1, generation: 1))
        // Ordering is guaranteed by the scheduler: A's cancellation is recorded before A's
        // `work.value` returns, which is before `start(B)` runs — B's own compute returns
        // immediately, so this settles fast without a long fixed wait.
        await waitUntil { observation.cancelled && delivered == ["B"] }
        #expect(observation.cancelled)
        #expect(observation.elapsed < .seconds(0.5))
        #expect(delivered == ["B"])
    }

    /// A stuck `compute` (never returns, ignores cancellation) must not hold the slot forever: the
    /// `scanDeadline` abandons it and hands the slot to whatever is waiting. `log.maxConcurrent`
    /// may read 2 here — the abandoned body keeps running in the background and genuinely overlaps
    /// B's scan, by design (see the type doc); the slot's guarantee is that B *starts*, not that
    /// nothing else is still executing.
    @Test func stuckScanReleasesTheSlotAtTheDeadline() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: stuckOnceScan(log), deadline: 0.2) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "STUCK", revision: 0, generation: 1))
        let bRequestedAt = ContinuousClock.now
        s.request(.init(text: "B", revision: 1, generation: 1))
        await waitUntil { delivered == ["B"] }
        #expect(delivered == ["B"])
        // B was delivered long before the stuck body's own 1.0 s sleep would have finished.
        #expect(ContinuousClock.now - bRequestedAt < .seconds(0.8))
        #expect(log.value == ["STUCK", "B"])
        // Do not leave the abandoned body running past the test: wait for it like the other timing tests do.
        await waitUntil { log.active == 0 }
        #expect(log.active == 0)
    }
}
