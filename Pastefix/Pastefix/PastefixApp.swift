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
        MenuBarExtra {
            MenuBarMenu(settings: delegate.settings, updater: delegate.updater) { delegate.summon() }
        } label: {
            MenuBarLabel(settings: delegate.settings)
        }

        Settings {
            SettingsView(settings: delegate.settings, model: delegate.model, updater: delegate.updater, history: delegate.history)
        }
    }
}

/// The menu bar icon. `App` is a struct and does not observe `delegate.settings` on its own,
/// so the glyph lives in a view that holds the store as an `@ObservedObject` and redraws when
/// `historyEnabled` flips.
struct MenuBarLabel: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Label("Pastefix", systemImage: settings.historyEnabled ? "doc.on.clipboard" : "pause.circle")
    }
}

/// The menu bar menu. Observes the settings store so the Clipboard History toggle reflects
/// changes made elsewhere (Settings, or another copy of the menu).
struct MenuBarMenu: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: UpdaterController
    let summon: () -> Void

    var body: some View {
        Button("Summon Pastefix") { summon() }
        Toggle("Clipboard History", isOn: $settings.historyEnabled)
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)
        CheckForUpdatesButton(updater: updater)
        Divider()
        Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
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
    private(set) lazy var history = HistoryStore(
        directory: Self.historyDirectory,
        limits: HistoryLimits(maxItems: settings.historyMaxItems))
    private(set) lazy var model = AppModel(settings: settings, history: history)
    private(set) lazy var snippetHotkeys = SnippetHotkeys(history: history)
    let updater = UpdaterController()
    private var panel: PanelController?
    private var scriptWatcher: ScriptWatcher?
    private var pasteboardMonitor: PasteboardMonitor?
    /// Built on first use and kept for the process lifetime: it has to have been listening for
    /// activations before a copy happens to be able to attribute it.
    private lazy var frontmostTracker = FrontmostAppTracker()
    private var lastSummonAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()

    static let historyDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pastefix/history", isDirectory: true)

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

        // Clipboard history: second hotkey opens the panel straight into the overlay.
        KeyboardShortcuts.onKeyUp(for: .summonHistory) { [weak self] in
            self?.summonHistory()
        }
        // `history` is already constructed with this cap; no need to reassert it here.
        settings.$historyMaxItems
            .dropFirst()
            // Every in-range intermediate otherwise applies immediately: holding the Settings
            // stepper's down arrow walks 200→20 in about a second, evicting and deleting blobs
            // at each step along the way. Debounce so only the value the user settles on lands.
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            // @Published emits from willSet, before SettingsStore's own didSet clamp — an
            // out-of-range value can arrive here raw (e.g. a live-typed "2" before "20" lands),
            // and applying it would evict and permanently delete blobs for a value the setting
            // itself never actually holds. Clamp ABOVE removeDuplicates so the whole chain
            // speaks in clamped values: two raw values that clamp to the same cap (2 then 5)
            // are one change, not two.
            .map { min(max($0, 20), 1000) }
            .removeDuplicates()
            .sink { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, n != self.history.limits.maxItems else { return }
                    self.history.limits.maxItems = n
                }
            }
            .store(in: &cancellables)
        updateMonitor(enabled: settings.historyEnabled)
        settings.$historyEnabled.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in MainActor.assumeIsolated { self?.updateMonitor(enabled: on) } }
            .store(in: &cancellables)
        // Exclusion-list edits are rare and one at a time, so no debounce: rebuild the monitor
        // so the new list takes effect on the very next poll. The main-queue hop is load-bearing,
        // not ceremony: @Published emits from willSet, so reading settings.historyExcludedBundleIDs
        // synchronously here would hand the monitor the list from *before* the edit.
        settings.$historyExcludedBundleIDs.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuildMonitor() } }
            .store(in: &cancellables)

        // Pasting a snippet targets the app the user was in before Pastefix took focus.
        model.previousAppProvider = { [weak self] in self?.frontmostTracker.previousApp }

        // One global shortcut per pinned snippet, re-synced whenever the pin set changes.
        snippetHotkeys.sync()
        history.$items
            .map { Set($0.filter(\.pinned).map(\.id)) }
            .removeDuplicates()
            // Pin/unpin arrives one item at a time, but a clear() or a cap trim can republish
            // `items` repeatedly in a single pass; coalesce so the shortcuts are rebuilt once.
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.snippetHotkeys.sync() } }
            .store(in: &cancellables)

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

    private func updateMonitor(enabled: Bool) {
        if enabled {
            if pasteboardMonitor == nil {
                pasteboardMonitor = PasteboardMonitor(
                    filters: [ConcealedTypeFilter(),
                              AppExclusionFilter(excludedBundleIDs: settings.historyExcludedBundleIDs)],
                    maxImageBytes: history.limits.maxImageBytes,
                    tracker: frontmostTracker) { [weak self] candidate in
                    self?.history.record(candidate)
                }
            }
            pasteboardMonitor?.start()
        } else {
            pasteboardMonitor?.stop()
        }
    }

    /// The filter chain is fixed at construction, so a changed exclusion list means a new
    /// monitor. Dropping the old one loses only its `lastChangeCount`, and `start()` reseeds
    /// that from the current pasteboard — the deliberate "never back-fill" behaviour.
    private func rebuildMonitor() {
        pasteboardMonitor?.stop()
        pasteboardMonitor = nil
        updateMonitor(enabled: settings.historyEnabled)
    }

    /// ⌘⇧V: show the panel (starting a session from the current clipboard if none) with history open.
    func summonHistory() {
        if model.document == nil { summon() } else { lastSummonAt = Date(); panel?.show() }
        model.historyOverlayRequested = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        history.flush()
    }
}
