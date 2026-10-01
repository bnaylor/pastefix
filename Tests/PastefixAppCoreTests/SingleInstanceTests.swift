import Testing
@testable import PastefixAppCore

/// #136: a new copy replaces any other running copy, so only one ever answers the hotkeys.
@Suite struct SingleInstanceTests {
    private let id = "scromp.net.Pastefix"

    @Test func replacesEveryOtherLiveCopyAndNeverItself() {
        let running = [
            RunningInstance(pid: 100, bundleID: id, isTerminated: false),   // us
            RunningInstance(pid: 200, bundleID: id, isTerminated: false),   // an older copy
            RunningInstance(pid: 300, bundleID: id, isTerminated: false),   // another
            RunningInstance(pid: 400, bundleID: id, isTerminated: true),    // already quitting
            RunningInstance(pid: 500, bundleID: "com.example.Other", isTerminated: false),
            RunningInstance(pid: 600, bundleID: nil, isTerminated: false),
        ]
        #expect(SingleInstance.toReplace(running, ownPID: 100, bundleID: id) == [200, 300])
    }

    @Test func aloneIsNothingToDo() {
        #expect(SingleInstance.toReplace([RunningInstance(pid: 100, bundleID: id, isTerminated: false)], ownPID: 100, bundleID: id).isEmpty)
        #expect(SingleInstance.toReplace([], ownPID: 100, bundleID: id).isEmpty)
    }
}
