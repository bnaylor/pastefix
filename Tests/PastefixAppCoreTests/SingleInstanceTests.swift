import Testing
import Foundation
@testable import PastefixAppCore

/// #136: a new copy replaces any OLDER running copy, so only one ever answers the hotkeys — and two
/// copies starting at the same moment agree on which one survives (review: both replacing each other
/// left none).
@Suite struct SingleInstanceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func replacesOlderCopiesOnly() {
        let me = RunningInstance(pid: 300, started: at(10))
        let running = [
            me,
            RunningInstance(pid: 100, started: at(1)),      // older: replaced
            RunningInstance(pid: 200, started: at(5)),      // older: replaced
            RunningInstance(pid: 400, started: at(11)),     // newer: it will replace us, not the reverse
            RunningInstance(pid: 500, started: nil),        // unknown start: an older copy, replaced
        ]
        #expect(SingleInstance.toReplace(running, me: me) == [100, 200, 500])
    }

    @Test func simultaneousLaunchesAgreeOnOneSurvivor() {
        // Same start time to the second: the higher pid is the newer, and wins.
        let a = RunningInstance(pid: 700, started: at(20)), b = RunningInstance(pid: 701, started: at(20))
        let aKills = SingleInstance.toReplace([a, b], me: a), bKills = SingleInstance.toReplace([a, b], me: b)
        #expect(aKills.isEmpty && bKills == [700], "exactly one replaces the other")
        // Ordered by time first.
        let c = RunningInstance(pid: 900, started: at(30)), d = RunningInstance(pid: 800, started: at(31))
        #expect(SingleInstance.toReplace([c, d], me: c).isEmpty && SingleInstance.toReplace([c, d], me: d) == [900])
    }

    @Test func aloneOrUnknownSelfReplacesNothing() {
        let me = RunningInstance(pid: 1, started: at(1))
        #expect(SingleInstance.toReplace([me], me: me).isEmpty)
        let unknownMe = RunningInstance(pid: 2, started: nil)
        #expect(SingleInstance.toReplace([unknownMe, RunningInstance(pid: 3, started: at(0))], me: unknownMe).isEmpty,
                "without our own start time we can't order, so we replace nothing")
    }
}

@Suite struct ProcessStartTests {
    @Test func readsThisProcessesStartAndLiveness() {
        let me = ProcessInfo.processInfo.processIdentifier
        let started = SingleInstance.startTime(of: me)
        #expect(started != nil && started! <= Date() && started! > Date().addingTimeInterval(-86_400))
        #expect(SingleInstance.isAlive(me))
        #expect(SingleInstance.startTime(of: 999_999) == nil && !SingleInstance.isAlive(999_999))
    }
}
