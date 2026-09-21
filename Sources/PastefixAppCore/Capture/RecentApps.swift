import Foundation

/// Pure windowing over frontmost-app activation entries. The app-side tracker feeds it.
public enum RecentApps {
    public struct Entry: Sendable, Equatable {
        public var bundleID: String
        public var appName: String
        public var activatedAt: Date
        public init(bundleID: String, appName: String, activatedAt: Date) { self.bundleID = bundleID; self.appName = appName; self.activatedAt = activatedAt }
    }

    /// Bundle ids of every app that was frontmost at some instant in `[now - window, now]`,
    /// newest first, de-duplicated. `entries` are in activation order (oldest first). The newest
    /// entry is always included; an older entry is included iff the entry that replaced it was
    /// activated inside the window (i.e. it was still frontmost when the window opened).
    public static func window(entries: [Entry], now: Date, window: TimeInterval) -> [String] {
        let cutoff = now.addingTimeInterval(-window)
        var out: [String] = []
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            // entries[i] stayed frontmost until entries[i+1] took over; if that hand-over happened
            // at or before the cutoff, entries[i] and everything older lie outside the window.
            if i + 1 < entries.count, entries[i + 1].activatedAt <= cutoff { break }
            let id = entries[i].bundleID
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Drops entries that stopped being frontmost more than `retention` ago, always keeping the current one.
    public static func trimmed(_ entries: [Entry], now: Date, retention: TimeInterval) -> [Entry] {
        let cutoff = now.addingTimeInterval(-retention)
        guard let last = entries.last else { return [] }
        var kept: [Entry] = [last]
        var i = entries.count - 2
        while i >= 0, entries[i + 1].activatedAt > cutoff { kept.insert(entries[i], at: 0); i -= 1 }
        return kept
    }
}
