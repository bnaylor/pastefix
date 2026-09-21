import SwiftUI
import AppKit

/// Read-only, selectable rendering of the buffer. Replaces the editor while previewing.
struct MarkdownPreviewView: NSViewRepresentable {
    let text: NSAttributedString

    /// Remembers the last render we applied. The storage itself can't answer "did this change?":
    /// `tv.textColor` below rewrites `.foregroundColor` on every run, so the stored string never
    /// compares equal to the render it came from.
    final class Coordinator { var lastApplied: NSAttributedString? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textColor = .labelColor
        // The importer never produces links we want live, and link detection would also
        // re-colour runs that `MarkdownPreview` deliberately stripped for dark mode.
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
        tv.textColor = .labelColor
        context.coordinator.lastApplied = text
    }
}
