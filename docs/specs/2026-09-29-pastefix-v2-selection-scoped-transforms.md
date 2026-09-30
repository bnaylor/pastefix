# Selection-scoped transforms (#25)

**Status:** approved design, 2026-09-29, revised after the `work` session's review (measured on main d292a6e). Owner decisions are marked **(owner)**.

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
   most **8 KB**, its "applicable first" ranking uses the kinds detected in the selection, frozen for
   that palette session as today. Over 8 KB it ranks by the buffer. (8 KB, not the 64 KB first
   proposed: detection measured **~40 ms worst at 64 KB**, debug and release — a visible hitch as ⌘K
   opens — and it is linear, so 8 KB is ~5 ms. It can't move off-main: kinds landing after the
   palette opened would reorder rows under the cursor, the bug `kindsSnapshot` exists to prevent.
   AGENTS.md's "no detection on the main actor" rule gets this bounded exception, with the number.)
5. **Whole buffer, as today, when:** there is no selection (a caret), the selection has more than
   one range (⌘-drag), the selection is the whole buffer (select-all), or no editor is on screen (an
   image entry, the large-text placeholder). One predicate decides this — *the scoping selection* —
   and both the hint and apply use it, so they can't disagree.
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

- `PanelView` derives the **scoping selection** from its own `editorSelection` state — never from
  the binding getter, which returns the marked range mid-composition — as a single, non-empty,
  expressible range that isn't the whole buffer. It calls `model.apply(transformer, scope:)` with a
  `TransformScope { range: NSRange (UTF-16), expected: String }`: the range, and the text it covers
  *now*. Both the palette and the sidebar go through this.
- `AppModel.apply` passes the scope to `TransformCoordinator.apply(_:to:scope:)`.
- UTF-16 offsets, not `String.Index`: an index is only meaningful in the string it was taken from,
  and applying one to another string traps (the #111 caret crash).
- **Staleness is checked by content, not bounds.** The text can change between the click and the
  apply: `apply` ends a live IME composition first (`settleComposition`, which can drop a dead-key
  accent), and a late binding echo can land. A range can still convert in bounds and cover
  different characters, so `Range(_:in:)` succeeding proves nothing. At apply time — *after*
  `settleComposition` — the coordinator scopes only if `text[range] == scope.expected`. If not, the
  apply is **refused** with "The selection changed before \(name) could run. Select the text
  again." — not silently widened to the whole buffer.

### Coordinator

`TransformCoordinator.apply(_ transformer:, to document:, scope: NSRange? = nil)` returns the
existing `(PasteDocument, TransformOutcome)` plus the **selected span after** the apply
(`NSRange?`).

A transform scopes when: the scope is valid, the current entry is text, `requiresRichInput` is
false, and the transformer is not an `OutputModeTransformer`. Then:

- **Input:** `TransformInput(text: selectedText, richRTFD: origin.richRTFD)`. The existing input
  cap is measured on the selection, with the existing message shape: "\(name) is limited to N of
  text." 
- **Result:** `.text(r)` is spliced over the range: `prefix + r + suffix`. The whole new text is
  pushed as **one** entry, so undo stays one step. The span after is `NSRange(location:
  range.location, length: r.utf16.count)`.
- **Outcomes keep their meaning.** An identical result is `.unchanged`; `.nothingToDo` and
  `.failed` leave the document untouched; `.appliedWithNote` carries its note.
- **Non-text results:** a text transform can't return `.image`. If one ever does from a scoped run,
  that's `.failed` with a clear message: an image can't be spliced into text.

Otherwise, the transform runs on the whole buffer exactly as today, and the span after is nil.

Transformers, scripts and presets are unchanged: they just receive a smaller input.

### Model: selection after, and undo — one owner

Measured on main: after a length-changing apply, `carrySelection` keeps the raw UTF-16 offsets
(selected "ccc" at 13,3 became 11,0 after Whitespace Cleanup), and ⌘Z/⌘⇧Z leave the selection
wherever it was. So re-selection is all new, and it must not race `carrySelection`: that and the
`requestedSelection` handler fire in the same transaction in an order SwiftUI doesn't define, and
the landing path's `resetSecretSelection()` clears `requestedSelection` in the same turn.

- **One owner.** `AppModel` publishes `pendingSelection: (range: NSRange, revision: Int)?` — the
  span to select, in UTF-16, and the `detectionRevision` of the buffer it indexes. It is *not*
  `requestedSelection`, and `resetSecretSelection()` doesn't touch it.
- `PanelView.carrySelection` (the `onChange(of: working)` handler) consumes it: when a pending span's
  revision matches the document's, it selects that span — built into a `TextSelection` against the
  text it indexes — **instead of** remapping, and clears it. Otherwise it remaps as today. No
  ordering between handlers is involved.
- **Focus, then select.** The landing refocus (`onChange(isApplying)` → focus the editor) can make
  the NSTextView restore the selection it resigned with (#111 pass 5), overwriting the span. So the
  pending span is applied on the turn after the refocus: the consume step, when the editor wasn't
  first responder, focuses first and sets the selection a turn later.
- **Undo.** The transform's undo step (`TransformStep`) records the scope range before and the span
  after. `stepBack` (⌘Z) sets `pendingSelection` to the original range for the revision the undo
  produced; `stepForward` (⌘⇧Z) the span after. A step without a scope sets nothing, as today. A
  scoped apply that changed nothing pushes no step (the #111 rule), so no spans are assumed.
- **With the preview or an overlay up**, a pending span is dropped (the editor isn't on screen, or
  focus belongs to the overlay) — ⌘Z/⌘⇧Z from the toolbar under the preview restore text but not the
  selection. Accepted.
- **Mid-composition:** a scoped apply that ends a live composition also empties the undo stack
  (#111's rule); the new step's ⌘Z works, earlier history is gone, as today.

### Palette and sidebar

- `PanelView` exposes whether a **scoping selection** exists: single range, non-empty, in an editor
  on screen. It passes this to `CommandPaletteView` and `SidebarView`.
- **Hint:** "Applies to selection" in the palette footer, and as a caption at the top of the
  sidebar list — shown exactly when a scoping selection exists (so not for select-all, a caret, or
  a multi-range selection). Whole-only transforms get a "whole buffer" subtitle (palette row) or suffix
  (sidebar row) while the hint shows.
- **Ranking:** on `onAppear`, `kindsSnapshot` is `ContentDetector.detect(selectedText)` when a
  scoping selection of at most 8 KB exists, else the document's kinds as today (see decision 4).

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
- A stale scope — in bounds but `expected` no longer matches, and out of bounds — refused with the
  "selection changed" sentence, document untouched.
- `.unchanged`, `.nothingToDo` and `.failed` with a scope.
- A scope on an image entry being ignored.

**Hosted app tests:**
- A real editor selection plus a transform changes only the span, and the span ends up selected —
  for a result shorter and longer than the selection (the measured `carrySelection` failure).
- ⌘Z restores the text and re-selects the original span; ⌘⇧Z re-selects the new one.
- `pendingSelection` wins regardless of handler order, and survives `resetSecretSelection()`.
- A scope whose text changed before apply (simulated: the model's text edited after the range was
  taken) is refused.
- Select-all and multi-range don't scope, and don't show the hint.
- No selection behaves as today (a regression pin).
- The palette ranks by the selection's kinds (select a URL inside prose).

**GUI pass (the `work` session, asserting exact spans with its `AXSelectedTextRange` probe):**
- The hint, and the "whole buffer" subtitles.
- ⌘K with a selection: the selection survives the palette taking focus.
- A sidebar click keeps the selection.
- Chaining two transforms on one span.
- ⌘Z and ⌘⇧Z selection restore.
- A dead-key composition in or next to the selection, then a transform: refused or scoped
  correctly, never the wrong characters.
- A drag-select plus a transform.
- Multi-range and whole-buffer fallbacks.
