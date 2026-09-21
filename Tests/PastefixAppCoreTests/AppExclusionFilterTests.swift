import Testing
import AppKit
@testable import PastefixAppCore

@Suite struct AppExclusionFilterTests {
    let f = AppExclusionFilter(excludedBundleIDs: ["com.1password.1password", "COM.Bitwarden.Desktop"])
    let noTypes: [NSPasteboard.PasteboardType] = [.string]
    func both(_ ctx: CaptureContext) -> (Bool, Bool) {
        (f.shouldRead(types: noTypes, context: ctx), f.shouldCapture(CaptureCandidate(plainText: "x"), types: noTypes, context: ctx))
    }
    @Test func excludedSourceRejectsBothStages() {
        #expect(both(CaptureContext(sourceBundleID: "com.1password.1password", recentBundleIDs: ["com.1password.1password"])) == (false, false))
    }
    @Test func excludedAppOnlyInRecentsRejects() {
        #expect(both(CaptureContext(sourceBundleID: "com.apple.Safari", recentBundleIDs: ["com.apple.Safari", "com.1password.1password"])) == (false, false))
    }
    @Test func matchIsCaseInsensitive() {
        #expect(f.isExcluded("com.bitwarden.desktop") && f.isExcluded("COM.1PASSWORD.1PASSWORD"))
        #expect(both(CaptureContext(sourceBundleID: "com.bitwarden.desktop", recentBundleIDs: [])) == (false, false))
    }
    @Test func unrelatedAppPasses() {
        #expect(both(CaptureContext(sourceBundleID: "com.apple.Safari", recentBundleIDs: ["com.apple.Safari"])) == (true, true))
    }
    @Test func nilSourceAndEmptyRecentsPass() { #expect(both(CaptureContext()) == (true, true)) }
    @Test func emptyListPassesEverything() {
        let e = AppExclusionFilter(excludedBundleIDs: [])
        #expect(e.shouldRead(types: noTypes, context: CaptureContext(sourceBundleID: "com.1password.1password", recentBundleIDs: ["com.1password.1password"])))
    }
}
