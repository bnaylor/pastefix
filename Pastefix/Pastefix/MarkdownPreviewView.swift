import SwiftUI
import AppKit

/// Read-only, selectable rendering of the buffer. Replaces the editor while previewing.
struct MarkdownPreviewView: NSViewRepresentable {
    let text: NSAttributedString

    /// Remembers the last render we applied, so `updateNSView` can skip the ones that would
    /// only drop the selection. Also the text view's delegate: link clicks are policed here
    /// rather than left to `NSTextView`'s default open-anything behaviour.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastApplied: NSAttributedString?

        /// The preview renders whatever was on the clipboard, so the click policy is stated here
        /// instead of resting on what the HTML importer happens to produce. `MarkdownHTML` emits
        /// scheme-less hrefs too, and today the importer drops them — but that is its behaviour,
        /// not our guarantee. Anything outside http/https/mailto is swallowed.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return true }
            NSWorkspace.shared.open(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        // Set once, here, and never in `updateNSView`: this setter rewrites `.foregroundColor`
        // on the whole text storage, so applying it after `setAttributedString` would flatten
        // the `.link` runs that `MarkdownPreview.stripForegroundColors` deliberately keeps
        // coloured. Runs the render leaves uncoloured still pick this up as the view default.
        tv.textColor = .labelColor
        tv.delegate = context.coordinator
        // The importer *does* produce `.link` runs (Markdown links), and those stay clickable —
        // see the delegate above. What is off here is data *detection*: it would find URLs in
        // plain text and re-colour runs `MarkdownPreview` deliberately stripped for dark mode.
        tv.isAutomaticLinkDetectionEnabled = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Only touch the text storage when the render actually changed: `setAttributedString`
        // drops the selection, and SwiftUI re-runs `updateNSView` for unrelated state changes
        // (sidebar toggle, applying spinner) while the user is mid-selection in the preview.
        guard let tv = scroll.documentView as? NSTextView,
              context.coordinator.lastApplied !== text,
              context.coordinator.lastApplied?.isEqual(to: text) != true else { return }
        tv.textStorage?.setAttributedString(text)
        context.coordinator.lastApplied = text
    }
}
