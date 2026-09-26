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

/// The upload overlay's "File type" field is seeded from `ZiplineUpload.extensionSeed`, and the
/// interesting part is *when*: detection runs off the main actor (Plan 14), so
/// `PasteDocument.detectedKinds` is empty at the instant the overlay is constructed and carries
/// the answer only once `applyDetection` has landed. The overlay itself is app-target and has no
/// test coverage by design, so the rule it calls is tested here against a real `PasteDocument`
/// moving through both states.
@MainActor
@Suite("Upload extension seeding across a pending detection")
struct UploadExtensionSeedTests {
    /// Exactly what `AppModel.summon` builds and what `DetectionScheduler` later delivers.
    private func pendingThenComplete(_ text: String) -> (pending: PasteDocument, complete: PasteDocument) {
        let pending = PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, changeCount: 7))
        var complete = pending
        complete.applyDetection(DetectionResult.compute(text), revision: complete.detectionRevision)
        return (pending, complete)
    }

    /// The whole regression, in one test. Before the fix the overlay asked this question once, at
    /// `init`, where the answer is necessarily `txt`.
    @Test("a JSON buffer seeds json once detection lands, not at init")
    func jsonSeedArrivesWithTheDetectionResult() {
        let (pending, complete) = pendingThenComplete(#"{"a": 1, "b": [2, 3]}"#)
        // The state the overlay is actually constructed in: pending, so no kinds yet.
        #expect(pending.isDetecting && pending.detectedKinds.isEmpty)
        #expect(ZiplineUpload.extensionSeed(setting: "txt",
                                            detectedKinds: pending.detectedKinds,
                                            userHasEditedField: false) == "txt")
        // ...and the state a moment later, which is what the overlay now also observes.
        #expect(complete.detectedKinds.contains(.json))
        #expect(ZiplineUpload.extensionSeed(setting: "txt",
                                            detectedKinds: complete.detectedKinds,
                                            userHasEditedField: false) == "json")
    }

    @Test("a hand-typed extension is never overwritten by a late result")
    func userEditWinsOverEverything() {
        let (_, complete) = pendingThenComplete(#"{"a": 1}"#)
        // nil means "leave the field alone", and it has to hold whatever the setting says too:
        // the user is the last word, not the tiebreak.
        for setting in ["txt", "yaml", "", "   "] {
            #expect(ZiplineUpload.extensionSeed(setting: setting,
                                                detectedKinds: complete.detectedKinds,
                                                userHasEditedField: true) == nil)
        }
    }

    /// The precedence that was arrived at after a reversal: a set setting beats the detector.
    /// Only *when* the detector's answer is available changed with Plan 14.
    @Test("a configured setting still beats the detector, before and after detection")
    func settingBeatsDetector() {
        let (pending, complete) = pendingThenComplete(#"{"a": 1}"#)
        #expect(ZiplineUpload.extensionSeed(setting: "yaml",
                                            detectedKinds: pending.detectedKinds,
                                            userHasEditedField: false) == "yaml")
        #expect(ZiplineUpload.extensionSeed(setting: "yaml",
                                            detectedKinds: complete.detectedKinds,
                                            userHasEditedField: false) == "yaml")
    }

    @Test("the setting the store ships with is the one that lets the detector fill in")
    func defaultSettingIsTheDetectorsOpening() {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        let s = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        // Not hardcoded "txt": if the shipped default ever changes, the detector silently stops
        // filling anything in and this is the test that says so.
        let (_, complete) = pendingThenComplete(#"{"a": 1}"#)
        #expect(ZiplineUpload.extensionSeed(setting: s.ziplineDefaultExtension,
                                            detectedKinds: complete.detectedKinds,
                                            userHasEditedField: false) == "json")
    }

    @Test("an empty or whitespace setting counts as no preference")
    func blankSettingIsNoPreference() {
        let (_, complete) = pendingThenComplete(#"{"a": 1}"#)
        #expect(ZiplineUpload.extensionSeed(setting: "",
                                            detectedKinds: complete.detectedKinds,
                                            userHasEditedField: false) == "json")
        #expect(ZiplineUpload.extensionSeed(setting: "  \n ",
                                            detectedKinds: complete.detectedKinds,
                                            userHasEditedField: false) == "json")
    }

    /// The overlay re-asks on every detection result, so a seed that moved the field on a second
    /// call would make the control twitch under the user.
    @Test("re-asking after the answer has landed changes nothing")
    func idempotent() {
        let (_, complete) = pendingThenComplete(#"{"a": 1}"#)
        for setting in ["txt", "yaml"] {
            let first = ZiplineUpload.extensionSeed(setting: setting,
                                                    detectedKinds: complete.detectedKinds,
                                                    userHasEditedField: false)
            let second = ZiplineUpload.extensionSeed(setting: setting,
                                                     detectedKinds: complete.detectedKinds,
                                                     userHasEditedField: false)
            #expect(first == second)
        }
    }

    /// A completed detection with nothing in it is a *result*, not a pending state — and the seed
    /// for it is the same `txt` the field already holds, so the late observation is a no-op rather
    /// than a change the user sees.
    @Test("prose completes with no kinds and seeds txt")
    func proseSeedsTxt() {
        let (_, complete) = pendingThenComplete("just some prose, nothing special")
        #expect(!complete.isDetecting && complete.detectedKinds.isEmpty)
        #expect(ZiplineUpload.extensionSeed(setting: "txt",
                                            detectedKinds: complete.detectedKinds,
                                            userHasEditedField: false) == "txt")
    }
}
