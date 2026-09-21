import AppKit
import PastefixAppCore

/// Knows which apps were frontmost recently, from workspace activation notifications, so the
/// monitor can attribute a pasteboard change (and apply exclusions) BEFORE reading it — the
/// poll runs up to half a second after the copy, by which time the user may have switched apps.
///
/// One instance lives for the process lifetime (the `AppDelegate` owns it and never drops it),
/// so the activation observer is deliberately never removed: `deinit` cannot touch
/// `NSWorkspace.shared` from a non-isolated context under strict concurrency, and there is no
/// teardown to balance.
@MainActor
final class FrontmostAppTracker {
    private var entries: [RecentApps.Entry] = []
    private var observer: NSObjectProtocol?
    private let retention: TimeInterval = 5

    init(workspace: NSWorkspace = .shared) {
        if let app = workspace.frontmostApplication { record(app, at: Date()) }
        observer = workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                            object: workspace, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.record(app, at: Date()) }
        }
    }

    private func record(_ app: NSRunningApplication, at date: Date) {
        entries.append(.init(bundleID: app.bundleIdentifier ?? "",
                             appName: app.localizedName ?? app.bundleIdentifier ?? "?",
                             activatedAt: date))
        entries = RecentApps.trimmed(entries, now: date, retention: retention)
    }

    /// Context for a change noticed now: the current app as source, plus everything frontmost
    /// within `window`. An app with no bundle identifier (the empty id above) is never reported
    /// as a source or a recent id — an empty string must not be matchable by an exclusion entry.
    func context(window: TimeInterval, now: Date = Date()) -> CaptureContext {
        let recent = RecentApps.window(entries: entries, now: now, window: window).filter { !$0.isEmpty }
        let current = entries.last
        return CaptureContext(sourceBundleID: current?.bundleID.isEmpty == false ? current?.bundleID : nil,
                              sourceAppName: current?.appName, recentBundleIDs: recent)
    }
}
