---
type: spec
status: approved
id: 2026-09-21-pastefix-v2-markdown-rich-text
title: Pastefix v2 — Markdown ↔ Rich Text (Plan 8)
description: Rich → Markdown transform over the clipboard's RTFD; Markdown → Rich Text transform that arms an output mode so Save writes HTML + RTF + the Markdown source; Markdown content detection; a Foundation-only Markdown → HTML renderer; a "Rich Text" transform category.
tags: [pastefix, macos, swift, markdown, rich-text, transforms]
timestamp: 2026-09-21T06:00:00Z
---

# Pastefix v2 — Markdown ↔ Rich Text (Plan 8)

Source: [issue #16](https://github.com/bnaylor/pastefix/issues/16). Builds on Plan 3's
detection/kinds machinery, Plan 6's rich history items (which now feed Rich → Markdown),
and Plan 6's multi-type `ClipboardBridge.write`.

## Scope

**In scope:**

- **Engine:** `OutputMode` (`.plain`, `.renderedMarkdown`) and `OutputModeTransformer`
  (a `Transformer` that also names an output mode). `TransformCategory.richText`
  ("Rich Text"), ordered after Layout; Rich → Plain Text moves into it.
- **`MarkdownHTML.render(_:)`** (PastefixCore, Foundation only): CommonMark + GFM
  tables via `AttributedString(markdown:)` in `.full` mode, walked by presentation intent
  into an HTML fragment. Headings, paragraphs, ordered/unordered/nested lists, fenced and
  indented code blocks (language class preserved), block quotes, thematic breaks, tables,
  links, images, emphasis, strong, strikethrough, inline code, hard and soft breaks.
  HTML-escaped throughout.
- **`MarkdownFromRich.convert(rtfd:)`** (PastefixCore): RTFD → GitHub-flavoured Markdown.
  Headings from `headerLevel` (HTML-imported text) or a size/weight heuristic (RTF);
  bullet/numbered lists from `NSTextList` with nesting; bold, italic, strikethrough,
  links; inline code from monospaced runs and fenced blocks from monospaced paragraphs.
  Tables flattened to lines; attachments (images) dropped.
- **Transforms:** `RichToMarkdown` (`builtin.richtomarkdown`, order 11,
  `requiresRichInput`), `MarkdownToRich` (`builtin.markdowntorich`, order 12,
  `applicableKinds: [.markdown]`, `outputMode = .renderedMarkdown`; validates the buffer
  parses, returns it unchanged).
- **Detection:** `ContentKind.markdown` ("Markdown"), conservative heuristic.
- **Document/coordinator:** `PasteDocument.outputMode` (default `.plain`, reset per
  session); the coordinator sets it from an `OutputModeTransformer` and reports
  `.applied` even when the text is unchanged.
- **Save:** with `.renderedMarkdown` armed, Save writes `public.html` (the rendered
  fragment), `public.rtf` (AppKit conversion of that HTML), and `public.utf8-plain-text`
  (the Markdown source). Otherwise unchanged.
- **UI:** action-bar badge "Rich text on save" (click to disarm) while armed; Save
  tooltip states what will be written; Detected badge shows "Markdown".
- README, AGENTS (Invariant 8 orders, Rich Text category, output-mode protocol), spec.

**Out of scope:** rendering Markdown *into the editor*; a Markdown preview; tables and
images in Rich → Markdown (flattened/dropped, stated in copy); HTML source on the
clipboard as an input path (we consume the RTFD AppKit derives from it); footnotes,
task-list checkboxes, math; making the rendered HTML themable.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| How Markdown → rich reaches the pasteboard | A transform arms `outputMode`; the *normal* ⌘S renders at save time | User's call. Editor keeps the Markdown source; edits after arming can't go stale because rendering happens from the current buffer at Save. |
| Where the mode lives | `PasteDocument.outputMode`, not undo history | It's a save preference for this session, not a text state; a new session resets it. Disarm via the badge. |
| Plain-text representation when armed | The Markdown source | Matches what browsers put alongside HTML; plain targets get exactly what the editor shows. |
| Parser | Foundation `AttributedString(markdown:options: .full)` | No third-party deps; supports blocks, GFM tables, links, images. `failurePolicy: .returnPartiallyParsedIfPossible` so a stray construct never blocks a save. |
| HTML → RTF | `NSAttributedString(html:)` in the app/AppCore at save time (main thread) | AppKit's importer applies a sane default stylesheet; RTF is what older AppKit targets want, HTML what modern ones want — write both. |
| Rich → Markdown source | The session's `origin.richRTFD` (same input as Rich → Plain) | One rich input path; history items already carry RTFD. |
| Heading heuristic for RTF | `headerLevel` if > 0; else paragraph entirely bold and size ≥ 1.8× body → `#`, ≥ 1.4× → `##`, ≥ 1.15× → `###` (body = most frequent point size) | RTF has no semantic headings; size tiers are what humans read as headings. |
| Lists | `NSTextList` depth → indent 2 spaces per level; marker format containing `decimal` → `N.` (counter per list object), else `-`; leading marker glyphs/tabs stripped from the text | Mirrors how AppKit represents imported lists. |
| Code | Font symbolic trait `.monoSpace` or family name containing Menlo/Monaco/Courier/Mono → inline backticks; whole paragraph mono → fenced block, consecutive merged | Best available signal in RTF. |
| Detection heuristic | Markdown if any line starts with an ATX heading (`#{1,6} `) or a fence, **or** ≥ 2 distinct signals among {list line, `> ` quote, pipe-table row, `[text](url)` link, `**strong**`/`` `code` `` inline}. Scan capped at the first 64 KB / 400 lines | Conservative: prose with one asterisk or a lone URL never lights up. |
| Category | New "Rich Text" after Layout: Rich → Plain (10), Rich → Markdown (11), Markdown → Rich Text (12) | The three belong together; Rich → Plain in Characters was a historical accident. |
| Coordinator outcome for an arming transform | `.applied` even if text unchanged (badge appears; error bar clears) | An `unchanged` outcome would be invisible. |
| Rendering failures at save | Fall back to plain-text save and show the error bar message "Couldn't render Markdown — saved plain text" *before* hiding? No: render first; on failure keep the session open with the error bar | The user asked for rich; silently downgrading would surprise. |

## Architecture

### PastefixCore

```swift
public enum OutputMode: String, Sendable, Equatable { case plain, renderedMarkdown }
public protocol OutputModeTransformer: Transformer { var outputMode: OutputMode { get } }

public enum TransformCategory { … static let richText = "Rich Text"; builtinOrder = [layout, richText, characters, urls, `case`, data, colors] }

public enum MarkdownHTML {
    public static func render(_ markdown: String) throws -> String          // fragment
    static func render(_ attributed: AttributedString) -> String            // testable core
}
public enum MarkdownFromRich {
    public static func convert(rtfd: Data) throws -> String
    static func convert(_ attributed: NSAttributedString) -> String         // testable core
}
public enum MarkdownDetector { public static func looksLikeMarkdown(_ text: String) -> Bool }
// ContentKind.markdown, displayName "Markdown"; ContentDetector inserts it.

public struct RichToMarkdown: Transformer   // id builtin.richtomarkdown, name "Rich → Markdown", requiresRichInput, category richText
public struct MarkdownToRich: OutputModeTransformer   // id builtin.markdowntorich, name "Markdown → Rich Text", applicableKinds [.markdown], outputMode .renderedMarkdown
```
`MarkdownToRich.apply` runs `MarkdownHTML.render` to validate (throws →
`invalidInput("Couldn't parse this as Markdown")`) and returns `input.text` unchanged.

Renderer algorithm: iterate `attributed.runs`; each run's `presentationIntent.components`
(innermost first) is reversed to outermost-first; diff against the currently open stack;
close the divergent tail (innermost first), open the new components, emit the run's inline
HTML. Paragraph tags are suppressed directly inside list items (tight lists). Table cells
are `<th>` under a header row, `<td>` otherwise. Inline: `imageURL` → `<img>`; `link` →
`<a>`; intents `.code`/`.stronglyEmphasized`/`.emphasized`/`.strikethrough` → `<code>`,
`<strong>`, `<em>`, `<del>`; `.lineBreak` → `<br>`; `.softBreak` → newline. Text inside
code blocks is escaped but not inline-wrapped.

### PastefixAppCore

```swift
public struct PasteDocument { … public var outputMode: OutputMode = .plain }
// TransformCoordinator.apply: after a successful apply,
//   if let t = transformer as? OutputModeTransformer { doc.outputMode = t.outputMode; unchanged text still → .applied }
public struct RichOutput: Sendable { public let html: String; public let rtf: Data? }
public enum RichOutputRenderer { @MainActor public static func render(markdown: String) throws -> RichOutput }
```
`RichOutputRenderer` calls `MarkdownHTML.render`, then
`NSAttributedString(html:options:documentAttributes:)` → `.rtf` data (nil if AppKit can't
convert; HTML alone still goes out).

### Pastefix app

- `ClipboardBridge.writeRich(text:html:rtf:)`: `clearContents`, `setString(text, .string)`,
  `setString(html, .html)`, `setData(rtf, .rtf)` when present.
- `AppModel.save()`: if `document.outputMode == .renderedMarkdown`, render; on success
  `writeRich` + `endSession()`; on failure set `errorMessage` and keep the session. Else
  `writePlain`. `func disarmRichOutput()` sets `.plain`.
- `PanelView` action bar: when armed, a capsule badge button "Rich text on save"
  (`textformat` symbol) with `.help("⌘S will paste as formatted text (HTML + RTF); plain-text targets get the Markdown source. Click to save plain text only.")`; Save button `.help` reflects the mode.
- Detected badge already renders any kind's `displayName`.

## Data flow

Copy a formatted email → ⌘⇧C → palette → Rich → Markdown → editor shows Markdown →
edit → ⌘S plain. Or: write Markdown in the editor (badge: "Detected: Markdown") → ⌘K
"markdown" → Markdown → Rich Text (promoted; badge "Rich text on save" appears, text
unchanged) → keep editing → ⌘S → pasteboard has HTML + RTF + source → paste into Mail:
formatted; paste into Terminal: the Markdown.

## Error handling

- Rich → Markdown with no rich input: existing `richInputUnavailable` message.
- Markdown → Rich Text on text the parser rejects entirely: `invalidInput`; partial
  parses succeed (Foundation's policy) so this is rare.
- Save with armed mode and a render failure: error bar, session stays open, mode stays
  armed so the user can disarm or fix.
- `NSAttributedString(html:)` returning nil: write HTML + plain without RTF (logged).

## Testing

`Tests/PastefixCoreTests/`:
- `MarkdownHTMLTests` (renderer core, exact HTML): heading levels; paragraph with strong/em/
  code/strike/link; image; tight unordered and ordered lists; nested list; fenced block
  with language and escaping of `<`; indented code; block quote; thematic break; GFM
  table with header; hard break; HTML escaping of `&`, `<`, `"` in text and attributes;
  partially malformed document still renders. (Expectations are written against
  Foundation's actual run segmentation; the implementer verifies each with a scratch run
  first and reports any semantic surprise.)
- `MarkdownFromRichTests` (attributed fixtures): headerLevel → `#`; size heuristic;
  bullet list with two levels; numbered list; bold/italic with trailing-space handling;
  link; inline mono → backticks; mono paragraphs → one fenced block; strikethrough;
  attachment dropped; table block flattened; RTFD round trip via `convert(rtfd:)`.
- `MarkdownDetectorTests`: positives (heading, fence, list+link, quote+strong, table) and
  negatives (prose, lone URL, `a * b * c`, JSON, a single `- item` line, 2 MB text).
- `ContentDetectorTests`: `.markdown` inserted; `.url` and `.markdown` can coexist.
- Transformer tests: `RichToMarkdown` on an RTFD fixture; `MarkdownToRich` returns input
  unchanged and exposes `.renderedMarkdown`; registry contains both at orders 11/12 in
  category Rich Text; Rich → Plain now in Rich Text.

`Tests/PastefixAppCoreTests/`:
- `PasteDocument.outputMode` default, survives `pushState`, resets on `refresh`.
- Coordinator: arming transform → `.applied` with unchanged text and mode set; ordinary
  transform leaves the mode alone; a failing arming transform leaves it `.plain`.
- `RichOutputRenderer` (main actor): html non-empty and contains `<h1>`; rtf non-nil and
  begins with `{\rtf`.
- Sidebar grouping puts Rich Text second.

Automated app pass (controller): type Markdown in the editor via keystrokes → Detected:
Markdown; ⌘K "markdown" ↵ → badge; ⌘S → `pb types` include `public.html`, `public.rtf`,
`public.utf8-plain-text`; `pbpaste` gives the source; the HTML contains `<h1>`; load a
rich history item → Rich → Markdown produces headings/lists; badge click disarms; new
session resets. Visual: badge appearance.

## Documentation

- README: "Markdown and rich text" subsection under transforms (both directions, what
  Save writes, the flatten/drop limits).
- AGENTS.md: Invariant 8 orders gain `11/12`; Rich Text category; a Patterns note on
  `OutputModeTransformer` (the only way a transform influences Save; keep it that way);
  layout entries; status row.

## Project layout delta

```
Sources/PastefixCore/
  Transformer.swift                    # OutputMode, OutputModeTransformer, TransformCategory.richText
  Detection/ContentKind.swift          # .markdown
  Detection/ContentDetector.swift      # inserts .markdown
  Detection/MarkdownDetector.swift     # heuristic
  Markdown/MarkdownHTML.swift          # renderer
  Markdown/MarkdownFromRich.swift      # RTFD → Markdown
  Native/RichToPlain.swift             # category → richText
  Native/RichToMarkdown.swift
  Native/MarkdownToRich.swift
  Discovery/TransformerRegistry.swift  # orders 11, 12
Sources/PastefixAppCore/
  PasteDocument.swift                  # outputMode
  TransformCoordinator.swift           # arming
  RichOutputRenderer.swift             # HTML → RTF
Pastefix/Pastefix/
  ClipboardBridge.swift                # writeRich
  AppModel.swift                       # save path, disarm
  PanelView.swift                      # badge, tooltips
```
