import AppKit
import PastefixAppCore

enum ClipboardBridge {
    static func snapshot(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let plain = pasteboard.string(forType: .string)
        let rich = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?
            .first as? NSAttributedString
        return ClipboardSnapshot(plainText: plain, rich: rich)
    }

    static func writePlain(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
