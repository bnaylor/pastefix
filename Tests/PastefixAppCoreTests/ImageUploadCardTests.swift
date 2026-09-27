import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// #48: the image card's wording and affordances, pinned here because the card itself has no test
/// host (#68).
@Suite("ImageUploadCard")
struct ImageUploadCardTests {
    /// A ready PNG, as the rule makes for a screenshot.
    static func sanitized() throws -> PreparedImage {
        let png = try #require(ImageUploadPreparationTests.png(width: 40, height: 20))
        let image = try #require(ImageSanitizer.stripped(png))
        return PreparedImage(choice: .png, chosen: image, pngAlternative: nil, pngByteCount: image.data.count)
    }

    /// A ready JPEG, with the PNG escape or forced by the cap (#21). Built from a real strip, so
    /// both images are genuine `SanitizedImage`s of the same pixels.
    static func jpeg(_ choice: ImageFormatChoice) throws -> PreparedImage {
        let png = try #require(ImageUploadPreparationTests.png(width: 40, height: 20))
        let encodings = try #require(ImageSanitizer.encodings(png))
        let jpeg = try #require(encodings.jpeg.image)
        return PreparedImage(choice: choice, chosen: jpeg,
                             pngAlternative: choice.offersPNGEscape ? encodings.png : nil,
                             pngByteCount: encodings.png.data.count)
    }

    /// A PNG sent because the JPEG could not be made (#93 review).
    static func pngAfterJPEGFailed() throws -> PreparedImage {
        let png = try #require(ImageUploadPreparationTests.png(width: 40, height: 20))
        let image = try #require(ImageSanitizer.stripped(png))
        return PreparedImage(choice: .png, chosen: image, pngAlternative: nil, pngByteCount: image.data.count,
                             jpegEncodeFailed: true)
    }

    static func allStates() throws -> [ImageUploadCard.State] {
        let image = try sanitized()
        return [.preparing,
                .ready(image, hasText: false),
                .ready(image, hasText: true),
                .refused(.tooManyPixels(31_000_000)),
                .ready(try jpeg(.jpegWithPNGEscape), hasText: false),
                .ready(try jpeg(.jpegForcedByCap), hasText: true),
                .refused(.tooManyBytes(23_700_000, .pngWithTransparency)),
                .refused(.tooManyBytes(23_700_000, .pngWithoutJPEG)),
                .refused(.tooManyBytes(17_100_000, .jpeg)),
                .ready(try pngAfterJPEGFailed(), hasText: true),
                .refused(.unusable),
                .superseded]
    }

    @Test("Return uploads only a ready image with no text detected; nothing else defaults to Upload")
    func returnUploadsOnlyReadyWithoutText() throws {
        // The owner's call (2026-09-27): a best-effort helper where Return should work, and
        // uploading a secret-bearing image is the user's responsibility when detection cannot see
        // it. Text detected keeps Cancel on Return — that is the case where secrets are likely and
        // the detector that decides it does work.
        for state in try Self.allStates() {
            let expected: ImageUploadCard.DefaultAction
            switch state {
            case .ready(_, let hasText): expected = hasText ? .cancel : .upload
            default: expected = .none
            }
            #expect(ImageUploadCard.defaultAction(for: state) == expected, "\(state)")
            #expect(ImageUploadCard.keyHint(for: state).contains("↵ Upload") == (expected == .upload))
        }
    }

    @Test("text detected makes Cancel the default and says so in the footer")
    func textMakesCancelDefault() throws {
        let state = ImageUploadCard.State.ready(try Self.sanitized(), hasText: true)
        #expect(ImageUploadCard.defaultAction(for: state) == .cancel)
        #expect(ImageUploadCard.keyHint(for: state) == "↵ Cancel   esc Close")
    }

    @Test("with nothing detected, Return uploads and the footer says so")
    func noTextReturnUploads() throws {
        let state = ImageUploadCard.State.ready(try Self.sanitized(), hasText: false)
        #expect(ImageUploadCard.defaultAction(for: state) == .upload)
        #expect(ImageUploadCard.keyHint(for: state) == "↵ Upload   esc Close")
    }

    @Test("states that cannot upload never make Upload the default")
    func noUploadDefaultWithoutBytes() {
        for state: ImageUploadCard.State in [.preparing, .refused(.unusable), .superseded] {
            #expect(ImageUploadCard.defaultAction(for: state) == .none)
            #expect(!ImageUploadCard.canUpload(state))
        }
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
            if let prepared = state.prepared {
                lines += [ImageUploadCard.formatLine(for: prepared), ImageUploadCard.formatSwitchTitle(for: prepared)].compactMap { $0 }
            }
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

    @Test("a PNG byte refusal names the size and the limit, and says why it can't be JPEG")
    func byteRefusal() {
        let line = ImageUploadCard.refusal(.tooManyBytes(23_697_818, .pngWithTransparency))
        #expect(line == "22.6 MB after preparing; the limit is 16 MB. It has transparency, so it can't be sent as JPEG.")
    }

    @Test("a JPEG byte refusal names the JPEG's size")
    func jpegByteRefusal() {
        let line = ImageUploadCard.refusal(.tooManyBytes(17_930_000, .jpeg))
        #expect(line == "17.1 MB even as JPEG; the limit is 16 MB.")
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
                == "image · \(HistoryFormatting.byteLabel(image.chosen.data.count))")
    }

