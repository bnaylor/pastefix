import Foundation
import Darwin

/// A running copy as `SingleInstance` sees it: its pid and when its process started.
public struct RunningInstance: Equatable, Sendable {
    public let pid: Int32
    public let started: Date?

    public init(pid: Int32, started: Date?) {
        self.pid = pid
        self.started = started
    }
}

/// One Pastefix at a time (#136). Every copy registers the same global hotkeys and writes the same
/// history, so two running copies both open a panel on ⌘⇧C. Debug and Release share the bundle id,
/// so this covers an Xcode build, `/tmp/pastefix-dd` and `/Applications` alike. The newest copy
/// **replaces** the older ones (owner's choice): a fresh build relaunched over an old one takes over,
/// and a double launch only restarts Pastefix — history is on disk and a session doesn't outlive a
/// summon, so nothing is lost.
public enum SingleInstance {
    /// The copies `me` replaces: every one that started before it, ordered by (start time, pid) so two
    /// copies starting in the same instant agree on which survives — each replacing the other left
    /// none (review). A copy whose start time can't be read is treated as older; without our own start
    /// time nothing is replaced, since nothing can be ordered.
    public static func toReplace(_ running: [RunningInstance], me: RunningInstance) -> [Int32] {
        guard let mine = me.started else { return [] }
        return running.filter { other in
            guard other.pid != me.pid else { return false }
            guard let theirs = other.started else { return true }
            return (theirs, other.pid) < (mine, me.pid)
        }.map(\.pid)
    }

    /// When process `pid` started, from the kernel (`kern.proc.pid`), or nil if it can't be read.
    /// Not `NSRunningApplication.launchDate`: this runs before AppKit has started.
    public static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Whether process `pid` still exists.
    public static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
