import SwiftUI
import os
import PastefixAppCore

/// The process entry point, and the one place that decides whether this launch is the real app.
///
/// When Pastefix.app is launched to host unit tests (#68), `PastefixApp` never runs, so
/// `AppDelegate` is never created. A guard inside the app's own launch sequence would be too
/// late: the delegate's property initialisers read the real settings domain and construct Sparkle,
/// the `MenuBarExtra` scene installs a second menu-bar icon whose Summon reads the real clipboard,
/// the `Settings` scene touches the lazy `HistoryStore`, and `applicationWillTerminate` flushes
/// history — which constructs `HistoryStore` on the real directory and runs its orphan-blob sweep,
/// able to delete a blob an installed, running Pastefix had just written. Deciding here means none
/// of that exists to guard.
///
/// The decision is logged at `.notice` on every launch, so "why is Pastefix doing nothing" is
/// answered by `log show --predicate 'subsystem == "net.scromp.Pastefix"'`.
@main
enum PastefixEntry {
    static func main() {
        let hosting = TestHostDetection.isHostingTests()
        Logger(subsystem: "net.scromp.Pastefix", category: "launch")
            .notice("launch: \(hosting ? "test host — the app is not started" : "app", privacy: .public)")
        if hosting {
            TestHostApp.main()
        } else {
            // Before the app exists — its Settings scene opens history during App.body (#136).
            InstanceReplacement.replaceOlderInstances()
            PastefixApp.main()
        }
    }
}

/// What a test host runs instead of the app: one inert scene, no delegate, no menu-bar item.
struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}
