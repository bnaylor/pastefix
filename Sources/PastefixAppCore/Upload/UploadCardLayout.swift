import CoreGraphics

/// The ⌘⇧U overlay card's height budget, as values and pure functions (#93 review).
///
/// The overlay (`UploadOverlayView`, app target, no test host) lays the card out with these
/// constants and calls these functions — it holds **no copies** of them, which is what lets
/// `UploadCardLayoutTests` pin the worst case: a row that grows here grows on screen, and a
/// combination that no longer fits fails a test instead of a GUI pass. The derivation of each
/// term and the on-screen measurements are in the overlay's `scrollHeight(forPanelHeight:)`
/// comment.
///
/// Everything outside the scroll region is pinned. Under height pressure the card gives up, in
/// order: the top padding (40 → `minCardTopPadding`), the bottom margin, then the option rows,
/// which scroll down to `minScrollHeight`. The verdict and the action row are never squeezed.
public enum UploadCardLayout {
    /// The panel's shortest content height. `PanelMetrics.minContentHeight` is this value — one
    /// number, so the budget cannot be checked against a panel size the app no longer uses.
    public static let minPanelHeight: CGFloat = 380

    /// How much of `cardBottomMargin` the worst combination must still leave clear at
    /// `minPanelHeight`, text card or image card — the bottom counterpart of `minCardTopPadding`.
    /// Asserted by
    /// `UploadCardLayoutTests`, not enforced by layout: it is the budget's promise.
    public static let minCardBottomMargin: CGFloat = 12

