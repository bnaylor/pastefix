import AppKit
import Combine
import Sparkle

/// Owns Sparkle's standard updater and exposes the little the UI needs.
///
/// The "automatically check" preference is Sparkle's own (`SPUUpdater.automaticallyChecksForUpdates`,
/// persisted by Sparkle in UserDefaults) — it is deliberately not mirrored in `SettingsStore`.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
    /// Mirrors `SPUUpdater.canCheckForUpdates` so menu items and buttons disable during a check.
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        // Not started here: Sparkle wants to start after the app has finished launching.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
            .store(in: &cancellables)
    }

    /// Starts scheduled checking. Call once from `applicationDidFinishLaunching`.
    func start() {
        controller.startUpdater()
    }

    /// User-initiated check. An LSUIElement agent gets no foreground promotion, so activate first
    /// or Sparkle's window opens behind the frontmost app (same lesson as the Settings window).
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    #if DEBUG
    /// Debug-only feed override for the local end-to-end update test:
    ///   defaults write scromp.net.Pastefix PastefixUpdateFeedURL http://localhost:8000/appcast.xml
    /// Release builds never compile this, so they always use SUFeedURL from Info.plist.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "PastefixUpdateFeedURL")
    }
    #endif
}
