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

    // Plan 21: ⌘Z is the editor's typing undo in a text session (#103). While text a transform
    // produced from an image is untouched, ⌘Z restores the image instead.
    @Test("undoRestoresImage: untouched text over an image, until the user types")
    func undoRestoresImage() {
        var d = imageDoc()
        #expect(!d.undoRestoresImage, "on the image itself")
        d.pushState("recognised")
        #expect(d.undoRestoresImage)
        // Review Focus 3: a write-back of the same text (focus, end of editing) is not typing.
        d.setWorking("recognised")
        #expect(d.undoRestoresImage)
        d.setWorking("recognised!")
        #expect(!d.undoRestoresImage)
        // Review Focus 5: typing back to the recognised text still counts as edited.
        d.setWorking("recognised")
        #expect(!d.undoRestoresImage)
        let text = PasteDocument(origin: ClipboardSnapshot(plainText: "hello", richRTFD: nil))
        #expect(!text.undoRestoresImage, "a text session never restores an image")
    }

    // GUI pass (Plan 21): typing after OCR crashed the app — and, measured, typing after ANY Swift
    // transform that leaves non-ASCII text. The editor's selection indices are UTF-16; a transform's
    // String is native UTF-8; comparing a UTF-16 caret past the old end against a UTF-8 endIndex
    // passed TextRangeClamp's bounds guard, and measuring it trapped ("String index is out of
    // bounds"). `String.Index(_:within:)` traps too, so the text is stored in the editor's encoding.
    @Test("a caret from the editor's longer text is refused, not trapped, after a non-ASCII transform")
    func editorCaretAfterTransform() {
        var d = PasteDocument(origin: ClipboardSnapshot(plainText: "héllo wörld", richRTFD: nil))
        d.pushState("héllo wörld".uppercased())                      // native UTF-8, as a transform makes it
        let editor = NSString(string: d.working + "x") as String     // the editor's text, one keystroke on
        let caret = editor.endIndex..<editor.endIndex
        #expect(TextRangeClamp.remap(caret, from: d.working, to: d.working) == nil)
    }

    @Test("byte counts count text only")
    func byteCounts() {
        var d = imageDoc()
        #expect(d.workingByteCount == 0 && !d.displaysAsLargeText)
        d.pushState("héllo")
        #expect(d.workingByteCount == "héllo".utf8.count)
    }
}
