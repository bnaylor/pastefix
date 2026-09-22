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
}
