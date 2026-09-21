import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KeyboardShortcuts
import PastefixCore
import PastefixAppCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: AppModel
    @ObservedObject var updater: UpdaterController
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false
    @State private var selectedExclusion: String?
    @State private var showIdentifierPrompt = false
    @State private var newIdentifier = ""
    @State private var noBundleIDNames: [String] = []

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            shortcut.tabItem { Label("Shortcut", systemImage: "keyboard") }
            transforms.tabItem { Label("Transforms", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 460, height: 400)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
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
                    Button("Use Default") {
                        settings.resetScriptsDirectoryToDefault()
                        model.reload()
                    }
                }
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                HStack {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                    Text("Pastefix \(updater.versionDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var privacy: some View {
        Form {
            Section("History") {
                Toggle("Remember clipboard history", isOn: $settings.historyEnabled)
                // A titled Stepper puts its title in the Form's leading gutter, which leaves this
                // row misaligned with the toggle above it. Label it by hand instead.
                HStack {
                    Text("Keep last \(settings.historyMaxItems) items")
                    Spacer()
                    Stepper("", value: $settings.historyMaxItems, in: 20...1000, step: 10)
                        .labelsHidden()
                }
                .disabled(!settings.historyEnabled)
                HStack {
                    Text("\(history.items.count) items · \(HistoryFormatting.byteLabel(history.totalBytes))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmClear = true }.disabled(history.items.isEmpty)
                }
                Text("Items marked private by password managers are never recorded.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Excluded apps") {
                Text("Copies made in these apps are never read or remembered.")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $selectedExclusion) {
                    ForEach(settings.historyExcludedBundleIDs, id: \.self) { id in
                        ExcludedAppRow(bundleID: id).tag(id)
                    }
                }
                .frame(minHeight: 120)
                // Four text buttons truncate at the 460pt window width ("Add Ap…", "Restore…"),
                // so the adds collapse into the standard macOS +/− pair under the list.
                HStack(spacing: 8) {
                    Menu {
                        Button("Application…") { addAppFromPanel() }
                        Button("Identifier…") { showIdentifierPrompt = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .frame(width: 34)
                    .help("Add an app, or a bundle identifier, to the exclusion list")
                    // The popover hangs off a zero-size sibling rather than the Menu: presenting it
                    // from the Menu itself races that menu's own dismissal.
                    Color.clear
                        .frame(width: 0, height: 0)
                        .popover(isPresented: $showIdentifierPrompt) {
                            VStack(alignment: .leading) {
                                Text("Bundle identifier").font(.caption)
                                TextField("com.example.app", text: $newIdentifier)
                                    .frame(width: 260)
                                    .onSubmit { commitIdentifier() }
                                HStack {
                                    Spacer()
                                    Button("Add") { commitIdentifier() }.keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding()
                        }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .frame(width: 34)
                        .disabled(selectedExclusion == nil)
                        .help("Remove the selected app from the exclusion list")
                    Spacer()
                    Button("Restore Defaults") {
                        settings.restoreDefaultExclusions()
                        // The selected id may not survive the reset; a stale selection would leave
                        // Remove enabled against a list that no longer contains it.
                        selectedExclusion = nil
                    }
                }
                Text("Copies made by browser password extensions come from the browser, not the manager; those are skipped when the extension marks them concealed, which 1Password, Bitwarden and Apple do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .alert("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear \(history.items.count) items", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes every remembered item and its files from disk.") }
        .alert("No bundle identifier", isPresented: Binding(
            get: { !noBundleIDNames.isEmpty },
            set: { if !$0 { noBundleIDNames = [] } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("These items have no bundle identifier and were not added:\n\(noBundleIDNames.joined(separator: "\n"))")
        }
    }

    private func removeSelected() {
        guard let selected = selectedExclusion else { return }
        settings.removeExcludedBundleID(selected)
        selectedExclusion = nil
    }

    private func commitIdentifier() {
        settings.addExcludedBundleID(newIdentifier)
        newIdentifier = ""
        showIdentifierPrompt = false
    }

    private func addAppFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var missing: [String] = []
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                settings.addExcludedBundleID(id)
            } else {
                missing.append(url.lastPathComponent)
            }
        }
        if !missing.isEmpty { noBundleIDNames = missing }
    }

    private var shortcut: some View {
        Form {
            KeyboardShortcuts.Recorder("Summon Pastefix:", name: .summonPastefix)
            Text("Global hotkey to summon the panel from any app.")
                .font(.caption).foregroundStyle(.secondary)
            KeyboardShortcuts.Recorder("Open history:", name: .summonHistory)
        }
        .padding()
    }

    private struct TransformerRow: Identifiable {
        let id: String
        let name: String
    }

    private var transforms: some View {
        let rows = model.allTransformers.map { TransformerRow(id: $0.id, name: $0.name) }
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
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.scriptsDirectoryPath = url.path
            model.reload()
        }
    }
}

/// One row of the excluded-apps list: the app's icon and name when it is installed,
/// otherwise the raw identifier greyed out and marked "not installed" — an exclusion
/// stays on the list even if the app is gone, so the user can still see and remove it.
struct ExcludedAppRow: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    // The generic document icon reads as a blank white rectangle at this size;
                    // a dashed app outline says "not here" legibly.
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.flatMap { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
                    .foregroundStyle(url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(url == nil ? "\(bundleID) · not installed" : bundleID)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
