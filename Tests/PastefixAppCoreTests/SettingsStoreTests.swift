import Testing
import Foundation
@testable import PastefixAppCore

@MainActor
@Suite struct SettingsStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "pastefix.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsWhenEmpty() {
        let s = SettingsStore(defaults: freshDefaults())
        #expect(s.wrapWidth == 400)
        #expect(s.autoHideOnBlur == true)
        #expect(s.scriptsDirectoryPath.hasSuffix("/.config/pastefix/scripts"))
        #expect(s.transformEnabled.isEmpty)
        #expect(s.transformOrder.isEmpty)
    }

    @Test func writesPersistAndReload() {
        let d = freshDefaults()
        let s = SettingsStore(defaults: d)
        s.wrapWidth = 72
        s.autoHideOnBlur = false
        s.transformEnabled = ["shell:foo.sh": false]
        s.transformOrder = ["builtin.whitespace": 5]

        // A second store over the same defaults sees the persisted values.
        let s2 = SettingsStore(defaults: d)
        #expect(s2.wrapWidth == 72)
        #expect(s2.autoHideOnBlur == false)
        #expect(s2.transformEnabled["shell:foo.sh"] == false)
        #expect(s2.transformOrder["builtin.whitespace"] == 5)
    }

    @Test func scriptsDirectoryURLMatchesPath() {
        let s = SettingsStore(defaults: freshDefaults())
        s.scriptsDirectoryPath = "/tmp/pfx-scripts"
        #expect(s.scriptsDirectoryURL == URL(fileURLWithPath: "/tmp/pfx-scripts", isDirectory: true))
    }

    @Test func scriptsDirectoryPathPersists() {
        let d = freshDefaults()
        let s = SettingsStore(defaults: d)
        s.scriptsDirectoryPath = "/custom/scripts"

        // A second store over the same defaults sees the persisted path.
        let s2 = SettingsStore(defaults: d)
        #expect(s2.scriptsDirectoryPath == "/custom/scripts")
    }
}
