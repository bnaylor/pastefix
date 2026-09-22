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
    /// Bumped when the app comes to front so the Accessibility status re-reads `AXIsProcessTrusted`:
    /// the grant happens in System Settings, outside anything SwiftUI would observe.
    @State private var trustTick = 0
    /// The Presets tab's draft, held here rather than in the tab: `TabView` tears the tab's view
    /// down on a switch, which would silently throw away a half-typed preset. `@StateObject`, so
    /// it survives every re-render of this view and dies with the Settings window.
    @StateObject private var presetEditor = PresetEditorState()

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            snippets.tabItem { Label("Snippets", systemImage: "pin") }
            shortcut.tabItem { Label("Shortcut", systemImage: "keyboard") }
            transforms.tabItem { Label("Transforms", systemImage: "slider.horizontal.3") }
            PresetsSettingsView(settings: settings, editor: presetEditor)
                .tabItem { Label("Presets", systemImage: "text.badge.plus") }
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
                    // Pins are counted apart from history: Clear History leaves them behind, so
                    // folding them into one total would misstate what the button is about to remove.
                    // With no pins the segment is dropped rather than shown as "0 pinned".
                    Text(historyCountLine)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmClear = true }.disabled(history.items.isEmpty)
                }
                Text("Items marked private by password managers are never recorded. Pinned snippets are kept by Clear History.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Excluded apps") {
                Text("Copies made in these apps are never read into history or remembered.")
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
            Button("Clear \(history.unpinnedItems.count) items", role: .destructive) { history.clear() }
            Button("Clear Everything (\(history.items.count))", role: .destructive) { history.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clearing history removes remembered copies and their files from disk. Pinned snippets are kept unless you clear everything.")
        }
        .alert("No bundle identifier", isPresented: Binding(
            get: { !noBundleIDNames.isEmpty },
            set: { if !$0 { noBundleIDNames = [] } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("These items have no bundle identifier and were not added:\n\(noBundleIDNames.joined(separator: "\n"))")
        }
    }

    private var historyCountLine: String {
        var parts = ["\(history.unpinnedItems.count) items"]
        if !history.pinnedItems.isEmpty { parts.append("\(history.pinnedItems.count) pinned") }
        parts.append(HistoryFormatting.byteLabel(history.totalBytes))
        return parts.joined(separator: " · ")
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

    private var snippets: some View {
        Form {
            Section("Paste with hotkey") {
                HStack {
                    Image(systemName: SnippetPaster.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(SnippetPaster.isTrusted ? .green : .orange)
                    Text(SnippetPaster.isTrusted
                         ? "Ready — snippet hotkeys paste into the frontmost app."
                         : "Needs Accessibility permission to press ⌘V. Hotkeys copy the snippet until then.")
                    Spacer()
                    if !SnippetPaster.isTrusted {
                        // `requestTrust`, not `ensureTrusted`: the once-per-launch rule would make
                        // an explicitly clicked button a no-op after the implicit prompt.
                        Button("Request…") { SnippetPaster.requestTrust() }
                        Button("System Settings…") { SnippetPaster.openAccessibilitySettings() }
                    }
                }
                Text("Pastefix uses Accessibility only to send ⌘V. It never reads your keystrokes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Trust is read straight from TCC rather than from published state, so the section has
            // to be rebuilt by hand after the user returns from System Settings.
            .id(trustTick)
            Section("Pinned snippets") {
                if history.pinnedItems.isEmpty {
                    Text("No pinned snippets yet. Pin from the history overlay (⌘P) or the editor (⌘⇧P).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history.pinnedItems) { item in
                        SnippetRow(item: item, history: history)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trustTick += 1
        }
    }

    private var shortcut: some View {
        Form {
            KeyboardShortcuts.Recorder("Summon Pastefix:", name: .summonPastefix)
                .shortcutValidation { validateSummon($0, recording: .summonPastefix) }
            Text("Global hotkey to summon the panel from any app.")
                .font(.caption).foregroundStyle(.secondary)
            KeyboardShortcuts.Recorder("Open history:", name: .summonHistory)
                .shortcutValidation { validateSummon($0, recording: .summonHistory) }
        }
        .padding()
    }

    /// The mirror of the Snippets tab's validation: a summon shortcut may not take a combo the
    /// other summon or a pinned snippet already holds. Refusing from one side only would leave
    /// the collision reachable by recording in the other order.
    private func validateSummon(_ shortcut: KeyboardShortcuts.Shortcut,
                                recording name: KeyboardShortcuts.Name) -> KeyboardShortcuts.ValidationResult {
        let other: KeyboardShortcuts.Name = name == .summonPastefix ? .summonHistory : .summonPastefix
        if KeyboardShortcuts.getShortcut(for: other) == shortcut {
            return .disallow(reason: "Already used by Pastefix's other summon shortcut.")
        }
        if let clash = history.pinnedItems.first(where: {
            KeyboardShortcuts.getShortcut(for: SnippetHotkeys.name(for: $0.id)) == shortcut
        }) {
            return .disallow(reason: "Already used by the snippet “\(SnippetRow.label(for: clash))”.")
        }
        return .allow
    }

    /// True when the combo is one of the app's own reserved summon shortcuts.
    static func isSummonShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        [KeyboardShortcuts.Name.summonPastefix, .summonHistory].contains {
            KeyboardShortcuts.getShortcut(for: $0) == shortcut
        }
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

/// One pinned snippet: its editable title, its global hotkey, and Unpin.
///
/// Unpin does not touch the recorder, and neither does anything else on the unpin path:
/// `HistoryStore.unpin` drops the pin but keeps the title, and `SnippetHotkeys.sync()` removes
/// only the handler. Re-pinning the same item restores both. The combo is forgotten only when the
/// item leaves the store for good, which `SnippetHotkeys` sweeps — clearing it here as well would
/// be a second writer to the same UserDefaults key.
struct SnippetRow: View {
    let item: HistoryItem
    @ObservedObject var history: HistoryStore
    @State private var title: String
    @FocusState private var titleFocused: Bool

    init(item: HistoryItem, history: HistoryStore) {
        self.item = item
        self.history = history
        _title = State(initialValue: item.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // `labelsHidden` keeps the placeholder out of the Form's leading gutter (the
                // same trap the Privacy tab's Stepper hit); the field then takes the width left
                // over by the recorder and Unpin.
                TextField("Title", text: $title)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    // Clicking straight from the field to another row loses the edit otherwise:
                    // a Settings window can be closed without ever submitting.
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                    // `title` is seeded once in `init`, so a rename that happens anywhere else
                    // (a re-pin from the editor's popover, which passes a title) would leave this
                    // field showing the old text and then write it back on the next commit.
                    .onChange(of: item.title) { _, new in title = new ?? "" }
                KeyboardShortcuts.Recorder("", name: SnippetHotkeys.name(for: item.id))
                    // The library only checks the shortcut against menu items and system
                    // shortcuts; two snippets sharing a combo is ours to catch.
                    .shortcutValidation { shortcut in
                        // The library's own ConflictPolicy has no category for another
                        // KeyboardShortcuts.Name in the same app, so a snippet bound to a summon
                        // combo would record, display and persist — and then silently lose, since
                        // the delegate registers the summon names before the snippets.
                        if SettingsView.isSummonShortcut(shortcut) {
                            return .disallow(reason: "Already used by Pastefix's summon shortcut.")
                        }
                        guard let clash = conflictingSnippet(with: shortcut) else { return .allow }
                        return .disallow(reason: "Already used by the snippet “\(Self.label(for: clash))”.")
                    }
                Button("Unpin") { history.unpin(item.id) }
            }
            Text(HistoryFormatting.previewText(for: item))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func commitTitle() {
        guard title != (item.title ?? "") else { return }
        history.rename(item.id, title: title)
    }

    private func conflictingSnippet(with shortcut: KeyboardShortcuts.Shortcut) -> HistoryItem? {
        history.pinnedItems.first {
            $0.id != item.id && KeyboardShortcuts.getShortcut(for: SnippetHotkeys.name(for: $0.id)) == shortcut
        }
    }

    /// What to call a snippet in the conflict message: its title, else a short piece of its text.
    static func label(for item: HistoryItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return String(HistoryFormatting.previewText(for: item).prefix(24))
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
