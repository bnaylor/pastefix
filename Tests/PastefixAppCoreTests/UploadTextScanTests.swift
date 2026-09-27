import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

@Suite("UploadTextScan", .serialized)
struct UploadTextScanTests {
    private let secret = "token: ABCD1234EFGH5678ijkl"

    @Test("the lane returns what the scan returns")
    func sameAnswer() async throws {
        let text = "config\n\(secret)\nmore"
        let direct = UploadTextScan.scan(text)
        #expect(!direct.matches.isEmpty && direct.redactedBytes != nil)
        #expect(await UploadTextScan.run(text) == direct)
        #expect(await UploadTextScan.run("nothing here") == UploadTextScan.Result(matches: [], redactedBytes: nil))
    }

    // #63: every overlay's scan goes through one process-wide lane, so a burst of ⌘⇧U cannot
    // stack uncancellable scans. With one scan running, a second waits and a third displaces it.
    @Test("a scan waiting behind a running one is displaced by a newer one")
    func burstDisplacesTheWaiter() async throws {
        // Large enough to still be running when the next two arrive (~0.2 s per MB measured).
        let big = String(repeating: "lorem ipsum dolor sit amet ", count: 150_000)   // ~4 MB
        let running = Task { await UploadTextScan.run(big) }
        #expect(await eventually { UploadTextScan.lane.isRunningWithNoneWaiting })
        let displaced = Task { await UploadTextScan.run("first waiter \(secret)") }
        #expect(await eventually { UploadTextScan.lane.waitingGeneration != nil })
        let newest = Task { await UploadTextScan.run("second waiter \(secret)") }
        #expect(await displaced.value == nil, "the waiter a newer scan displaced must not run")
        #expect(await newest.value?.matches.isEmpty == false)
        #expect(await running.value != nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }
}
