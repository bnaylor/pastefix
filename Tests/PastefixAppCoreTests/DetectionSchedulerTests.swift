import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// Records which texts the injected scan ran for, from detached tasks.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var value: [String] { lock.withLock { items } }
    func add(_ s: String) { lock.withLock { items.append(s) } }
}

@MainActor
private func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }

private func slowScan(_ log: Log, sleep: TimeInterval = 0.15) -> @Sendable (String) -> DetectionResult {
    { text in log.add(text); Thread.sleep(forTimeInterval: sleep); return DetectionResult.compute(text) }
}

/// Records whether an injected scan observed cancellation and how long that took.
private final class CancelObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _elapsed: TimeInterval = 0
    func recordCancelled(elapsed: TimeInterval) { lock.withLock { _cancelled = true; _elapsed = elapsed } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var elapsed: TimeInterval { lock.withLock { _elapsed } }
}

@Suite @MainActor struct DetectionSchedulerTests {
    @Test func deliversWithTheOriginatingRequest() async {
        var delivered: [(DetectionScheduler.Request, DetectionResult)] = []
        let s = DetectionScheduler(compute: DetectionResult.compute) { delivered.append(($0, $1)) }
        s.request(.init(text: "https://example.com", revision: 3, generation: 7))
        await settle(0.3)
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
        await settle()
        #expect(log.value == ["A", "C"], "B was displaced before it started; A was cancelled but could not be stopped")
        #expect(delivered == ["C"])
    }

    @Test func aFinishedScanIsDeliveredWhenNothingDisplacedIt() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log, sleep: 0.05)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        await settle(0.3)
        s.request(.init(text: "B", revision: 1, generation: 1))
        await settle(0.3)
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

    @Test func requestAfterCancelAllRunsFresh() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log, sleep: 0.05)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.cancelAll()
        s.request(.init(text: "B", revision: 0, generation: 2))
        await settle(0.4)
        #expect(delivered == ["B"])
    }

    @Test func cancellationReachesTheRunningScan() async {
        let observation = CancelObservation()
        let compute: @Sendable (String) -> DetectionResult = { text in
            let start = Date()
            let deadline = ContinuousClock.now + .seconds(1)
            while !Task.isCancelled && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if Task.isCancelled {
                observation.recordCancelled(elapsed: Date().timeIntervalSince(start))
            }
            return DetectionResult.compute(text)
        }
        var delivered: [String] = []
        let s = DetectionScheduler(compute: compute) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.request(.init(text: "B", revision: 1, generation: 1))
        // B is never displaced, so its scan runs the full spin to its own 1 s deadline before
        // finishing normally; only A's cancellation is expected to be fast.
        await settle(1.3)
        #expect(observation.cancelled)
        #expect(observation.elapsed < 0.5)
        #expect(delivered == ["B"])
    }
}
