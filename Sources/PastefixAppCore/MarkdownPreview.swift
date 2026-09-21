import Foundation
import AppKit
import PastefixCore

/// Read-only rendering of the buffer for the panel's Preview toggle. Shares the armed-save
/// pipeline: same HTML renderer, same `<img>` stripping (no network), plus a stylesheet and a
/// colour strip so the text follows the system appearance.
public enum MarkdownPreview {
    public static let maxBytes = 65_536
    static let notice = "Preview is limited to 64 KB of Markdown."
    // Known limitation: the importer drops every form of blockquote inset we can express here
    // (`margin-left`, `padding-left`, the `margin` shorthand below) — a quoted paragraph comes
    // back with `firstLineHeadIndent == headIndent == 0`, indistinguishable from body text. Only
    // a paragraph-style post-pass could indent it, and there is no marker in the imported runs
    // to tell a quote from a paragraph, so blockquotes render flush until we render them
    // ourselves.
    static let stylesheet = "<style>body{font-family:-apple-system,system-ui;font-size:13px;line-height:1.35}code,pre{font-family:Menlo,monospace;font-size:12px}h1{font-size:22px}h2{font-size:18px}h3{font-size:15px}blockquote{margin:0 0 0 12px}</style>"

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
        stripTextLists(imported)
        return imported
    }

    static func stripForegroundColors(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttributes(in: full) { attrs, range, _ in
            if attrs[.link] == nil, attrs[.foregroundColor] != nil { s.removeAttribute(.foregroundColor, range: range) }
        }
    }

    /// The importer emits every list marker *twice*: once as literal text in the run ("\t•\t",
    /// "\t1\t") and once as an `NSTextList` on the run's paragraph style, which TextKit 2 draws
    /// itself — so every list item rendered with two bullets. Drop the text lists and keep the
    /// literal markers, along with the indents the importer already set.
    static func stripTextLists(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = value as? NSParagraphStyle, !style.textLists.isEmpty,
                  let mutable = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            mutable.textLists = []
            s.addAttribute(.paragraphStyle, value: mutable, range: range)
        }
    }

    private static func plain(_ text: String, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13)])
    }
}
