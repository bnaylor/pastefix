# Pastefix v2 Markdown ↔ Rich Text (Plan 8) — Implementation Plan

> ## ⬜ STATUS: NOT STARTED — written 2026-09-21 from the approved spec (issue #16).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; SwiftUI (Task 6) → `swiftui-pro`. **TDD is required** for every package task. Foundation's Markdown run segmentation is the one place where a test expectation may legitimately need adjusting: verify with a scratch `swift` script first, keep the *semantics* the test names, and report every adjustment. **One implementer at a time on the branch.**

**Goal:** Rich → Markdown over the clipboard's RTFD; Markdown → Rich Text that arms an output mode so ⌘S writes HTML + RTF + the Markdown source; Markdown detection; a "Rich Text" category.

**Architecture:** `PastefixCore` gains `OutputMode`/`OutputModeTransformer`, a Foundation-only Markdown → HTML renderer (`MarkdownHTML`), an RTFD → Markdown converter (`MarkdownFromRich`), a Markdown detector and content kind, and two transforms. `PastefixAppCore` carries the mode on `PasteDocument`, arms it in the coordinator, and renders HTML → RTF at save time (`RichOutputRenderer`). The app writes three pasteboard types on an armed save and shows a disarmable badge.

**Tech Stack:** Swift 6 SwiftPM (macOS 14+), Foundation `AttributedString(markdown:)` with `.full` interpreted syntax, AppKit `NSAttributedString` RTFD/HTML conversion, Swift Testing, SwiftUI app target.

**Spec:** `docs/specs/2026-09-21-pastefix-v2-markdown-rich-text.md` — read it first.

## Global Constraints

