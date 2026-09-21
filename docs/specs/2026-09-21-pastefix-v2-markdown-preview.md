---
type: spec
status: approved
id: 2026-09-21-pastefix-v2-markdown-preview
title: Pastefix v2 — Markdown Preview in the Panel (Plan 10)
description: A toggleable, read-only rendered preview of the working buffer that reuses the Plan 8 Markdown → HTML renderer and AppKit's HTML importer; ⌘⇧M swaps the editor area for the preview; no network, dark-mode aware, debounced, size-capped.
tags: [pastefix, macos, swift, markdown, preview]
timestamp: 2026-09-21T10:00:00Z
---

# Pastefix v2 — Markdown Preview in the Panel (Plan 10)

Source: [issue #15](https://github.com/bnaylor/pastefix/issues/15). Builds on Plan 8
(`MarkdownHTML`, `RichOutputRenderer.htmlForRTF`, `ContentKind.markdown`).

## Scope

**In scope:**

- `MarkdownPreview.attributedString(markdown:)` in `PastefixAppCore`: Markdown → HTML
  (existing renderer) → images stripped (existing helper) → a prepended stylesheet →
  `NSAttributedString(html:)` → foreground colours stripped (link colour kept) so the view
  follows the system appearance. Input capped at 64 KB; over the cap returns a notice
  attributed string instead of rendering.
- A read-only, selectable preview view (`MarkdownPreviewView`, `NSViewRepresentable` over
  `NSTextView`) that replaces the editor area while previewing.
- Toolbar **Preview** toggle, **⌘⇧M**; tinted when `.markdown` is detected; disabled while an
  overlay is open or a transform is applying. Per-session state (a new summon starts in the
  editor). Esc while previewing returns to the editor.
- Re-render on buffer changes, debounced 150 ms; transforms/undo/redo while previewing update
  the preview.
- README line, AGENTS layout entry, spec.

**Out of scope:** side-by-side split; editing in the preview; images in the preview (stripped,
as for RTF); syntax highlighting in code blocks; a WebKit view.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Renderer | HTML importer into `NSTextView`, not `WKWebView` | Same pipeline the armed save uses; no network by construction (images stripped); no web view in a menu-bar app. |
| Layout | Toggle replacing the editor; no split | 560 pt minimum width (plus a 220 pt sidebar) can't hold two readable columns; the issue asks for read-only. |
| Prominence | Button always enabled; tinted (accent) when `.markdown` detected | Any text can be previewed; detection makes it a suggestion, not a gate. |
| Appearance | Strip `.foregroundColor` from the imported string except on `.link` runs; text view uses `labelColor`; stylesheet sets `-apple-system` 13 pt body, Menlo 12 pt code, heading sizes 22/18/15, blockquote left inset | The importer bakes black text; without stripping, dark mode shows black-on-dark. |
| Cost | Debounce 150 ms; cap 64 KB (notice above); render on the main actor (importer requirement) | Clipboard sizes are instant; 200 KB measured ~2.8 s in Plan 8, so cap well below. |
| Keys | ⌘⇧M toggle; Esc closes the preview first | Consistent with the other Esc arbitration (palette → history → preview → cancel). |
| Focus | Closing the preview returns focus to the editor | Same rule as the overlays. |

## Architecture

### PastefixAppCore

```swift
public enum MarkdownPreview {
    public static let maxBytes = 65_536
    /// Main actor: AppKit's HTML importer is WebKit-backed.
    @MainActor public static func attributedString(markdown: String) -> NSAttributedString
    static let stylesheet: String            // <style>…</style> prepended to the fragment
    static func stripForegroundColors(_ s: NSMutableAttributedString)   // keeps colour on runs with .link
}
```
`attributedString` returns a plain notice ("Preview is limited to 64 KB of Markdown.") when
over the cap, and a plain rendering of the raw text when `MarkdownHTML.render` throws or the
importer returns nil.

### Pastefix app

- **`MarkdownPreviewView.swift`** (new): `NSViewRepresentable` wrapping an `NSScrollView` +
  `NSTextView` (`isEditable = false`, `isSelectable = true`, `drawsBackground = false`,
  `textContainerInset = (8, 8)`, `textColor = .labelColor`); `updateNSView` sets
  `textStorage` when the attributed string changes.
- **`PanelView`**: `@State isPreviewing = false`, `@State previewText: NSAttributedString`,
  `@State previewTask: Task<Void, Never>?`. Editor area: `if isPreviewing { MarkdownPreviewView(text: previewText) } else { TextEditor… }`.
  Re-render: `.onChange(of: model.document?.working)` (and on `isPreviewing` becoming true)
  cancels `previewTask` and schedules a 150 ms sleep then `MarkdownPreview.attributedString`.
  Toolbar button `Button { togglePreview() } label: { Image(systemName: "eye") }` with
  `.tint(model.document?.detectedKinds.contains(.markdown) == true ? .accentColor : nil)`,
  `.help("Preview as Markdown (⌘⇧M)")`, shortcut nil while an overlay is open, `.disabled(model.document == nil || model.isApplying)`.
  `escape()`: palette → history → `isPreviewing = false; editorFocused = true` → cancel.
  Session end/new summon (`sessionGeneration` change) resets `isPreviewing`.

## Error handling

- Render throw / importer nil → raw text shown monospaced (never an empty preview).
- Over cap → notice.
- `isApplying`: preview stays visible; re-renders when the transform lands.

## Testing

`Tests/PastefixAppCoreTests/MarkdownPreviewTests` (`@MainActor`): heading run has a larger
font than body; inline code run uses a monospaced font; no run carries a foreground colour
except link runs; a `[x](https://a.b)` run keeps `.link`; over-cap input returns the notice;
malformed input still returns non-empty text; an `<img>` in the Markdown produces no
attachment (no network path).

Automated app pass: put Markdown on the clipboard → ⌘⇧C → ⌘⇧M → screenshot shows rendered
headings/list; type in the editor → toggle → updated; Esc returns to the editor (panel still
open); second Esc cancels; ⌘K still opens over the preview; new summon starts in the editor.

## Documentation

- README: one paragraph under "Markdown and rich text": Preview button / ⌘⇧M, read-only,
  images not shown, 64 KB cap.
- AGENTS.md: layout entries (`MarkdownPreview.swift`, `MarkdownPreviewView.swift`); a
  Patterns note that the preview shares the RTF pipeline's image stripping and must keep it;
  status row.

## Project layout delta

```
Sources/PastefixAppCore/MarkdownPreview.swift      # new
Pastefix/Pastefix/MarkdownPreviewView.swift        # new
Pastefix/Pastefix/PanelView.swift                  # toggle, state, Esc arbitration
```
