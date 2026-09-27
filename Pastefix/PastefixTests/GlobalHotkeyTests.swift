import Testing
@testable import Pastefix

/// The real guard for `GlobalHotkey` is the compiler: `AppDelegate` registers each case through an
/// exhaustive switch. This only checks what can be checked without touching `.name` — the
/// `KeyboardShortcuts.Name` statics write their defaults into `the standard defaults domain`, the real
/// settings domain inside a test host.
@Suite("GlobalHotkey")
struct GlobalHotkeyTests {
    @Test("three global hotkeys, with distinct labels — collision messages name them by label")
    func labels() {
        let labels = GlobalHotkey.allCases.map(\.label)
        #expect(labels.count == 3)
        #expect(Set(labels).count == labels.count)
    }
}
