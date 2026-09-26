import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global summon hotkey. Default ⌘⇧C; rebindable in Settings.
    static let summonPastefix = Self(
        "summonPastefix",
        default: .init(.c, modifiers: [.command, .shift])
    )

    /// Opens the panel straight into clipboard history. Default ⌘⇧V; rebindable in Settings.
    static let summonHistory = Self("summonHistory", default: .init(.v, modifiers: [.command, .shift]))

    /// Opens the panel straight into the Zipline upload overlay. Default ⌘⇧U;
    /// rebindable in Settings. No dots in the name — `KeyboardShortcuts` will
    /// not take them (AGENTS.md, Plan 9).
    static let uploadToZipline = Self("uploadToZipline", default: .init(.u, modifiers: [.command, .shift]))

    /// Every global (non-snippet) hotkey the app registers, paired with the label its Shortcut-tab
    /// Recorder shows. The single source of truth for the Shortcut tab's collision validation
    /// (`SettingsView.validateSummon`, `.isSummonShortcut`): both walk this list instead of naming
    /// each other's names by hand, so a hotkey added here is covered by construction rather than by
    /// remembering every call site.
    static let globalHotkeys: [(name: Self, label: String)] = [
        (.summonPastefix, "Summon Pastefix"),
        (.summonHistory, "Open history"),
        (.uploadToZipline, "Upload to Zipline"),
    ]
}
