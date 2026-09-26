import AppKit
import PastefixAppCore

enum ClipboardBridge {
    static func snapshot(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        // Count **first**, contents second, and the order is the whole safety argument. A copy
        // landing between the two reads is recorded as count C against contents from C+1: the
        // snapshot then looks *older* than it is, so ⌘⇧U re-snapshots — a wasted read of the
        // clipboard, and nothing else. Read the count last and the same race stores C+1 against
        // the *old* contents, which is a stale buffer claiming to be the current clipboard: the
        // false all-clear finding A exists to stop, and a header that lies about its source,
        // produced by the one function both of those now rest on.
        //
        // Two adjacent main-actor statements, so nobody hits this by hand; ordered correctly
        // because the cost of being wrong is not symmetric.
        let changeCount = pasteboard.changeCount
        let plain = pasteboard.string(forType: .string)
        let richTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .html]
        let rich: NSAttributedString?
        if pasteboard.availableType(from: richTypes) != nil {
            rich = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?
                .first as? NSAttributedString
        } else {
            rich = nil
        }
        // A standalone pasteboard image, on the same footing as the text reads above: it is
        // content, so it comes after the count. The three "no image" rules live in
        // `ClipboardImageRead` (see there for why nil is never `Data()`), and the bytes-level
        // decisions — PNG kept verbatim, TIFF converted, the pixel ceiling — live in `ImageBytes`,
        // which the capture path uses too.
        //
        // Set by the decode closure below when the clipboard *had* an image we would not convert.
        var refusedPixels: Int?
        let image = ClipboardImageRead.imagePNG(
            // PNG first, and the order is the point: `availableType(from:)` answers with the
            // earliest match, so a pasteboard offering both (most screenshot sources do) is read
            // as the PNG it already holds instead of paying a TIFF decode to arrive at one.
            available: { types in
                let ordered = [ClipboardImageRead.pngType, ClipboardImageRead.tiffType]
                    .filter { types.contains($0) }
                    .map { NSPasteboard.PasteboardType(rawValue: $0) }
                return pasteboard.availableType(from: ordered)?.rawValue
            },
            data: { pasteboard.data(forType: NSPasteboard.PasteboardType(rawValue: $0)) },
            // `ImageBytes` is shared with the capture path, ceiling and all. The refusal is
            // recorded rather than swallowed: `nil` here is the only thing `ClipboardImageRead`
            // can be told, and an image that silently becomes no image is a defect, not a policy.
            decodePNG: { bytes in
                switch ImageBytes.normalise(bytes) {
                case .png(let png): return png
                case .tooLarge(let pixels): refusedPixels = pixels; return nil
                case .unusable: return nil
                }
            }
        )
        // Stored with the snapshot: it is what later tells a summon whether the buffer it is
        // holding is older than the clipboard.
        return ClipboardSnapshot(plainText: plain, rich: rich, imagePNG: image,
                                 refusedImagePixels: refusedPixels, changeCount: changeCount)
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
    /// writes (upload, then Copy Again) leaves the last one matching. Main-actor state, enforced
    /// rather than assumed: the app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    /// so this enum is main-actor isolated without saying so, the same as `SnippetPaster`'s
    /// pending generation (which says so explicitly).
    private(set) static var lastSelfWriteChangeCount: Int?

    /// Whether the general pasteboard's current contents are something Pastefix itself put there.
    static func clipboardIsSelfWritten(changeCount: Int) -> Bool {
        changeCount == lastSelfWriteChangeCount
    }

    /// Armed-Markdown save: formatted targets take HTML/RTF, plain targets get the Markdown source.
    ///
    /// `imagePNG` is here for the same reason it is on `write`: a session can carry a standalone
    /// image alongside text (a copy that put both on the clipboard), and arming Markdown → Rich
    /// Text must not be the one save path that silently drops it. Save never writes less than it
    /// was given.
    static func writeRich(text: String, html: String, rtf: Data?, imagePNG: Data? = nil,
                          to pasteboard: NSPasteboard = .general) {
        beginWrite(pasteboard)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(html, forType: .html)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
        if let imagePNG { pasteboard.setData(imagePNG, forType: .png) }
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
