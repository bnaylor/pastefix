import SwiftUI
import AppKit
import KeyboardShortcuts
import PastefixAppCore

@main
struct PastefixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Pastefix", systemImage: "doc.on.clipboard") {
            Button("Summon Pastefix") { delegate.summon() }
            Divider()
            Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
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
    private var panel: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the panel once, hosting PanelView against the single AppModel.
        let hostingView = NSHostingView(rootView: PanelView(model: model))
        let panel = PanelController(rootView: hostingView)
        self.panel = panel

        // When the user saves or cancels, AppModel calls onEndSession → hide panel.
        model.onEndSession = { [weak self] in
            self?.panel?.hide()
        }

        // Global summon hotkey (default ⌘⇧C, rebindable in Settings).
        KeyboardShortcuts.onKeyUp(for: .summonPastefix) { [weak self] in
            self?.summon()
        }
    }

    /// Summons the panel: snapshot clipboard, update model, show panel.
    func summon() {
        model.summon()
        panel?.show()
    }
}
