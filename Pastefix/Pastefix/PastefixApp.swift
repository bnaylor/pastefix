import SwiftUI
import AppKit

// Minimal scaffold stub so the app target builds. Replaced by the real
// menu-bar app (panel, hotkey, palette) in Plan 2a Task 9.
@main
struct PastefixApp: App {
    var body: some Scene {
        MenuBarExtra("Pastefix", systemImage: "doc.on.clipboard") {
            Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}
