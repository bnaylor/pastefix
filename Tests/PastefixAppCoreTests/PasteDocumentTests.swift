import Testing
import PastefixCore
@testable import PastefixAppCore

@Suite struct PasteDocumentTests {
    private func doc(_ text: String) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil))
    }

    @Test func startsWithOriginText() {
        let d = doc("hi")
        #expect(d.working == "hi")
        #expect(d.canUndo == false)
        #expect(d.canRedo == false)
    }

    @Test func nilOriginTextStartsEmpty() {
        let d = PasteDocument(origin: ClipboardSnapshot(plainText: nil, richRTFD: nil))
        #expect(d.working == "")
    }

    @Test func pushEnablesUndo() {
        var d = doc("a")
        d.pushState("b")
        #expect(d.working == "b")
        #expect(d.canUndo == true)
        d.undo()
        #expect(d.working == "a")
        #expect(d.canRedo == true)
        d.redo()
        #expect(d.working == "b")
    }

    @Test func pushTruncatesRedoTail() {
        var d = doc("a")
        d.pushState("b")
        d.pushState("c")
        d.undo()               // back to "b"
        d.pushState("d")       // truncates "c"
        #expect(d.working == "d")
        #expect(d.canRedo == false)
    }

    @Test func pushIsNoOpWhenUnchanged() {
        var d = doc("a")
        d.pushState("a")
        #expect(d.canUndo == false)
    }

    @Test func setWorkingEditsInPlace() {
        var d = doc("a")
        d.pushState("b")
        d.setWorking("b-edited")
        #expect(d.working == "b-edited")
        d.undo()
        #expect(d.working == "a")   // the edit stayed on the "b" state, not a new one
    }

    @Test func refreshResets() {
        var d = doc("a")
        d.pushState("b")
        d.refresh(origin: ClipboardSnapshot(plainText: "fresh", richRTFD: nil))
        #expect(d.working == "fresh")
        #expect(d.canUndo == false)
    }

    /// Runs the scan the scheduler would and installs it, as the app does after each event.
    private func settle(_ d: inout PasteDocument) {
        // Assigned to a local first: Swift Testing's `#expect` macro can't take the address of
        // an `inout` parameter for a mutating call written directly inside the expression.
        let applied = d.applyDetection(DetectionResult.compute(d.working), revision: d.detectionRevision)
        #expect(applied)
    }

    @Test func startsPendingAndSettlesToKinds() {
        var d = doc("https://example.com")
        #expect(d.isDetecting && d.detectionRevision == 0 && d.detectedKinds.isEmpty)
        settle(&d)
        #expect(!d.isDetecting && d.detectedKinds == [.url])
    }

    @Test func discreteEventsBumpRevisionAndResetToPending() {
        var d = doc("https://example.com"); settle(&d)
        d.pushState("{\"a\":1}")
        #expect(d.isDetecting && d.detectionRevision == 1 && d.detectedKinds.isEmpty)
        settle(&d); #expect(d.detectedKinds == [.json])
        d.undo();   #expect(d.isDetecting && d.detectionRevision == 2)
        settle(&d); #expect(d.detectedKinds == [.url])
        d.redo();   #expect(d.detectionRevision == 3)
        settle(&d); #expect(d.detectedKinds == [.json])
        d.setWorking("plain")                       // manual edit: no event
        #expect(!d.isDetecting && d.detectionRevision == 3 && d.detectedKinds == [.json])
        d.pushState("plain")                        // equal text is still an event
        #expect(d.isDetecting && d.detectionRevision == 4)
        let beforeRefresh = d.detectionRevision
        d.refresh(origin: ClipboardSnapshot(plainText: "www.example.com", richRTFD: nil))
        #expect(d.isDetecting && d.detectionRevision > beforeRefresh)
    }

    @Test func refreshRefusesAPreRefreshResult() {
        var d = doc("https://example.com")
        settle(&d)
        let preRefreshRevision = d.detectionRevision
        let preRefreshResult = DetectionResult.compute(d.working)
        d.refresh(origin: ClipboardSnapshot(plainText: "something else entirely", richRTFD: nil))
        let applied = d.applyDetection(preRefreshResult, revision: preRefreshRevision)
        #expect(!applied)
        #expect(d.isDetecting)
    }

    @Test func staleRevisionIsRefused() {
        var d = doc("https://example.com")
        let old = DetectionResult.compute(d.working)
        d.pushState("{\"a\":1}")
        // Assigned to a local first: Swift Testing's `#expect` macro can't take the address of
        // `d` for a mutating call written directly inside the negated expression.
        let staleApplied = d.applyDetection(old, revision: 0)
        #expect(!staleApplied)
        #expect(d.isDetecting && d.detectedKinds.isEmpty)
        settle(&d)
        #expect(d.detectedKinds == [.json])
        let secondApplied = d.applyDetection(old, revision: 1)
        #expect(!secondApplied, "a settled revision does not take a second result")
    }

    @Test func secretsAndSkipFlagComeFromTheResult() {
        var d = doc("AKIAIOSFODNN7EXAMPLE")
        #expect(d.secretMatches.isEmpty && !d.secretScanSkipped, "pending is neither found nor skipped")
        settle(&d)
        #expect(d.secretMatches.map(\.kind) == [.awsAccessKey] && d.detectedKinds.contains(.secret))
        let big = String(repeating: "a", count: SecretDetector.maxBytes) + " AKIAIOSFODNN7EXAMPLE"
        d.pushState(big); settle(&d)
        #expect(d.secretScanSkipped && d.secretMatches.isEmpty && !d.detectedKinds.contains(.secret))
    }

    @Test func oversizeRoundTripFlipsTheSkipFlag() {
        let big = String(repeating: "a", count: SecretDetector.maxBytes) + " AKIAIOSFODNN7EXAMPLE"
        var d = doc(big)
        settle(&d)
        #expect(d.secretScanSkipped && d.secretMatches.isEmpty)
        d.pushState("AKIAIOSFODNN7EXAMPLE")
        settle(&d)
        #expect(!d.secretScanSkipped && d.secretMatches.map(\.kind) == [.awsAccessKey])
        d.undo()
        settle(&d)
        #expect(d.secretScanSkipped && d.secretMatches.isEmpty)
    }

    @Test func computeMatchesTheOldInlineScan() {
        let r = DetectionResult.compute("see https://example.com and AKIAIOSFODNN7EXAMPLE")
        #expect(r.kinds == [.url, .secret] && r.secretMatches.count == 1 && !r.secretScanSkipped)
        #expect(DetectionResult.compute("").kinds.isEmpty)
    }

    @Test func outputModeDefaultsSurvivesPushResetsOnRefresh() {
        var d = PasteDocument(origin: ClipboardSnapshot(plainText: "a", richRTFD: nil))
        #expect(d.outputMode == .plain)
        d.outputMode = .renderedMarkdown; d.pushState("b")
        #expect(d.outputMode == .renderedMarkdown)
        d.refresh(origin: ClipboardSnapshot(plainText: "c", richRTFD: nil))
        #expect(d.outputMode == .plain)
    }
}
