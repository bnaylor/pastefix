import SwiftUI
import AppKit
import Combine
import KeyboardShortcuts
import PastefixCore
import PastefixAppCore

@main
struct PastefixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Pastefix", systemImage: "doc.on.clipboard") {
            Button("Summon Pastefix") { delegate.summon() }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
            CheckForUpdatesButton(updater: delegate.updater)
            Divider()
            Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView(settings: delegate.settings, model: delegate.model, updater: delegate.updater)
        }
    }
}

/// Menu item that disables itself while a check is already running.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

// MARK: - AppDelegate

/// Owns AppKit objects that must outlive SwiftUI scene updates:
/// the AppModel and PanelController.
/// Created once by the system before applicationDidFinishLaunching;
/// its lifetime equals the process lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var settings = SettingsStore()
    private(set) lazy var model = AppModel(settings: settings)
    let updater = UpdaterController()
    private var panel: PanelController?
    private var scriptWatcher: ScriptWatcher?
    private var lastSummonAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle: scheduled daily checks start here, after launch, per Sparkle's guidance.
        updater.start()

        // Build the panel once, hosting PanelView against the single AppModel.
        let hostingView = NSHostingView(rootView: PanelView(model: model, settings: settings))
        let panel = PanelController(rootView: hostingView)
        self.panel = panel
        // Size the panel for the persisted sidebar state before it is ever shown.
        panel.setSidebarVisible(settings.showSidebar)

        // Auto-hide the panel when it loses key focus (if enabled in settings and a session is active).
        panel.onResignKey = { [weak self] in
            guard let self, self.settings.autoHideOnBlur, self.model.document != nil else { return }
            // Ignore the transient resign-key that fires during the summon activation
            // sequence; only auto-hide on a genuine later blur.
            guard Date().timeIntervalSince(self.lastSummonAt) > 0.3 else { return }
            self.model.cancel()   // ends session; onEndSession hides the panel
        }

        // When the user saves or cancels, AppModel calls onEndSession → hide panel.
        model.onEndSession = { [weak self] in
            self?.panel?.hide()
        }

        // Global summon hotkey (default ⌘⇧C, rebindable in Settings).
        KeyboardShortcuts.onKeyUp(for: .summonPastefix) { [weak self] in
            self?.summon()
        }

        // Live-reload the palette when the user's scripts directory changes.
        startWatchingScripts()

        // Re-point the watcher whenever the user picks a new scripts folder.
        settings.$scriptsDirectoryPath
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.startWatchingScripts() }
            }
            .store(in: &cancellables)

        // Grow/shrink the panel when the sidebar is toggled: SwiftUI's minWidth can't
        // resize an AppKit window on its own.
        settings.$showSidebar
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shown in
                MainActor.assumeIsolated { self?.panel?.setSidebarVisible(shown) }
            }
            .store(in: &cancellables)
    }

    private func startWatchingScripts() {
        scriptWatcher?.stop()
        let dir = settings.scriptsDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let watcher = ScriptWatcher(directory: dir) { [weak self] in
            // onChange is delivered on the main queue by ScriptWatcher's debouncer.
            MainActor.assumeIsolated { self?.model.reload() }
        }
        watcher.start()
        scriptWatcher = watcher
    }

    /// Summons the panel: snapshot clipboard, update model, show panel.
    func summon() {
        lastSummonAt = Date()
        model.summon()
        panel?.show()
    }
}
