import Testing
import Foundation
@testable import PastefixAppCore

@MainActor
@Suite struct SettingsStoreTests {
    /// Runs `body` against an empty, uniquely-named UserDefaults suite and tears the
    /// suite down afterwards. Without the teardown every test run leaves a stray
    /// `pastefix.test.<UUID>.plist` behind in ~/Library/Preferences — 30+ of them had
    /// accumulated before this was fixed.
    ///
    /// Clearing the domain alone is not enough: `cfprefsd` still flushes an empty
    /// plist to disk for a suite it has seen, so the backing file is unlinked too.
    /// Both cleanup steps are best-effort and must never fail a test.
    private func withFreshDefaults(_ body: @MainActor (UserDefaults) -> Void) {
        let suite = "pastefix.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer {
            d.removePersistentDomain(forName: suite)
            d.synchronize()
            UserDefaults.standard.removeSuite(named: suite)
            let plist = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        body(d)
    }

    @Test func defaultsWhenEmpty() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.wrapWidth == 400)
            #expect(s.autoHideOnBlur == true)
            #expect(s.scriptsDirectoryPath.hasSuffix("/.config/pastefix/scripts"))
            #expect(s.transformEnabled.isEmpty)
            #expect(s.transformOrder.isEmpty)
        }
    }

    @Test func writesPersistAndReload() {
        withFreshDefaults { d in
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
    }

    @Test func scriptsDirectoryURLMatchesPath() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            s.scriptsDirectoryPath = "/tmp/pfx-scripts"
            #expect(s.scriptsDirectoryURL == URL(fileURLWithPath: "/tmp/pfx-scripts", isDirectory: true))
        }
    }

    @Test func scriptsDirectoryPathPersists() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            s.scriptsDirectoryPath = "/custom/scripts"

            // A second store over the same defaults sees the persisted path.
            let s2 = SettingsStore(defaults: d)
            #expect(s2.scriptsDirectoryPath == "/custom/scripts")
        }
    }

    @Test func resetScriptsDirectoryRestoresDefault() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            s.scriptsDirectoryPath = "/tmp/custom"
            #expect(s.scriptsDirectoryPath == "/tmp/custom")
            s.resetScriptsDirectoryToDefault()
            #expect(s.scriptsDirectoryPath.hasSuffix("/.config/pastefix/scripts"))
            #expect(s.scriptsDirectoryPath == SettingsStore.defaultScriptsPath)
        }
    }
}
