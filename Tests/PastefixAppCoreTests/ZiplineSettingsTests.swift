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

    @Test("no settings key is token- or credential-shaped")
    func tokenIsNotInDefaults() {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s = SettingsStore(defaults: defaults)

        // `didSet` does not fire on the assignments `SettingsStore.init` performs on itself — so
        // a key is missing from `dictionaryRepresentation()` until something *reassigns* the
        // property, not merely because the store was constructed. The previous version of this
        // test relied on that: it set exactly one property (`ziplineServerURL`) and then checked
        // for exactly the keys that single assignment could have produced, which is a test that
        // cannot fail no matter what else the type does. Reassigning every persisted property
        // here — not just the Zipline ones — is what makes the scan below actually mean
        // something: it now covers every key `SettingsStore` can currently write, not the one key
        // an earlier version of this test happened to poke.
        //
        // This still cannot catch a future property whose own assignment is missing from this
        // list: an untouched `didSet` never runs, and a key that never runs `defaults.set` never
        // appears in `dictionaryRepresentation()` for the scan below to see, credential-shaped or
        // not. So when a new persisted property is added to `SettingsStore`, add its assignment
        // here too — this list is the guard, not just documentation of one.
        s.wrapWidth = 500
        s.autoHideOnBlur.toggle()
        s.showSidebar.toggle()
        s.scriptsDirectoryPath = "/tmp/pastefix-test-scripts"
        s.transformEnabled = ["x": false]
        s.transformOrder = ["x": 10]
        s.historyEnabled.toggle()
        s.historyMaxItems = 250
        s.historyExcludedBundleIDs = ["com.example.test"]
        s.regexPresets = [RegexPreset(name: "t", pattern: "a", replacement: "b")]
        s.ziplineServerURL = "https://zip.example.test"
        s.ziplineDefaultExpiry = "7d"
        s.ziplineDefaultBurnOnRead.toggle()
        s.ziplineDefaultExtension = "md"

        // Key names only, per the type's own contract: the token is meant to live in the
        // Keychain, under `KeychainTokenStore`, never as a `UserDefaults` key at all — so no key
        // this suite holds should even be named like a credential, whatever the corresponding
        // value is.
        let credentialWords = ["token", "secret", "password", "credential", "apikey", "auth"]
        for key in defaults.dictionaryRepresentation().keys {
            let lowered = key.lowercased()
            let hit = credentialWords.first { lowered.contains($0) }
            #expect(hit == nil, "Settings key '\(key)' looks credential-shaped (matched '\(hit ?? "")') and must not be persisted to UserDefaults.")
        }
    }
}
