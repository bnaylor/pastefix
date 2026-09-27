import Testing
import CoreGraphics
import PastefixCore
@testable import PastefixAppCore

/// #93 review: the ⌘⇧U image card's worst case fits the shortest panel, as arithmetic over the
/// constants the overlay itself lays out with (`UploadCardLayout` — the overlay holds no copies).
@Suite("UploadCardLayout")
struct UploadCardLayoutTests {
    static let panel = UploadCardLayout.minPanelHeight

    /// Every image-card verdict the overlay can show.
    static func imageStates() throws -> [(String, ImageUploadCard.State)] {
        var switched = try ImageUploadCardTests.jpeg(.jpegWithPNGEscape)
        switched.toggleFormat()
        var states: [(String, ImageUploadCard.State)] = [
            ("preparing", .preparing),
            ("refused", .refused(.tooManyBytes(20_000_000, .jpeg))),
            ("superseded", .superseded),
        ]
        for hasText in [false, true] {
            states += [
                ("png text=\(hasText)", .ready(try ImageUploadCardTests.sanitized(), hasText: hasText)),
                ("jpeg+escape text=\(hasText)", .ready(try ImageUploadCardTests.jpeg(.jpegWithPNGEscape), hasText: hasText)),
                ("switched to png text=\(hasText)", .ready(switched, hasText: hasText)),
                ("jpeg forced text=\(hasText)", .ready(try ImageUploadCardTests.jpeg(.jpegForcedByCap), hasText: hasText)),
                ("png after failed jpeg text=\(hasText)", .ready(try ImageUploadCardTests.pngAfterJPEGFailed(), hasText: hasText)),
            ]
        }
        return states
    }

    static func bottom(_ state: ImageUploadCard.State, banner: Bool) -> CGFloat {
        UploadCardLayout.cardBottom(panelHeight: panel,
                                    verdictHeight: UploadCardLayout.imageVerdictHeight(for: state),
                                    bannerHeight: UploadCardLayout.bannerHeight(shown: banner),
                                    contentHeight: UploadCardLayout.imageOptionsHeight)
    }

    @Test("every image-card combination, banner or not, ends clear of the shortest panel's bottom")
    func everyImageCombinationFits() throws {
        for (name, state) in try Self.imageStates() {
            for banner in [false, true] {
                let bottom = Self.bottom(state, banner: banner)
                #expect(bottom + UploadCardLayout.minCardBottomMargin <= Self.panel,
                        "\(name), banner \(banner): card ends at \(bottom) of \(Self.panel)")
            }
        }
    }

    @Test("the worst case — banner, text, JPEG row with its escape — is pinned by the sum")
    func worstCaseSum() throws {
        let state = ImageUploadCard.State.ready(try ImageUploadCardTests.jpeg(.jpegWithPNGEscape), hasText: true)
        let worst = try Self.imageStates().map { Self.bottom($0.1, banner: true) }.max()
        #expect(Self.bottom(state, banner: true) == worst)
        // Spelled out, so a changed term shows up here and not only as a failed inequality:
        // padding 12 + chrome 97 + scroll floor 44 + verdict (53 + text 22 + format row 24)
        // + action 60 + banner 56 = 368, leaving 12 of 380.
        let sum = UploadCardLayout.minCardTopPadding + UploadCardLayout.cardChromeHeight + UploadCardLayout.minScrollHeight
            + UploadCardLayout.imageReadyBaseHeight + UploadCardLayout.imageRowHeight + UploadCardLayout.imageFormatRowHeight
            + UploadCardLayout.actionBlockHeight + UploadCardLayout.bannerBlockHeight
        #expect(Self.bottom(state, banner: true) == sum)
        #expect(sum + UploadCardLayout.minCardBottomMargin <= Self.panel)
    }

    @Test("the format row replaces the size line; it is never budgeted beside it")
    func formatRowReplacesSizeLine() throws {
        let png = UploadCardLayout.imageVerdictHeight(for: .ready(try ImageUploadCardTests.sanitized(), hasText: false))
        let jpeg = UploadCardLayout.imageVerdictHeight(for: .ready(try ImageUploadCardTests.jpeg(.jpegWithPNGEscape), hasText: false))
        #expect(png == UploadCardLayout.imageReadyBaseHeight + UploadCardLayout.imageSizeLineHeight)
        #expect(jpeg == UploadCardLayout.imageReadyBaseHeight + UploadCardLayout.imageFormatRowHeight)
    }
}

/// #93 review: the text card's worst case fits too — it used to end 1pt past the 380pt panel.
@Suite("UploadCardLayout text card")
struct UploadCardLayoutTextTests {
    static let panel = UploadCardLayout.minPanelHeight

    /// Every text-card verdict, including findings from one kind up to more kinds than the
    /// detector has (the per-kind lines only grow the scroll content, never the pinned side).
    static let verdicts: [UploadCardLayout.TextVerdict] =
        [.quiet, .scanRow, .refusedTooLarge] + (1...20).map { .findings(kinds: $0) }

    static func bottom(_ verdict: UploadCardLayout.TextVerdict, banner: Bool) -> CGFloat {
        UploadCardLayout.cardBottom(panelHeight: panel,
                                    verdictHeight: UploadCardLayout.textVerdictHeight(for: verdict),
                                    bannerHeight: UploadCardLayout.bannerHeight(shown: banner),
                                    contentHeight: UploadCardLayout.textContentHeight(for: verdict))
    }

    @Test("every text-card combination, banner or not, ends clear of the shortest panel's bottom")
    func everyTextCombinationFits() {
        for verdict in Self.verdicts {
            for banner in [false, true] {
                let bottom = Self.bottom(verdict, banner: banner)
                #expect(bottom + UploadCardLayout.minCardBottomMargin <= Self.panel,
                        "\(verdict), banner \(banner): card ends at \(bottom) of \(Self.panel)")
            }
        }
    }

    @Test("the text card's worst case — findings plus banner — is pinned by the sum")
    func textWorstCaseSum() {
        let worst = Self.verdicts.flatMap { v in [false, true].map { Self.bottom(v, banner: $0) } }.max()
        // padding 12 + chrome 97 + scroll floor 44 + findings 96 + action 60 + banner 56 = 365,
        // leaving 15 of 380.
        let sum = UploadCardLayout.minCardTopPadding + UploadCardLayout.cardChromeHeight + UploadCardLayout.minScrollHeight
            + UploadCardLayout.findingsChromeHeight + UploadCardLayout.actionBlockHeight + UploadCardLayout.bannerBlockHeight
        #expect(Self.bottom(.findings(kinds: 2), banner: true) == sum)
        #expect(worst == sum)
        #expect(sum + UploadCardLayout.minCardBottomMargin <= Self.panel)
    }

    @Test("findings grow the scroll content by a line per kind plus the caption, and nothing pinned")
    func findingsGrowOnlyTheScrollContent() {
        #expect(UploadCardLayout.textContentHeight(for: .scanRow) == UploadCardLayout.optionsHeight)
        #expect(UploadCardLayout.textContentHeight(for: .findings(kinds: 3))
                == UploadCardLayout.optionsHeight + 4 * UploadCardLayout.findingLineHeight + UploadCardLayout.findingKindsGap)
        #expect(UploadCardLayout.textVerdictHeight(for: .findings(kinds: 1))
                == UploadCardLayout.textVerdictHeight(for: .findings(kinds: 7)))
    }
}
