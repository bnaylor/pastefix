/// What Esc does next in the panel: the whole order in one pure decision, so it can be tested
/// without a window (annotate spec). Overlays, then the preview, then the markup text field,
/// then markup mode, then the region, then the panel itself.
enum PanelEscape: Equatable {
    case closePalette, closeHistory, closeUpload, closePreview, discardText, leaveMarkup, clearRegion, cancel

    static func action(paletteOpen: Bool, historyOpen: Bool, uploadOpen: Bool, previewing: Bool,
                       textDraftOpen: Bool, markupMode: Bool, regionUp: Bool) -> PanelEscape {
        if paletteOpen { return .closePalette }
        if historyOpen { return .closeHistory }
        if uploadOpen { return .closeUpload }
        if previewing { return .closePreview }
        if textDraftOpen { return .discardText }
        if markupMode { return .leaveMarkup }
        if regionUp { return .clearRegion }
        return .cancel
    }
}