    /// Whitespace above the card, and the **first thing given up under height pressure**: it is
    /// the only term in the whole budget with nothing inside it. See
    /// `cardTopPadding(panelHeight:verdictHeight:bannerHeight:)`, which walks it down to `minCardTopPadding` before
    /// anything with content in it is squeezed.
    public static let cardTopPadding: CGFloat = 40
    /// How close to the panel's top edge the card is allowed to get. Not zero: a card flush
    /// against the edge reads as a sheet that failed to lay out rather than a floating card.
    public static let minCardTopPadding: CGFloat = 12
    /// Kept clear below the card so it never sits flush against the panel's bottom edge — and,
    /// more to the point, so the height budget below stops short of it. Given up second, after
    /// the top padding: also whitespace, but whitespace at the edge the buttons are nearest.
    public static let cardBottomMargin: CGFloat = 24
    /// Header block (46 for the title row, plus 18 for the source line under it — a `.caption` is
    /// 10pt on macOS, so ~13pt of line box plus the 2pt `VStack` spacing, reserved at 18 so this
    /// errs towards over-reserving like every other term here), three dividers (3), footer (30).
    public static let cardChromeHeight: CGFloat = 97
    /// The action row and its padding (12 above, 12 below, a ~22pt button between: ~46pt
    /// measured, budgeted at 60). Pinned below the scroll region, never inside it: an Upload or
    /// Cancel button that can be scrolled out of reach is the one thing a height budget must not
    /// produce. The failure banner shares this block and is budgeted separately below — it used
    /// to be exempt from the budget entirely, which was a bug; see `scrollHeight(panelHeight:verdictHeight:bannerHeight:contentHeight:)`.
    public static let actionBlockHeight: CGFloat = 60
    /// What the failure banner adds to the action block when there is one. `errorBanner` is
    /// `.callout` at `lineLimit(3)` — ~16pt a line, so 48 at worst — plus the 8pt `VStack`
    /// spacing between it and the action row.
    ///
    /// Budgeted at the worst case rather than measured per message, so the estimate can only
    /// over-reserve. Over-reserving on a one-line banner leaves ~32pt of panel unused below the
    /// card, which nobody can see; under-reserving pushes Retry and Cancel past the window's
    /// bottom edge, which is exactly what this constant exists to stop.
    public static let bannerBlockHeight: CGFloat = 56
    /// The three option rows, their spacings, and the scroll region's own 12pt padding top and
    /// bottom. No divider term any more: the one that used to sit between the options and the
    /// secret block moved above the per-kind lines, and is only present when there are any
    /// (`findingKindsGap`). These rows are what the region gives up first, because they are the
    /// only thing in the card that can be changed again at any time.
    public static let optionsHeight: CGFloat = 122
    /// One "Checking for secrets…" / "No secrets found" line, plus the 8pt spacing below it — the
    /// pinned verdict's whole height in those two states.
    public static let scanRowHeight: CGFloat = 28
    /// The pinned verdict when findings exist: the "N possible secrets" label, the disposition
    /// radio group, its caption, their spacings, and the 8pt gap to the banner/action row below.
    /// Independent of how many kinds were found — that part lives in the scroll region — which is
    /// the property that makes this safe to pin at all.
    ///
    /// **96, measured, not 112** (#93 review). The AX pass at 380pt measured this block at 79pt
    /// (label top 160 to caption bottom 239, with two kinds and with seven — identical), so 87 with
    /// the gap; 96 keeps 9pt of reserve. At 112 the text card's worst case (findings + banner)
    /// ended 1pt past the panel.
    public static let findingsChromeHeight: CGFloat = 96
    /// The over-cap refusal: a two-line `.callout` label (~16pt a line) over a two-line
    /// `.caption` (~13pt), plus the 4pt spacing between them and the 8pt gap to the action row
    /// below. Budgeted at both lines of each, like `bannerBlockHeight`, so the estimate can only
    /// over-reserve — this row is pinned, and the one thing it must never do is push the action
    /// row off a short panel.
    public static let refusalRowHeight: CGFloat = 70
    /// One per-kind line in the scroll region, and the "Found:" caption above them.
    public static let findingLineHeight: CGFloat = 16
    /// The divider and spacings between the per-kind lines and the option rows under them.
    public static let findingKindsGap: CGFloat = 11
    /// The floor on the scroll region: about one option row plus enough height to be scrollable.
    ///
    /// Reaching it means the card is taller than the budget wanted, and at the panel's 380pt
    /// minimum with findings *and* a failure banner it is reached (35pt available against this 44, with findingsChromeHeight at 96).
    /// That is the deliberate outcome: the option rows become something to scroll to rather than
    /// something to read at a glance, and the verdict, the choice and the buttons are untouched.
    /// It must stay big enough to scroll — a region of zero height cannot be scrolled, and the
    /// expiry control is precisely what a `1001 bad options[deletes-at]` failure needs the user to
    /// reach. It exists at all so the arithmetic cannot produce a negative height.
    public static let minScrollHeight: CGFloat = 44
    /// The image card's scroll region: Expires and Burn, no "File type" row. Two ~26pt rows, the
    /// 10pt spacing between them and the region's 12pt padding top and bottom (86), rounded up —
    /// derived the same way as `optionsHeight`'s three rows.
    public static let imageOptionsHeight: CGFloat = 88
    /// One pinned image row: a `.callout` `Label` (~16pt, a symbol can make it 17) plus the 6pt
    /// `VStack` spacing. Also what "This image contains text" adds when it is shown.
    public static let imageRowHeight: CGFloat = 22
    /// The preparing block: the not-checked verdict and the spinner row (a small `ProgressView`
    /// is 16pt), each a row, plus the 8pt gap: 52.
    public static let imagePreparingHeight: CGFloat = 52
    /// The ready block's fixed part: the not-checked verdict and the "removed" line (a row each)
    /// and the 8pt gap to the banner/action row — 52, budgeted at 53. Below them goes *either*
    /// the size line or the format row, never both.
    public static let imageReadyBaseHeight: CGFloat = 53
    /// The size caption (~13pt) plus the 6pt `VStack` spacing. With `imageReadyBaseHeight`, the
    /// 72 the whole ready block was budgeted at before #21.
    public static let imageSizeLineHeight: CGFloat = 19
    /// The format row (#21): a `.caption` line beside a `.link` button in `.caption` (~16pt
    /// together) plus the 6pt `VStack` spacing, budgeted at 24. It **replaces** the size line —
    /// it states the size itself — which is what keeps the worst case inside the panel.
    public static let imageFormatRowHeight: CGFloat = 24


