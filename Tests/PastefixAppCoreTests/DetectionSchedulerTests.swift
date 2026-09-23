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

@Suite @MainActor struct DetectionSchedulerTests {
    @Test func deliversWithTheOriginatingRequest() async {
        var delivered: [(DetectionScheduler.Request, DetectionResult)] = []
        let s = DetectionScheduler(compute: DetectionResult.compute) { delivered.append(($0, $1)) }
        s.request(.init(text: "https://example.com", revision: 3, generation: 7))
        await settle(0.3)
        #expect(delivered.count == 1)
        #expect(delivered.first?.0.revision == 3 && delivered.first?.0.generation == 7)
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
}
