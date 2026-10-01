import AppKit
import OSLog
import PastefixAppCore

/// Makes this the only running Pastefix (#136). Called from `PastefixEntry.main()` BEFORE the
/// SwiftUI app exists: the `Settings` scene builds the lazy `HistoryStore` while `App.body` is
/// evaluated, ahead of `applicationDidFinishLaunching`, so doing this there let the new copy load and
/// orphan-sweep history while the old one was still writing it (review). Older copies are asked to
/// quit — a normal quit, so their `applicationWillTerminate` flushes history — and waited for on the
/// process itself (`kill(pid, 0)`), since no run loop is running yet; one still there after the
/// timeout is force-quit, and logged. Only copies that started before this one are replaced
/// (`SingleInstance`), so two launched together don't each quit the other. Never runs in a test host.
enum InstanceReplacement {
    private static let log = Logger(subsystem: "net.scromp.Pastefix", category: "launch")

    static func replaceOlderInstances(timeout: TimeInterval = 3) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let me = RunningInstance(pid: ownPID, started: SingleInstance.startTime(of: ownPID))
        let running = apps.map { RunningInstance(pid: $0.processIdentifier, started: SingleInstance.startTime(of: $0.processIdentifier)) }
        let pids = Set(SingleInstance.toReplace(running + [me], me: me))
        let older = apps.filter { pids.contains($0.processIdentifier) }
        guard !older.isEmpty else { return }
        for app in older {
            log.notice("launch: replacing the older copy pid \(app.processIdentifier, privacy: .public) at \(app.bundleURL?.path ?? "?", privacy: .public)")
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while older.contains(where: { SingleInstance.isAlive($0.processIdentifier) }) && Date() < deadline {
            usleep(50_000)
        }
        for app in older where SingleInstance.isAlive(app.processIdentifier) {
            log.error("launch: pid \(app.processIdentifier, privacy: .public) didn't quit in \(timeout, privacy: .public) s; force-quitting it")
            app.forceTerminate()
        }
    }
}