    // MARK: The arithmetic

    /// The top padding: full `cardTopPadding` when the pinned blocks plus a floor-height scroll
    /// region fit under it, otherwise walked down, never below `minCardTopPadding`.
    public static func cardTopPadding(panelHeight: CGFloat, verdictHeight: CGFloat, bannerHeight: CGFloat) -> CGFloat {
        let pinned = cardChromeHeight + minScrollHeight + verdictHeight + actionBlockHeight + bannerHeight + cardBottomMargin
        return min(cardTopPadding, max(minCardTopPadding, panelHeight - pinned))
    }

    /// The scroll region's height: the smaller of what its content wants and what is left, never
    /// below `minScrollHeight`.
    public static func scrollHeight(panelHeight: CGFloat, verdictHeight: CGFloat, bannerHeight: CGFloat,
                                    contentHeight: CGFloat) -> CGFloat {
        let available = max(minScrollHeight,
                            panelHeight - cardTopPadding(panelHeight: panelHeight, verdictHeight: verdictHeight, bannerHeight: bannerHeight)
                                - cardBottomMargin - cardChromeHeight - verdictHeight - actionBlockHeight - bannerHeight)
        return min(contentHeight, available)
    }

    /// Where the card's bottom edge lands, measured from the panel's top.
    public static func cardBottom(panelHeight: CGFloat, verdictHeight: CGFloat, bannerHeight: CGFloat,
                                  contentHeight: CGFloat) -> CGFloat {
        cardTopPadding(panelHeight: panelHeight, verdictHeight: verdictHeight, bannerHeight: bannerHeight)
            + cardChromeHeight
            + scrollHeight(panelHeight: panelHeight, verdictHeight: verdictHeight, bannerHeight: bannerHeight,
                           contentHeight: contentHeight)
            + verdictHeight + actionBlockHeight + bannerHeight
    }

    public static func bannerHeight(shown: Bool) -> CGFloat {
        shown ? bannerBlockHeight : 0
    }

    /// The text card's pinned verdict, as the budget sees it (`UploadOverlayView.textVerdict`
    /// maps its scan state onto this).
    public enum TextVerdict: Equatable, Sendable {
        /// Scanning, inside the 150ms before the progress line appears: nothing drawn.
        case quiet
        /// "Checking for secrets…" or the all-clear line.
        case scanRow
        /// Findings: the pinned chrome, plus `kinds` per-kind lines in the scroll region.
        case findings(kinds: Int)
        /// Over the upload cap: the two-line refusal.
        case refusedTooLarge
    }

    public static func textVerdictHeight(for verdict: TextVerdict) -> CGFloat {
        switch verdict {
        case .quiet: return 0
        case .scanRow: return scanRowHeight
        case .findings: return findingsChromeHeight
        case .refusedTooLarge: return refusalRowHeight
        }
    }

    /// What the text card's scroll region wants: the option rows, plus the per-kind lines and the
    /// "Found:" caption above them when there are findings. An estimate that only has to be right
    /// in the safe direction — everything that must not be hidden is pinned outside the region.
    public static func textContentHeight(for verdict: TextVerdict) -> CGFloat {
        guard case .findings(let kinds) = verdict else { return optionsHeight }
        return optionsHeight + CGFloat(kinds + 1) * findingLineHeight + findingKindsGap
    }

    /// What the image card's pinned verdict renders, row for row (`UploadOverlayView.imageVerdict`).
    public static func imageVerdictHeight(for state: ImageUploadCard.State) -> CGFloat {
        switch state {
        case .preparing:
            return imagePreparingHeight
        case .ready(let prepared, let hasText):
            return imageReadyBaseHeight + (hasText ? imageRowHeight : 0)
                + (ImageUploadCard.formatLine(for: prepared) != nil ? imageFormatRowHeight : imageSizeLineHeight)
        // Same layout as the text path's over-cap refusal: a two-line callout over a caption.
        case .refused, .superseded:
            return refusalRowHeight
        }
    }
}
