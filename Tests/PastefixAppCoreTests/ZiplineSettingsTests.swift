import Testing
import Foundation
@testable import PastefixAppCore
@testable import PastefixCore

@MainActor
@Suite("Zipline settings")
struct ZiplineSettingsTests {
    private func store() -> SettingsStore {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        return SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("defaults are empty server, 1d expiry, no burn, txt")
    func defaults() {
        let s = store()
        #expect(s.ziplineServerURL.isEmpty)
        #expect(s.ziplineDefaultExpiry == "1d")
        #expect(s.ziplineDefaultBurnOnRead == false)
        #expect(s.ziplineDefaultExtension == "txt")
    }

    @Test("values persist across instances")
    func persists() {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = SettingsStore(defaults: defaults)
        first.ziplineServerURL = "https://zip.example.test"
        first.ziplineDefaultExpiry = "7d"
        first.ziplineDefaultBurnOnRead = true
        first.ziplineDefaultExtension = "md"

        let second = SettingsStore(defaults: defaults)
        #expect(second.ziplineServerURL == "https://zip.example.test")
        #expect(second.ziplineDefaultExpiry == "7d")
        #expect(second.ziplineDefaultBurnOnRead == true)
        #expect(second.ziplineDefaultExtension == "md")
    }

    @Test("raw expiry strings map to the enum")
    func expiryMapping() {
        #expect(SettingsStore.expiry(fromRaw: "never") == .never)
        #expect(SettingsStore.expiry(fromRaw: "7d") == .relative("7d"))
        // An unrecognised value must not become "never" — that would silently
        // turn a corrupted setting into a permanent upload.
        #expect(SettingsStore.expiry(fromRaw: "nonsense") == .relative("1d"))
    }

    @Test("the token is not a settings key")
    func tokenIsNotInDefaults() {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s = SettingsStore(defaults: defaults)
        s.ziplineServerURL = "https://zip.example.test"
        let keys = defaults.dictionaryRepresentation().keys
        #expect(!keys.contains { $0.lowercased().contains("token") })
    }
}