- **No third-party dependencies.** Markdown parsing is `AttributedString(markdown:options:)` with `interpretedSyntax: .full`, `failurePolicy: .returnPartiallyParsedIfPossible`, `allowsExtendedAttributes: true`.
- **Ids/orders/names:** `builtin.richtomarkdown` "Rich → Markdown" order 11; `builtin.markdowntorich` "Markdown → Rich Text" order 12; both `category: TransformCategory.richText` ("Rich Text"); `RichToPlain` category → `richText`. `builtinOrder = [layout, richText, characters, urls, case, data, colors]`.
- **`OutputMode`:** `.plain`, `.renderedMarkdown`. `MarkdownToRich` returns its input unchanged; the coordinator reports `.applied` and sets `document.outputMode`.
- **Armed save writes exactly:** `.string` = Markdown source, `.html` = rendered fragment, `.rtf` = AppKit conversion of that fragment (omitted only if conversion returns nil). Render failure → error bar, session stays open.
- **Detection heuristic (verbatim):** Markdown iff any line matches `^#{1,6} \S` or `^(```|~~~)`, **or** ≥ 2 distinct signal kinds among: list line `^\s{0,3}([-*+]|\d+[.)]) \S`, quote `^> `, table row `^\|.+\|\s*$`, link `\[[^\]]+\]\([^)\s]+\)`, inline `(\*\*|__)\S.*?\S(\*\*|__)` or `` `[^`\n]+` ``. Scan at most the first 64 KB and 400 lines. Existing 1 MB detector guard still applies first.
- **Rich → Markdown rules:** headings from `headerLevel`, else whole-paragraph bold with size ≥ 1.8× body → `#`, ≥ 1.4× → `##`, ≥ 1.15× → `###`; lists from `NSTextList` (depth = list count, 2-space indent per level, `decimal` marker format → `N.` else `-`); mono trait or family containing Menlo/Monaco/Courier/Mono → backticks; whole-paragraph mono → fenced block, consecutive merged; strikethrough → `~~`; `.link` → `[text](url)`; attachments dropped; paragraphs with `textBlocks` (tables) emitted as plain lines.
- **HTML escaping:** `&`, `<`, `>` in text; additionally `"` in attribute values.
- **Branch:** `feat/markdown-rich-text`. Conventional commits + `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #16. `main` is protected — never push to it directly.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/PastefixCore/Transformer.swift` | `OutputMode`, `OutputModeTransformer`, `TransformCategory.richText` |
| `Sources/PastefixCore/Detection/ContentKind.swift`, `ContentDetector.swift` | `.markdown` |
| `Sources/PastefixCore/Detection/MarkdownDetector.swift` (new) | heuristic |
| `Sources/PastefixCore/Markdown/MarkdownHTML.swift` (new) | renderer |
| `Sources/PastefixCore/Markdown/MarkdownFromRich.swift` (new) | RTFD → Markdown |
| `Sources/PastefixCore/Native/RichToMarkdown.swift`, `MarkdownToRich.swift` (new); `RichToPlain.swift` | transforms |
| `Sources/PastefixCore/Discovery/TransformerRegistry.swift` | orders 11, 12 |
| `Sources/PastefixAppCore/PasteDocument.swift`, `TransformCoordinator.swift` | mode + arming |
| `Sources/PastefixAppCore/RichOutputRenderer.swift` (new) | HTML → RTF |
| `Pastefix/Pastefix/ClipboardBridge.swift`, `AppModel.swift`, `PanelView.swift` | writeRich, save path, badge |
| Tests: `MarkdownDetectorTests`, `MarkdownHTMLTests`, `MarkdownFromRichTests`, `RichTextTransformTests` (Core, new); `ContentDetectorTests`, `TransformerRegistryTests` (extend); `PasteDocumentTests`, `TransformCoordinatorTests`, `SidebarGroupingTests` (extend), `RichOutputRendererTests` (AppCore, new) | |

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/markdown-rich-text && swift test 2>&1 | tail -1` → `308 tests in 39 suites passed`.

---

### Task 1: Engine types, category, detection

**Files:**
- Modify: `Sources/PastefixCore/Transformer.swift`, `Detection/ContentKind.swift`, `Detection/ContentDetector.swift`, `Native/RichToPlain.swift`
- Create: `Sources/PastefixCore/Detection/MarkdownDetector.swift`
- Test: `Tests/PastefixCoreTests/MarkdownDetectorTests.swift` (new), `ContentDetectorTests.swift` (extend), `SidebarGroupingTests.swift` in AppCore tests (extend: Rich Text second)

- [ ] **Step 1: Failing tests**

```swift
// MarkdownDetectorTests.swift
import Testing
@testable import PastefixCore

@Suite struct MarkdownDetectorTests {
    @Test(arguments: [
        "# Title\nbody", "text\n\n```swift\nlet x = 1\n```", "- one\n- two\nsee [docs](https://x.y)",
        "> quoted\nand **strong**", "| a | b |\n|---|---|\n| 1 | 2 |\nwith `code`", "1. first\n2. second\n\n> note",
    ])
    func positives(_ s: String) { #expect(MarkdownDetector.looksLikeMarkdown(s)) }

    @Test(arguments: [
        "Just a sentence with a * star * in it.", "https://example.com/path", "a * b * c = d", "{\"k\": [1,2]}",
        "- a single list line", "Call me **maybe**", "email me at a@b.co\nthanks", "",
    ])
    func negatives(_ s: String) { #expect(!MarkdownDetector.looksLikeMarkdown(s)) }

    @Test func scanIsBounded() {
        let big = String(repeating: "plain line\n", count: 100_000) + "# heading far below the cap\n"
        #expect(!MarkdownDetector.looksLikeMarkdown(big))   // heading is beyond 64 KB / 400 lines
    }
}
```
Append to `ContentDetectorTests`:
```swift
    @Test func detectsMarkdownAndCoexistsWithURL() {
        let kinds = ContentDetector.detect("# Notes\n\nsee https://example.com and **this**")
        #expect(kinds.contains(.markdown) && kinds.contains(.url))
        #expect(ContentKind.markdown.displayName == "Markdown")
    }
```
Append to AppCore `SidebarGroupingTests` (read the file for its fixture helper; add a Rich Text transformer stub with `category: TransformCategory.richText`):
```swift
    @Test func richTextGroupComesRightAfterLayout() {
        let groups = SidebarGrouping.group([stub("a", category: TransformCategory.layout), stub("b", category: TransformCategory.richText), stub("c", category: TransformCategory.characters)])
        #expect(groups.map(\.title) == ["Layout", "Rich Text", "Characters"])
    }
```
(adapt names to the file's actual API — the assertion is the contract).

- [ ] **Step 2:** `swift test --filter "MarkdownDetectorTests|ContentDetectorTests|SidebarGroupingTests"` → compile errors.

- [ ] **Step 3: Implement**

`Transformer.swift` additions:
```swift
/// How Save should write the buffer. Set by an `OutputModeTransformer`; lives on the document for the session.
public enum OutputMode: String, Sendable, Equatable {
    case plain
    /// Render the buffer as Markdown: Save writes HTML + RTF alongside the Markdown source.
    case renderedMarkdown
}

/// A transform that, besides (possibly) changing the text, chooses how the buffer is written on Save.
/// This is the only channel through which a transform influences Save.
public protocol OutputModeTransformer: Transformer {
    var outputMode: OutputMode { get }
}
```
`TransformCategory`: add `public static let richText = "Rich Text"` and `builtinOrder = [layout, richText, characters, urls, `case`, data, colors]`. `RichToPlain.category` → `TransformCategory.richText`.

`ContentKind`: add `case markdown` (last) with `displayName` "Markdown".

`MarkdownDetector.swift`:
```swift
import Foundation

/// Conservative Markdown sniff for the Detected badge and palette promotion.
public enum MarkdownDetector {
    static let maxBytes = 65_536
    static let maxLines = 400

    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6} \S"#)
    private static let fence = try! NSRegularExpression(pattern: #"^(```|~~~)"#)
    private static let list = try! NSRegularExpression(pattern: #"^\s{0,3}([-*+]|\d+[.)]) \S"#)
    private static let quote = try! NSRegularExpression(pattern: #"^> "#)
    private static let table = try! NSRegularExpression(pattern: #"^\|.+\|\s*$"#)
    private static let link = try! NSRegularExpression(pattern: #"\[[^\]]+\]\([^)\s]+\)"#)
    private static let inline = try! NSRegularExpression(pattern: #"(\*\*|__)\S.*?\S(\*\*|__)|`[^`\n]+`"#)

    public static func looksLikeMarkdown(_ text: String) -> Bool {
        var head = text
        if head.utf8.count > maxBytes { head = String(decoding: head.utf8.prefix(maxBytes), as: UTF8.self) }
        var signals: Set<String> = []
        for (i, lineSub) in head.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i >= maxLines { break }
            let line = String(lineSub)
            let r = NSRange(location: 0, length: (line as NSString).length)
            if heading.firstMatch(in: line, range: r) != nil || fence.firstMatch(in: line, range: r) != nil { return true }
            if list.firstMatch(in: line, range: r) != nil { signals.insert("list") }
            if quote.firstMatch(in: line, range: r) != nil { signals.insert("quote") }
            if table.firstMatch(in: line, range: r) != nil { signals.insert("table") }
            if link.firstMatch(in: line, range: r) != nil { signals.insert("link") }
            if inline.firstMatch(in: line, range: r) != nil { signals.insert("inline") }
            if signals.count >= 2 { return true }
        }
        return false
    }
}
```
Note the "Call me **maybe**" negative: one signal (inline) → false. "- a single list line": one signal → false. "1. first\n2. second\n\n> note": list + quote → true.

`ContentDetector.detect`: after the entity check, `if MarkdownDetector.looksLikeMarkdown(text) { kinds.insert(.markdown) }`.

- [ ] **Step 4:** filter green; full `swift test` green (some existing tests may enumerate `ContentKind.allCases` counts or category order — update them only if they assert the old list literally, and say so).
- [ ] **Step 5: Commit** `feat(core): OutputMode protocol, Rich Text category, Markdown detection`.

---

### Task 2: `MarkdownHTML` renderer

**Files:** Create `Sources/PastefixCore/Markdown/MarkdownHTML.swift`; Test `Tests/PastefixCoreTests/MarkdownHTMLTests.swift`.

- [ ] **Step 0: Scratch verification (not committed).** Before writing tests, run a throwaway script (`swift /tmp/md.swift`) that parses each fixture below with `AttributedString(markdown:options:)` (`.full`) and prints every run's text, `presentationIntent?.components` (kind + identity), `inlinePresentationIntent`, `link`, `imageURL`. Use what you see to confirm the expected HTML below; where Foundation segments differently but the semantics are the same (e.g. an extra empty run), keep the expected HTML and make the renderer robust (skip empty runs). Record surprises in the report.

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import PastefixCore

@Suite struct MarkdownHTMLTests {
    func r(_ s: String) throws -> String { try MarkdownHTML.render(s) }
    @Test func headings() throws {
        #expect(try r("# One") == "<h1>One</h1>")
        #expect(try r("### Three") == "<h3>Three</h3>")
    }
    @Test func inlineStyles() throws {
        #expect(try r("**b** and *i* and `c` and ~~s~~") == "<p><strong>b</strong> and <em>i</em> and <code>c</code> and <del>s</del></p>")
    }
    @Test func linkAndImage() throws {
        #expect(try r("[site](https://x.y/?a=1&b=2)") == "<p><a href=\"https://x.y/?a=1&amp;b=2\">site</a></p>")
        #expect(try r("![alt text](https://x.y/i.png)") == "<p><img src=\"https://x.y/i.png\" alt=\"alt text\"></p>")
    }
    @Test func tightLists() throws {
        #expect(try r("- a\n- b") == "<ul><li>a</li><li>b</li></ul>")
        #expect(try r("1. a\n2. b") == "<ol><li>a</li><li>b</li></ol>")
    }
    @Test func nestedList() throws {
        #expect(try r("- a\n  - b\n- c") == "<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>")
    }
    @Test func fencedCodeEscapes() throws {
        #expect(try r("```swift\nlet a = 1 < 2\n```") == "<pre><code class=\"language-swift\">let a = 1 &lt; 2\n</code></pre>")
        #expect(try r("    indented\n") == "<pre><code>indented\n</code></pre>")
    }
    @Test func blockQuoteAndRule() throws {
        #expect(try r("> quoted") == "<blockquote><p>quoted</p></blockquote>")
        #expect(try r("a\n\n***\n\nb") == "<p>a</p><hr><p>b</p>")
    }
    @Test func table() throws {
        #expect(try r("| h1 | h2 |\n|---|---|\n| c1 | c2 |") == "<table><thead><tr><th>h1</th><th>h2</th></tr></thead><tbody><tr><td>c1</td><td>c2</td></tr></tbody></table>")
    }
    @Test func breaksAndEscaping() throws {
        #expect(try r("line one  \nline two") == "<p>line one<br>line two</p>")
        #expect(try r("a & b <script>") == "<p>a &amp; b &lt;script&gt;</p>")
    }
    @Test func partiallyMalformedStillRenders() throws {
        let out = try r("# ok\n\n[unclosed link(\n\n**bold")
        #expect(out.hasPrefix("<h1>ok</h1>") && out.contains("<p>"))
    }
}
```

- [ ] **Step 2:** `swift test --filter MarkdownHTMLTests` → compile errors.

- [ ] **Step 3: Implement** `MarkdownHTML.swift`:
```swift
import Foundation

/// Markdown → HTML fragment via Foundation's parser, walked by presentation intent.
public enum MarkdownHTML {
    public static func render(_ markdown: String) throws -> String {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        return render(try AttributedString(markdown: markdown, options: options))
    }

    static func render(_ s: AttributedString) -> String {
        var out = ""
        var open: [PresentationIntent.IntentType] = []          // outermost first
        for run in s.runs {
            let comps = Array((run.presentationIntent?.components ?? []).reversed())
            var common = 0
            while common < min(open.count, comps.count), open[common] == comps[common] { common += 1 }
            for i in stride(from: open.count - 1, through: common, by: -1) { out += closeTag(open, at: i) }
            for i in common..<comps.count { out += openTag(comps, at: i) }
            open = comps
            out += inline(run, in: s, inCodeBlock: comps.contains { if case .codeBlock = $0.kind { return true } else { return false } })
        }
        for i in stride(from: open.count - 1, through: 0, by: -1) { out += closeTag(open, at: i) }
        return out
    }

    private static func parentKind(_ stack: [PresentationIntent.IntentType], _ i: Int) -> PresentationIntent.Kind? { i > 0 ? stack[i - 1].kind : nil }
    private static func isListItem(_ k: PresentationIntent.Kind?) -> Bool { if case .listItem = k { return true } else { return false } }
    private static func isHeaderRow(_ k: PresentationIntent.Kind?) -> Bool { if case .tableHeaderRow = k { return true } else { return false } }
    private static func inTable(_ stack: [PresentationIntent.IntentType], _ i: Int) -> Bool { stack[..<i].contains { if case .table = $0.kind { return true } else { return false } } }

    private static func openTag(_ stack: [PresentationIntent.IntentType], at i: Int) -> String {
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
        case .tableRow(let index): return index == 1 || !previousWasBodyRow ? "<tbody><tr>" : "<tr>"   // see note below
        case .tableCell: return isHeaderRow(parent) ? "<th>" : "<td>"
        @unknown default: return ""
        }
    }
    private static func closeTag(_ stack: [PresentationIntent.IntentType], at i: Int) -> String {
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
        case .table: return "</tbody></table>"
        case .tableHeaderRow: return "</tr></thead>"
        case .tableRow: return "</tr>"
        case .tableCell: return isHeaderRow(parent) ? "</th>" : "</td>"
        @unknown default: return ""
        }
    }
```
**Table body wrapping:** the simplest correct approach is to emit `<tbody>` when opening the *first* body row of a table and `</tbody>` when closing the table. Implement that with a tiny state flag inside `render` (e.g. `var openedBodyFor: Int?` keyed by the table's `identity`) rather than the placeholder `previousWasBodyRow` expression above — the expected HTML in the test is the contract. If a table has no body rows, don't emit `<tbody></tbody>`; adjust `closeTag(.table)` accordingly via the same flag.

```swift
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
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func attr(_ s: String) -> String { escape(s).replacingOccurrences(of: "\"", with: "&quot;") }
}
```
Known Foundation quirks (verified on this machine; see the Task 2 brief appendix): the thematic-break run text is a placeholder glyph "⸻" that must be discarded; hard breaks are a "\n" run with `.lineBreak`; soft breaks a " " run with `.softBreak`; the first table body row has rowIndex 1. Also: (a) a thematic break may arrive as a run with empty text — the `<hr>` comes from `openTag`, nothing else is emitted; (b) hard breaks (`  \n`) surface as `.lineBreak` runs whose text is "\n"; (c) the soft-break run text is "\n" too; (d) `imageURL` runs carry the alt text; (e) list item paragraphs always carry a `.paragraph` component inside `.listItem` — suppressed to keep lists tight; (f) `header` levels are 1…6.

- [ ] **Step 4:** `swift test --filter MarkdownHTMLTests` green; full suite green.
- [ ] **Step 5: Commit** `feat(core): MarkdownHTML — Foundation-only Markdown → HTML renderer`.

---

### Task 3: `MarkdownFromRich`, the two transforms, registry

**Files:** Create `Sources/PastefixCore/Markdown/MarkdownFromRich.swift`, `Native/RichToMarkdown.swift`, `Native/MarkdownToRich.swift`; Modify `Discovery/TransformerRegistry.swift`; Test `Tests/PastefixCoreTests/MarkdownFromRichTests.swift`, `RichTextTransformTests.swift` (new), `TransformerRegistryTests.swift` (extend).

- [ ] **Step 1: Failing tests**
```swift
// MarkdownFromRichTests.swift
import Testing
import AppKit
@testable import PastefixCore

@Suite struct MarkdownFromRichTests {
    let body = NSFont.systemFont(ofSize: 13)
    func para(_ s: String, font: NSFont? = nil, header: Int = 0, lists: [NSTextList] = [], link: String? = nil, strike: Bool = false) -> NSAttributedString {
        let ps = NSMutableParagraphStyle(); ps.headerLevel = header; ps.textLists = lists
        var attrs: [NSAttributedString.Key: Any] = [.font: font ?? body, .paragraphStyle: ps]
        if let link { attrs[.link] = URL(string: link)! }
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: s + "\n", attributes: attrs)
    }
    func doc(_ parts: [NSAttributedString]) -> NSAttributedString { let m = NSMutableAttributedString(); parts.forEach(m.append); return m }
    func md(_ parts: [NSAttributedString]) -> String { MarkdownFromRich.convert(doc(parts)) }

    @Test func headerLevelBecomesHashes() {
        #expect(md([para("Title", header: 2), para("body")]) == "## Title\n\nbody")
    }
    @Test func sizeHeuristicForRTF() {
        let big = NSFont.boldSystemFont(ofSize: 26), mid = NSFont.boldSystemFont(ofSize: 19)
        #expect(md([para("Big", font: big), para("Mid", font: mid), para("body"), para("body two")]) == "# Big\n\n## Mid\n\nbody\n\nbody two")
    }
    @Test func bulletAndNestedLists() {
        let l1 = NSTextList(markerFormat: .disc, options: 0), l2 = NSTextList(markerFormat: .circle, options: 0)
        #expect(md([para("\t•\tone", lists: [l1]), para("\t◦\ttwo", lists: [l1, l2]), para("\t•\tthree", lists: [l1])]) == "- one\n  - two\n- three")
    }
    @Test func numberedList() {
        let l = NSTextList(markerFormat: .decimal, options: 0)
        #expect(md([para("\t1.\tfirst", lists: [l]), para("\t2.\tsecond", lists: [l])]) == "1. first\n2. second")
    }
    @Test func boldItalicWithEdgeSpaces() {
        let m = NSMutableAttributedString(string: "plain ", attributes: [.font: body])
        m.append(NSAttributedString(string: "bold ", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        m.append(NSAttributedString(string: "italic", attributes: [.font: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)]))
        m.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        #expect(MarkdownFromRich.convert(m) == "plain **bold** *italic*")
    }
    @Test func linkStrikeAndInlineCode() {
        let m = NSMutableAttributedString(string: "see ", attributes: [.font: body])
        m.append(para("docs", link: "https://x.y/d").attributedSubstring(from: NSRange(location: 0, length: 4)))
        m.append(NSAttributedString(string: " or ", attributes: [.font: body]))
        m.append(NSAttributedString(string: "x", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        m.append(NSAttributedString(string: " gone", attributes: [.font: body, .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        m.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        #expect(MarkdownFromRich.convert(m) == "see [docs](https://x.y/d) or `x` ~~gone~~")
    }
    @Test func monoParagraphsBecomeOneFence() {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        #expect(md([para("intro"), para("let a = 1", font: mono), para("let b = 2", font: mono), para("after")]) == "intro\n\n```\nlet a = 1\nlet b = 2\n```\n\nafter")
    }
    @Test func attachmentsDroppedAndTablesFlattened() {
        let att = NSAttributedString(attachment: NSTextAttachment())
        let m = NSMutableAttributedString(attributedString: para("before")); m.append(att); m.append(para("after"))
        #expect(MarkdownFromRich.convert(m) == "before\n\nafter")
        let ps = NSMutableParagraphStyle(); ps.textBlocks = [NSTextTableBlock(table: NSTextTable(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)]
        let cell = NSAttributedString(string: "cell\n", attributes: [.font: body, .paragraphStyle: ps])
        #expect(MarkdownFromRich.convert(cell) == "cell")
    }
    @Test func rtfdRoundTrip() throws {
        let d = try doc([para("Title", header: 1), para("body")]).data(from: NSRange(location: 0, length: 12), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        #expect(try MarkdownFromRich.convert(rtfd: d).hasPrefix("# Title"))
    }
}

// RichTextTransformTests.swift
import Testing
import AppKit
@testable import PastefixCore

@Suite struct RichTextTransformTests {
    @Test func richToMarkdownUsesRTFD() async throws {
        let ps = NSMutableParagraphStyle(); ps.headerLevel = 1
        let a = NSAttributedString(string: "Hello\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: ps])
        let d = try a.data(from: NSRange(location: 0, length: 6), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let out = try await RichToMarkdown().apply(TransformInput(text: "Hello", richRTFD: d))
        #expect(out == "# Hello")
        await #expect(throws: TransformError.richInputUnavailable) { try await RichToMarkdown().apply(TransformInput(text: "x")) }
    }
    @Test func markdownToRichArmsWithoutChangingText() async throws {
        let t = MarkdownToRich()
        #expect(t.outputMode == .renderedMarkdown && t.applicableKinds == [.markdown] && t.category == TransformCategory.richText)
        #expect(try await t.apply(TransformInput(text: "# hi\n\n- a")) == "# hi\n\n- a")
    }
}
```
Append to `TransformerRegistryTests` (match its existing style):
```swift
    @Test func richTextTransformsRegisteredInOrder() {
        let ids = TransformerRegistry(config: .init(scriptsDirectory: URL(fileURLWithPath: "/nonexistent"), wrapWidth: 80)).load().map(\.id)
        #expect(ids.prefix(3) == ["builtin.richtoplain", "builtin.richtomarkdown", "builtin.markdowntorich"])
    }
```

- [ ] **Step 2:** `swift test --filter "MarkdownFromRichTests|RichTextTransformTests|TransformerRegistryTests"` → compile errors.

- [ ] **Step 3: Implement**

`MarkdownFromRich.swift` (AppKit for `NSAttributedString`, like `RichToPlain`):
```swift
import Foundation
import AppKit

/// RTFD → GitHub-flavoured Markdown. Best effort: headings, lists, emphasis, links, code; tables flattened, attachments dropped.
public enum MarkdownFromRich {
    public static func convert(rtfd: Data) throws -> String {
        let a = try NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        return convert(a)
    }

    struct Line { var text: String; var isCode: Bool; var isList: Bool }

    static func convert(_ a: NSAttributedString) -> String {
        let ns = a.string as NSString
        let bodySize = dominantPointSize(a)
        var lines: [Line] = []
        var listCounters: [ObjectIdentifier: Int] = [:]
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(pr) }
            var content = pr
            if let last = ns.substring(with: pr).last, last.isNewline { content.length -= 1 }
            guard content.length > 0 else { lines.append(Line(text: "", isCode: false, isList: false)); continue }
            let attrs = a.attributes(at: content.location, effectiveRange: nil)
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let sub = a.attributedSubstring(from: content)
            if !(ps?.textBlocks.isEmpty ?? true) { lines.append(Line(text: inlineMarkdown(sub), isCode: false, isList: false)); continue }
            if isWholly(sub, where: isMono) { lines.append(Line(text: sub.string, isCode: true, isList: false)); continue }
            var text = inlineMarkdown(sub)
            if let lists = ps?.textLists, !lists.isEmpty, let list = lists.last {
                text = stripMarker(text)
                let indent = String(repeating: "  ", count: lists.count - 1)
                if list.markerFormat.rawValue.contains("decimal") {
                    let n = (listCounters[ObjectIdentifier(list)] ?? (list.startingItemNumber - 1)) + 1
                    listCounters[ObjectIdentifier(list)] = n
                    text = "\(indent)\(n). \(text)"
                } else { text = "\(indent)- \(text)" }
                lines.append(Line(text: text, isCode: false, isList: true)); continue
            }
            let level = headingLevel(sub, headerLevel: ps?.headerLevel ?? 0, bodySize: bodySize)
            if level > 0 { text = String(repeating: "#", count: level) + " " + stripEmphasis(text) }
            lines.append(Line(text: text, isCode: false, isList: false))
        }
        return join(lines)
    }
```
- `join`: walk lines; consecutive `isCode` lines become one block "```\n…\n```"; consecutive `isList` lines are separated by single newlines; everything else by blank lines; empty lines are dropped (they only separate). Trim trailing whitespace.
- `inlineMarkdown(_:)`: enumerate attribute runs; skip runs whose text is the attachment character (`"\u{FFFC}"`); for each run compute `text`, then wrap: mono → `` `text` ``, bold → `**`, italic → `*`, strikethrough → `~~`, link → `[text](url)`. Move leading/trailing whitespace outside the markers (`"bold "` → `"**bold** "`). Merge adjacent runs with identical styling before wrapping so `**bo****ld**` never appears (compare the styling tuple).
- `isMono(font)`: `font.fontDescriptor.symbolicTraits.contains(.monoSpace) || ["Menlo","Monaco","Courier","Mono"].contains { font.familyName?.contains($0) ?? false }`; `isBold`: traits `.bold`; `isItalic`: traits `.italic`.
- `headingLevel`: if `headerLevel > 0` return it; else if the paragraph is wholly bold: size ≥ 1.8×body → 1, ≥ 1.4× → 2, ≥ 1.15× → 3; else 0. `stripEmphasis` removes the `**` a wholly-bold heading would otherwise get.
- `dominantPointSize`: most frequent `NSFont.pointSize` by character count; default 13.
- `stripMarker`: regex `^[\t ]*([•◦▪‣\-\*]|\d+[.)])?[\t ]+` removed once.

`RichToMarkdown.swift`:
```swift
public struct RichToMarkdown: Transformer {
    public let id = "builtin.richtomarkdown"
    public let name = "Rich → Markdown"
    public let requiresRichInput = true
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.richText
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String {
        guard let data = input.richRTFD else { throw TransformError.richInputUnavailable }
        return try MarkdownFromRich.convert(rtfd: data)
    }
}
```
`MarkdownToRich.swift`:
```swift
public struct MarkdownToRich: OutputModeTransformer {
    public let id = "builtin.markdowntorich"
    public let name = "Markdown → Rich Text"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.richText
    public let applicableKinds: Set<ContentKind>? = [.markdown]
    public let outputMode: OutputMode = .renderedMarkdown
    public init() {}
    /// Validates the buffer parses; the text is returned unchanged — the effect is the armed output mode.
    public func apply(_ input: TransformInput) async throws -> String {
        do { _ = try MarkdownHTML.render(input.text) } catch { throw TransformError.invalidInput("Couldn't parse this as Markdown") }
        return input.text
    }
}
```
Registry: insert `(11, "Rich → Markdown", RichToMarkdown())` and `(12, "Markdown → Rich Text", MarkdownToRich())` after the order-10 entry.

- [ ] **Step 4:** filters green; full suite green.
- [ ] **Step 5: Commit** `feat(core): Rich → Markdown and Markdown → Rich Text transforms; RTFD → Markdown converter`.

---

### Task 4: Document mode, coordinator arming, `RichOutputRenderer`

**Files:** Modify `Sources/PastefixAppCore/PasteDocument.swift`, `TransformCoordinator.swift`; Create `Sources/PastefixAppCore/RichOutputRenderer.swift`; Test `PasteDocumentTests`, `TransformCoordinatorTests` (extend), `RichOutputRendererTests` (new).

- [ ] **Step 1: Failing tests** (append to the existing suites in their style; new file for the renderer)
```swift
    // PasteDocumentTests
    @Test func outputModeDefaultsSurvivesPushResetsOnRefresh() {
        var d = PasteDocument(origin: ClipboardSnapshot(plainText: "a", richRTFD: nil))
        #expect(d.outputMode == .plain)
        d.outputMode = .renderedMarkdown; d.pushState("b")
        #expect(d.outputMode == .renderedMarkdown)
        d.refresh(origin: ClipboardSnapshot(plainText: "c", richRTFD: nil))
        #expect(d.outputMode == .plain)
    }
    // TransformCoordinatorTests
    struct Arming: OutputModeTransformer { let id = "t.arm"; let name = "Arm"; let requiresRichInput = false; let source = TransformerSource.builtin; let outputMode = OutputMode.renderedMarkdown; func apply(_ i: TransformInput) async throws -> String { i.text } }
    struct FailingArming: OutputModeTransformer { let id = "t.fail"; let name = "Fail"; let requiresRichInput = false; let source = TransformerSource.builtin; let outputMode = OutputMode.renderedMarkdown; func apply(_ i: TransformInput) async throws -> String { throw TransformError.invalidInput("no") } }
    @Test func armingTransformAppliesWithoutTextChange() async {
        let doc = PasteDocument(origin: ClipboardSnapshot(plainText: "# x", richRTFD: nil))
        let (out, outcome) = await TransformCoordinator.apply(Arming(), to: doc)
        #expect(outcome == .applied && out.outputMode == .renderedMarkdown && out.working == "# x" && !out.canUndo)
    }
    @Test func failingArmingLeavesModePlain() async {
        let doc = PasteDocument(origin: ClipboardSnapshot(plainText: "# x", richRTFD: nil))
        let (out, outcome) = await TransformCoordinator.apply(FailingArming(), to: doc)
        #expect(out.outputMode == .plain); if case .failed = outcome {} else { Issue.record("expected failure") }
    }
    // RichOutputRendererTests.swift
    @MainActor @Suite struct RichOutputRendererTests {
        @Test func rendersHTMLAndRTF() throws {
            let out = try RichOutputRenderer.render(markdown: "# Title\n\nsome **bold**")
            #expect(out.html.contains("<h1>Title</h1>") && out.html.contains("<strong>bold</strong>"))
            #expect(out.rtf.map { String(decoding: $0.prefix(5), as: UTF8.self) } == "{\\rtf")
        }
    }
```
- [ ] **Step 2:** filters → compile errors.
- [ ] **Step 3: Implement**
  - `PasteDocument`: `public var outputMode: OutputMode = .plain` (init sets `.plain`; `refresh` re-inits so it resets).
  - Coordinator `apply`: after `let result = try await transformer.apply(input)`:
    ```swift
    if let arming = transformer as? OutputModeTransformer { doc.outputMode = arming.outputMode }
    if result == doc.working { return (doc, transformer is OutputModeTransformer ? .applied : .unchanged) }
    ```
  - `RichOutputRenderer.swift`:
    ```swift
    import Foundation
    import AppKit
    import PastefixCore

    public struct RichOutput: Sendable { public let html: String; public let rtf: Data? }

    /// Renders the buffer for an armed `.renderedMarkdown` save. Main actor: AppKit's HTML importer is WebKit-backed.
    public enum RichOutputRenderer {
        @MainActor public static func render(markdown: String) throws -> RichOutput {
            let html = try MarkdownHTML.render(markdown)
            let attributed = NSAttributedString(html: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            let rtf = attributed.flatMap { try? $0.data(from: NSRange(location: 0, length: $0.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) }
            return RichOutput(html: html, rtf: rtf)
        }
    }
    ```
- [ ] **Step 4:** filters green; full suite green.
- [ ] **Step 5: Commit** `feat(appcore): PasteDocument.outputMode, coordinator arming, RichOutputRenderer`.

---

### Task 5: App — armed save, badge, tooltips

**Files:** Modify `Pastefix/Pastefix/ClipboardBridge.swift`, `AppModel.swift`, `PanelView.swift`.

- [ ] **Step 1: `ClipboardBridge`**
```swift
    /// Armed-Markdown save: formatted targets take HTML/RTF, plain targets get the Markdown source.
    static func writeRich(text: String, html: String, rtf: Data?, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(html, forType: .html)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }
```
- [ ] **Step 2: `AppModel`**
```swift
    func save() {
        guard let doc = document else { endSession(); return }
        if doc.outputMode == .renderedMarkdown {
            do {
                let rich = try RichOutputRenderer.render(markdown: doc.working)
                ClipboardBridge.writeRich(text: doc.working, html: rich.html, rtf: rich.rtf)
            } catch {
                errorMessage = "Couldn't render Markdown: \(error.localizedDescription)"
                return                                   // session stays open, mode stays armed
            }
        } else {
            ClipboardBridge.writePlain(doc.working)
        }
        endSession()
    }

    var isRichOutputArmed: Bool { document?.outputMode == .renderedMarkdown }
    func disarmRichOutput() { guard var doc = document else { return }; doc.outputMode = .plain; document = doc }
```
- [ ] **Step 3: `PanelView`** — in the action bar next to the Detected badge:
```swift
            if model.isRichOutputArmed {
                Button { model.disarmRichOutput() } label: {
                    Label("Rich text on save", systemImage: "textformat")
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("⌘S will paste as formatted text (HTML + RTF); plain-text targets get the Markdown source. Click to save plain text only.")
                .accessibilityLabel("Rich text on save; click to disarm")
            }
```
and on the Save button: `.help(model.isRichOutputArmed ? "Save as formatted text + Markdown source (⌘S)" : "Save to clipboard (⌘S)")`.
- [ ] **Step 4: Build** `xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:|BUILD"` → `BUILD SUCCEEDED`, no new warnings. `swift test` unchanged.
- [ ] **Step 5: Commit** `feat(app): armed Markdown save writes HTML + RTF + source; "Rich text on save" badge`.

---

### Task 6: Documentation

- [ ] README: under transforms, a "Markdown and rich text" subsection: Rich → Markdown (what it handles; tables flattened, images dropped), Markdown → Rich Text (arms; ⌘S writes HTML + RTF + source; badge; click to disarm), Detected: Markdown; Rich Text category.
- [ ] AGENTS.md: Invariant 8 orders `10–12/20/…`; layout entries (`Markdown/`, `Detection/MarkdownDetector.swift`, `RichOutputRenderer.swift`); Patterns: "`OutputModeTransformer` is the only channel by which a transform influences Save; render at save time from the live buffer, never cache rendered output on the document"; status row Plan 8 (🟡 in progress). No bitten-us entries (controller adds).
- [ ] Banner of this plan → 🟡 IN PROGRESS. Commit `docs: Markdown ↔ rich text — README, AGENTS invariant 8 + output-mode pattern`.

---

### Task 7: Automated app pass (controller) and finish

- [ ] Build Debug to `/tmp/pastefix-dd`; quit any Pastefix.
- [ ] Put `# Title\n\nsome **bold** text\n\n- a\n- b` on the pasteboard → ⌘⇧C → Detected badge includes "Markdown" (AX read or screenshot) → ⌘K, type "markdown", ↵ → badge "Rich text on save" → ⌘S → `pb types` shows `public.html`, `public.rtf`, `public.utf8-plain-text`; `pbpaste` == source; `pbpaste -Prefer html`/`osascript -e 'the clipboard as «class HTML»'` contains `<h1>Title</h1>`.
- [ ] Put rich text on the pasteboard (helper `rich` case) → ⌘⇧C → ⌘K "rich → markdown" ↵ → editor contains `**Bold words**` (verify via ⌘S + pbpaste).
- [ ] Load a rich history item via ⌘⇧V ↵ → Rich → Markdown works.
- [ ] Badge click disarms (AX or ⌘S then check types are plain only after disarm via a second run). New session resets.
- [ ] Final whole-branch review, one fix wave, AGENTS "bitten us", push, PR closing #16, `git checkout main`.

---

## Self-review

- **Spec coverage:** engine types/category/detection (T1); renderer (T2); converter + transforms + registry (T3); document/coordinator/renderer-to-RTF (T4); save path + badge + tooltips (T5); docs (T6); automated pass (T7).
- **Type consistency:** `OutputMode.renderedMarkdown`, `OutputModeTransformer.outputMode`, `MarkdownHTML.render(_:)`, `MarkdownFromRich.convert(rtfd:)`/`convert(_:)`, `MarkdownDetector.looksLikeMarkdown(_:)`, `ContentKind.markdown`, `TransformCategory.richText`, `PasteDocument.outputMode`, `RichOutputRenderer.render(markdown:) -> RichOutput(html:rtf:)`, `ClipboardBridge.writeRich(text:html:rtf:)`, `AppModel.isRichOutputArmed/disarmRichOutput()` — used identically across tasks.
- **Placeholders:** the table `<tbody>` handling in T2 is called out explicitly with the expected HTML as the contract; everything else is concrete.
