import Foundation

/// Markdown → HTML fragment via Foundation's parser, walked by presentation intent.
///
/// Foundation gives us a flat run list where every run carries the *stack* of block
/// intents it sits inside (innermost first). Reversing that stack and diffing it
/// against the previously open one turns the flat list back into nested markup:
/// close what the new run left, open what it entered, emit its inline HTML.
public enum MarkdownHTML {
    public static func render(_ markdown: String) throws -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return render(try AttributedString(markdown: markdown, options: options))
    }

    static func render(_ s: AttributedString) -> String {
        var out = ""
        var open: [PresentationIntent.IntentType] = []          // outermost first
        // Tables whose <tbody> we have already emitted, keyed by the table intent's
        // identity: the first tableRow opens it, the table's close tag ends it.
        var bodyOpened: Set<Int> = []

        for run in s.runs {
            let comps = Array((run.presentationIntent?.components ?? []).reversed())
            var common = 0
            while common < min(open.count, comps.count), open[common] == comps[common] { common += 1 }
            for i in stride(from: open.count - 1, through: common, by: -1) {
                out += closeTag(open, at: i, bodyOpened: &bodyOpened)
            }
            for i in common..<comps.count {
                out += openTag(comps, at: i, bodyOpened: &bodyOpened)
            }
            open = comps

            // A thematic break arrives as a run of placeholder text ("⸻"); the <hr>
            // came from its open tag and the text itself must never be emitted.
            if comps.contains(where: { if case .thematicBreak = $0.kind { return true } else { return false } }) {
                continue
            }
            let inCode = comps.contains { if case .codeBlock = $0.kind { return true } else { return false } }
            out += inline(run, in: s, inCodeBlock: inCode)
        }
        for i in stride(from: open.count - 1, through: 0, by: -1) {
            out += closeTag(open, at: i, bodyOpened: &bodyOpened)
        }
        return out
    }

    private static func parentKind(_ stack: [PresentationIntent.IntentType], _ i: Int) -> PresentationIntent.Kind? {
        i > 0 ? stack[i - 1].kind : nil
    }

    private static func isListItem(_ k: PresentationIntent.Kind?) -> Bool {
        if case .listItem = k { return true } else { return false }
    }

    private static func isHeaderRow(_ k: PresentationIntent.Kind?) -> Bool {
        if case .tableHeaderRow = k { return true } else { return false }
    }

    /// Identity of the innermost enclosing table, for the <tbody> bookkeeping.
    private static func enclosingTableIdentity(_ stack: [PresentationIntent.IntentType], _ i: Int) -> Int? {
        for c in stack[..<i].reversed() {
            if case .table = c.kind { return c.identity }
        }
        return nil
    }

    private static func openTag(
        _ stack: [PresentationIntent.IntentType],
        at i: Int,
        bodyOpened: inout Set<Int>
    ) -> String {
        let parent = parentKind(stack, i)
        switch stack[i].kind {
        case .paragraph: return isListItem(parent) ? "" : "<p>"
        case .header(let level): return "<h\(level)>"
        case .orderedList: return "<ol>"
        case .unorderedList: return "<ul>"
        case .listItem: return "<li>"
        case .codeBlock(let lang):
            if let lang, !lang.isEmpty { return "<pre><code class=\"language-\(attr(lang))\">" }
            return "<pre><code>"
        case .blockQuote: return "<blockquote>"
        case .thematicBreak: return "<hr>"
        case .table: return "<table>"
        case .tableHeaderRow: return "<thead><tr>"
        case .tableRow:
            guard let table = enclosingTableIdentity(stack, i) else { return "<tr>" }
            return bodyOpened.insert(table).inserted ? "<tbody><tr>" : "<tr>"
        case .tableCell: return isHeaderRow(parent) ? "<th>" : "<td>"
        @unknown default: return ""
        }
    }

    private static func closeTag(
        _ stack: [PresentationIntent.IntentType],
        at i: Int,
        bodyOpened: inout Set<Int>
    ) -> String {
        let parent = parentKind(stack, i)
        switch stack[i].kind {
        case .paragraph: return isListItem(parent) ? "" : "</p>"
        case .header(let level): return "</h\(level)>"
        case .orderedList: return "</ol>"
        case .unorderedList: return "</ul>"
        case .listItem: return "</li>"
        case .codeBlock: return "</code></pre>"
        case .blockQuote: return "</blockquote>"
        case .thematicBreak: return ""
        case .table:
            return bodyOpened.remove(stack[i].identity) != nil ? "</tbody></table>" : "</table>"
        case .tableHeaderRow: return "</tr></thead>"
        case .tableRow: return "</tr>"
        case .tableCell: return isHeaderRow(parent) ? "</th>" : "</td>"
        @unknown default: return ""
        }
    }

    private static func inline(_ run: AttributedString.Runs.Run, in s: AttributedString, inCodeBlock: Bool) -> String {
        let text = String(s[run.range].characters)
        let intents = run.inlinePresentationIntent ?? []
        if intents.contains(.lineBreak) { return "<br>" }
        if intents.contains(.softBreak) { return "\n" }
        if inCodeBlock { return escape(text) }
        if let image = run.imageURL { return "<img src=\"\(attr(image.absoluteString))\" alt=\"\(attr(text))\">" }
        if text.isEmpty { return "" }
        var html = escape(text)
        if intents.contains(.code) { html = "<code>\(html)</code>" }
        if intents.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if intents.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intents.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if let link = run.link { html = "<a href=\"\(attr(link.absoluteString))\">\(html)</a>" }
        return html
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func attr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
