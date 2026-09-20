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
        d.setWorking("plain")
        #expect(d.detectedKinds == [])
        d.refresh(origin: ClipboardSnapshot(plainText: "www.example.com", richRTFD: nil))
        #expect(d.detectedKinds == [.url])
    }
}