    // MARK: Format (#21)

    @Test("a PNG has no format line and no switch: nothing to explain")
    func pngHasNoFormatLine() throws {
        let prepared = try Self.sanitized()
        #expect(ImageUploadCard.formatLine(for: prepared) == nil)
        #expect(ImageUploadCard.formatSwitchTitle(for: prepared) == nil)
    }

    @Test("a JPEG with the escape says both sizes and offers Send as PNG instead")
    func jpegWithEscapeWording() throws {
        let prepared = try Self.jpeg(.jpegWithPNGEscape)
        let jpeg = HistoryFormatting.byteLabel(prepared.chosen.data.count)
        let png = HistoryFormatting.byteLabel(prepared.pngByteCount)
        #expect(ImageUploadCard.formatLine(for: prepared) == "Sending as JPEG (\(jpeg); as PNG it would be \(png))")
        #expect(ImageUploadCard.formatSwitchTitle(for: prepared) == "Send as PNG instead")
    }

    @Test("Send as PNG instead switches the bytes Upload sends, and the wording with it")
    func escapeSwitchesImage() throws {
        let prepared = try Self.jpeg(.jpegWithPNGEscape)
        let png = try #require(prepared.pngAlternative)
        var state = ImageUploadCard.State.ready(prepared, hasText: false)
        #expect(state.sanitized == prepared.chosen)
        #expect(state.sanitized?.format == .jpeg)

        state.toggleFormat()
        #expect(state.sanitized == png)
        #expect(state.sanitized?.format == .png)
        let switched = try #require(state.prepared)
        let jpegLabel = HistoryFormatting.byteLabel(prepared.chosen.data.count)
        let pngLabel = HistoryFormatting.byteLabel(prepared.pngByteCount)
        #expect(ImageUploadCard.formatLine(for: switched) == "Sending as PNG (\(pngLabel); as JPEG it would be \(jpegLabel))")
        #expect(ImageUploadCard.formatSwitchTitle(for: switched) == "Send as JPEG instead")
        #expect(ImageUploadCard.headerDetail(for: state) == "image · \(pngLabel)")
        // The switch changes nothing about Return or whether Upload is enabled.
        #expect(ImageUploadCard.defaultAction(for: state) == .upload)

        state.toggleFormat()
        #expect(state.sanitized == prepared.chosen)
        #expect(ImageUploadCard.headerDetail(for: state) == "image · \(jpegLabel)")
    }

    @Test("a JPEG forced by the cap says so, and there is no escape to press")
    func forcedByCapWording() throws {
        let prepared = try Self.jpeg(.jpegForcedByCap)
        #expect(prepared.pngAlternative == nil)
        let jpeg = HistoryFormatting.byteLabel(prepared.chosen.data.count)
        let png = HistoryFormatting.byteLabel(prepared.pngByteCount)
        #expect(ImageUploadCard.formatLine(for: prepared)
                == "Sending as JPEG (\(jpeg)). As PNG it would be \(png), over the 16 MB limit")
        #expect(ImageUploadCard.formatSwitchTitle(for: prepared) == nil)
        var state = ImageUploadCard.State.ready(prepared, hasText: false)
        state.toggleFormat()
        #expect(state.sanitized == prepared.chosen)   // nothing to switch to
    }

    @Test("toggling outside a ready state does nothing")
    func toggleOutsideReady() {
        for original: ImageUploadCard.State in [.preparing, .refused(.unusable), .superseded] {
            var state = original
            state.toggleFormat()
            #expect(state == original)
        }
    }

    @Test("a failed JPEG never produces transparency wording, anywhere")
    func encodeFailedNeverSaysTransparency() throws {
        let prepared = try Self.pngAfterJPEGFailed()
        let lines = [ImageUploadCard.formatLine(for: prepared), ImageUploadCard.formatSwitchTitle(for: prepared),
                     ImageUploadCard.refusal(.tooManyBytes(20_000_000, .pngWithoutJPEG)),
                     ImageUploadCard.headerDetail(for: .ready(prepared, hasText: false))].compactMap { $0 }
        #expect(lines.count == 3)   // no switch title: there is nothing to switch to
        for line in lines { #expect(!line.lowercased().contains("transparen"), "\(line)") }
        #expect(ImageUploadCard.refusal(.tooManyBytes(20_000_000, .pngWithoutJPEG))
                == "19.1 MB as PNG; the limit is 16 MB. It couldn't also be prepared as JPEG.")
    }
}
