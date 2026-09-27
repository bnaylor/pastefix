import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// #48: the image card's wording and affordances, pinned here because the card itself has no test
/// host (#68).
@Suite("ImageUploadCard")
struct ImageUploadCardTests {
    static func sanitized() throws -> SanitizedImage {
        let png = try #require(ImageUploadPreparationTests.png(width: 40, height: 20))
        return try #require(ImageSanitizer.stripped(png))
    }

    static func allStates() throws -> [ImageUploadCard.State] {
        let image = try sanitized()
        return [.preparing,
                .ready(image, hasText: false),
                .ready(image, hasText: true),
                .refused(.tooManyPixels(31_000_000)),
                .refused(.tooManyBytes(23_700_000)),
                .refused(.unusable),
                .superseded]
    }

    @Test("Return never uploads an image, in any state")
    func noStateDefaultsToUpload() throws {
        for state in try Self.allStates() {
            // `DefaultAction` has no upload case at all; this pins which of the two remain.
            let expected: ImageUploadCard.DefaultAction = state.hasText ? .cancel : .none
            #expect(ImageUploadCard.defaultAction(for: state) == expected)
            #expect(!ImageUploadCard.keyHint(for: state).contains("Upload"))
        }
    }

    @Test("text detected makes Cancel the default and says so in the footer")
    func textMakesCancelDefault() throws {
        let state = ImageUploadCard.State.ready(try Self.sanitized(), hasText: true)
        #expect(ImageUploadCard.defaultAction(for: state) == .cancel)
        #expect(ImageUploadCard.keyHint(for: state) == "↵ Cancel   esc Close")
    }

    @Test("with nothing detected there is no default action at all")
    func noTextNoDefault() throws {
        let state = ImageUploadCard.State.ready(try Self.sanitized(), hasText: false)
        #expect(ImageUploadCard.defaultAction(for: state) == .none)
        #expect(ImageUploadCard.keyHint(for: state) == "esc Close")
    }

    @Test("only a ready state can upload, and only it yields bytes")
    func onlyReadyUploads() throws {
        for state in try Self.allStates() {
            let ready: Bool
            if case .ready = state { ready = true } else { ready = false }
            #expect(ImageUploadCard.canUpload(state) == ready)
            #expect((state.sanitized != nil) == ready)
        }
    }

    @Test("the lane's nil is superseded, not a refusal or a ready state")
    func nilIsSuperseded() throws {
        #expect(ImageUploadCard.State(nil) == .superseded)
        #expect(ImageUploadCard.State(.refused(.unusable)) == .refused(.unusable))
        let image = try Self.sanitized()
        #expect(ImageUploadCard.State(.ready(image, hasText: true)) == .ready(image, hasText: true))
    }

    @Test("the send button escalates when text is detected")
    func sendTitles() {
        #expect(ImageUploadCard.sendTitle(hasText: true, isRetry: false) == "Upload without checking")
        #expect(ImageUploadCard.sendTitle(hasText: true, isRetry: true) == "Retry without checking")
        #expect(ImageUploadCard.sendTitle(hasText: false, isRetry: false) == "Upload")
        #expect(ImageUploadCard.sendTitle(hasText: false, isRetry: true) == "Retry")
    }

    @Test("the fixed lines say exactly what the spec says")
    func fixedWording() {
        #expect(ImageUploadCard.notCheckedVerdict == "Images are not checked for secrets.")
        #expect(ImageUploadCard.metadataRemoved == "Any location and camera details removed.")
        #expect(ImageUploadCard.clipboardReplaced == "The image is no longer on your clipboard.")
    }

    @Test("no wording anywhere reassures that there is no text")
    func neverReassures() throws {
        var lines = [ImageUploadCard.notCheckedVerdict, ImageUploadCard.containsText,
                     ImageUploadCard.metadataRemoved, ImageUploadCard.preparing,
                     ImageUploadCard.clipboardReplaced, ImageUploadCard.refusalDetail,
                     ImageUploadCard.supersededMessage, ImageUploadCard.sizeLine(bytes: 1000)]
        for state in try Self.allStates() {
            lines.append(ImageUploadCard.keyHint(for: state))
            lines.append(ImageUploadCard.headerDetail(for: state))
            if case .refused(let refusal) = state { lines.append(ImageUploadCard.refusal(refusal)) }
        }
        for line in lines {
            let lower = line.lowercased()
            #expect(!lower.contains("no text"), "\(line)")
            #expect(!lower.contains("no secrets"), "\(line)")
            #expect(!lower.contains("clean"), "\(line)")
        }
    }

    @Test("a pixel refusal names the figure and the limit in megapixels")
    func pixelRefusal() {
        #expect(ImageUploadCard.refusal(.tooManyPixels(31_000_000))
                == "Too large to upload — 31 MP; the limit is 25 MP.")
    }

    @Test("an unmeasurable pixel count reads as words, not a 19-digit number")
    func unmeasurablePixelRefusal() {
        let line = ImageUploadCard.refusal(.tooManyPixels(ImageBytes.unmeasurablePixels))
        #expect(line.contains("too large to measure"))
    }

    @Test("a byte refusal names the prepared size, the 16 MB limit, and points at #21")
    func byteRefusal() {
        let line = ImageUploadCard.refusal(.tooManyBytes(23_697_818))
        #expect(line == "22.6 MB after preparing; the limit is 16 MB. Uploading as JPEG (#21) would be smaller.")
    }

    @Test("an unusable image says so plainly")
    func unusableRefusal() {
        #expect(ImageUploadCard.refusal(.unusable) == "This image couldn't be prepared for upload.")
    }

    @Test("the size line states the stripped size against the limit")
    func sizeLine() {
        #expect(ImageUploadCard.sizeLine(bytes: 1_258_291) == "1.2 MB after preparing, of the 16 MB limit")
    }

    @Test("the header shows a size only once there are prepared bytes")
    func headerDetail() throws {
        let image = try Self.sanitized()
        #expect(ImageUploadCard.headerDetail(for: .preparing) == "image")
        #expect(ImageUploadCard.headerDetail(for: .refused(.unusable)) == "image")
        #expect(ImageUploadCard.headerDetail(for: .ready(image, hasText: false))
                == "image · \(HistoryFormatting.byteLabel(image.png.count))")
    }
}
