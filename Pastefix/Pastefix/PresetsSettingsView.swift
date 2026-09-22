import SwiftUI
import PastefixCore
import PastefixAppCore

/// The Presets tab: a preset picker with +/− across the top, a full-width editor with a live
/// preview underneath.
///
/// Edits are made against a `draft` copy rather than straight into the store, so a half-typed
/// pattern never reaches the registry: the delegate rebuilds the transformer list on every
/// `regexPresets` change, and a preset only becomes a transform when Save writes it back — which
/// is also why **+** only makes a draft. The same copy is what Revert throws away, and the
/// discard alert is what stops a stray selection change throwing it away silently.
struct PresetsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selected: UUID?
    @State private var draft: RegexPreset?
    @State private var sample = "The quick brown fox\njumps over the lazy dog"
    @State private var preview = ""
    /// "3 matches", or why there is no preview.
    @State private var previewInfo = ""
    @State private var previewTask: Task<Void, Never>?
    /// What to do if the user confirms the discard alert. Non-nil means the alert is up.
    @State private var pending: PendingAction?

    /// The preview runs on a slice of the sample, not the whole thing: this is a live keystroke-
    /// driven path, and a user pattern's cost is theirs to choose, not ours to trust. Measured in
    /// UTF-8 bytes, like the engine's own caps — `prefix(16_384)` counts Characters, and 16 384
    /// emoji is ~65 KB, which both overstates the documented 16 KB and could walk into
    /// `preview`'s 256 KB input cap.
    private static let sampleLimit = 16_384
    /// `nonisolated` so the detached preview can read it: with `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor` a plain static would be main-actor state, which is an error in Swift 6 mode.
    nonisolated private static let previewTimeout = Duration.seconds(1)

    /// A selection change or a removal held back until the user answers the discard alert.
    private enum PendingAction: Equatable {
        case select(UUID?)
        case remove(UUID)
        case newDraft
    }

    var body: some View {
        VStack(spacing: 0) {
            chooser
            Divider()
            if let bound = Binding($draft) {
                editor(bound)
            } else {
                Text("Select or add a preset")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // `selected` and `draft` are always assigned together (see `applySelection`) rather than
        // the draft following the selection through an `onChange`: a **+** draft sets `selected`
        // to nil, and a nil-driven reload from the store would wipe the draft it just made.
        .onChange(of: draft) { _, _ in schedulePreview() }
        .onChange(of: sample) { _, _ in schedulePreview() }
        .onDisappear { previewTask?.cancel() }
        .alert("Discard unsaved changes?", isPresented: discardAlertShown) {
            Button("Discard", role: .destructive) { commitPending() }
            Button("Keep Editing", role: .cancel) { pending = nil }
        } message: {
            Text("This preset has edits that haven't been saved.")
        }
    }

    private var chooser: some View {
        HStack(spacing: 8) {
            Picker("Preset", selection: requestedSelection) {
                // The picker needs a row for "nothing saved is selected" — an unsaved draft from
                // **+**, or an empty store — or it would display the first preset while the
                // editor showed something else.
                if draft != nil && selected == nil {
                    Text("New preset (unsaved)").tag(UUID?.none)
                } else if selected == nil {
                    Text("None").tag(UUID?.none)
                }
                ForEach(settings.regexPresets) { preset in
                    Text(rowTitle(preset)).tag(Optional(preset.id))
                }
            }
            .pickerStyle(.menu)
            Button { add() } label: { Image(systemName: "plus") }
                .help("Add a preset")
            Button { requestRemove() } label: { Image(systemName: "minus") }
                .disabled(selected == nil)
                .help("Remove the selected preset")
        }
        .padding(10)
    }

    private func rowTitle(_ preset: RegexPreset) -> String {
        let name = preset.name.isEmpty ? "Untitled" : preset.name
        return preset.id == draft?.id && isDirty ? "\u{2022} \(name)" : name
    }

    private func editor(_ preset: Binding<RegexPreset>) -> some View {
        Form {
            HStack {
                TextField("Name", text: preset.name)
                if isNewDraft {
                    Text("(unsaved)").font(.caption).foregroundStyle(.secondary)
                } else if isDirty {
                    Text("\u{2022}").foregroundStyle(.secondary)
                        .help("Unsaved changes")
                }
            }
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
                Button("Save") { save(preset.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
                    // A preset that can't compile would load as a transform that throws on every
                    // use, and a nameless one would be unpickable in the palette. An empty
                    // pattern doesn't compile either, so this is also what keeps a bare **+**
                    // draft out of the store.
                    .disabled(!isSavable(preset.wrappedValue))
            }
            Text("Saved presets appear in the palette and in the Transforms tab, where they can be disabled and reordered.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    /// **+** builds a draft and selects nothing. It deliberately does not call `addPreset`: the
    /// store feeds the registry, so persisting here would put a transform named "New preset" —
    /// with a pattern that doesn't even compile — into the palette and the sidebar before the
    /// user had typed a character. Save is the only thing that writes.
    private func add() {
        guard !isDirty else { pending = .newDraft; return }
        startNewDraft()
    }

    private func startNewDraft() {
        selected = nil
        draft = RegexPreset(name: "New preset", pattern: "", replacement: "")
    }

    private func save(_ preset: RegexPreset) {
        if settings.regexPresets.contains(where: { $0.id == preset.id }) {
            settings.updatePreset(preset)
        } else {
            settings.addPreset(preset)
        }
        // Select what was just written: the draft now equals its stored copy, which is what
        // clears the dirty marker (and, for a **+** draft, the "(unsaved)" hint).
        applySelection(preset.id)
    }

    private func requestRemove() {
        guard let id = selected else { return }
        if isDirty { pending = .remove(id) } else { remove(id) }
    }

    private func remove(_ id: UUID) {
        settings.removePreset(id: id)
        // Leaving the draft for a deleted preset behind would let Save resurrect it: Save now
        // falls through to `addPreset` for an id the store doesn't have, so clearing both here
        // is load-bearing, not just tidy.
        applySelection(nil)
    }

    /// Selection changes route through here so a dirty draft can put up the alert first. The
    /// getter still reports the *current* selection, so a picker change the user declines snaps
    /// straight back on the next render — "Keep Editing" needs no restore of its own.
    private var requestedSelection: Binding<UUID?> {
        Binding(get: { selected }, set: { requestSelection($0) })
    }

    private func requestSelection(_ id: UUID?) {
        guard id != selected else { return }
        if isDirty { pending = .select(id) } else { applySelection(id) }
    }

    /// The one place `selected` moves: the draft is reloaded from the store in the same step.
    private func applySelection(_ id: UUID?) {
        selected = id
        draft = settings.regexPresets.first { $0.id == id }
    }

    private var discardAlertShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private func commitPending() {
        switch pending {
        case .select(let id): applySelection(id)
        case .remove(let id): remove(id)
        case .newDraft: startNewDraft()
        case nil: break
        }
        pending = nil
    }

    /// True once the editor's copy has diverged from what is stored — including a **+** draft,
    /// which has nothing stored at all.
    private var isDirty: Bool {
        guard let draft else { return false }
        guard let stored = settings.regexPresets.first(where: { $0.id == draft.id }) else { return true }
        return stored != draft
    }

    private var isNewDraft: Bool {
        guard let draft else { return false }
        return !settings.regexPresets.contains { $0.id == draft.id }
    }

    private func isSavable(_ preset: RegexPreset) -> Bool {
        compileError(preset) == nil && !preset.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func compileError(_ preset: RegexPreset) -> String? {
        // `NSRegularExpression` rejects "" outright, but its message ("The value “” is invalid")
        // describes a typo rather than the untouched field it actually is.
        guard !preset.pattern.isEmpty else { return "Pattern is empty" }
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
        guard let preset = draft, !preset.pattern.isEmpty else { preview = ""; previewInfo = ""; return }
        let text = Self.sampleSlice(sample)
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

    /// The first `sampleLimit` UTF-8 bytes of the sample, cut on a Character boundary so the
    /// preview never shows a `\u{FFFD}` the sample doesn't contain.
    private static func sampleSlice(_ text: String) -> String {
        guard text.utf8.count > sampleLimit else { return text }
        var out = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            if bytes + size > sampleLimit { break }
            out.append(character)
            bytes += size
        }
        return out
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
