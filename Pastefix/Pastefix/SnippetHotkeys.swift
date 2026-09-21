import AppKit
import KeyboardShortcuts
import PastefixAppCore

/// One global shortcut per pinned snippet, named by the item id. `sync()` installs a handler when
/// an item is pinned and tears it down when it is unpinned, so an id never carries two handlers
/// (which would paste the snippet twice).
@MainActor
final class SnippetHotkeys {
    private let history: HistoryStore
    /// Ids with a live handler, as of the last `sync()`.
    private var registered: Set<UUID> = []

    init(history: HistoryStore) { self.history = history }

    /// The shortcut name for an item. Hyphen, not a dot: KeyboardShortcuts rejects names
    /// containing "." (`isValidShortcutName`) and raises a runtime issue for them.
    ///
    /// This is also a persistence contract — the name becomes the UserDefaults key
    /// `KeyboardShortcuts_snippet-<uuid>`, so changing the format orphans every recorded shortcut.
    static func name(for id: UUID) -> KeyboardShortcuts.Name { .init("snippet-\(id.uuidString)") }

    func sync() {
        let pinned = Set(history.pinnedItems.map(\.id))
        for id in pinned.subtracting(registered) {
            KeyboardShortcuts.onKeyUp(for: Self.name(for: id)) { [weak self] in
                self?.fire(id)
            }
        }
        for id in registered.subtracting(pinned) {
            // Reset first: `removeHandler` drops the handler but leaves the recorded shortcut in
            // UserDefaults, so a re-pin would inherit a binding the user never re-chose.
            KeyboardShortcuts.reset(Self.name(for: id))
            KeyboardShortcuts.removeHandler(for: Self.name(for: id))
        }
        registered = pinned
    }

    private func fire(_ id: UUID) {
        guard let item = history.items.first(where: { $0.id == id && $0.pinned }) else { return }
        // An image-only pin has nothing to paste as text, and `SnippetPaster` must never be handed
        // an empty string: it would clear the clipboard and post a ⌘V that deletes the target's
        // selection. Images are refused at the pin gate now, but a pin recorded before that fix
        // can still reach here, and a bound shortcut that does nothing at all is worse than a beep.
        guard item.hasText, let text = item.plainText else { NSSound.beep(); return }
        // The hotkey itself does not activate Pastefix, but our panel might already be up
        // (`PanelController.show()` calls `NSApp.activate`), in which case the frontmost app is
        // us. `SnippetPaster` refuses that target rather than typing into our own editor or
        // search field; otherwise the frontmost app is the one the user is typing into.
        let outcome = SnippetPaster.paste(text: text,
                                          richRTFD: history.richRTFD(for: item),
                                          into: NSWorkspace.shared.frontmostApplication)
        // Copy-only has three causes here — no Accessibility, our own panel holding the front, a
        // target that never came forward — and the hotkey path has no UI of its own to say so. A
        // beep at least distinguishes "copied, paste it yourself" from a dead keystroke. The
        // overlay path stays silent: it has the panel to report through.
        if outcome == .copiedOnly { NSSound.beep() }
    }
}
