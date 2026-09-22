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
    private let workspace: NSWorkspace
    private let retention: TimeInterval = 5

    /// The app that was frontmost before the current one: the app to paste into after Pastefix
    /// hides. Pastefix's own activations are skipped, so summoning the panel (or the menu bar)
    /// never overwrites the user's real target.
    private(set) var previousApp: NSRunningApplication?
    /// The newest activation seen, kept as a running application (not just an id) so it can
    /// become `previousApp` on the next switch.
    private var currentApp: NSRunningApplication?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        currentApp = workspace.frontmostApplication
        if let app = workspace.frontmostApplication { record(app, at: Date()) }
        // The returned token is deliberately not stored: the notification center owns it, and
        // this observer is never removed (see the class note above).
        _ = workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                     object: workspace, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if let cur = self.currentApp,
                   cur.bundleIdentifier != Bundle.main.bundleIdentifier,
                   cur.processIdentifier != app.processIdentifier {
                    self.previousApp = cur
                }
                self.currentApp = app
                self.record(app, at: Date())
            }
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
    ///
    /// `entries` only holds activations the notification stream has already delivered to us, and
    /// a delivery can lose the race with the poll timer in the same runloop pass (or arrive after
    /// any main-thread stall — a long rich-text import, say). So
    /// `NSWorkspace.frontmostApplication` is cross-checked in and unioned into `recentBundleIDs`: it can only ever WIDEN the set an
    /// exclusion can match, never change attribution, which stays the newest tracked activation.
    /// This narrows the window rather than closing it — `NSWorkspace`'s own frontmost cache is
    /// updated asynchronously too, so a blocked main thread can leave it just as stale as ours.
    func context(window: TimeInterval, now: Date = Date()) -> CaptureContext {
        var recent = RecentApps.window(entries: entries, now: now, window: window).filter { !$0.isEmpty }
        if let live = workspace.frontmostApplication?.bundleIdentifier, !live.isEmpty, !recent.contains(live) {
            recent.insert(live, at: 0)   // newest first
        }
        let current = entries.last
        return CaptureContext(sourceBundleID: current?.bundleID.isEmpty == false ? current?.bundleID : nil,
                              sourceAppName: current?.appName, recentBundleIDs: recent)
    }
}
