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

    @Test func detectedKindsTrackWorkingText() {
        var d = doc("https://example.com")
        #expect(d.detectedKinds == [.url])
        d.pushState("{\"a\":1}")
        #expect(d.detectedKinds == [.json])
        d.undo()
        #expect(d.detectedKinds == [.url])
        d.redo()
        #expect(d.detectedKinds == [.json])
        // Manual edits do not re-detect: the palette order is pinned per discrete event.
        d.setWorking("plain")
        #expect(d.detectedKinds == [.json])
        d.pushState("x")
        #expect(d.detectedKinds == [])
        d.refresh(origin: ClipboardSnapshot(plainText: "www.example.com", richRTFD: nil))
        #expect(d.detectedKinds == [.url])
    }

    @Test func secretMatchesPinnedAtDiscreteEvents() {
        var d = PasteDocument(origin: ClipboardSnapshot(plainText: "AKIAIOSFODNN7EXAMPLE", richRTFD: nil))
        #expect(d.secretMatches.map(\.kind) == [.awsAccessKey] && d.detectedKinds.contains(.secret))
        d.setWorking("plain now")                      // manual edit: not re-detected
        #expect(d.secretMatches.count == 1)
        d.pushState("plain now")                       // discrete event
        #expect(d.secretMatches.isEmpty && !d.detectedKinds.contains(.secret))
    }

    @Test func oversizeBufferIsFlaggedUnscannedNotClean() {
        // An empty `secretMatches` from a buffer that was never scanned is not a clean bill of
        // health, and the badge needs to be able to tell the two apart.
        let big = String(repeating: "a", count: SecretDetector.maxBytes) + " AKIAIOSFODNN7EXAMPLE"
        var d = PasteDocument(origin: ClipboardSnapshot(plainText: big, richRTFD: nil))
        #expect(d.secretScanSkipped && d.secretMatches.isEmpty && !d.detectedKinds.contains(.secret))
        d.pushState("AKIAIOSFODNN7EXAMPLE")                    // back under the cap
        #expect(!d.secretScanSkipped && d.secretMatches.map(\.kind) == [.awsAccessKey])
        d.undo()
        #expect(d.secretScanSkipped && d.secretMatches.isEmpty)
        #expect(!doc("small").secretScanSkipped)
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
