import AppKit
import KeyboardShortcuts
import PastefixAppCore

/// One global shortcut per pinned snippet, named by the item id. `sync()` installs a handler when
/// an item is pinned and tears it down when it is unpinned, so an id never carries two handlers
/// (which would paste the snippet twice).
///
/// Unpinning takes the *handler* away and leaves the recorded combo in UserDefaults: the shortcut
/// is keyed to the item id, so re-pinning the same item re-registers it and the chord the user
/// chose still applies. A combo is only forgotten when its item is gone from the store entirely
/// (evicted, removed, or cleared), which `sweepOrphanedShortcuts` handles — including at launch,
/// for ids that disappeared while the app was not running.
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

    /// The `Name` prefix, and therefore the UserDefaults key prefix (`KeyboardShortcuts_` + this).
    private static let namePrefix = "snippet-"

    func sync() {
        let pinned = Set(history.pinnedItems.map(\.id))
        for id in pinned.subtracting(registered) {
            KeyboardShortcuts.onKeyUp(for: Self.name(for: id)) { [weak self] in
                self?.fire(id)
            }
        }
        for id in registered.subtracting(pinned) {
            // Handler only, deliberately no `reset`. An unpin is one unconfirmed ⌘P and the combo
            // is something the user recorded by hand; dropping it would make a mis-hit destroy
            // work rather than be undone by a second ⌘P. The name is derived from the item id, so
            // a re-pin of the same item picks the recorded combo back up, and a *different* item
            // can never inherit it.
            KeyboardShortcuts.removeHandler(for: Self.name(for: id))
        }
        registered = pinned
        sweepOrphanedShortcuts()
    }

    /// Forgets recorded combos whose item no longer exists in the store at all — evicted by the
    /// cap, removed with ⌘⌫, or wiped by Clear Everything. Those ids are never coming back (a new
    /// capture of the same text gets a new UUID), so their UserDefaults keys are pure leak: the
    /// binding is invisible in Settings, which only lists pins, yet still collides with what the
    /// user tries to record next.
    ///
    /// Run on every `sync()`, which includes the one at launch, so ids that disappeared while the
    /// app was not running (or in the gap between `unpin`'s flush and a crash) are also collected.
    private func sweepOrphanedShortcuts() {
        let live = Set(history.items.map(\.id.uuidString))
        for name in KeyboardShortcuts.storedNames
        where name.rawValue.hasPrefix(Self.namePrefix)
            && !live.contains(String(name.rawValue.dropFirst(Self.namePrefix.count))) {
            KeyboardShortcuts.reset(name)
            KeyboardShortcuts.removeHandler(for: name)
        }
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
        // `onGaveUp` covers the other half of "nothing was pasted": `paste` returns `.pasted` as
        // soon as it schedules the post, so a chain that expires — a target that never came
        // forward, modifiers still held, or one of our own windows holding key focus for the
        // whole window — would otherwise be completely silent.
        let outcome = SnippetPaster.paste(text: text,
                                          richRTFD: history.richRTFD(for: item),
                                          into: NSWorkspace.shared.frontmostApplication,
                                          onGaveUp: { NSSound.beep() })
        // Copy-only has three causes here — no Accessibility, our own panel holding the front, a
        // target that never came forward — and the hotkey path has no UI of its own to say so. A
        // beep at least distinguishes "copied, paste it yourself" from a dead keystroke. The
        // overlay path stays silent: it has the panel to report through.
        if outcome == .copiedOnly { NSSound.beep() }
    }
}
