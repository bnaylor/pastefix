import SwiftUI
import AppKit

/// A `SettingsLink` that also activates the app: from inside the non-activating panel a plain
/// `SettingsLink` opens Settings without making Pastefix active, so the window can appear
/// unfocused (and, before PanelController yielded its level, behind the panel). An
/// `LSUIElement` agent gets no automatic foreground promotion either (see `9ad051b`), so the
/// menu bar item needs the same activation (#54).
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    let label: () -> Label

    var body: some View {
        Button(action: {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }, label: label)
    }
}
