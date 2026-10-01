/// A running app as `SingleInstance` sees it: just what the decision needs, so it's testable
/// without `NSRunningApplication`.
public struct RunningInstance: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let isTerminated: Bool

    public init(pid: Int32, bundleID: String?, isTerminated: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.isTerminated = isTerminated
    }
}

/// One Pastefix at a time (#136). Every copy registers the same global hotkeys and writes the same
/// history, so two running copies both open a panel on ⌘⇧C. Debug and Release share the bundle id,
/// so this covers an Xcode build, `/tmp/pastefix-dd` and `/Applications` alike. A new copy
/// **replaces** the others (owner's choice): a fresh build relaunched over an old one takes over,
/// and a double launch only restarts Pastefix — history is on disk and a session doesn't outlive
/// a summon, so nothing is lost.
public enum SingleInstance {
    /// The other live copies to replace: same bundle id, not this process, not already quitting.
    public static func toReplace(_ running: [RunningInstance], ownPID: Int32, bundleID: String) -> [Int32] {
        running.filter { $0.pid != ownPID && $0.bundleID == bundleID && !$0.isTerminated }.map(\.pid)
    }
}
