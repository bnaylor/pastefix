import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global summon hotkey. Default ⌘⇧C; rebindable in Settings.
    static let summonPastefix = Self(
        "summonPastefix",
        initial: .init(.c, modifiers: [.command, .shift])
    )

    /// Opens the panel straight into clipboard history. Default ⌘⇧V; rebindable in Settings.
    static let summonHistory = Self("summonHistory", initial: .init(.v, modifiers: [.command, .shift]))

    /// Opens the panel straight into the Zipline upload overlay. Default ⌘⇧U;
    /// rebindable in Settings. No dots in the name — `KeyboardShortcuts` will
    /// not take them (AGENTS.md, Plan 9).
    static let uploadToZipline = Self("uploadToZipline", initial: .init(.u, modifiers: [.command, .shift]))

    /// Every global (non-snippet) hotkey's name and label, derived from `GlobalHotkey` so there is
    /// one list. The Shortcut tab's collision validation walks it.
    static var globalHotkeys: [(name: Self, label: String)] {
        GlobalHotkey.allCases.map { ($0.name, $0.label) }
    }
}

/// The app's global (non-snippet) hotkeys, as one closed set (#68).
///
/// The third hotkey once shipped with no recorder in Settings, because the recorders, the
/// registrations and the collision validation were three hand-written lists and only one was
/// updated. Everything now derives from this enum:
/// - the Shortcut tab builds one recorder per case (`SettingsView.shortcut`), so a case always has one;
/// - `AppDelegate` registers each case through an exhaustive `switch`, so a new case does not
///   compile until it has an action;
/// - collision validation walks `KeyboardShortcuts.Name.globalHotkeys`, derived from `allCases`.
/// That is the fix, and it is structural rather than tested: a test would have to touch the
/// `KeyboardShortcuts.Name` statics, which write their defaults into `UserDefaults.standard` — the
/// real settings domain, inside a test host.
enum GlobalHotkey: CaseIterable {
    case summon
    case history
    case upload

    var name: KeyboardShortcuts.Name {
        switch self {
        case .summon: .summonPastefix
        case .history: .summonHistory
        case .upload: .uploadToZipline
        }
    }

    /// The recorder's label and the name a collision message gives this hotkey.
    var label: String {
        switch self {
        case .summon: "Summon Pastefix"
        case .history: "Open history"
        case .upload: "Upload to Zipline"
        }
    }

    /// Shown under the recorder, where one helps.
    var caption: String? {
        switch self {
        case .summon: "Global hotkey to summon the panel from any app."
        case .history, .upload: nil
        }
    }
}
