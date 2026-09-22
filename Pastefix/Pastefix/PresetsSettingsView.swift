import SwiftUI
import PastefixCore
import PastefixAppCore

/// The Presets tab: a list of user-defined find & replace rules on the left, an editor with a
/// live preview on the right.
///
/// Edits are made against a `draft` copy rather than straight into the store, so a half-typed
/// pattern never reaches the registry: the delegate rebuilds the transformer list on every
/// `regexPresets` change, and a preset only becomes a transform when Save writes it back. The
/// same copy is what Revert throws away.
struct PresetsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selected: UUID?
    @State private var draft: RegexPreset?
    @State private var sample = "The quick brown fox\njumps over the lazy dog"
    @State private var preview = ""
    /// "3 matches", or why there is no preview.
    @State private var previewInfo = ""
    @State private var previewTask: Task<Void, Never>?

    /// The preview runs on a slice of the sample, not the whole thing: this is a live keystroke-
    /// driven path, and a user pattern's cost is theirs to choose, not ours to trust.
    private static let sampleLimit = 16_384
    /// `nonisolated` so the detached preview can read it: with `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor` a plain static would be main-actor state, which is an error in Swift 6 mode.
    nonisolated private static let previewTimeout = Duration.seconds(1)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if let bound = Binding($draft) {
                editor(bound)
            } else {
                Text("Select or add a preset")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The draft follows the selection; a preset removed while selected clears both (see
        // `remove`), so this also empties the editor.
        .onChange(of: selected) { _, id in
            draft = settings.regexPresets.first { $0.id == id }
            schedulePreview()
        }
        .onChange(of: draft) { _, _ in schedulePreview() }
        .onChange(of: sample) { _, _ in schedulePreview() }
        .onDisappear { previewTask?.cancel() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(settings.regexPresets, selection: $selected) { preset in
                Text(preset.name.isEmpty ? "Untitled" : preset.name).tag(preset.id)
            }
            HStack(spacing: 8) {
                Button { add() } label: { Image(systemName: "plus") }
                    .help("Add a preset")
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                    .help("Remove the selected preset")
                Spacer()
            }
            .padding(6)
        }
        .frame(width: 160)
    }

    private func editor(_ preset: Binding<RegexPreset>) -> some View {
        Form {
            TextField("Name", text: preset.name)
            TextField("Pattern", text: preset.pattern)
                .font(.system(.body, design: .monospaced))
            if let error = compileError(preset.wrappedValue) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            TextField("Replacement ($1, \\n, \\t)", text: preset.replacement)
                .font(.system(.body, design: .monospaced))
            Toggle("Case-insensitive", isOn: preset.caseInsensitive)
            Toggle("^ and $ match at line boundaries", isOn: preset.anchorsMatchLines)
            Toggle(". matches newlines", isOn: preset.dotMatchesNewlines)
            Toggle("Replace all matches", isOn: preset.replaceAll)
            Section("Preview") {
                TextEditor(text: $sample)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 60)
                Text(previewInfo).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 60)
            }
            HStack {
                Spacer()
                Button("Revert") { draft = settings.regexPresets.first { $0.id == preset.wrappedValue.id } }
                Button("Save") { settings.updatePreset(preset.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
                    // A preset that can't compile would load as a transform that throws on every
                    // use, and a nameless one would be unpickable in the palette.
                    .disabled(!isSavable(preset.wrappedValue))
            }
            Text("Saved presets appear in the palette and in the Transforms tab, where they can be disabled and reordered.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func add() {
        let preset = RegexPreset(name: "New preset", pattern: "", replacement: "")
        settings.addPreset(preset)
        selected = preset.id
    }

    private func remove() {
        guard let id = selected else { return }
        settings.removePreset(id: id)
        // Clearing the selection by hand rather than letting the List drop it: `onChange(of:
        // selected)` is what reloads the draft, and leaving a draft for a deleted preset behind
        // would let Save re-add it (it wouldn't — `updatePreset` no-ops on a missing id — but the
        // editor would still be showing a preset that is gone).
        selected = nil
        draft = nil
    }

    private func isSavable(_ preset: RegexPreset) -> Bool {
        compileError(preset) == nil && !preset.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func compileError(_ preset: RegexPreset) -> String? {
        do {
            _ = try preset.compile()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Restarts the debounced preview. The old task is cancelled rather than left to land: it
    /// would otherwise publish a result for the pattern the user has already typed past.
    private func schedulePreview() {
        previewTask?.cancel()
        guard let preset = draft else { preview = ""; previewInfo = ""; return }
        let text = String(sample.prefix(Self.sampleLimit))
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            // Detached, so a slow pattern burns a background thread instead of blocking the
            // Settings window. Nothing cancels it — the deadline inside `preview` is what bounds
            // it — so the staleness check below is what keeps its result from landing late.
            let outcome = await Task.detached { () -> PreviewOutcome in
                do {
                    let result = try RegexPresetTransformer.preview(
                        text, preset: preset, deadline: .now + Self.previewTimeout)
                    return PreviewOutcome(
                        output: result.output,
                        info: result.matches == 1 ? "1 match" : "\(result.matches) matches")
                } catch {
                    return PreviewOutcome(output: "", info: Self.message(for: error))
                }
            }.value
            guard !Task.isCancelled else { return }
            preview = outcome.output
            previewInfo = outcome.info
        }
    }

    /// What the detached preview hands back. A plain `Sendable` value with the message already
    /// rendered: `TransformCoordinator.message(for:)` is internal to AppCore, and the mapping is
    /// pure anyway, so it happens off the main actor with the rest of the work.
    private struct PreviewOutcome: Sendable {
        var output: String
        var info: String
    }

    /// Preview-side wording for the two failures a preset can produce. `nonisolated` because it
    /// is called from the detached task as well as from `compileError` on the main actor.
    nonisolated private static func message(for error: any Error) -> String {
        guard let error = error as? TransformError else { return "Invalid pattern" }
        switch error {
        case .invalidInput(let message): return message
        case .timeout: return "Pattern took too long on the sample (over 1 s)"
        default: return "Invalid pattern"
        }
    }
}
