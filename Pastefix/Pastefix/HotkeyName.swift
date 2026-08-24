import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global summon hotkey. Default ⌘⇧C; rebindable in Settings.
    static let summonPastefix = Self(
        "summonPastefix",
        default: .init(.c, modifiers: [.command, .shift])
    )
}
