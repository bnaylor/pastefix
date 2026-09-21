import Foundation
import AppKit
import PastefixCore

/// Read-only rendering of the buffer for the panel's Preview toggle. Shares the armed-save
/// pipeline: same HTML renderer, same `<img>` stripping (no network), plus a stylesheet and a
/// colour strip so the text follows the system appearance.
public enum MarkdownPreview {
    public static let maxBytes = 65_536
    static let notice = "Preview is limited to 64 KB of Markdown."
    static let stylesheet = "<style>body{font-family:-apple-system,system-ui;font-size:13px;line-height:1.35}code,pre{font-family:Menlo,monospace;font-size:12px}h1{font-size:22px}h2{font-size:18px}h3{font-size:15px}blockquote{margin-left:12px;padding-left:8px}</style>"

    @MainActor
    public static func attributedString(markdown: String) -> NSAttributedString {
        guard markdown.utf8.count <= maxBytes else { return plain(notice) }
        guard let html = try? MarkdownHTML.render(markdown) else { return plain(markdown, mono: true) }
        let body = RichOutputRenderer.htmlForRTF(html)
        guard let imported = NSMutableAttributedString(html: Data((stylesheet + body).utf8),
                                                       options: [.documentType: NSAttributedString.DocumentType.html,
                                                                 .characterEncoding: String.Encoding.utf8.rawValue],
                                                       documentAttributes: nil) else { return plain(markdown, mono: true) }
        stripForegroundColors(imported)
        return imported
    }

    static func stripForegroundColors(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttributes(in: full) { attrs, range, _ in
            if attrs[.link] == nil, attrs[.foregroundColor] != nil { s.removeAttribute(.foregroundColor, range: range) }
        }
    }

    private static func plain(_ text: String, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13)])
    }
}
