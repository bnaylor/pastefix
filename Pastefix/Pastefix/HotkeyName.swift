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
}
