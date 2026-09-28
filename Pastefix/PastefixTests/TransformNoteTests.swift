import Testing
import AppKit
import PastefixCore
import PastefixAppCore
@testable import Pastefix

private struct Noting: ImageTransformer {
    let id = "test.noting"; let name = "Noting"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.noting")
    let result: TransformOutput
    func transformImage(_ png: Data) throws -> TransformOutput { result }
}

private struct Failing: ImageTransformer {
    let id = "test.failing"; let name = "Failing"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.failing")
    func transformImage(_ png: Data) throws -> TransformOutput { throw TransformError.invalidInput("nope") }
}

@MainActor
@Suite("the transform note (Plan 20)")
struct TransformNoteTests {
    @Test("a note appears after an apply, follows its entry through undo and redo, and a new session clears it")
    func lifecycle() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        let other = try #require(Pixels.encoded(width: 30, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        f.model.apply(Noting(result: .image(other, note: "Removed location details.")))
        #expect(await f.eventually { f.model.transformNote == "Removed location details." })
        #expect(f.model.document?.imagePNG == other)
        f.model.undo()
        #expect(f.model.transformNote == nil, "undo makes the sentence false")
        #expect(f.model.document?.imagePNG == png)

        f.model.apply(Noting(result: .nothingToDo("Nothing to remove.")))
        #expect(await f.eventually { f.model.transformNote == "Nothing to remove." })
        #expect(f.model.errorMessage == nil && f.model.noticeMessage == nil)
        f.model.redo()
        #expect(f.model.transformNote == "Removed location details.", "redo lands on the entry the note describes")
        f.model.apply(Noting(result: .nothingToDo("again")))
        #expect(await f.eventually { f.model.transformNote == "again" })
        f.model.beginSession(from: ClipboardSnapshot(plainText: "new", richRTFD: nil))
        #expect(f.model.transformNote == nil)
    }

    // #104 review: `apply` cleared the note and only a noted outcome set it again, so a failed
    // apply on the stripped entry dropped "Removed location…" though that entry was still current.
    @Test("an apply that doesn't move the entry leaves that entry's note")
    func failedApplyKeepsNote() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        let other = try #require(Pixels.encoded(width: 30, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        f.model.apply(Noting(result: .image(other, note: "Removed location details.")))
        #expect(await f.eventually { f.model.transformNote == "Removed location details." })
        f.model.apply(Failing())
        #expect(await f.eventually { f.model.errorMessage != nil })
        #expect(f.model.transformNote == "Removed location details.")
    }

    @Test("Save on an image entry ignores an armed output mode")
    func saveIgnoresArmedMode() async throws {
        let f = try ModelFixture(); defer { f.finish() }
        let png = try #require(Pixels.encoded(width: 20, height: 10, type: "public.png"))
        f.model.beginSession(from: ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png))
        f.model.apply(Noting(result: .text("# heading")))
        #expect(await f.eventually { f.model.document?.working == "# heading" })
        f.model.apply(MarkdownToRich())
        #expect(await f.eventually { f.model.isRichOutputArmed })
        f.model.undo()
        #expect(!f.model.isRichOutputArmed, "the badge hides on an image entry")
        f.model.save()
        let types = f.pasteboard.types ?? []
        #expect(types.contains(.png) && !types.contains(.rtf) && !types.contains(.html))
    }
}
