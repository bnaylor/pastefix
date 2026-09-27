import Testing
import AppKit
@testable import Pastefix

/// Plan 13's one defect that reached the user: ⌘⇧U scanned a stale buffer — text captured before
/// the user copied something new — and reported "No secrets found" on text nobody had examined.
/// The rule is `AppModel.uploadNeedsFreshSnapshot`.
@MainActor
@Suite("⌘⇧U: fresh snapshot or the open session")
struct UploadSnapshotTests {
    @Test("no session: always a fresh snapshot")
    func noSession() throws {
        let f = try ModelFixture(); defer { f.finish() }
        #expect(f.model.uploadNeedsFreshSnapshot())
    }

    @Test("an unedited session whose clipboard has moved on is stale — the shipped defect")
    func uneditedAndStale() throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "first")
        f.model.summon()
        f.copy(text: "the user copied this afterwards")
        #expect(f.model.uploadNeedsFreshSnapshot())
    }

    @Test("an unedited session over an unchanged clipboard stands")
    func uneditedAndCurrent() throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "first")
        f.model.summon()
        #expect(!f.model.uploadNeedsFreshSnapshot())
    }

    @Test("an edited session stands even when the clipboard has moved on: the user's edits win")
    func editedWins() throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "first")
        f.model.summon()
        f.model.setWorking("first, edited")
        f.copy(text: "copied afterwards")
        #expect(!f.model.uploadNeedsFreshSnapshot())
    }

    @Test("Pastefix's own write — the short URL after an upload — is not the user copying")
    func selfWriteIsNotACopy() throws {
        let f = try ModelFixture(); defer { f.finish() }
        f.copy(text: "first")
        f.model.summon()
        ClipboardBridge.writePlain("https://zip.example/u/abc", to: f.pasteboard)
        #expect(!f.model.uploadNeedsFreshSnapshot())
    }
}
