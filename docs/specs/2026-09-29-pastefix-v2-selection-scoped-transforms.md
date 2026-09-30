# Selection-scoped transforms (#25)

**Status:** approved design, 2026-09-29. Owner decisions are marked **(owner)**.

## Goal

When part of the buffer is selected, a transform changes only that part: prettify one JSON blob
inside a Slack message, unwrap one paragraph, decode the JWT in a log line. With no selection,
nothing changes from today.

## Decisions

1. **Automatic, with a hint (owner).** A single, non-empty selection scopes the transform. The
   palette footer and the sidebar header say **"Applies to selection"** while one exists.
2. **Whole-only transforms stay listed and run on the whole buffer (owner).** Rich → Plain Text,
   Rich → Markdown and Markdown → Rich Text can't scope: the first two convert the origin's rich
   copy, and the third arms Save for the whole buffer. While a selection exists they show a
   **"whole buffer"** subtitle, and they run exactly as today.
3. **The replacement stays selected (owner).** After a scoped apply, the new text is selected, so
   transforms chain on the same span. ⌘Z restores the original text *and* re-selects the original
   span; ⌘⇧Z re-selects the new one.
4. **Palette ranking follows the selection (owner).** When ⌘K opens with a scoping selection of at
   most 64 KB, its "applicable first" ranking uses the kinds detected in the selection, frozen for
   that palette session as today. Over 64 KB it ranks by the buffer.
5. **Whole buffer, as today, when:** there is no selection (a caret), the selection has more than
   one range (⌘-drag), or no editor is on screen (an image entry, the large-text placeholder).
6. **Unchanged:** Save, ⌘⇧U upload, the Secrets badge and the `Detected:` label all stay about the
   whole buffer. They describe what leaves the panel.
7. **Image transforms** never see a selection (they only run on an image entry, which has no editor).

## Design

### Where the selection travels

The live selection stays `PanelView`'s `@State`. It is **not** put on the model or on
`PasteDocument`, although #25 suggested that: selection state on `AppModel` has already caused
harm once (republishing it re-rendered the panel and took first responder from the ⌘K field; see
`AppModel.requestedSelection`).

Instead, apply takes the scope as an argument:

- `PanelView` converts its selection to a **UTF-16 `NSRange`** in the current buffer, but only if
  it is a single, non-empty range that `TextRangeClamp` finds expressible in the text. It then
  calls `model.apply(transformer, scope: NSRange?)`. Both the palette and the sidebar go through
  this.
- `AppModel.apply` passes the scope to `TransformCoordinator.apply(_:to:scope:)`.
- UTF-16 offsets, not `String.Index`: an index is only meaningful in the string it was taken from,
  and applying one to another string traps (the #111 caret crash). The coordinator converts the
  range with `Range(_:in:)` against the document's text **at apply time**. If it doesn't convert,
  or it's out of bounds, the scope is dropped and the transform runs on the whole buffer.

### Coordinator

`TransformCoordinator.apply(_ transformer:, to document:, scope: NSRange? = nil)` returns the
existing `(PasteDocument, TransformOutcome)` plus the **selected span after** the apply
(`NSRange?`).

A transform scopes when: the scope is valid, the current entry is text, `requiresRichInput` is
false, and the transformer is not an `OutputModeTransformer`. Then:

- **Input:** `TransformInput(text: selectedText, richRTFD: origin.richRTFD)`. The existing input
  cap is measured on the selection. Its refusal message says "the selection is limited to …".
- **Result:** `.text(r)` is spliced over the range: `prefix + r + suffix`. The whole new text is
  pushed as **one** entry, so undo stays one step. The span after is `NSRange(location:
  range.location, length: r.utf16.count)`.
- **Outcomes keep their meaning.** An identical result is `.unchanged`; `.nothingToDo` and
  `.failed` leave the document untouched; `.appliedWithNote` carries its note.
- **Non-text results:** a text transform can't return `.image`. If one ever does from a scoped run,
  that's `.failed` with a clear message: an image can't be spliced into text.

Otherwise, the transform runs on the whole buffer exactly as today, and the span after is nil.

Transformers, scripts and presets are unchanged: they just receive a smaller input.

### Model: selection after, and undo

- After a scoped apply that pushed an entry, `AppModel` sets `requestedSelection` to the span after,
  converted into the new text. It's the one-shot request `PanelView` already consumes for the
  Secrets badge. It must be applied **after** `carrySelection` has run for the buffer change, so
  it wins.
- The transform's undo step (`TransformStep`) records the scope before and the span after. On
  `stepBack` (⌘Z), after the model undo, it requests the original span. On `stepForward` (⌘⇧Z), it
  requests the span after. A step without a scope requests nothing, as today.
- While a request is pending and an overlay is up, the existing rule applies (the request is
  dropped rather than taking focus from the overlay).

### Palette and sidebar

- `PanelView` exposes whether a **scoping selection** exists: single range, non-empty, in an editor
  on screen. It passes this to `CommandPaletteView` and `SidebarView`.
- **Hint:** "Applies to selection" in the palette footer, and as a caption at the top of the
  sidebar list. Whole-only transforms get a "whole buffer" subtitle (palette row) or suffix
  (sidebar row) while the hint shows.
- **Ranking:** on `onAppear`, `kindsSnapshot` is `ContentDetector.detect(selectedText)` when a
  scoping selection of at most 64 KB exists, else the document's kinds as today. Detection on 64 KB
  is well inside what the main actor can afford: `ContentDetector` is linear, and the summon path
  already runs it at up to 1 MB off-main.

## Out of scope

- Multi-range selections applied range by range.
- Scoping the Secrets badge, Save or upload to the selection.
- A preference to turn scoping off.

## Testing

**Package (`TransformCoordinatorTests`):**
- A splice at the start, middle and end of the text.
- Multi-byte text and emoji at the range edges, where UTF-16 and grapheme boundaries differ.
- The span after, for a result that is longer, shorter or empty.
- The input cap measured on the selection: a selection under the cap in an over-cap buffer runs,
  and one over the cap is refused naming the selection.
- Whole-only transforms (rich input, output mode) ignoring the scope.
- A stale or out-of-bounds range falling back to the whole buffer.
- `.unchanged`, `.nothingToDo` and `.failed` with a scope.
- A scope on an image entry being ignored.

**Hosted app tests:**
- A real editor selection plus a transform changes only the span, and the span ends up selected.
- ⌘Z restores the text and re-selects the original span; ⌘⇧Z re-selects the new one.
- No selection behaves as today (a regression pin).
- The palette ranks by the selection's kinds (select a URL inside prose).

**GUI pass (the `work` session):**
- The hint, and the "whole buffer" subtitles.
- ⌘K with a selection: the selection survives the palette taking focus.
- A sidebar click keeps the selection.
- Chaining two transforms on one span.
- ⌘Z and ⌘⇧Z selection restore.
- A drag-select plus a transform.
- Multi-range and whole-buffer fallbacks.
