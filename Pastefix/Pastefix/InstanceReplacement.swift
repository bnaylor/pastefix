import AppKit
import OSLog
import PastefixAppCore

/// Makes this the only running Pastefix (#136), before anything registers a hotkey or opens the
/// history: the other copies are asked to quit — a normal quit, so their `applicationWillTerminate`
/// flushes history — and given a few seconds; one that is still there after that is force-quit,
/// and logged. Runs only in the real app: a test host never gets here (`PastefixEntry`).
@MainActor
enum InstanceReplacement {
    private static let log = Logger(subsystem: "net.scromp.Pastefix", category: "launch")

    static func replaceOtherInstances(timeout: TimeInterval = 3) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let running = apps.map { RunningInstance(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, isTerminated: $0.isTerminated) }
        let pids = Set(SingleInstance.toReplace(running, ownPID: ProcessInfo.processInfo.processIdentifier, bundleID: bundleID))
        let others = apps.filter { pids.contains($0.processIdentifier) }
        guard !others.isEmpty else { return }
        for app in others {
            log.notice("launch: replacing the running copy pid \(app.processIdentifier, privacy: .public) at \(app.bundleURL?.path ?? "?", privacy: .public)")
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for app in others where !app.isTerminated {
            log.error("launch: pid \(app.processIdentifier, privacy: .public) didn't quit in \(timeout, privacy: .public) s; force-quitting it")
            app.forceTerminate()
        }
    }
}
