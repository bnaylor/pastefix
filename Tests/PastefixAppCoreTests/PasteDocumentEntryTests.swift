import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

@Suite("PasteDocument entries (Plan 20)")
struct PasteDocumentEntryTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    private let png2 = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9])
    private func imageDoc(text: String? = nil) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, imagePNG: png))
    }

    @Test("the first entry follows the init rule: image and no real text opens as an image")
    func firstEntry() {
        #expect(imageDoc().currentEntry == .image(png) && imageDoc().openedAsImage)
        #expect(imageDoc(text: "  \n").currentEntry == .image(png))
        let mixed = imageDoc(text: "caption")
        #expect(mixed.currentEntry == .text("caption") && !mixed.openedAsImage && !mixed.displaysAsImage)
        #expect(mixed.imagePNG == png, "a mixed session carries its image, as today")
    }

    @Test("an image result, then undo and redo, move the display with the entry")
    func pushImageUndoRedo() {
        var d = imageDoc()
        d.push(.image(png2))
        #expect(d.displaysAsImage && d.imagePNG == png2 && d.working == "")
        d.undo()
        #expect(d.imagePNG == png)
        d.redo()
        #expect(d.imagePNG == png2)
    }

    @Test("a text result replaces the image: Save writes the text only, and undo brings it back")
    func textReplacesImage() {
        var d = imageDoc()
        d.pushState("recognised")
        #expect(!d.displaysAsImage && d.working == "recognised" && d.imagePNG == nil)
        #expect(SavePayload(document: d).imagePNG == nil && SavePayload(document: d).text == "recognised")
        d.undo()
        #expect(d.displaysAsImage && d.imagePNG == png && SavePayload(document: d).imagePNG == png)
    }

    // pushState's guard compared text; on an image entry `working` is "" and pushing "" was
    // silently dropped.
    @Test("pushing empty text onto an image entry is a real push")
    func emptyTextOntoImage() {
        var d = imageDoc()
        d.pushState("")
        #expect(d.currentEntry == .text("") && d.canUndo)
    }

    // The TextEditor's binding calls setWorking; an IME commit or end-of-editing write can land
    // after ⌘Z has moved onto an image entry.
    @Test("a stale editor write-back on an image entry changes nothing")
    func staleWriteBack() {
        var d = imageDoc()
        d.pushState("text")
        d.undo()
        d.setWorking("late keystroke")
        #expect(d.currentEntry == .image(png) && d.working == "" && d.workingByteCount == 0)
        d.redo()
        #expect(d.working == "text")
    }

    @Test("isUnedited compares against the init rule's entry, image-first included")
    func isUnedited() {
        #expect(imageDoc().isUnedited)
        #expect(imageDoc(text: " ").isUnedited)
        var d = imageDoc(); d.push(.image(png2)); d.undo()
        #expect(!d.isUnedited, "a redo is pending")
    }

    // Output mode is document-wide and survives undo; on an image entry Save would take the
    // rendered-Markdown branch with working == "" and write empty HTML/RTF beside the PNG.
    @Test("an armed output mode is ignored on an image entry")
    func outputModeOnImage() {
        var d = imageDoc()
        d.pushState("# md")
        d.outputMode = .renderedMarkdown
        #expect(d.effectiveOutputMode == .renderedMarkdown)
        d.undo()
        #expect(d.effectiveOutputMode == .plain)
        d.redo()
        #expect(d.effectiveOutputMode == .renderedMarkdown)
    }

    // GUI pass: a stripped image looks identical to the original, so a note cleared on redo left
    // no way to tell where you were. The note belongs to the entry it describes (Plan 20).
    @Test("a note belongs to its entry: redo shows it again, undo to the original shows none")
    func noteFollowsEntry() {
        var d = imageDoc()
        #expect(d.currentNote == nil)
        d.push(.image(png2), note: "Removed location details.")
        #expect(d.currentNote == "Removed location details.")
        d.undo()
        #expect(d.currentNote == nil)
        d.redo()
        #expect(d.currentNote == "Removed location details.")
        d.undo(); d.pushState("text")          // a new branch drops the old entry and its note
        #expect(d.currentNote == nil && !d.canRedo)
    }

    @Test("byte counts count text only")
    func byteCounts() {
        var d = imageDoc()
        #expect(d.workingByteCount == 0 && !d.displaysAsLargeText)
        d.pushState("héllo")
        #expect(d.workingByteCount == "héllo".utf8.count)
    }
}
