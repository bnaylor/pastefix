import AppKit
import PastefixAppCore

enum ClipboardBridge {
    static func snapshot(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let plain = pasteboard.string(forType: .string)
        let richTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .html]
        let rich: NSAttributedString?
        if pasteboard.availableType(from: richTypes) != nil {
            rich = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?
                .first as? NSAttributedString
        } else {
            rich = nil
        }
        // Read last, and stored with the snapshot: it is what later tells a summon whether the
        // buffer it is holding is older than the clipboard. Reading it after the contents means a
        // copy that lands mid-snapshot shows up as a change rather than being recorded as the
        // count we already satisfied.
        return ClipboardSnapshot(plainText: plain, rich: rich, changeCount: pasteboard.changeCount)
    }

    static func writePlain(_ text: String, to pasteboard: NSPasteboard = .general) {
        write(text: text, richRTFD: nil, imagePNG: nil, to: pasteboard)
    }

    /// Every write starts here. Clearing the general pasteboard supersedes any `SnippetPaster`
    /// chain still waiting to post ⌘V: such a chain's whole premise is that the clipboard holds
    /// *its* text, and Save, copy-back and the ⌘K palette all come through this door. Factored
    /// into one place so a future writer cannot clear the pasteboard without invalidating them.
    ///
    /// Scoped to the general pasteboard by name: a write to some other pasteboard (a test's, say)
    /// has no bearing on what a paste chain is about to send.
    private static func beginWrite(_ pasteboard: NSPasteboard) {
        if pasteboard.name == .general { SnippetPaster.invalidatePending() }
        // `clearContents` is what bumps `changeCount` — the `setString`/`setData` calls that
        // follow do not — so its return value is exactly the count this write produced.
        let count = pasteboard.clearContents()
        if pasteboard.name == .general { lastSelfWriteChangeCount = count }
    }

    /// The `changeCount` Pastefix's own last write to the general pasteboard produced.
    ///
    /// ⌘⇧U asks "has the clipboard moved on since this buffer was captured?" and re-snapshots
    /// when it has. Without this, the app's own success write — the short URL it puts on the
    /// clipboard after an upload — would answer yes, and a second ⌘⇧U in the same session would
    /// helpfully offer to upload the link to the thing just uploaded. A copy the user did not
    /// make is not a copy that redirects the next upload.
    ///
    /// Only the latest write is kept, which is all the comparison needs: a chain of our own
    /// writes (upload, then Copy Again) leaves the last one matching. Main-actor state by
    /// convention — every writer here is a UI action — in the same shape as `SnippetPaster`'s
    /// pending generation.
    private(set) static var lastSelfWriteChangeCount: Int?

    /// Whether the general pasteboard's current contents are something Pastefix itself put there.
    static func clipboardIsSelfWritten(changeCount: Int) -> Bool {
        changeCount == lastSelfWriteChangeCount
    }

    /// Armed-Markdown save: formatted targets take HTML/RTF, plain targets get the Markdown source.
    static func writeRich(text: String, html: String, rtf: Data?, to pasteboard: NSPasteboard = .general) {
        beginWrite(pasteboard)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(html, forType: .html)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }

    /// Writes every representation we have for one item. Empty inputs write nothing for that type.
    static func write(text: String?, richRTFD: Data?, imagePNG: Data?, to pasteboard: NSPasteboard = .general) {
        beginWrite(pasteboard)
        if let text { pasteboard.setString(text, forType: .string) }
        if let richRTFD {
            pasteboard.setData(richRTFD, forType: .rtfd)
            if let attributed = NSAttributedString(rtfd: richRTFD, documentAttributes: nil),
               let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pasteboard.setData(rtf, forType: .rtf)
            }
        }
        if let imagePNG { pasteboard.setData(imagePNG, forType: .png) }
    }
}
