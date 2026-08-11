import Testing
import Foundation
@testable import PastefixCore

@Suite struct ScriptWatcherTests {
    @Test func debouncerFiresOnceAfterBurst() async throws {
        let counter = Counter()
        let debouncer = Debouncer(delay: 0.1, queue: .global())
        for _ in 0..<5 { debouncer.schedule { counter.increment() } }
        try await Task.sleep(nanoseconds: 300_000_000)   // 0.3s > delay
        #expect(counter.value == 1)
    }

    @Test func debouncerFiresAgainAfterQuietPeriod() async throws {
        let counter = Counter()
        let debouncer = Debouncer(delay: 0.1, queue: .global())
        debouncer.schedule { counter.increment() }
        try await Task.sleep(nanoseconds: 250_000_000)
        debouncer.schedule { counter.increment() }
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(counter.value == 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
