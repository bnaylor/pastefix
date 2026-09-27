import Testing
import AppKit
import PastefixAppCore
@testable import Pastefix

/// #71 against a real (private) pasteboard, a real summon and the real `save()`: an unedited Save
/// over a copied file writes nothing, so the file stays on the clipboard.
@MainActor
@Suite("Save over a copied file (#71)")
struct FileCopySaveTests {
    /// Finder's shape for a copied file: its name as text, a file reference, and an icon.
    func copyFinderFile(_ f: ModelFixture) throws {
        let icon = try #require(Pixels.encoded(width: 32, height: 32, type: "public.tiff"))
        f.copy([.string: Data("Report.pdf".utf8), .fileURL: Data("file:///.file/id=1.2".utf8),
                NSPasteboard.PasteboardType("com.apple.icns"): Data([0]), .tiff: icon])
    }

    @Test("an unedited ⌘S over a Finder file copy writes nothing — the file stays on the clipboard")
    func uneditedFinderCopy() throws {
        let f = try ModelFixture(); defer { f.finish() }
        try copyFinderFile(f)
        f.model.summon()
        #expect(f.model.document?.origin.fileReferenceTypes != nil)   // fixture sanity
        let before = f.pasteboard.changeCount
        f.model.save()
        #expect(f.pasteboard.changeCount == before)
        #expect(f.pasteboard.types?.contains(.fileURL) == true)
    }

    @Test("an unedited ⌘S over a Photos-shaped copy writes nothing either")
    func uneditedPhotosCopy() throws {
        let f = try ModelFixture(); defer { f.finish() }
        let tiff = try #require(Pixels.encoded(width: 40, height: 30, type: "public.tiff"))
        let jpeg = try #require(Pixels.encoded(width: 40, height: 30, type: "public.jpeg"))
        f.copy([.fileURL: Data("file:///.file/id=3.4".utf8), NSPasteboard.PasteboardType("public.jpeg"): jpeg, .tiff: tiff])
        f.model.summon()
        #expect(f.model.document?.displaysAsImage == true)            // #78: it is an image session
        let before = f.pasteboard.changeCount
        f.model.save()
        #expect(f.pasteboard.changeCount == before)
    }

    @Test("edited text over a file copy does write — typing is a deliberate act")
    func editedWrites() throws {
        let f = try ModelFixture(); defer { f.finish() }
        try copyFinderFile(f)
        f.model.summon()
        f.model.setWorking("Report — final.pdf")
        f.model.save()
        #expect(f.pasteboard.string(forType: .string) == "Report — final.pdf")
    }
}
