import Foundation
import AppKit
import PastefixCore

public struct RichOutput: Sendable { public let html: String; public let rtf: Data? }

/// Renders the buffer for an armed `.renderedMarkdown` save. Main actor: AppKit's HTML importer is WebKit-backed.
public enum RichOutputRenderer {
    @MainActor public static func render(markdown: String) throws -> RichOutput {
        let html = try MarkdownHTML.render(markdown)
        let attributed = NSAttributedString(html: Data(htmlForRTF(html).utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        let rtf = attributed.flatMap { try? $0.data(from: NSRange(location: 0, length: $0.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) }
        return RichOutput(html: html, rtf: rtf)
    }

    /// Strips `<img …>` tags before the HTML is handed to `NSAttributedString(html:)`.
    ///
    /// AppKit's HTML importer is WebKit-backed and will fetch remote `<img src="https://…">`
    /// resources while converting, which would turn a Save into a network request to whatever
    /// URL the Markdown named. The `html` returned by `render(markdown:)` (written to the
    /// `.html` sibling file) keeps the images — only the input to the RTF conversion is
    /// stripped. The HTML we generate is well-formed (`<img src="…" alt="…">`), so a simple
    /// regex is safe here.
    static func htmlForRTF(_ html: String) -> String {
        html.replacingOccurrences(of: "<img\\b[^>]*>", with: "", options: .regularExpression)
    }
}
