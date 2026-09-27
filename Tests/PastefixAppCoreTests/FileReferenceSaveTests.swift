import Testing
import Foundation
@testable import PastefixAppCore

/// #71: copying a file in Finder, summoning Pastefix and pressing ⌘S used to replace the file on
/// the clipboard with its name as text. The owner's decision (2026-09-27): an unedited Save over a
/// file copy does nothing — as macOS itself does when there is nothing it can meaningfully write.
/// Editing the text is a deliberate act and still writes.
@Suite("Save over a file reference")
struct FileReferenceSaveTests {
    func doc(fileReference: [String]?, text: String = "Report.pdf") -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil, fileReferenceTypes: fileReference))
    }

    @Test("an unedited session over a file copy would lose the file reference, so Save must not write")
    func uneditedFileCopyRefuses() {
        #expect(doc(fileReference: ["public.file-url"]).saveWouldLoseContent)
    }

    @Test("the loss is reported as the file reference, by the generic classification")
    func reportedAsFileReference() {
        let d = doc(fileReference: ["public.file-url"])
        #expect(d.origin.unreproduced(by: SavePayload(document: d)).contains(.lossIfPresent("fileReferenceTypes")))
    }

    @Test("edited text still writes — typing is a deliberate act")
    func editedWrites() {
        var d = doc(fileReference: ["public.file-url"])
        d.setWorking("Report.pdf — renamed")
        #expect(!d.saveWouldLoseContent)
    }

    @Test("no file reference: an ordinary unedited text session is unaffected")
    func noFileReference() {
        #expect(!doc(fileReference: nil).saveWouldLoseContent)
    }
}
