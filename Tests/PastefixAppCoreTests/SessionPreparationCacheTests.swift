import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// #48: a repeat ⌘⇧U rebuilds the overlay; the rebuilt overlay must get the same preparation, not
/// start another uncancellable decode.
@Suite("SessionPreparationCache", .serialized)
@MainActor
struct SessionPreparationCacheTests {
    /// Counts runs; the job for `blocking` holds the lane until released, so a test can put a
    /// second job in the waiting slot deterministically.
    final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var runs: [Data] = []
        let blocking: Data?
        var started = false
        let release = DispatchSemaphore(value: 0)
        init(blocking: Data? = nil) { self.blocking = blocking }
        func work(_ input: Data) -> Int {
            lock.lock(); runs.append(input); lock.unlock()
            if input == blocking {
                lock.lock(); started = true; lock.unlock()
                release.wait()
            }
            return input.count
        }
        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
        func releaseFirst() { release.signal() }
        var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return runs }
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }

    let a = Data([1])
    let b = Data([2, 2])

    @Test("the same bytes in the same session reuse one task, and the work runs once")
    func reusesWithinSession() async {
        let probe = Probe()
        let cache = SessionPreparationCache(lane: SingleSlotLane<Data, Int>(label: "t.reuse") { probe.work($0) })
        let first = cache.preparation(for: a, generation: 1)
        let second = cache.preparation(for: a, generation: 1)
        #expect(await first.value == 1)
        #expect(await second.value == 1)
        #expect(probe.snapshot == [a])
    }

    @Test("a new session starts a new preparation")
    func newGenerationStartsNew() async {
        let probe = Probe()
        let cache = SessionPreparationCache(lane: SingleSlotLane<Data, Int>(label: "t.gen") { probe.work($0) })
        _ = await cache.preparation(for: a, generation: 1).value
        _ = await cache.preparation(for: a, generation: 2).value
        #expect(probe.snapshot == [a, a])
    }

    @Test("new bytes in the same session (⌘R) start a new preparation, not the old image's result")
    func newBytesStartNew() async {
        let probe = Probe()
        let cache = SessionPreparationCache(lane: SingleSlotLane<Data, Int>(label: "t.bytes") { probe.work($0) })
        #expect(await cache.preparation(for: a, generation: 1).value == 1)
        #expect(await cache.preparation(for: b, generation: 1).value == 2)
        #expect(probe.snapshot == [a, b])
    }

    @Test("clear drops the entry, so the next request is a new preparation")
    func clearDrops() async {
        let probe = Probe()
        let cache = SessionPreparationCache(lane: SingleSlotLane<Data, Int>(label: "t.clear") { probe.work($0) })
        _ = await cache.preparation(for: a, generation: 1).value
        cache.clear()
        #expect(!cache.hasEntry)
        _ = await cache.preparation(for: a, generation: 1).value
        #expect(probe.snapshot == [a, a])
    }

    @Test("clear skips a preparation still waiting behind a running one")
    func clearSkipsWaiting() async {
        let blocker = Data([9, 9, 9])
        let probe = Probe(blocking: blocker)
        let lane = SingleSlotLane<Data, Int>(label: "t.skip") { probe.work($0) }
        let cache = SessionPreparationCache(lane: lane)
        let running = cache.preparation(for: blocker, generation: 1)
        // Polled, never a blocking wait: the cache's task starts on the main actor, which a
        // semaphore wait here would be holding.
        #expect(await eventually { probe.hasStarted })
        let waiting = cache.preparation(for: a, generation: 2)
        #expect(await eventually { lane.waitingGeneration != nil })
        cache.clear()
        probe.releaseFirst()
        #expect(await running.value == 3)   // started: runs to completion
        #expect(await waiting.value == nil) // never started
        #expect(probe.snapshot == [blocker])
    }
}
