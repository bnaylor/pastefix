import Testing
import AppKit
@testable import PastefixAppCore

@Suite struct ConcealedTypeFilterTests {
    let f = ConcealedTypeFilter()
    let ctx = CaptureContext(sourceBundleID: "com.apple.Safari", recentBundleIDs: ["com.apple.Safari"])
    @Test(arguments: ConcealedTypeFilter.markers.map(\.rawValue))
    func eachMarkerRejectsBothStages(marker: String) {
        let types: [NSPasteboard.PasteboardType] = [.string, .init(marker)]
        #expect(!f.shouldRead(types: types, context: ctx))
        #expect(!f.shouldCapture(CaptureCandidate(plainText: "x"), types: types, context: ctx))
    }
    @Test func plainTypesPass() {
        #expect(f.shouldRead(types: [.string, .rtf], context: ctx))
        #expect(f.shouldCapture(CaptureCandidate(plainText: "x"), types: [.string], context: CaptureContext()))
    }
    @Test func sixMarkers() { #expect(ConcealedTypeFilter.markers.count == 6) }
}
