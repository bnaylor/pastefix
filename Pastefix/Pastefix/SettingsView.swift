import SwiftUI
import AppKit
import KeyboardShortcuts
import PastefixCore
import PastefixAppCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shortcut.tabItem { Label("Shortcut", systemImage: "keyboard") }
            transforms.tabItem { Label("Transforms", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 460, height: 340)
    }

    private var general: some View {
        Form {
            Stepper("Wrap width: \(settings.wrapWidth)", value: $settings.wrapWidth, in: 20...2000, step: 4)
                .onChange(of: settings.wrapWidth) { _, _ in model.reload() }
            Toggle("Hide panel when it loses focus", isOn: $settings.autoHideOnBlur)
            LabeledContent("Scripts folder") {
                HStack {
                    Text(settings.scriptsDirectoryPath).truncationMode(.middle).lineLimit(1)
                    Button("Choose…") { chooseScriptsDir() }
                }
            }
        }
        .padding()
    }

    private var shortcut: some View {
        Form {
            KeyboardShortcuts.Recorder("Summon Pastefix:", name: .summonPastefix)
            Text("Global hotkey to summon the panel from any app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private struct TransformerRow: Identifiable {
        let id: String
        let name: String
    }

    private var transforms: some View {
        let rows = model.transformers.map { TransformerRow(id: $0.id, name: $0.name) }
        return VStack(alignment: .leading) {
            Text("Enable, disable, and reorder transforms. Drag to reorder.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(rows) { row in
                    Toggle(isOn: enabledBinding(for: row.id)) { Text(row.name) }
                }
                .onMove { source, destination in moveTransforms(rows: rows, from: source, to: destination) }
            }
        }
        .padding()
    }

    private func enabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { settings.transformEnabled[id] ?? true },
            set: { settings.transformEnabled[id] = $0; model.reload() }
        )
    }

    private func moveTransforms(rows: [TransformerRow], from source: IndexSet, to destination: Int) {
        var ids = rows.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        var order: [String: Int] = [:]
        for (index, id) in ids.enumerated() { order[id] = index * 10 }
        settings.transformOrder = order
        model.reload()
    }

    private func chooseScriptsDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.scriptsDirectoryPath = url.path
            model.reload()
        }
    }
}
