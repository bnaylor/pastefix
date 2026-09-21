import Testing
import Foundation
@testable import PastefixAppCore

@Suite struct RecentAppsTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func e(_ id: String, _ dt: TimeInterval) -> RecentApps.Entry { .init(bundleID: id, appName: id, activatedAt: t0.addingTimeInterval(dt)) }
    @Test func singleEntry() {
        #expect(RecentApps.window(entries: [e("a", 0)], now: t0.addingTimeInterval(10), window: 1) == ["a"])
    }
    @Test func switchInsideWindowKeepsBoth() {
        // b became frontmost 0.3 s ago; a was frontmost until then, i.e. inside the last 1 s.
        #expect(RecentApps.window(entries: [e("a", 0), e("b", 9.7)], now: t0.addingTimeInterval(10), window: 1) == ["b", "a"])
    }
    @Test func switchOutsideWindowKeepsNewestOnly() {
        #expect(RecentApps.window(entries: [e("a", 0), e("b", 5)], now: t0.addingTimeInterval(10), window: 1) == ["b"])
    }
    @Test func repeatedIdsDeduplicatedNewestFirst() {
        #expect(RecentApps.window(entries: [e("a", 9.2), e("b", 9.5), e("a", 9.8)], now: t0.addingTimeInterval(10), window: 1) == ["a", "b"])
    }
    @Test func emptyEntries() { #expect(RecentApps.window(entries: [], now: t0, window: 1).isEmpty) }
    @Test func trimDropsEntriesOlderThanRetentionButKeepsTheCurrent() {
        let kept = RecentApps.trimmed([e("a", 0), e("b", 1), e("c", 9)], now: t0.addingTimeInterval(10), retention: 5)
        #expect(kept.map(\.bundleID) == ["b", "c"])   // b is the entry that was current when c took over inside retention; a is fully outside
    }
}
