import AppKit
import KeyboardShortcuts
import PastefixAppCore

/// One global shortcut per pinned snippet, named by the item id. Handlers live for the process
/// (the library has no unregister); an unpinned id's handler is a no-op because the lookup fails.
@MainActor
final class SnippetHotkeys {
    private let history: HistoryStore
    /// Ids whose `onKeyUp` handler has been installed. Never shrinks: the library appends
    /// handlers and cannot remove them, so re-pinning an id must not install a second one
    /// (which would paste the snippet twice).
    private var handled: Set<UUID> = []
    /// Ids currently pinned as of the last `sync()` — the enable/disable bookkeeping.
    private var active: Set<UUID> = []

    init(history: HistoryStore) { self.history = history }

    /// The shortcut name for an item. Hyphen, not a dot: KeyboardShortcuts rejects names
    /// containing "." (`isValidShortcutName`) and raises a runtime issue for them.
    static func name(for id: UUID) -> KeyboardShortcuts.Name { .init("snippet-\(id.uuidString)") }

    func sync() {
        let pinned = Set(history.pinnedItems.map(\.id))
        for id in pinned.subtracting(handled) {
            KeyboardShortcuts.onKeyUp(for: Self.name(for: id)) { [weak self] in
                self?.fire(id)
            }
            handled.insert(id)
        }
        for id in active.subtracting(pinned) {
            // Reset clears the recorded shortcut (no initial shortcut to fall back to), so the
            // surviving handler can never fire; disable keeps it unregistered until re-pinned.
            KeyboardShortcuts.reset(Self.name(for: id))
            KeyboardShortcuts.disable(Self.name(for: id))
        }
        for id in pinned.subtracting(active) { KeyboardShortcuts.enable(Self.name(for: id)) }
        active = pinned
    }

    private func fire(_ id: UUID) {
        guard let item = history.items.first(where: { $0.id == id && $0.pinned }),
              let text = item.plainText else { return }
        // The hotkey does not activate Pastefix (it is an LSUIElement agent), so the frontmost
        // app at this instant is the one the user is typing into.
        _ = SnippetPaster.paste(text: text,
                                richRTFD: history.richRTFD(for: item),
                                into: NSWorkspace.shared.frontmostApplication)
    }
}
