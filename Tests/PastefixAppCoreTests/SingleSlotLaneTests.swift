import Testing
import Foundation
@testable import PastefixAppCore

@Suite("SingleSlotLane", .serialized)
struct SingleSlotLaneTests {
    /// Records concurrency and order; the first job blocks until released, so the test decides
    /// exactly what is running and what is waiting rather than inferring it from timing.
    final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var running = 0, maxRunning = 0, ran: [Int] = []
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func work(_ n: Int) -> Int {
            lock.lock(); running += 1; maxRunning = max(maxRunning, running); ran.append(n); lock.unlock()
            if n == 1 { started.signal(); release.wait() }
            lock.lock(); running -= 1; lock.unlock()
            return n * 10
        }
        // Synchronous wrappers: blocking primitives are unavailable directly in async code.
        func awaitStart() -> Bool { started.wait(timeout: .now() + 5) == .success }
        func releaseFirst() { release.signal() }
        func snapshot() -> (ran: [Int], maxRunning: Int) { lock.lock(); defer { lock.unlock() }; return (ran, maxRunning) }
    }

    /// Polls a condition with a generous ceiling — fixed sleeps flake under the parallel runner.
    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }

    @Test("a job runs and returns its output")
    func runs() async {
        let lane = SingleSlotLane<Int, Int>(label: "t.runs") { $0 * 2 }
        #expect(await lane.run(21, generation: lane.nextGeneration()) == 42)
    }

    @Test("a burst runs one job at a time, holds one waiter, and the displaced waiter never runs")
    func burstIsBounded() async throws {
        let probe = Probe()
        let lane = SingleSlotLane<Int, Int>(label: "t.burst") { probe.work($0) }
        // Generations are minted per arrival, as callers do; only the newest may run.
        let g1 = lane.nextGeneration()
        let a = Task { await lane.run(1, generation: g1) }
        #expect(probe.awaitStart())    // job 1 is running
        // Job 1 already started, so the newer generations do not stop it.
        let g2 = lane.nextGeneration()
        let b = Task { await lane.run(2, generation: g2) }
        #expect(await eventually { lane.waitingGeneration == g2 })     // job 2 waits
        let g3 = lane.nextGeneration()
        let c = Task { await lane.run(3, generation: g3) }
        #expect(await eventually { lane.waitingGeneration == g3 })     // job 3 displaced job 2
        probe.releaseFirst()

        #expect(await a.value == 10)      // started before being superseded: finishes
        #expect(await b.value == nil)     // displaced while waiting: never ran
        #expect(await c.value == 30)
        let seen = probe.snapshot()
        #expect(seen.ran == [1, 3])
        #expect(seen.maxRunning == 1)
    }

    @Test("a waiting job superseded by a newer generation is skipped even with no replacement")
    func supersededWithoutReplacement() async {
        let probe = Probe()
        let lane = SingleSlotLane<Int, Int>(label: "t.superseded") { probe.work($0) }
        let a = Task { await lane.run(1, generation: lane.nextGeneration()) }
        #expect(probe.awaitStart())
        let g2 = lane.nextGeneration()
        let b = Task { await lane.run(2, generation: g2) }
        #expect(await eventually { lane.waitingGeneration == g2 })
        _ = lane.nextGeneration()          // abandon, as a session ending does
        probe.releaseFirst()
        #expect(await a.value == 10)
        #expect(await b.value == nil)
        #expect(probe.snapshot().ran == [1])
    }
}
