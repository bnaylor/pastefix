import SwiftUI
import AppKit

@main
struct PastefixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Pastefix", systemImage: "doc.on.clipboard") {
            Button("Summon Pastefix") { delegate.summon() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - AppDelegate

/// Owns AppKit objects that must outlive SwiftUI scene updates:
/// the AppModel, GlobalHotkey (Carbon), and PanelController.
/// Created once by the system before applicationDidFinishLaunching;
/// its lifetime equals the process lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model = AppModel()
    private var hotkey: GlobalHotkey?
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

        // Register the global hotkey (Cmd-Shift-C via Carbon).
        let hotkey = GlobalHotkey(onFire: { [weak self] in self?.summon() })
        hotkey.register()
        self.hotkey = hotkey
    }

    /// Summons the panel: snapshot clipboard, update model, show panel.
    func summon() {
        model.summon()
        panel?.show()
    }
}
