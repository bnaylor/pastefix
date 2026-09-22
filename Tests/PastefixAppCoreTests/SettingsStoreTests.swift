import Testing
import Foundation
@testable import PastefixAppCore
import PastefixCore

@MainActor
// `.serialized` because every test now shares one UserDefaults suite. Synchronous
// `@MainActor` bodies already cannot interleave, but the marker is what keeps that true
// if a test ever gains an `await`.
@Suite(.serialized) struct SettingsStoreTests {
    /// The one defaults suite these tests use. Deliberately a fixed name rather than a
    /// per-test UUID: a UUID suite is a new domain that `cfprefsd` flushes to
    /// ~/Library/Preferences, so every run left another `pastefix.test.<UUID>.plist`
    /// behind (hundreds had accumulated). One name means at most one file, and the
    /// teardown below removes that.
    private static let suiteName = "pastefix.test"

    /// Runs `body` against an empty suite, clearing the domain before *and* after so
    /// tests cannot see each other's writes. Safe because the tests share one suite
    /// that is both `@MainActor` and `.serialized`, so no two of them are ever inside
    /// this helper at once.
    ///
    /// Clearing the domain alone is not enough: `cfprefsd` still flushes an empty plist
    /// to disk for a suite it has seen, so the backing file is unlinked too. Every
    /// cleanup step is best-effort and must never fail a test. `cfprefsd` can still win
    /// the last race and re-flush an empty `pastefix.test.plist` after the final
    /// teardown; with a fixed name that is one reused file rather than one per test.
    private func withFreshDefaults(_ body: @MainActor (UserDefaults) -> Void) {
        let suite = Self.suiteName
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

    @Test func showSidebarDefaultsOffAndPersists() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.showSidebar == false)
            s.showSidebar = true
            #expect(SettingsStore(defaults: d).showSidebar == true)
        }
    }

    @Test func historyKeysDefaultAndClamp() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.historyEnabled == true && s.historyMaxItems == 200)
            s.historyMaxItems = 5;    #expect(s.historyMaxItems == 20)
            s.historyMaxItems = 5000; #expect(s.historyMaxItems == 1000)
            s.historyEnabled = false
            let s2 = SettingsStore(defaults: d)
            #expect(s2.historyEnabled == false && s2.historyMaxItems == 1000)
        }
    }

    @Test func exclusionsDefaultToSeedsAndEmptyStaysEmpty() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.historyExcludedBundleIDs == ExclusionSeeds.passwordManagers)
            s.historyExcludedBundleIDs = []
            #expect(SettingsStore(defaults: d).historyExcludedBundleIDs.isEmpty)
        }
    }
    @Test func addRemoveRestoreExclusions() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            s.historyExcludedBundleIDs = []
            s.addExcludedBundleID("  com.example.App ")
            s.addExcludedBundleID("COM.EXAMPLE.APP")
            s.addExcludedBundleID("")
            #expect(s.historyExcludedBundleIDs == ["com.example.App"])
            s.removeExcludedBundleID("com.example.app")
            #expect(s.historyExcludedBundleIDs.isEmpty)
            s.restoreDefaultExclusions()
            #expect(SettingsStore(defaults: d).historyExcludedBundleIDs == ExclusionSeeds.passwordManagers)
        }
    }

    @Test func regexPresetsRoundTrip() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.regexPresets.isEmpty)
            let p = RegexPreset(name: "n", pattern: "a", replacement: "b")
            s.addPreset(p)
            var q = p; q.name = "renamed"; s.updatePreset(q)
            #expect(SettingsStore(defaults: d).regexPresets == [q])
            s.removePreset(id: p.id)
            #expect(SettingsStore(defaults: d).regexPresets.isEmpty)
        }
    }
}
